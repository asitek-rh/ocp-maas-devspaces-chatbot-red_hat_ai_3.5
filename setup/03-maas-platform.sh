#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${REPO_ROOT}/manifests"

source "${SCRIPT_DIR}/ensure-authenticated.sh"

echo "========================================="
echo "Phase 3: MaaS Platform"
echo "========================================="

echo "1. Generating PostgreSQL credentials..."
PG_PASSWORD=$(openssl rand -hex 16)

oc create secret generic maas-postgres-credentials \
  -n redhat-ods-applications \
  --from-literal=password="${PG_PASSWORD}" \
  --dry-run=client -o yaml | oc apply -f -

echo "2. Deploying PostgreSQL for MaaS..."
oc apply -f "${MANIFESTS_DIR}/maas-platform/postgres/postgres.yaml"

echo "   Waiting for PostgreSQL to be ready..."
oc wait statefulset/postgres -n redhat-ods-applications \
  --for=jsonpath='{.status.readyReplicas}'=1 --timeout=120s 2>/dev/null || \
  sleep 30

echo "3. Creating maas-db-config secret..."
DB_URL="postgresql://maasuser:${PG_PASSWORD}@postgres.redhat-ods-applications.svc.cluster.local:5432/maasdb?sslmode=disable"

# maas-api reads DB_CONNECTION_URL from its own namespace (redhat-ai-gateway-infra),
# not from redhat-ods-applications. Both secrets must be kept in sync.
oc create secret generic maas-db-config \
  -n redhat-ods-applications \
  --from-literal=DB_CONNECTION_URL="${DB_URL}" \
  --dry-run=client -o yaml | oc apply -f -

oc create secret generic maas-db-config \
  -n redhat-ai-gateway-infra \
  --from-literal=DB_CONNECTION_URL="${DB_URL}" \
  --dry-run=client -o yaml | oc apply -f -

echo "4. Configuring Authorino TLS..."
oc annotate service authorino-authorino-authorization \
  -n kuadrant-system \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
  --overwrite 2>/dev/null || echo "   Authorino service not yet available, will retry..."

sleep 5

echo "5. Patching Authorino CR for TLS..."
oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
  "spec": {
    "listener": {
      "tls": {
        "enabled": true,
        "certSecretRef": {
          "name": "authorino-server-cert"
        }
      }
    }
  }
}' 2>/dev/null || echo "   Authorino CR not yet available. Will be configured when RHOAI reconciles."

echo "6. Setting Authorino TLS environment variables..."
oc -n kuadrant-system set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  2>/dev/null || echo "   Authorino deployment not yet ready."

echo ""
echo "Phase 3 complete: MaaS platform infrastructure ready."
echo "========================================="
