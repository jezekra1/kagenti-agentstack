#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AGENTSTACK_ADMIN_USER=admin
AGENTSTACK_ADMIN_PASSWORD=admin
KAGENTI_ADMIN_USER=admin
KAGENTI_ADMIN_PASSWORD=admin

OLD_PATH="${PATH}"

# Helper: exchange credentials for access token using Kagenti public client
get_token() {
  curl -s -X POST \
    -d "grant_type=password&client_id=kagenti-cli&username=${KAGENTI_ADMIN_USER}&password=${KAGENTI_ADMIN_PASSWORD}" \
    http://keycloak.localtest.me:8080/realms/master/protocol/openid-connect/token \
    | python3 -c "import sys,json; data=json.load(sys.stdin); print(data.get('access_token',''))" 2>/dev/null || true
}

# Helper: run a curl API call and check for errors
api_call() {
  local response http_code body
  
  response=$(curl -s -w "\n%{http_code}" "$@")

  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')
  if [ "${http_code}" -ge 400 ] 2>/dev/null; then
    echo "❌ API call failed (HTTP ${http_code}):" >&2
    echo "   ${body}" >&2
    return 1
  fi
  echo "${body}"
}

echo "🔧 [Step 1/12] Downloading helm versions..."
${SCRIPT_DIR}/download-helm.sh v3.19.5
${SCRIPT_DIR}/download-helm.sh v4.0.5

# activate old helm
export PATH="${REPO_ROOT}/bin/helm-v3.19.5:${OLD_PATH}"

echo "🚀 [Step 2/12] Installing kagenti..."
cd "${REPO_ROOT}"

if [ ! -f deployments/envs/.secret_values.yaml ]; then
    cp deployments/envs/secret_values.yaml.example deployments/envs/.secret_values.yaml
fi

deployments/ansible/run-install.sh --env dev


cd ${SCRIPT_DIR}/..
# Activate kind-kagenti context for kubectl + helm
kubectl config use-context kind-kagenti
export HELM_KUBECONTEXT="kind-kagenti"

# activate new helm version
export PATH="${REPO_ROOT}/bin/helm-v4.0.5:${OLD_PATH}"

echo "📦 [Step 3/12] Installing agentstack..."
helm uninstall agentstack -n team1 || true
kubectl delete pvc -n team1 --all
helm upgrade --install agentstack -n team1 -f agentstack-config.yaml oci://ghcr.io/i-am-bee/agentstack/chart/agentstack:0.6.2-rc5

echo "🔑 [Step 4/12] Patching keycloak for backchannel dynamic hostname..."
kubectl set env statefulset/keycloak -n keycloak \
  KC_HOSTNAME_BACKCHANNEL_DYNAMIC="true" \
  KC_HOSTNAME_STRICT="true"

echo "🔗 [Step 5/12] Patching deployments with internal Keycloak URL..."
INTERNAL_ISSUER="http://keycloak-service.keycloak:8080/realms/agentstack"

kubectl set env deployment/agentstack-server -n team1 \
  AUTHLIB_INSECURE_TRANSPORT="true" \
  AUTH__OIDC__ISSUER="${INTERNAL_ISSUER}" \
  AUTH__OIDC__INSECURE_TRANSPORT="false"

kubectl set env deployment/agentstack-ui -n team1 \
  OIDC_PROVIDER_ISSUER="${INTERNAL_ISSUER}"

echo "🌐 [Step 6/12] Applying HTTPRoutes for agentstack..."
kubectl apply -f ${SCRIPT_DIR}/../agentstack-routes.yaml

echo "🔐 [Step 7/12] Provisioning Keycloak for AgentStack..."
${SCRIPT_DIR}/provision-keycloak.sh

echo "⏳ [Step 8/12] Waiting for API healthcheck..."
while true; do
  if curl -sf -H "Host: agentstack-api.localtest.me" http://localhost:8080/healthcheck > /dev/null 2>&1; then
    echo "✅ AgentStack API is ready!"
    break
  fi
  sleep 2
done

echo ""
echo "🤖 [Step 9/12] Deploying chat agent..."
API_TOKEN=$(get_token)
if [ -z "${API_TOKEN}" ]; then
  echo "❌ Failed to obtain API token from Keycloak." >&2
  exit 1
fi

api_call \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -X POST http://kagenti-api.localtest.me:8080/api/v1/agents \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "chat",
    "namespace": "team1",
    "imageTag": "0.6.2-rc5",
    "protocol": "a2a",
    "framework": "Python",
    "envVars": [
      {"name": "PORT", "value": "8000"},
      {"name": "HOST", "value": "0.0.0.0"},
      {"name": "PLATFORM_URL", "value": "http://agentstack-server-svc:8333"},
      {"name": "PLATFORM_AUTH__SKIP_AUDIENCE_VALIDATION", "value": "true"}
    ],
    "workloadType": "deployment",
    "deploymentMethod": "image",
    "containerImage": "ghcr.io/i-am-bee/agentstack/agents/chat:0.6.2-rc5",
    "servicePorts": [
      {"name": "http", "port": 8080, "targetPort": 8000, "protocol": "TCP"}
    ],
    "createHttpRoute": true,
    "authBridgeEnabled": false,
    "spireEnabled": false
  }' > /dev/null
echo ""

echo "⏳ [Step 9/12] Waiting for chat agent to be ready..."
for i in {1..3}; do
  if kubectl rollout status deployment/chat -n team1 --timeout=120s; then
    break
  fi
  echo "⏳ Retrying rollout status... ($i/3)"
  sleep 5
done
echo "✅ Chat agent deployed and ready."

echo "🔌 [Step 10/12] Registering chat agent as provider..."
REGISTERED=0
for i in {1..15}; do
  if api_call \
    -u "${AGENTSTACK_ADMIN_USER}:${AGENTSTACK_ADMIN_PASSWORD}" \
    -X POST http://agentstack-api.localtest.me:8080/api/v1/providers \
    -H 'Content-Type: application/json' \
    -d '{
      "location": "http://chat.team1.svc.cluster.local:8080"
    }' > /dev/null; then
    echo ""
    echo "✅ Chat agent registered as provider."
    REGISTERED=1
    break
  fi
  echo "⏳ Retrying provider registration in 3s... ($i/10)"
  sleep 3
done

if [ "$REGISTERED" -eq 0 ]; then
  echo "❌ Failed to register chat agent as provider." >&2
  exit 1
fi

echo ""
read -rp "🔑 Enter your OpenAI API key (or press Enter to skip): " OPENAI_API_KEY
if [ -n "${OPENAI_API_KEY}" ]; then
  echo "🧠 [Step 11/12] Registering OpenAI model provider..."
  api_call \
    -u "${AGENTSTACK_ADMIN_USER}:${AGENTSTACK_ADMIN_PASSWORD}" \
    -X POST http://agentstack-api.localtest.me:8080/api/v1/model_providers \
    -H 'Content-Type: application/json' \
    -d "{
      \"name\": \"openai\",
      \"type\": \"openai\",
      \"base_url\": \"https://api.openai.com/v1\",
      \"api_key\": \"${OPENAI_API_KEY}\"
    }" > /dev/null
  echo ""
  echo "✅ OpenAI model provider registered."

  echo ""
  echo "📋 Available models:"
  api_call -u "${AGENTSTACK_ADMIN_USER}:${AGENTSTACK_ADMIN_PASSWORD}" \
    http://agentstack-api.localtest.me:8080/api/v1/openai/models \
    | python3 -c "import sys,json; [print(f'  - {m[\"id\"]}') for m in json.load(sys.stdin).get('data',[])]" || true

  echo ""
  echo "⚙️  [Step 12/12] Setting gpt-4o as default LLM model..."
  api_call \
    -u "${AGENTSTACK_ADMIN_USER}:${AGENTSTACK_ADMIN_PASSWORD}" \
    -X PUT http://agentstack-api.localtest.me:8080/api/v1/configurations/system \
    -H 'Content-Type: application/json' \
    -d '{"default_llm_model": "openai:gpt-4o"}' > /dev/null
  echo ""
  echo "✅ Default LLM model set to gpt-4o."
else
  echo "⏭️  Skipped OpenAI model provider registration."
fi

echo ""
echo "✅ Installation complete!"
echo ""
echo "  AgentStack API:        http://agentstack-api.localtest.me:8080"
echo "  AgentStack UI:         http://agentstack.localtest.me:8080"
echo "  Kagenti UI:            http://kagenti.localtest.me:8080"
echo "  Keycloak:              http://keycloak.localtest.me:8080"
echo "  Keycloak credentials:  "${KAGENTI_ADMIN_USER}"/"${KAGENTI_ADMIN_PASSWORD}""
echo "  Agentstack admin:      "${AGENTSTACK_ADMIN_USER}"/"${AGENTSTACK_ADMIN_PASSWORD}""
