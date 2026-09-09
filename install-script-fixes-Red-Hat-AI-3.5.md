# OCP MaaS Demo — Installation Script Fixes

**Repository:** `ocp-maas-devspaces-chatbot`  
**RHOAI Version:** 3.5.0  
**Date:** 2026-09-09

---

## Overview

The `full-setup.sh` script was written against RHOAI 3.4.x. Running it against a cluster with
RHOAI 3.5.0 exposed six files requiring fixes due to deprecated fields, renamed API conditions,
changed service ports, missing CRDs, wrong namespaces, and renamed Kubernetes resources.

---

## Fix 1 — `setup/04-rhoai-config.sh`

**Problem:** `spec.dashboardConfig.maasAuthPolicies` was deprecated and removed in RHOAI 3.5.0.
The OdhDashboardConfig validation webhook rejects the field with:

```
The OdhDashboardConfig "odh-dashboard-config" is invalid: spec.dashboardConfig:
Invalid value: "object": no such key: maasAuthPolicies evaluating rule:
DEPRECATED: spec.dashboardConfig.maasAuthPolicies must be removed or left unchanged.
```

**Fix:** Removed the `"maasAuthPolicies": true` line from the `oc patch` payload in step 4.

---

## Fix 2 — `setup/05-model-registry.sh`

**Problem:** The Model Registry REST API is served by the `rest-container` on port **8080** inside
the pod. The Kubernetes Service only exposes port **8443** (the `kube-rbac-proxy` sidecar, which
requires an auth token). The script addressed the API via the Service DNS name on port 8080 —
a port not exposed by the Service — causing `curl` to hang until timeout.

```bash
# Before (hangs — port 8080 not on the Service)
MR_SVC="http://default-registry.rhoai-model-registries.svc.cluster.local:8080/..."

# After (correct — exec is inside the pod, localhost:8080 hits rest-container directly)
MR_SVC="http://localhost:8080/api/model_registry/v1alpha3"
```

**Applies to:** All `oc exec deployment/default-registry` curl calls in this script.

---

## Fix 3 — `manifests/model/llm-inference-service.yaml`

**Problem:** The `LLMInferenceService` referenced an `LLMInferenceServiceConfig` named
`v3-4-2-kserve-config-llm-template-nvidia-cuda` which does not exist on RHOAI 3.5.0.
Available configs use the `v3-5-0` prefix. The resource was created in a `NewObservedGenFailure`
state with condition:

```
ConfigNotFound: LLMInferenceServiceConfig "v3-4-2-kserve-config-llm-template-nvidia-cuda"
not found in namespaces [models-as-a-service redhat-ods-applications]
```

**Fix:** Updated the `baseRefs` name to match the RHOAI 3.5.0 single-node NVIDIA CUDA config:

```yaml
# Before
spec:
  baseRefs:
    - name: v3-4-2-kserve-config-llm-template-nvidia-cuda

# After
spec:
  baseRefs:
    - name: v3-5-0-kserve-config-llm-single-node-template-nvidia-cuda
```

The existing `LLMInferenceService` was deleted and re-applied after the fix.

---

## Fix 4 — `setup/06-deploy-model.sh`

**Problem:** The script applies a `LlamaStackDistribution` resource (`llamastack.io/v1alpha1`)
for the Gen AI Playground, but the CRD is not installed. RHOAI 3.5.0 lists
`llamastackoperator` as a DSC component (`managementState: Managed`) but ships no images
for it — the component status is `{}` with no releases. The operator that provides the
`LlamaStackDistribution` CRD is not deployed, causing `oc apply` to fail with:

```
no matches for kind "LlamaStackDistribution" in version "llamastack.io/v1alpha1"
ensure CRDs are installed first
```

With `set -euo pipefail` at the top of the script, this error aborts the entire phase.

**Fix:** Added a CRD existence guard around both the `oc apply` and the readiness wait loop.
If the CRD is absent the step is skipped with a warning and the script continues.

```bash
if oc api-resources 2>/dev/null | grep -q "LlamaStackDistribution"; then
  oc apply -f "${MANIFESTS_DIR}/playground/llama-stack-config.yaml"
  oc apply -f "${MANIFESTS_DIR}/playground/llamastack-distribution.yaml"
  # ... wait loop ...
else
  echo "WARNING: LlamaStackDistribution CRD not available. Skipping Gen AI Playground."
fi
```

---

## Fix 5 — `setup/07-verify-maas.sh`

Three independent bugs in the verification checks:

### 5a — Wrong namespace for `maas-api`

```bash
# Before — deployment does not exist in this namespace
oc get deployment maas-api -n redhat-ods-applications ...

# After — correct namespace
oc get deployment maas-api -n redhat-ai-gateway-infra ...
```

### 5b — Renamed DSC condition

The `ModelsAsServiceReady` condition was renamed to `ModelsAsAServiceReady` in RHOAI 3.5.0:

```bash
# Before
-o jsonpath='{.status.conditions[?(@.type=="ModelsAsServiceReady")].status}'

# After
-o jsonpath='{.status.conditions[?(@.type=="ModelsAsAServiceReady")].status}'
```

### 5c — Model registry URL and missing curl timeout

Same service port issue as Fix 2, plus no `--max-time` causing silent hang:

```bash
# Before
MR_SVC="http://default-registry.rhoai-model-registries.svc.cluster.local:8080/..."
curl -s "${MR_SVC}/registered_models" ...

# After
MR_SVC="http://localhost:8080/api/model_registry/v1alpha3"
curl -s --max-time 15 "${MR_SVC}/registered_models" ...
```

---

## Fix 6 — `setup/08-setup-subscriptions.sh`

Two independent bugs:

### 6a — Non-existent API key endpoint

The script POSTs to `/maas-api/v1/api-keys` to generate per-subscription API keys.
This endpoint does not exist in MaaS v0.2.0 (returns 404). The fix checks endpoint
availability and falls back to the OpenShift Bearer token, which the MaaS gateway
already accepts for authentication (confirmed by HTTP 200 on model list endpoint):

```bash
API_KEY_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  "${MAAS_URL}/v1/api-keys" -H "Authorization: Bearer ${TOKEN}")

if [[ "$API_KEY_CODE" == "200" || "$API_KEY_CODE" == "405" ]]; then
  # Use MaaS API key endpoint
else
  # Fall back to OpenShift Bearer token
  DEVSPACES_KEY="${TOKEN}"
  CHATBOT_KEY="${TOKEN}"
fi
```

### 6b — Wrong resource type and name for tenant telemetry patch

```bash
# Before — resource type and name both wrong; Tenant CR does not exist
oc patch tenants.maas.opendatahub.io default-tenant -n models-as-a-service ...

# After — correct resource is AITenant named models-as-a-service in ai-tenants namespace
oc patch aitenants.maas.opendatahub.io models-as-a-service -n ai-tenants ...
```

---

## Manual Cluster Fix — Kuadrant / Limitador

**Problem:** MaaS subscriptions showed `Degraded` phase with:

```
[Limitador Operator] is not installed,
please restart Kuadrant Operator pod once dependency has been installed
```

The Limitador operator CSV was `Succeeded` and its controller pod was running, but the
Kuadrant operator had started before Limitador was ready during Phase 1 and cached a
"not installed" state. The Kuadrant operator never re-checks at runtime.

**Fix:** Deleted the Kuadrant operator pod to force a fresh start:

```bash
oc delete pod -n openshift-operators \
  $(oc get pods -n openshift-operators | grep kuadrant-operator-controller | awk '{print $1}')
```

On restart the operator detected Limitador, created the `Limitador` CR, and the
`limitador-limitador` pod started. Both MaaS subscriptions moved from `Degraded` to `Active`.

**Root cause:** Phase 1 installs all operators in parallel via `oc apply -k`. Kuadrant and
Limitador operators race during CSV reconciliation. If Kuadrant wins the race, it caches
"Limitador absent" permanently until restarted. A robust fix would be to add an explicit
`oc wait` for the Limitador operator CSV before the Kuadrant CR is created.

---

## Summary Table

| File | Change | Root Cause |
|---|---|---|
| `04-rhoai-config.sh` | Remove `maasAuthPolicies` from dashboard patch | Field deprecated and removed in RHOAI 3.5.0 |
| `05-model-registry.sh` | Change service URL to `localhost:8080` | Service only exposes 8443 (kube-rbac-proxy); port 8080 is pod-local only |
| `manifests/model/llm-inference-service.yaml` | Update `baseRefs` to `v3-5-0-kserve-config-llm-single-node-template-nvidia-cuda` | LLMInferenceServiceConfig name changed between RHOAI 3.4.x and 3.5.0 |
| `06-deploy-model.sh` | Guard LlamaStack steps behind CRD existence check | `llamastackoperator` DSC component not yet implemented in RHOAI 3.5.0 |
| `07-verify-maas.sh` | Fix namespace, DSC condition name, URL, add curl timeout | Three separate 3.4→3.5 regressions |
| `08-setup-subscriptions.sh` | Fallback API key; fix tenant resource name/type | API key endpoint removed; `Tenant` CR replaced by `AITenant` |
| Cluster (manual) | Delete Kuadrant operator pod | Operator start-up race with Limitador during Phase 1 |
