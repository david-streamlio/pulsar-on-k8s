#!/usr/bin/env bash
#
# One-command deploy of an MCP-enhanced StreamNative Private Cloud cluster:
#   sn-operator -> license -> JWT auth secrets -> cert-manager/TLS -> Pulsar cluster -> snmcp
#
# Defaults to the ZooKeeper manifest (03-pulsar-zookeeper.yaml) because it supports
# package management + Function-Mesh jar functions. Use CLUSTER_MANIFEST to switch to
# Oxia (02-pulsar-oxia.yaml) for a ZK-free cluster (no package management).
#
# Usage:
#   ./deploy.sh
#
# microk8s users:
#   KUBECTL="microk8s kubectl" HELM="microk8s helm3" ./deploy.sh
#
# Toggles (env):
#   CLUSTER_MANIFEST=02-pulsar-oxia.yaml   # default: 03-pulsar-zookeeper.yaml
#   ENABLE_TLS=false                       # skip cert-manager + broker TLS
#   CERT_MANAGER_VERSION=v1.16.2
#
# Prerequisites: a StreamNative license (configs/00-license-secret.yaml from the
# template, or an existing `sn-license` secret in `operators`) and `snctl` on PATH
# (for JWT key/token generation).
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
SNCTL="${SNCTL:-snctl}"
ENABLE_TLS="${ENABLE_TLS:-true}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"
CLUSTER_MANIFEST="${CLUSTER_MANIFEST:-03-pulsar-zookeeper.yaml}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS="$DIR/configs"

echo "==> [1/8] namespaces"
for ns in operators pulsar; do
  $KUBECTL create namespace "$ns" --dry-run=client -o yaml | $KUBECTL apply -f -
done

echo "==> [2/8] license"
if [ -f "$CONFIGS/00-license-secret.yaml" ]; then
  $KUBECTL apply -f "$CONFIGS/00-license-secret.yaml"
elif $KUBECTL get secret sn-license -n operators >/dev/null 2>&1; then
  echo "    using existing sn-license secret"
else
  echo "ERROR: no license. Create $CONFIGS/00-license-secret.yaml from the .template," >&2
  echo "       or create a labelled 'sn-license' secret in the operators namespace." >&2
  exit 1
fi

echo "==> [3/8] sn-operator (helm)"
$HELM repo add streamnative https://charts.streamnative.io >/dev/null 2>&1 || true
$HELM repo update streamnative >/dev/null
$HELM upgrade --install sn-operator streamnative/sn-operator -n operators --wait

echo "==> [4/8] JWT auth secrets"
if $KUBECTL get secret token-public-key -n pulsar >/dev/null 2>&1; then
  echo "    auth secrets already exist — skipping token generation"
else
  TMP="$(mktemp -d)"
  $SNCTL pulsar admin token create-key-pair \
    --output-private-key "$TMP/token-private.key" --output-public-key "$TMP/token-public.key"
  for s in broker-admin proxy-admin client; do
    $SNCTL pulsar admin token create --private-key-file "$TMP/token-private.key" --subject "$s" 2>&1 \
      | grep -oE 'eyJ[A-Za-z0-9_.-]+' > "$TMP/$s.token"
  done
  $KUBECTL create secret generic token-public-key -n pulsar --from-file=my-public.key="$TMP/token-public.key"
  for s in broker-admin proxy-admin client; do
    $KUBECTL create secret generic "$s" -n pulsar --from-file=token="$TMP/$s.token"
  done
  echo "    tokens generated under $TMP — keep them to configure clients (e.g. the MCP Bearer token)"
fi

echo "==> [5/8] cert-manager + TLS certs"
if [ "$ENABLE_TLS" = "true" ]; then
  $KUBECTL apply -f "https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml"
  $KUBECTL -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
  $KUBECTL apply -f "$CONFIGS/03-pulsar-tls.yaml"
  $KUBECTL wait --for=condition=Ready certificate/pulsar-server-tls -n pulsar --timeout=120s
else
  echo "    ENABLE_TLS=false — skipping (NOTE: 02-pulsar-oxia.yaml references spec.tls; remove it or keep ENABLE_TLS=true)"
fi

echo "==> [6/8] Pulsar cluster ($CLUSTER_MANIFEST)"
$KUBECTL apply -f "$CONFIGS/$CLUSTER_MANIFEST"

echo "==> [7/8] waiting for the cluster"
for i in $(seq 1 60); do
  $KUBECTL get statefulset private-cloud-broker -n pulsar >/dev/null 2>&1 && break
  sleep 5
done
$KUBECTL rollout status statefulset/private-cloud-broker -n pulsar --timeout=600s
$KUBECTL wait --for=condition=ready pod -l cloud.streamnative.io/component=proxy -n pulsar --timeout=300s || true

echo "==> [8/8] snmcp MCP server (helm)"
$HELM upgrade --install snmcp streamnative/snmcp -n pulsar -f "$CONFIGS/snmcp-values.yaml" --wait

echo
echo "================================================================"
echo " Done. MCP-enhanced Pulsar cluster is up."
MCP_IP="$($KUBECTL get svc snmcp -n pulsar -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
echo "  MCP endpoint : http://${MCP_IP:-<pending>}:9090/mcp"
echo "  Auth         : each client sends 'Authorization: Bearer <pulsar-token>'"
echo "                 (multi-session passthrough — no token stored server-side)"
echo "================================================================"
