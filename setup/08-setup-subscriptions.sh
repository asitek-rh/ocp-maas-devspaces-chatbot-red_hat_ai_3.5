#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 8: Setup Subscriptions"
echo "========================================="

CURRENT_USER=$(oc whoami)

echo "1. Creating OpenShift groups..."
oc adm groups new devspaces-users --dry-run=client -o yaml | oc apply -f -
oc adm groups new chatbot-users --dry-run=client -o yaml | oc apply -f -

echo "2. Adding current user (${CURRENT_USER}) to both groups..."
oc adm groups add-users devspaces-users "${CURRENT_USER}" 2>/dev/null || true
oc adm groups add-users chatbot-users "${CURRENT_USER}" 2>/dev/null || true

echo "3. Creating models-as-a-service namespace..."
oc create namespace models-as-a-service --dry-run=client -o yaml | oc apply -f -

echo "4. Applying MaaS Subscriptions..."
oc apply -f "${MANIFESTS_DIR}/subscriptions/devspaces-subscription.yaml"
oc apply -f "${MANIFESTS_DIR}/subscriptions/chatbot-subscription.yaml"

echo "5. Applying MaaS Auth Policies..."
oc apply -f "${MANIFESTS_DIR}/subscriptions/devspaces-auth-policy.yaml"
oc apply -f "${MANIFESTS_DIR}/subscriptions/chatbot-auth-policy.yaml"

echo "6. Generating API keys for each subscription..."
TOKEN=$(oc whoami -t)

echo "   Checking MaaS API key endpoint availability..."
API_KEY_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  "${MAAS_URL}/v1/api-keys" -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "000")

if [[ "$API_KEY_CODE" == "200" || "$API_KEY_CODE" == "405" ]]; then
  echo "   Creating Dev Spaces API key via MaaS API..."
  DEVSPACES_KEY=$(curl -sk -X POST "${MAAS_URL}/v1/api-keys" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"name": "devspaces-key", "subscription": "devspaces-subscription"}' | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || echo "")
  echo "   Creating Chatbot API key via MaaS API..."
  CHATBOT_KEY=$(curl -sk -X POST "${MAAS_URL}/v1/api-keys" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"name": "chatbot-key", "subscription": "chatbot-subscription"}' | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || echo "")
else
  echo "   MaaS API key endpoint not available (HTTP ${API_KEY_CODE})."
  echo "   Using OpenShift Bearer token as API key (MaaS gateway accepts it directly)."
  DEVSPACES_KEY="${TOKEN}"
  CHATBOT_KEY="${TOKEN}"
fi

echo "7. Storing API keys in secrets..."
oc create namespace openshift-devspaces --dry-run=client -o yaml | oc apply -f -
oc create namespace open-webui --dry-run=client -o yaml | oc apply -f -

if [[ -n "$DEVSPACES_KEY" ]]; then
  oc create secret generic devspaces-maas-apikey \
    -n openshift-devspaces \
    --from-literal=api-key="${DEVSPACES_KEY}" \
    --dry-run=client -o yaml | oc apply -f -
  echo "   Dev Spaces API key stored."
else
  echo "   WARNING: Could not generate Dev Spaces API key."
fi

if [[ -n "$CHATBOT_KEY" ]]; then
  oc create secret generic chatbot-maas-apikey \
    -n open-webui \
    --from-literal=api-key="${CHATBOT_KEY}" \
    --dry-run=client -o yaml | oc apply -f -
  echo "   Chatbot API key stored."
else
  echo "   WARNING: Could not generate Chatbot API key."
fi

echo "8. Enabling MaaS telemetry for Usage Dashboard..."
# AITenant CRD does not support a telemetry field — TelemetryPolicy must be created directly.
oc apply -f - <<'TELEMETRY_EOF'
apiVersion: extensions.kuadrant.io/v1alpha1
kind: TelemetryPolicy
metadata:
  name: maas-telemetry
  namespace: openshift-ingress
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: maas-default-gateway
  metrics:
    default:
      labels:
        user: "request.headers['x-forwarded-user'] == '' ? 'anonymous' : request.headers['x-forwarded-user']"
        model: "request.path.split('/')[2]"
        subscription: "request.headers['x-maas-subscription'] == '' ? 'unknown' : request.headers['x-maas-subscription']"
TELEMETRY_EOF
echo "   TelemetryPolicy created targeting maas-default-gateway."

echo "   Waiting for TelemetryPolicy to be accepted..."
TIMEOUT=60
INTERVAL=5
ELAPSED=0
while true; do
  if oc get telemetrypolicy maas-telemetry -n openshift-ingress &>/dev/null; then
    echo "   TelemetryPolicy is available."
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "   WARNING: TelemetryPolicy not found after ${TIMEOUT}s."
    break
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "9. Ensuring Perses datasource secret for Usage Dashboard..."
if ! oc get secret kuadrant-prometheus-datasource-secret -n redhat-ods-applications &>/dev/null; then
  DS_TOKEN=$(oc create token data-science-prometheus-cluster-proxy -n redhat-ods-monitoring --duration=8760h)
  CA_CERT=$(oc get secret cluster-prometheus-datasource-secret -n redhat-ods-monitoring -o jsonpath='{.data.ca\.crt}' | base64 -d)
  oc create secret generic kuadrant-prometheus-datasource-secret \
    -n redhat-ods-applications \
    --from-literal=token="${DS_TOKEN}" \
    --from-literal=ca.crt="${CA_CERT}"
  echo "   Datasource secret created."
else
  echo "   Datasource secret already exists."
fi

echo "   Ensuring RBAC for Thanos tenancy in kuadrant-system..."
oc adm policy add-role-to-user view \
  system:serviceaccount:redhat-ods-monitoring:data-science-prometheus-cluster-proxy \
  -n kuadrant-system 2>/dev/null || true

echo ""
echo "Phase 8 complete: Two independent subscriptions with API keys and telemetry configured."
echo "========================================="
