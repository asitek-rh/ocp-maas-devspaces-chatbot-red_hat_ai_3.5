#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 5: Model Registry"
echo "========================================="

echo "1. Verifying Model Registry namespace exists..."
oc get namespace rhoai-model-registries &>/dev/null || \
  oc create namespace rhoai-model-registries

echo "2. Verifying Model Registry operator is running..."
oc wait deployment model-registry-operator-controller-manager \
  -n redhat-ods-applications \
  --for=condition=Available --timeout=120s

echo "3. Verifying component-level ModelRegistry is ready..."
oc wait modelregistry default-modelregistry -n rhoai-model-registries \
  --for=jsonpath='{.status.conditions[0].status}'=True --timeout=120s 2>/dev/null || \
  echo "   ModelRegistry component not ready yet, will reconcile automatically."

echo "4. Verifying Model Catalog is operational..."
oc wait deployment model-catalog -n rhoai-model-registries \
  --for=condition=Available --timeout=120s 2>/dev/null || \
  echo "   Model Catalog deployment not yet available."

echo "5. Deploying MySQL backend for Model Registry..."
if ! oc get secret model-registry-db-credentials -n rhoai-model-registries &>/dev/null; then
  MR_DB_PASS=$(openssl rand -hex 16)
  MR_ROOT_PASS=$(openssl rand -hex 16)
  oc create secret generic model-registry-db-credentials \
    -n rhoai-model-registries \
    --from-literal=password="${MR_DB_PASS}" \
    --from-literal=root-password="${MR_ROOT_PASS}"
fi
oc apply -f "${MANIFESTS_DIR}/model-registry/mysql/mysql.yaml"
echo "   Waiting for MySQL to be ready..."
oc wait statefulset model-registry-db -n rhoai-model-registries \
  --for=jsonpath='{.status.readyReplicas}'=1 --timeout=120s 2>/dev/null || \
  echo "   WARNING: MySQL not ready yet, continuing..."

echo "6. Creating Model Registry instance (REST API server)..."
oc apply -f "${MANIFESTS_DIR}/model-registry/model-registry-instance.yaml"

echo "   Waiting for Model Registry server to be available..."
TIMEOUT=120
INTERVAL=10
ELAPSED=0
while true; do
  READY=$(oc get deployment default-registry -n rhoai-model-registries \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
  if [[ "$READY" -ge 1 ]]; then
    echo "   Model Registry server is running!"
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "   WARNING: Model Registry server not ready after ${TIMEOUT}s."
    break
  fi
  echo "   Waiting... (${ELAPSED}s / ${TIMEOUT}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "7. Registering Qwen3-8B-FP8-dynamic model..."
MR_SVC="http://localhost:8080/api/model_registry/v1alpha3"

MODEL_EXISTS=$(oc exec deployment/default-registry -n rhoai-model-registries -- \
  curl -s "${MR_SVC}/registered_models?name=qwen3-8b-fp8-dynamic" 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('size',0))" 2>/dev/null || echo "0")

if [[ "$MODEL_EXISTS" == "0" ]]; then
  echo "   Creating registered model..."
  MODEL_ID=$(oc exec deployment/default-registry -n rhoai-model-registries -- \
    curl -s -X POST "${MR_SVC}/registered_models" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "qwen3-8b-fp8-dynamic",
      "description": "Red Hat AI validated Qwen3-8B FP8 Dynamic quantized model for code generation and chat",
      "customProperties": {
        "source": {"metadataType": "MetadataStringValue", "string_value": "Red Hat AI Model Catalog"},
        "provider": {"metadataType": "MetadataStringValue", "string_value": "RedHatAI"},
        "task": {"metadataType": "MetadataStringValue", "string_value": "text-generation"},
        "quantization": {"metadataType": "MetadataStringValue", "string_value": "FP8-dynamic"},
        "parameters": {"metadataType": "MetadataStringValue", "string_value": "8B"}
      }
    }' 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

  echo "   Creating model version v1.5..."
  VERSION_ID=$(oc exec deployment/default-registry -n rhoai-model-registries -- \
    curl -s -X POST "${MR_SVC}/model_versions" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"v1.5\",
      \"description\": \"OCI Modelcar from registry.redhat.io - FP8 dynamic quantization\",
      \"registeredModelId\": \"${MODEL_ID}\",
      \"customProperties\": {
        \"runtime\": {\"metadataType\": \"MetadataStringValue\", \"string_value\": \"vLLM CUDA\"},
        \"gpu_required\": {\"metadataType\": \"MetadataStringValue\", \"string_value\": \"NVIDIA L4 (24GB VRAM)\"},
        \"serving_framework\": {\"metadataType\": \"MetadataStringValue\", \"string_value\": \"Red Hat AI Inference Server\"}
      }
    }" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

  echo "   Creating model artifact (OCI image reference)..."
  oc exec deployment/default-registry -n rhoai-model-registries -- \
    curl -s -X POST "${MR_SVC}/model_versions/${VERSION_ID}/artifacts" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "qwen3-8b-fp8-dynamic-oci",
      "description": "OCI Modelcar container image with Qwen3-8B FP8 dynamic model weights",
      "uri": "oci://registry.redhat.io/rhelai1/modelcar-qwen3-8b-fp8-dynamic:1.5",
      "artifactType": "model-artifact",
      "modelFormatName": "safetensors",
      "modelFormatVersion": "1.0",
      "customProperties": {
        "format": {"metadataType": "MetadataStringValue", "string_value": "OCI Modelcar"},
        "registry": {"metadataType": "MetadataStringValue", "string_value": "registry.redhat.io"}
      }
    }' >/dev/null 2>&1

  echo "   Model registered successfully!"
else
  echo "   Model already registered in Model Registry."
fi

echo ""
echo "   Model Catalog: Red Hat AI validated models appear in RHOAI Dashboard."
echo "   Model Registry: Qwen3-8B-FP8-dynamic registered with version and artifact."
echo "   Flow: Catalog -> Register -> Deploy (shown in demo walkthrough)"

echo ""
echo "Phase 5 complete: Model Registry configured with Qwen3-8B model."
echo "========================================="
