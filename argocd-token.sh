#!/usr/bin/env bash
#
# Prints an API token for the read-only `atlas` Argo CD account (created by bootstrap.sh),
# for ARGOCD_TOKEN in atlas-api/.env. The token is a secret: never commit it.
#
# Uses the Argo CD REST API through a short-lived port-forward instead of the argocd CLI:
# the CLI first tries plain gRPC (HTTP/2), which kubectl port-forward resets, killing the
# forward ("lost connection to pod"). A new cluster needs a new token (new signing key).
#
# Usage:  ./atlas-infra/argocd-token.sh            (EXPIRES_IN_SECONDS=31536000 → 1 year; 0 = never)
set -euo pipefail

PORT="${PORT:-18083}"
EXPIRES="${EXPIRES_IN_SECONDS:-31536000}"
URL="https://localhost:$PORT"

kubectl -n argocd port-forward svc/argocd-server "$PORT:443" >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -sk -o /dev/null "$URL/api/version" && break
  sleep 0.5
done

PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
[ -n "$PW" ] || { echo "argocd-initial-admin-secret not found" >&2; exit 1; }

ADMIN="$(curl -sk "$URL/api/v1/session" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg p "$PW" '{username: "admin", password: $p}')" | jq -r '.token // empty')"
[ -n "$ADMIN" ] || { echo "admin login failed" >&2; exit 1; }

TOKEN="$(curl -sk -X POST "$URL/api/v1/account/atlas/token" -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $ADMIN" -d "{\"expiresIn\": $EXPIRES}" | jq -r '.token // empty')"
[ -n "$TOKEN" ] || { echo "token generation failed (is the 'atlas' account enabled? re-run bootstrap.sh)" >&2; exit 1; }

echo "$TOKEN"
