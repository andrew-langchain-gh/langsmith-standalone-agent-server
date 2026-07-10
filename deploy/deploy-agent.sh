#!/usr/bin/env bash
#
# Steps 6 & 8 of docs/deployment-guide.md — deploy ONE agent as its own standalone
# Agent Server (its own namespace + Helm release), backed by the shared Postgres/Redis.
#
# Run it once per agent:
#   deploy/deploy-agent.sh weather     1
#   deploy/deploy-agent.sh calculator  2
#
# Arguments:
#   $1  agent name   — must match deploy/<agent>-values.yaml and the built image
#                      docker.io/$DOCKERHUB_USER/<agent>-agent. Also the Postgres db name.
#   $2  redis db num — Redis logical DB for this agent; MUST be unique per deployment.
#
# Required environment (same vars as the guide; nothing is written to disk):
#   LICENSE_KEY  LANGSMITH_API_KEY  ANTHROPIC_API_KEY
#   DOCKERHUB_USER  DOCKERHUB_TOKEN  PG_PASSWORD
#
# Safe to re-run: secrets are applied idempotently and it uses `helm upgrade --install`.
set -euo pipefail

AGENT="${1:-}"
REDIS_DB="${2:-}"

if [[ -z "$AGENT" || -z "$REDIS_DB" ]]; then
  echo "usage: $(basename "$0") <agent-name> <redis-db-number>" >&2
  echo "  e.g. $(basename "$0") weather 1" >&2
  exit 2
fi
if ! [[ "$REDIS_DB" =~ ^[0-9]+$ ]]; then
  echo "error: redis-db-number must be a non-negative integer (got '$REDIS_DB')" >&2
  exit 2
fi

# Fail early with a clear message if any required secret/var is missing.
: "${LICENSE_KEY:?set LICENSE_KEY}"
: "${LANGSMITH_API_KEY:?set LANGSMITH_API_KEY}"
: "${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY}"
: "${DOCKERHUB_USER:?set DOCKERHUB_USER}"
: "${DOCKERHUB_TOKEN:?set DOCKERHUB_TOKEN}"
: "${PG_PASSWORD:?set PG_PASSWORD (printed by deploy-shared-datastores.sh)}"

# Derive everything else from the agent name (mirrors the guide's naming).
NS="$AGENT"
RELEASE="${AGENT}-agent"
IMAGE_REPO="docker.io/${DOCKERHUB_USER}/${AGENT}-agent"
PG_HOST="postgres.langgraph-shared.svc.cluster.local"
REDIS_HOST="redis.langgraph-shared.svc.cluster.local"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VALUES="$REPO_ROOT/deploy/${AGENT}-values.yaml"
[[ -f "$VALUES" ]] || { echo "error: values file not found: $VALUES" >&2; exit 1; }

echo "==> [$AGENT] namespace"
kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

echo "==> [$AGENT] secrets (license / LangSmith / Anthropic, and Docker Hub pull secret)"
# Key names MUST match what the chart's existingSecretName wiring expects:
#   langgraph_cloud_license_key -> LANGGRAPH_CLOUD_LICENSE_KEY
#   api_key                     -> LANGSMITH_API_KEY
kubectl -n "$NS" create secret generic agent-secrets \
  --from-literal=langgraph_cloud_license_key="$LICENSE_KEY" \
  --from-literal=api_key="$LANGSMITH_API_KEY" \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create secret docker-registry dockerhub \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username="$DOCKERHUB_USER" --docker-password="$DOCKERHUB_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> [$AGENT] helm upgrade --install $RELEASE"
helm upgrade --install "$RELEASE" langchain/langgraph-cloud \
  -n "$NS" -f "$VALUES" \
  --set images.apiServerImage.repository="$IMAGE_REPO" \
  --set-string postgres.external.connectionUrl="postgres://postgres:${PG_PASSWORD}@${PG_HOST}:5432/${AGENT}?sslmode=disable" \
  --set-string redis.external.connectionUrl="redis://${REDIS_HOST}:6379/${REDIS_DB}"

echo "==> [$AGENT] waiting for rollout"
kubectl -n "$NS" rollout status "deploy/${RELEASE}-langgraph-cloud-api-server"

echo
echo "[$AGENT] deployed. Find its address with:"
echo "  kubectl -n $NS get svc -l app.kubernetes.io/name=langgraph-cloud -o wide"
