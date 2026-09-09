#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 7: Verify MaaS"
echo "========================================="

PASS=0
FAIL=0

check() {
  local desc="$1"
  local result="$2"
  if [[ "$result" == "true" || "$result" == "True" || "$result" == "Running" || "$result" == "ok" ]]; then
    echo "  [PASS] $desc"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $desc (got: $result)"
    FAIL=$((FAIL + 1))
  fi
}

echo "1. Infrastructure health..."
GW_STATUS=$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "Unknown")
check "Gateway Programmed" "$GW_STATUS"

PG_READY=$(oc get statefulset postgres -n redhat-ods-applications \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
check "PostgreSQL ready" "$([ "$PG_READY" -ge 1 ] 2>/dev/null && echo true || echo false)"

MAAS_API=$(oc get deployment maas-api -n redhat-ai-gateway-infra \
  -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
check "maas-api running" "$([ "$MAAS_API" -ge 1 ] 2>/dev/null && echo true || echo false)"

DSC_STATUS=$(oc get datasciencecluster default-dsc \
  -o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}' 2>/dev/null || echo "Unknown")
check "ModelsAsAServiceReady" "$DSC_STATUS"

echo ""
echo "2. Model readiness..."
IS_READY=$(oc get llminferenceservice qwen3-8b-fp8 -n models-as-a-service \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
check "LLMInferenceService Ready" "$IS_READY"

GPU_NODE=$(oc get nodes -l node-role.kubernetes.io/worker-gpu --no-headers 2>/dev/null | grep -c " Ready" || echo "0")
check "GPU node Ready" "$([ "$GPU_NODE" -ge 1 ] && echo true || echo false)"

echo ""
echo "3. MaaS Gateway routing..."
MODELREF_PHASE=$(oc get maasmodelref qwen3-8b -n models-as-a-service \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
check "MaaSModelRef Ready" "$([ "$MODELREF_PHASE" == "Ready" ] && echo true || echo false)"

TOKEN=$(oc whoami -t)
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  "https://maas.${CLUSTER_DOMAIN}/models-as-a-service/qwen3-8b-fp8/v1/models" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "000")
check "Gateway serves model list (200 or 403)" "$([ "$HTTP_CODE" == "200" ] || [ "$HTTP_CODE" == "403" ] && echo true || echo false)"

echo ""
echo "4. Model Registry..."
MR_READY=$(oc get deployment default-registry -n rhoai-model-registries \
  -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
check "Model Registry server" "$([ "$MR_READY" -ge 1 ] 2>/dev/null && echo true || echo false)"

MR_SVC="http://localhost:8080/api/model_registry/v1alpha3"
MODEL_COUNT=$(oc exec deployment/default-registry -n rhoai-model-registries -- \
  curl -s --max-time 15 "${MR_SVC}/registered_models" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('size',0))" 2>/dev/null || echo "0")
check "Model registered in registry" "$([ "$MODEL_COUNT" -ge 1 ] 2>/dev/null && echo true || echo false)"

echo ""
echo "5. Observability (Perses)..."
PERSES_READY=$(oc get pods -n redhat-ods-monitoring -l app.kubernetes.io/managed-by=perses-operator \
  --no-headers 2>/dev/null | grep -c "Running" || echo "0")
check "Perses server running" "$([ "$PERSES_READY" -ge 1 ] 2>/dev/null && echo true || echo false)"

DASHBOARDS=$(oc get persesdashboard -A -o jsonpath='{.items[*].status.conditions[0].status}' 2>/dev/null | tr ' ' '\n' | grep -c "True" || echo "0")
check "Perses dashboards synced" "$([ "$DASHBOARDS" -ge 2 ] 2>/dev/null && echo true || echo false)"

echo ""
echo "6. Direct model inference test..."
POD_NAME=$(oc get pods -n models-as-a-service -l app.kubernetes.io/name=qwen3-8b-fp8 --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | head -1)
if [[ -n "$POD_NAME" ]]; then
  RESPONSE=$(oc exec "$POD_NAME" -n models-as-a-service -c main -- \
    curl -sk https://localhost:8000/v1/models 2>/dev/null || echo "")
  HAS_DATA=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if 'data' in d else 'false')" 2>/dev/null || echo "false")
  check "Model endpoint responds" "$HAS_DATA"
else
  check "Model pod running" "false"
fi

echo ""
echo "========================================="
echo "MaaS Verification Summary"
echo "========================================="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "Status: ALL CHECKS PASSED"
else
  echo "Status: SOME CHECKS FAILED (non-critical checks may fail during initial setup)"
fi
echo "========================================="
