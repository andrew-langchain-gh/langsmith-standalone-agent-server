#!/usr/bin/env bash
#
# Step 5 of docs/deployment-guide.md — deploy the SHARED Postgres + Redis for the
# standalone Agent Server demo, then create one database per agent.
#
# Safe to re-run (idempotent). The Postgres password is generated once and stored in
# the `postgres-credentials` secret; on a re-run it is read back from that secret.
#
# IMPORTANT: the later helm-install steps (6 and 8) need $PG_PASSWORD in your shell.
# This script prints an `export PG_PASSWORD=...` line at the end — run it in your
# terminal before deploying the agents.
#
# Usage:
#   deploy/deploy-shared-datastores.sh
#   PG_PASSWORD=my-own-password deploy/deploy-shared-datastores.sh   # bring your own
set -euo pipefail

NS=langgraph-shared
DATABASES=(weather calculator)

# Resolve the repo root from this script's location so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/deploy/shared-datastores.yaml"

echo "==> namespace + Postgres password secret"
kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

if kubectl -n "$NS" get secret postgres-credentials >/dev/null 2>&1; then
  echo "    secret 'postgres-credentials' already exists — reusing it"
  PG_PASSWORD="$(kubectl -n "$NS" get secret postgres-credentials \
    -o jsonpath='{.data.password}' | base64 -d)"
else
  PG_PASSWORD="${PG_PASSWORD:-$(openssl rand -hex 16)}"
  kubectl -n "$NS" create secret generic postgres-credentials \
    --from-literal=password="$PG_PASSWORD"
  echo "    created secret 'postgres-credentials'"
fi

echo "==> deploying Postgres + Redis"
kubectl apply -f "$MANIFEST"
kubectl -n "$NS" rollout status statefulset/postgres
kubectl -n "$NS" rollout status deploy/redis

echo "==> creating one database per agent (isolation within the shared instance)"
for db in "${DATABASES[@]}"; do
  if kubectl -n "$NS" exec postgres-0 -- \
       psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1; then
    echo "    database '$db' already exists"
  else
    kubectl -n "$NS" exec postgres-0 -- psql -U postgres -c "CREATE DATABASE $db;"
    echo "    created database '$db'"
  fi
done

cat <<EOF

======================================================================
 Shared Postgres + Redis are up; databases ${DATABASES[*]} are ready.

 Steps 6 and 8 (agent installs) need PG_PASSWORD in your shell. Run:

   export PG_PASSWORD='$PG_PASSWORD'
======================================================================
EOF
