#!/usr/bin/env bash
#
# Bootstrap the Atlas local environment from scratch:
#   kind cluster  ->  Argo CD  ->  root Application (app-of-apps)  ->  Argo CD reconciles everything from git.
#
# Idempotent: safe to re-run. Requires the Docker daemon running.
# Usage:  ./atlas-infra/bootstrap.sh
set -euo pipefail

CLUSTER="atlas-local"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> 1/4  kind cluster"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "    cluster '$CLUSTER' already exists — skipping create"
else
  kind create cluster --config "$SCRIPT_DIR/kind-config.yaml"
fi

# Local-dev shim: with no registry, the service image must live inside the kind node.
# In the full flow CI publishes an immutable image to a registry and this step goes away.
echo "==> 2/4  build + load service image (local dev, no registry)"
docker build -t hello-service:dev "$ROOT/atlas-templates/go-service-template"
kind load docker-image hello-service:dev --name "$CLUSTER"

echo "==> 3/4  Argo CD (server-side apply avoids the oversized-CRD error)"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts -f "$ARGOCD_MANIFEST"
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=180s
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s

echo "==> 4/4  root Application (app-of-apps) — Argo CD reconciles the rest from git"
kubectl apply -f "$ROOT/atlas-gitops/bootstrap/root.yaml"

echo
echo "Done. Watch reconciliation with:"
echo "  kubectl -n argocd get applications"
echo "  kubectl -n hello get pods"
echo "  curl -s http://localhost:30080/healthz   # -> ok"
