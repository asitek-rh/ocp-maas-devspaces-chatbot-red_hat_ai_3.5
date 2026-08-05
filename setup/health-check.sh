#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Health Check & Post-Reboot Recovery"
echo "========================================="
echo ""

ERRORS=0

check_pass() { echo "  ✓ $1"; }
check_fail() { echo "  ✗ $1"; ERRORS=$((ERRORS + 1)); }
check_warn() { echo "  ! $1"; }

# ─── 1. Nodes ───────────────────────────────────────────────────────────────────
echo "1. Cluster Nodes"
NOT_READY=$(oc get nodes --no-headers 2>/dev/null | { grep -cv " Ready " || true; })
GPU_NODES=$(oc get nodes -l node-role.kubernetes.io/worker-gpu --no-headers 2>/dev/null | wc -l)
if [[ "$NOT_READY" -gt 0 ]]; then
  check_fail "$NOT_READY node(s) not Ready"
else
  check_pass "All nodes Ready"
fi
if [[ "$GPU_NODES" -gt 0 ]]; then
  check_pass "GPU node(s) present: $GPU_NODES"
else
  check_fail "No GPU nodes found"
fi
echo ""

# ─── 2. GPU Operator ────────────────────────────────────────────────────────────
echo "2. NVIDIA GPU Operator"
GPU_STATE=$(oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}' 2>/dev/null || echo "missing")
if [[ "$GPU_STATE" == "ready" ]]; then
  check_pass "ClusterPolicy: ready"
else
  check_warn "ClusterPolicy: $GPU_STATE (may need recovery — see below)"
fi

GPU_ALLOC=$(oc get nodes -l node-role.kubernetes.io/worker-gpu -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
if [[ "$GPU_ALLOC" -ge 1 ]]; then
  check_pass "GPU allocatable: $GPU_ALLOC"
else
  check_fail "No GPU allocatable on GPU node"
fi
echo ""

# ─── 3. LLM Inference Service ───────────────────────────────────────────────────
echo "3. LLM Inference Service"
LLM_READY=$(oc get llminferenceservice qwen3-8b-fp8 -n models-as-a-service -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
if [[ "$LLM_READY" == "True" ]]; then
  check_pass "LLMInferenceService qwen3-8b-fp8: Ready"
else
  check_fail "LLMInferenceService qwen3-8b-fp8: Not Ready ($LLM_READY)"
fi

MAAS_REF=$(oc get maasmodelref qwen3-8b -n models-as-a-service -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
if [[ "$MAAS_REF" == "Ready" ]]; then
  check_pass "MaaSModelRef: Ready"
else
  check_fail "MaaSModelRef: $MAAS_REF"
fi
echo ""

# ─── 4. MaaS Gateway ────────────────────────────────────────────────────────────
echo "4. MaaS Gateway"
GW_STATUS=$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "Unknown")
if [[ "$GW_STATUS" == "True" ]]; then
  check_pass "Gateway: Programmed"
else
  check_fail "Gateway not Programmed: $GW_STATUS"
fi
echo ""

# ─── 5. Observability ───────────────────────────────────────────────────────────
echo "5. Observability Stack"
MON_READY=$(oc get monitoring default-monitoring -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
if [[ "$MON_READY" == "True" ]]; then
  check_pass "Monitoring component: Ready"
else
  check_warn "Monitoring component: $MON_READY"
fi

PERSES_PODS=$(oc get pods -n redhat-ods-monitoring -l app.kubernetes.io/managed-by=perses-operator --no-headers 2>/dev/null | grep "Running" | wc -l)
if [[ "$PERSES_PODS" -ge 1 ]]; then
  check_pass "Perses: Running"
else
  check_warn "Perses: not running"
fi

TP_EXISTS=$(oc get telemetrypolicy maas-telemetry -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || echo "Unknown")
if [[ "$TP_EXISTS" == "True" ]]; then
  check_pass "TelemetryPolicy: Enforced (Usage Dashboard labels)"
else
  check_warn "TelemetryPolicy: $TP_EXISTS (Usage Dashboard may not show subscription data)"
fi
echo ""

# ─── 6. Open WebUI ──────────────────────────────────────────────────────────────
echo "6. Open WebUI (Chatbot)"
WEBUI_READY=$(oc get deploy open-webui -n open-webui -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "$WEBUI_READY" -ge 1 ]]; then
  check_pass "Open WebUI: Running"
else
  check_fail "Open WebUI: not ready"
fi
echo ""

# ─── 7. Dev Spaces ──────────────────────────────────────────────────────────────
echo "7. OpenShift Dev Spaces"
CHE_PHASE=$(oc get checluster devspaces -n openshift-devspaces -o jsonpath='{.status.chePhase}' 2>/dev/null || echo "Unknown")
if [[ "$CHE_PHASE" == "Active" ]]; then
  check_pass "CheCluster: Active"
else
  check_warn "CheCluster phase: $CHE_PHASE"
fi
echo ""

# ─── 8. Model Registry ──────────────────────────────────────────────────────────
echo "8. Model Registry"
MR_PODS=$(oc get pods -n rhoai-model-registries --no-headers 2>/dev/null | grep -c "Running" || true)
if [[ "$MR_PODS" -ge 1 ]]; then
  check_pass "Model Registry API: Running"
else
  check_warn "Model Registry API: not running"
fi
echo ""

# ─── 9. MaaS endpoint test ──────────────────────────────────────────────────────
echo "9. MaaS Endpoint Test"
TOKEN=$(oc whoami -t)
HTTP_CODE=$(timeout 10 curl -sk -o /dev/null -w "%{http_code}" \
  "${MAAS_URL}/models-as-a-service/qwen3-8b-fp8/v1/models" \
  -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "403" ]]; then
  check_pass "MaaS endpoint reachable (HTTP $HTTP_CODE)"
else
  check_fail "MaaS endpoint returned HTTP $HTTP_CODE"
fi
echo ""

# ─── Summary ────────────────────────────────────────────────────────────────────
echo "========================================="
if [[ "$ERRORS" -eq 0 ]]; then
  echo "All checks PASSED. Demo is ready."
else
  echo "$ERRORS check(s) FAILED."
  echo "Run 'setup/health-check.sh --fix' to attempt automatic recovery."
fi
echo "========================================="

# ─── Auto-fix mode ──────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--fix" ]]; then
  echo ""
  echo "========================================="
  echo "Attempting automatic recovery..."
  echo "========================================="

  # Fix 1: GPU driver stuck after reboot
  if [[ "$GPU_STATE" != "ready" || "$GPU_ALLOC" -lt 1 ]]; then
    echo ""
    echo ">>> Fixing GPU driver (post-reboot recovery)..."

    echo "    Scaling down inference service..."
    oc patch llminferenceservice qwen3-8b-fp8 -n models-as-a-service --type merge -p '{"spec":{"replicas":0}}' 2>/dev/null || true
    sleep 5
    oc delete pods -n models-as-a-service --all --force --grace-period=0 2>/dev/null || true
    sleep 5

    echo "    Force-deleting stuck NVIDIA pods..."
    oc get pods -n nvidia-gpu-operator --no-headers | grep -v "Running\|Completed" | awk '{print $1}' | \
      xargs -r -I{} oc delete pod {} -n nvidia-gpu-operator --force --grace-period=0 2>/dev/null

    echo "    Uncordoning GPU node..."
    GPU_NODE=$(oc get nodes -l node-role.kubernetes.io/worker-gpu -o name | head -1)
    oc adm uncordon ${GPU_NODE} 2>/dev/null || true

    echo "    Waiting for GPU driver to install (up to 300s)..."
    TIMEOUT=300
    INTERVAL=30
    ELAPSED=0
    while true; do
      STATE=$(oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
      if [[ "$STATE" == "ready" ]]; then
        echo "    GPU ClusterPolicy is ready!"
        break
      fi
      if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
        echo "    WARNING: GPU not ready after ${TIMEOUT}s. May need manual intervention."
        echo "    Try: oc delete pod -n nvidia-gpu-operator -l app=nvidia-driver-daemonset --force --grace-period=0"
        break
      fi
      # Check if driver pod is stuck due to inference pods
      DRIVER_LOG=$(oc logs -n nvidia-gpu-operator -l app=nvidia-driver-daemonset -c k8s-driver-manager --tail=3 2>/dev/null || true)
      if echo "$DRIVER_LOG" | grep -q "cannot delete Pods with local storage"; then
        echo "    Driver blocked by inference pod — cleaning..."
        oc delete pods -n models-as-a-service --all --force --grace-period=0 2>/dev/null || true
        oc delete pod -n nvidia-gpu-operator -l app=nvidia-driver-daemonset --force --grace-period=0 2>/dev/null || true
      fi
      echo "    GPU state: $STATE (${ELAPSED}s / ${TIMEOUT}s)"
      sleep "$INTERVAL"
      ELAPSED=$((ELAPSED + INTERVAL))
    done
  fi

  # Fix 2: Restore LLM Inference Service
  LLM_REPLICAS=$(oc get llminferenceservice qwen3-8b-fp8 -n models-as-a-service -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  if [[ "$LLM_REPLICAS" -lt 1 ]]; then
    echo ""
    echo ">>> Restoring LLM Inference Service replicas..."
    oc patch llminferenceservice qwen3-8b-fp8 -n models-as-a-service --type merge -p '{"spec":{"replicas":1}}'
  fi

  # Fix 3: Wait for inference to become ready
  echo ""
  echo ">>> Waiting for LLM Inference Service to become Ready (up to 600s)..."
  TIMEOUT=600
  INTERVAL=30
  ELAPSED=0
  while true; do
    READY=$(oc get llminferenceservice qwen3-8b-fp8 -n models-as-a-service -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$READY" == "True" ]]; then
      echo "    LLMInferenceService is Ready!"
      break
    fi
    if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
      echo "    WARNING: LLM not ready after ${TIMEOUT}s. Check logs:"
      echo "    oc logs -n models-as-a-service -l app=qwen3-8b-fp8-kserve -c main --tail=20"
      break
    fi
    echo "    Status: $READY (${ELAPSED}s / ${TIMEOUT}s)"
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
  done

  # Fix 4: Re-apply ServiceMonitor labels (operators recreate them on restart)
  echo ""
  echo ">>> Re-labeling operator ServiceMonitors (suppress bearerTokenFile rejections)..."
  oc label servicemonitor nfd-controller-manager-metrics-monitor -n openshift-nfd \
    openshift.io/user-monitoring=false --overwrite 2>/dev/null || true
  oc label servicemonitor odh-model-controller-metrics-monitor -n redhat-ods-applications \
    openshift.io/user-monitoring=false --overwrite 2>/dev/null || true
  oc label servicemonitor tempo-operator-controller-manager-metrics-monitor -n openshift-operators \
    openshift.io/user-monitoring=false --overwrite 2>/dev/null || true
  oc label servicemonitor opentelemetry-operator-metrics-monitor -n openshift-operators \
    openshift.io/user-monitoring=false --overwrite 2>/dev/null || true

  # Fix 5: Prometheus secret (monitoring stack)
  if oc get configmap prometheus-web-tls-ca -n redhat-ods-monitoring &>/dev/null; then
    if ! oc get secret prometheus-web-tls-ca -n redhat-ods-monitoring &>/dev/null; then
      echo ""
      echo ">>> Creating prometheus-web-tls-ca secret..."
      CA_DATA=$(oc get configmap prometheus-web-tls-ca -n redhat-ods-monitoring -o jsonpath='{.data.service-ca\.crt}')
      oc create secret generic prometheus-web-tls-ca -n redhat-ods-monitoring --from-literal=service-ca.crt="$CA_DATA"
      oc delete pod -n redhat-ods-monitoring -l app.kubernetes.io/name=prometheus --ignore-not-found 2>/dev/null || true
    fi
  fi

  # Fix 6: Kuadrant Perses datasource secret (may be GC'd on restart)
  if ! oc get secret kuadrant-prometheus-datasource-secret -n redhat-ods-applications &>/dev/null; then
    echo ""
    echo ">>> Recreating kuadrant-prometheus-datasource-secret..."
    DS_TOKEN=$(oc create token data-science-prometheus-cluster-proxy -n redhat-ods-monitoring --duration=8760h)
    CA_CERT=$(oc get secret cluster-prometheus-datasource-secret -n redhat-ods-monitoring -o jsonpath='{.data.ca\.crt}' | base64 -d)
    oc create secret generic kuadrant-prometheus-datasource-secret \
      -n redhat-ods-applications \
      --from-literal=token="${DS_TOKEN}" \
      --from-literal=ca.crt="${CA_CERT}"
    echo "   Secret recreated."
  fi

  # Fix 7: RBAC for Thanos tenancy in kuadrant-system
  if ! oc get rolebinding kuadrant-metrics-reader -n kuadrant-system &>/dev/null; then
    echo ""
    echo ">>> Creating kuadrant-system RoleBinding for Perses datasource..."
    oc adm policy add-role-to-user view \
      system:serviceaccount:redhat-ods-monitoring:data-science-prometheus-cluster-proxy \
      -n kuadrant-system 2>/dev/null || true
  fi

  # Fix 8: Perses service alias
  if ! oc get svc perses -n redhat-ods-monitoring &>/dev/null; then
    echo ""
    echo ">>> Recreating 'perses' service alias..."
    cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: perses
  namespace: redhat-ods-monitoring
  labels:
    app: perses-alias
spec:
  type: ExternalName
  externalName: data-science-perses.redhat-ods-monitoring.svc.cluster.local
EOF
  fi

  echo ""
  echo "========================================="
  echo "Recovery complete. Run this script again without --fix to verify."
  echo "========================================="
fi

exit $ERRORS
