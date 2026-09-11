#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 6: Deploy Model"
echo "========================================="

echo "1. Labeling models-as-a-service namespace..."
oc label namespace models-as-a-service \
  maas.opendatahub.io/gateway-access=true \
  opendatahub.io/dashboard=true \
  modelmesh-enabled=false \
  --overwrite

echo "2. Creating LLMInferenceService for Qwen3-8B-FP8-dynamic..."
oc apply -f "${MANIFESTS_DIR}/model/llm-inference-service.yaml"

echo "3. Waiting for LLMInferenceService to be Ready..."
echo "   This takes 5-15 minutes (image pull + model loading into GPU memory)..."
TIMEOUT=900
INTERVAL=30
ELAPSED=0
while true; do
  IS_READY=$(oc get llminferenceservice qwen3-8b-fp8 -n models-as-a-service \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  POD_STATUS=$(oc get pods -n models-as-a-service -l app.kubernetes.io/name=qwen3-8b-fp8 --no-headers 2>/dev/null | awk '{print $3}' || echo "None")
  if [[ "$IS_READY" == "True" ]]; then
    echo "   LLMInferenceService is Ready!"
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "ERROR: Timeout waiting for model deployment"
    exit 1
  fi
  echo "   LLMInferenceService: ${IS_READY} | Pod: ${POD_STATUS} (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "4. Creating MaaSModelRef..."
oc apply -f "${MANIFESTS_DIR}/model/maas-model-ref.yaml"

echo "5. Waiting for MaaSModelRef to become Ready (HTTPRoute auto-created)..."
TIMEOUT=120
INTERVAL=10
ELAPSED=0
while true; do
  PHASE=$(oc get maasmodelref qwen3-8b -n models-as-a-service \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [[ "$PHASE" == "Ready" ]]; then
    echo "   MaaSModelRef is Ready!"
    ENDPOINT=$(oc get maasmodelref qwen3-8b -n models-as-a-service \
      -o jsonpath='{.status.endpoint}' 2>/dev/null || echo "")
    echo "   MaaS Endpoint: ${ENDPOINT}"
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "   WARNING: MaaSModelRef not Ready yet (phase: ${PHASE}). May need more time."
    break
  fi
  echo "   MaaSModelRef phase: ${PHASE} (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "6. Verifying model serves through MaaS Gateway..."
sleep 5
TOKEN=$(oc whoami -t)
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  "https://maas.${CLUSTER_DOMAIN}/models-as-a-service/qwen3-8b-fp8/v1/models" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
  echo "   MaaS Gateway returns 200 - Model accessible!"
elif [[ "$HTTP_CODE" == "403" ]]; then
  echo "   MaaS Gateway returns 403 (subscription required) - Auth working!"
elif [[ "$HTTP_CODE" == "401" ]]; then
  echo "   MaaS Gateway returns 401 (auth required) - Gateway routing works!"
else
  echo "   WARNING: Unexpected HTTP code: ${HTTP_CODE}. Check gateway routing."
fi

echo ""
echo "7. Installing OGX operator (required for Gen AI Playground in RHOAI 3.5.0)..."
# In RHOAI 3.5.0, the Playground requires ogx.io/v1beta1 (OGX = successor to LlamaStack).
# The RHOAI operator does not yet auto-deploy OGX, so we install the upstream operator manually.
oc apply -k https://github.com/opendatahub-io/llama-stack-k8s-operator/config/default 2>/dev/null
echo "   OGX operator resources applied."

# Patch to Red Hat certified image — upstream image does not support rh-dev distribution
OGX_RH_IMAGE=$(oc get csv rhods-operator.3.5.0 -n redhat-ods-applications \
  -o jsonpath='{.spec.relatedImages[?(@.name=="odh_ogx_k8s_operator_image")].image}' 2>/dev/null)
OGX_CORE_IMAGE=$(oc get csv rhods-operator.3.5.0 -n redhat-ods-applications \
  -o jsonpath='{.spec.relatedImages[?(@.name=="odh_ogx_core_image")].image}' 2>/dev/null)

if [[ -n "${OGX_RH_IMAGE}" ]]; then
  oc set image deployment/ogx-k8s-operator-controller-manager \
    manager="${OGX_RH_IMAGE}" \
    -n ogx-k8s-operator-system 2>/dev/null
  echo "   OGX operator patched to Red Hat certified image (supports rh-dev distribution)."
  # Set RELATED_IMAGE env vars — without these the rh-dev distribution fails validation
  oc set env deployment/ogx-k8s-operator-controller-manager \
    -n ogx-k8s-operator-system \
    RELATED_IMAGE_ODH_OGX_CORE_IMAGE="${OGX_CORE_IMAGE}" \
    RELATED_IMAGE_STARTER="${OGX_CORE_IMAGE}" \
    RELATED_IMAGE_REMOTE_VLLM="${OGX_CORE_IMAGE}" \
    RELATED_IMAGE_META_REFERENCE_GPU="${OGX_CORE_IMAGE}" \
    RELATED_IMAGE_POSTGRES_DEMO="registry.redhat.io/rhel9/postgresql-16" \
    2>/dev/null
  echo "   OGX RELATED_IMAGE env vars set from RHOAI CSV."
else
  echo "   WARNING: Could not find Red Hat OGX image in RHOAI CSV. Using upstream image."
fi

# Grant the Gen AI Studio dashboard service account access to ogx.io resources
oc apply -f - <<'OGX_DASH_RBAC_EOF' 2>/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: odh-dashboard-ogx-access
rules:
- apiGroups: ["ogx.io"]
  resources: ["ogxservers", "ogxservers/status"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: odh-dashboard-ogx-access
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: odh-dashboard-ogx-access
subjects:
- kind: ServiceAccount
  name: odh-dashboard-gen-ai
  namespace: redhat-ods-applications
OGX_DASH_RBAC_EOF

# OpenShift requires extra RBAC for the OGX operator to read apiservers.config.openshift.io
oc apply -f - <<'OGX_RBAC_EOF' 2>/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ogx-k8s-operator-openshift-extra
rules:
- apiGroups: ["config.openshift.io"]
  resources: ["apiservers"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ogx-k8s-operator-openshift-extra
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ogx-k8s-operator-openshift-extra
subjects:
- kind: ServiceAccount
  name: ogx-k8s-operator-controller-manager
  namespace: ogx-k8s-operator-system
OGX_RBAC_EOF

# Remove the validating webhook — cert-manager is not configured for this namespace
oc delete validatingwebhookconfiguration \
  ogx-k8s-operator-validating-webhook-configuration 2>/dev/null || true

# Create a self-signed TLS cert to satisfy the webhook volume mount
if ! oc get secret ogx-k8s-operator-webhook-cert -n ogx-k8s-operator-system &>/dev/null; then
  openssl req -x509 -newkey rsa:2048 \
    -keyout /tmp/ogx-tls.key -out /tmp/ogx-tls.crt \
    -days 365 -nodes \
    -subj '/CN=ogx-k8s-operator-webhook-service.ogx-k8s-operator-system.svc' \
    -addext 'subjectAltName=DNS:ogx-k8s-operator-webhook-service.ogx-k8s-operator-system.svc' \
    2>/dev/null
  oc create secret tls ogx-k8s-operator-webhook-cert \
    -n ogx-k8s-operator-system \
    --cert=/tmp/ogx-tls.crt --key=/tmp/ogx-tls.key 2>/dev/null
  echo "   Webhook TLS secret created."
fi

echo "   Waiting for OGX operator to be ready..."
TIMEOUT=120
INTERVAL=10
ELAPSED=0
while true; do
  READY=$(oc get deployment ogx-k8s-operator-controller-manager \
    -n ogx-k8s-operator-system \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
  if [[ "$READY" -ge 1 ]]; then
    echo "   OGX operator is ready — ogx.io/v1beta1 API registered."
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "   WARNING: OGX operator not ready after ${TIMEOUT}s. Playground may show errors."
    break
  fi
  echo "   Waiting for OGX operator... (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""
echo "8. Configuring Gen AI Studio to show Playground menu..."
# The gen-ai-ui shows the Playground menu item only when LLAMA_STACK_URL is set (isCustomLSD=true).
# Create an ExternalName service in redhat-ods-applications so the gen-ai-ui BFF can reach the
# OGXServer service across namespaces, then point gen-ai-ui at it via LLAMA_STACK_URL.
oc apply -f - <<'LSD_SVC_EOF' 2>/dev/null
apiVersion: v1
kind: Service
metadata:
  name: odh-dashboard-lsd-ui
  namespace: redhat-ods-applications
spec:
  type: ExternalName
  externalName: lsd-genai-playground-service.models-as-a-service.svc.cluster.local
  ports:
  - port: 8321
    targetPort: 8321
LSD_SVC_EOF

oc set env deployment/gen-ai-ui -n redhat-ods-applications \
  LLAMA_STACK_URL="http://odh-dashboard-lsd-ui.redhat-ods-applications.svc.cluster.local:8321" \
  2>/dev/null
echo "   LLAMA_STACK_URL set — Playground will appear in Gen AI studio menu."

echo ""
echo "9. Adding NetworkPolicy to allow gen-ai-ui → OGXServer traffic..."
oc apply -f - <<'NP_EOF' 2>/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: lsd-playground-allow-genai-ui
  namespace: models-as-a-service
spec:
  podSelector:
    matchLabels:
      app: ogx
      app.kubernetes.io/instance: lsd-genai-playground
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: redhat-ods-applications
    ports:
    - port: 8321
      protocol: TCP
NP_EOF
echo "   NetworkPolicy applied."

echo ""
echo "10. Deploying OpenShift MCP Server..."
oc apply -f "${MANIFESTS_DIR}/playground/openshift-mcp-server.yaml"
echo "   Waiting for OpenShift MCP Server to be ready..."
oc wait mcpserver openshift-mcp-server -n models-as-a-service \
  --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True --timeout=60s 2>/dev/null || \
  echo "   WARNING: MCP Server not ready yet. Check prerequisites."
echo "   OpenShift MCP Server: $(oc get mcpserver openshift-mcp-server -n models-as-a-service -o jsonpath='{.status.address.url}' 2>/dev/null)"

echo ""
echo "Phase 6 complete: Model deployed and exposed via MaaS."
echo "   Model: Qwen3-8B-FP8-dynamic (vLLM CUDA)"
echo "   MaaS Endpoint: https://maas.${CLUSTER_DOMAIN}/models-as-a-service/qwen3-8b-fp8/v1"
echo "   Gen AI Playground: lsd-genai-playground (models-as-a-service namespace)"
echo "   OpenShift MCP Server: openshift-mcp-server (models-as-a-service namespace)"
echo "========================================="
