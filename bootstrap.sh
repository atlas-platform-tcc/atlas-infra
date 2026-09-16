#!/usr/bin/env bash
#
# Bootstrap the Atlas local environment from scratch:
#   kind cluster  ->  Argo CD  ->  ingress-nginx  ->  root Application (app-of-apps)  ->  Argo CD reconciles everything from git.
#
# Services are created by the Golden Path (atlas-api), which adds their entries to
# atlas-gitops/apps/; the root Application then reconciles them here.
#
# Idempotent: safe to re-run. Requires the Docker daemon running.
# Usage:  ./atlas-infra/bootstrap.sh
set -euo pipefail

CLUSTER="atlas-local"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
# ingress-nginx manifest for the kind provider (maps to the host's 80/443, ADR atlas-infra/0007).
INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> 1/4  kind cluster"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "    cluster '$CLUSTER' already exists — skipping create"
else
  kind create cluster --config "$SCRIPT_DIR/kind-config.yaml"
fi

echo "==> 2/4  Argo CD (server-side apply avoids the oversized-CRD error)"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts -f "$ARGOCD_MANIFEST"

# Faster reconciliation for local development: poll git every 30s instead of the
# default 180s. A GitHub webhook cannot reach a local kind cluster, so shorter
# polling is how new services (root discovery) and promotions (day-2 deploy) show
# up quickly without a manual `argocd app get --refresh`. The application-controller
# reads timeout.reconciliation from argocd-cm, so it must be restarted to pick it up.
kubectl -n argocd patch configmap argocd-cm --type merge \
  -p '{"data":{"timeout.reconciliation":"30s"}}'
kubectl -n argocd rollout restart statefulset argocd-application-controller

kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=180s
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=180s

echo "==> 3/4  ingress-nginx (exposes each service on http://<name>.127.0.0.1.nip.io)"
kubectl apply -f "$INGRESS_MANIFEST"
# The admission webhook must be Ready before any Ingress can be admitted; without
# this wait, the first service's Ingress apply can race and fail.
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
kubectl -n ingress-nginx wait --for=condition=complete job/ingress-nginx-admission-patch --timeout=120s || true

echo "==> 4/4  root Application (app-of-apps) — Argo CD reconciles services from git"
kubectl apply -f "$ROOT/atlas-gitops/bootstrap/root.yaml"

echo
echo "Done. Watch reconciliation with:"
echo "  kubectl -n argocd get applications"
