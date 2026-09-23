#!/usr/bin/env bash
set -euo pipefail

echo "[Running set-up.sh]"

METALLB_VERSION="v0.16.1"

echo "[1/4] Creating kind cluster..."
kind create cluster --config ~/manifests/kind-cluster/kindconfig.yaml

echo "[2/4] Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "[3/4] Installing MetalLB ${METALLB_VERSION}..."
kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

echo "Waiting for MetalLB pods to become ready..."
kubectl -n metallb-system rollout status deployment/controller --timeout=180s
kubectl -n metallb-system rollout status daemonset/speaker --timeout=180s

echo "[4/4] Configuring MetalLB IP address pool..."
# Kind attaches every node container to a docker network named "kind".
# Carve out an unused slice near the top of that network's IPv4 subnet
# for MetalLB to hand out as LoadBalancer IPs.
SUBNET="$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep -v ':' | head -n1)"
if [ -z "${SUBNET}" ]; then
  echo "ERROR: could not determine the docker 'kind' network subnet" >&2
  exit 1
fi
PREFIX="$(echo "${SUBNET}" | cut -d/ -f2)"
if [ "${PREFIX}" -le 16 ]; then
  BASE="$(echo "${SUBNET}" | cut -d. -f1-2)"
  POOL_START="${BASE}.255.200"
  POOL_END="${BASE}.255.250"
else
  BASE="$(echo "${SUBNET}" | cut -d/ -f1 | cut -d. -f1-3)"
  POOL_START="${BASE}.200"
  POOL_END="${BASE}.250"
fi

echo "Detected kind network subnet: ${SUBNET}"
echo "MetalLB address pool: ${POOL_START}-${POOL_END}"

sed -e "s/POOL_START/${POOL_START}/" -e "s/POOL_END/${POOL_END}/" \
  ~/manifests/kind-cluster/metallb-config.yaml | kubectl apply -f -

echo "Done. Cluster nodes:"
kubectl get nodes -o wide
echo "MetalLB status:"
kubectl get pods -n metallb-system
