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
echo "7. Deploying Gen AI Playground (LlamaStackDistribution)..."
if oc api-resources 2>/dev/null | grep -q "LlamaStackDistribution"; then
  oc apply -f "${MANIFESTS_DIR}/playground/llama-stack-config.yaml"
  oc apply -f "${MANIFESTS_DIR}/playground/llamastack-distribution.yaml"
else
  echo "   WARNING: LlamaStackDistribution CRD not available (llamastack-k8s-operator not installed)."
  echo "   RHOAI 3.5.0 llamastackoperator component is not yet deployed by the RHOAI operator."
  echo "   Skipping Gen AI Playground deployment."
fi

if oc api-resources 2>/dev/null | grep -q "LlamaStackDistribution"; then
  echo "   Waiting for Playground to be ready..."
  TIMEOUT=120
  INTERVAL=10
  ELAPSED=0
  while true; do
    PHASE=$(oc get llamastackdistribution lsd-genai-playground -n models-as-a-service \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [[ "$PHASE" == "Ready" ]]; then
      echo "   Gen AI Playground is Ready!"
      break
    fi
    if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
      echo "   WARNING: Playground not ready after ${TIMEOUT}s (phase: ${PHASE})."
      break
    fi
    echo "   Playground phase: ${PHASE} (${ELAPSED}s / ${TIMEOUT}s)"
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
  done
fi

echo ""
echo "8. Deploying OpenShift MCP Server..."
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
