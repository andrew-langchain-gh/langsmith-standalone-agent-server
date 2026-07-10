# Deploy a LangGraph Agent to a Standalone Agent Server on Kubernetes

A self-contained, cluster-agnostic guide to running a LangGraph agent as a **self-hosted
standalone Agent Server** — no LangSmith control plane. Works on any Kubernetes cluster
(cloud or on-prem). Everything cluster-specific is a clearly marked placeholder.

Reference: <https://docs.langchain.com/langsmith/deploy-standalone-server>

---

## What you're deploying

A standalone Agent Server is a **data plane you own**: one server container plus a
Postgres and a Redis. There is no control plane — you build an image, push it, deploy it.

```
   build host                 registry                 Kubernetes
 ┌────────────┐   push   ┌────────────────┐   pull   ┌──────────────────────┐
 │ agent code │ ───────▶ │ <your image>   │ ───────▶ │ Agent Server (pod)   │
 │ langgraph  │          └────────────────┘          │   ├─▶ Postgres        │
 │   build    │                                      │   └─▶ Redis           │
 └────────────┘   helm install ──────────────────────▶ (runs your graph)    │
                                                      └──────────────────────┘
```

**Mental model — three separate steps connected by a registry:**

```
langgraph build   →  image in local Docker
docker push       →  image in a registry the cluster can pull from   (nothing running yet)
helm install      →  Kubernetes pulls it and starts the pod          ← this makes it live
```

Pushing to a registry does **not** auto-deploy. Helm is what turns an image into a
running agent. (Auto-deploy-on-push is a *control plane* feature; standalone servers
leave the deploy trigger to you / your CI.)

---

## Prerequisites

**Tools (on your build machine):**

- `docker` (the `langgraph` CLI shells out to `docker build`)
- `langgraph-cli` — `pip install langgraph-cli`
- `kubectl` and `helm` 3, configured for your cluster

**Credentials:**

- **`LANGGRAPH_CLOUD_LICENSE_KEY`** — LangSmith enterprise license key (validated once at
  server startup)
- **`LANGSMITH_API_KEY`** — LangSmith API key
- A **model provider key** for whatever your agent calls (e.g. `ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`)
- Outbound network access to `https://beacon.langchain.com` for license verification
  (unless you run in air-gapped/offline mode)

**Cluster capabilities:**

- **Postgres ≥ 14** and **Redis ≥ 5** reachable from the cluster (bring your own, or
  deploy them — see Step 4)
- A **container registry** the cluster's nodes can pull from (Step 3)
- A way to **reach the server's HTTP port** — a `LoadBalancer`, an `Ingress`, a
  `NodePort`, or just `kubectl port-forward` (Step 6)
- A default **StorageClass** if you deploy Postgres in-cluster

Add the Helm chart repo:

```bash
helm repo add langchain https://langchain-ai.github.io/helm
helm repo update
```

---

## Step 1 — Write your agent

An agent is a directory with three files. The Agent Server loads it via `langgraph.json`.

`graph.py` — exposes a compiled graph named `graph`:

```python
import os
from langchain.agents import create_agent
from langchain_core.tools import tool

@tool
def get_weather(city: str) -> str:
    """Get the current weather for a city."""
    return f"It's sunny and 22°C in {city}."  # replace with a real API call

graph = create_agent(
    model=os.getenv("MODEL_NAME", "anthropic:claude-sonnet-5"),
    tools=[get_weather],
    system_prompt="You are a helpful weather assistant.",
)
```

> **Do NOT attach a checkpointer** (e.g. `MemorySaver`) in code. The Agent Server
> provides its own Postgres-backed persistence at runtime; compiling one in conflicts
> with it. Also **do not read secrets from a baked-in `.env`** — inject them at deploy
> time (Step 5).

`langgraph.json` — points at the graph. Add more entries to serve several agents from
one server:

```json
{
  "dependencies": ["."],
  "graphs": {
    "weather": "./graph.py:graph"
  }
}
```

`pyproject.toml`:

```toml
[project]
name = "weather-agent"
version = "0.1.0"
requires-python = ">=3.11,<4.0"
dependencies = [
  "langgraph>=1.0,<2.0",
  "langchain>=1.0,<2.0",
  "langchain-core>=1.0,<2.0",
  "langchain-anthropic>=0.3,<1.0"
]

[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[tool.setuptools]
py-modules = ["graph"]
```

Test locally first (optional): `ANTHROPIC_API_KEY=... langgraph dev`.

---

## Step 2 — Build the image

```bash
export IMAGE=<your-registry>/weather-agent:0.1     # e.g. docker.io/acme/weather-agent:0.1
langgraph build -t "$IMAGE"
```

This bakes your graph onto the official `langchain/langgraph-api` base image.

> **Gotcha — build-time network.** `langgraph build` runs `pip install` *inside*
> `docker build`. If your build host's Docker bridge has no outbound network (common on
> some VMs/CI), the install fails with a DNS / `Try again` error. Fix by building on the
> host network — everything after `--` is passed to `docker build`:
> ```bash
> langgraph build -t "$IMAGE" -- --network=host
> ```

---

## Step 3 — Make the image pullable by the cluster

Cluster nodes pull images **over the network** — they cannot see your local Docker
daemon. Push the image somewhere the nodes can reach. Pick one:

- **Managed registry** (Docker Hub, ECR, GCR, ACR, GitHub Container Registry, Harbor…) —
  recommended. `docker login`, then `docker push "$IMAGE"`.
- **In-cluster registry** (e.g. the `registry:2` image on a Service the nodes can reach)
  — good for air-gapped/on-prem. Note: an HTTP (non-TLS) registry requires configuring
  each node's container runtime to trust it as "insecure."

```bash
docker push "$IMAGE"
```

**Private registry?** Create a pull secret in the target namespace and reference it in
the values file (Step 5):

```bash
kubectl -n <namespace> create secret docker-registry regcred \
  --docker-server=<registry-host> \
  --docker-username=<user> --docker-password=<token-or-password>
```

> **Gotcha — reused tags don't redeploy.** Kubernetes won't re-pull a tag it already has.
> Use a **new tag** each build (`:0.2`, `:0.3`, …), or force `kubectl rollout restart`.

---

## Step 4 — Provide Postgres and Redis

The server needs a **Postgres ≥ 14** and a **Redis ≥ 5**. Use managed services (RDS,
Cloud SQL, ElastiCache, MemoryStore…) or deploy them in-cluster.

Requirements and tips:

- The Postgres role should be able to create the extensions the server installs at
  startup (`btree_gin`, `btree_gist`, `pgcrypto`, `citext`, `ltree`, `pg_trgm`) — a
  superuser/owner role covers this.
- **One database per deployment.** Multiple Agent Servers can share a Postgres instance
  as long as each uses a **different database**; likewise they can share a Redis instance
  using a **different DB number** (`redis://host:6379/1`, `/2`, …).
- You will pass connection URLs in Step 5:
  - `postgres://<user>:<pass>@<host>:5432/<db>?sslmode=<mode>`
  - `redis://<host>:6379/<db-number>`

---

## Step 5 — Deploy with the Helm chart

Create a namespace and a secret holding the license, LangSmith, and model keys.

> **⚠️ Gotcha — secret key names are exact.** When you use `config.existingSecretName`,
> the chart reads these specific keys. Getting them wrong is a silent
> `License verification failed` → `CrashLoopBackOff`:
> | Env var the server needs | Secret key name it reads |
> | --- | --- |
> | `LANGGRAPH_CLOUD_LICENSE_KEY` | **`langgraph_cloud_license_key`** |
> | `LANGSMITH_API_KEY` | **`api_key`** |
> Your model key (e.g. `ANTHROPIC_API_KEY`) is injected separately via `extraEnv`, so
> name that one however your `extraEnv` references it.

```bash
kubectl create namespace weather

kubectl -n weather create secret generic agent-secrets \
  --from-literal=langgraph_cloud_license_key="$LANGGRAPH_CLOUD_LICENSE_KEY" \
  --from-literal=api_key="$LANGSMITH_API_KEY" \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
```

Create a `values.yaml`:

```yaml
# --- image ---
images:
  apiServerImage:
    repository: <your-registry>/weather-agent   # NO tag here
    tag: "0.1"
    pullPolicy: Always
  # imagePullSecrets:            # uncomment for a PRIVATE registry
  #   - name: regcred

# --- license + LangSmith key, read from the secret above ---
config:
  existingSecretName: agent-secrets   # keys: langgraph_cloud_license_key, api_key

# --- external Postgres + Redis (disables the chart's bundled ones) ---
postgres:
  external:
    enabled: true
    connectionUrl: ""   # pass via --set-string at install (keeps password off disk)
redis:
  external:
    enabled: true
    connectionUrl: ""   # pass via --set-string at install

apiServer:
  service:
    type: LoadBalancer          # or ClusterIP + Ingress / NodePort — see Step 6
  deployment:
    # inject the model key at runtime (never bake it into the image)
    extraEnv:
      - name: ANTHROPIC_API_KEY
        valueFrom:
          secretKeyRef:
            name: agent-secrets
            key: ANTHROPIC_API_KEY

    # ⚠️ Gotcha — the chart's default probe timeoutSeconds is 1s, which is too tight
    # for `python /api/healthcheck.py`. Without this the pod CrashLoopBackOffs on the
    # STARTUP probe even though the app logs "Application startup complete". Give the
    # probes a realistic 5s timeout.
    startupProbe:
      exec: { command: ["/bin/sh", "-c", "exec python /api/healthcheck.py"] }
      timeoutSeconds: 5
      periodSeconds: 10
      failureThreshold: 12
    readinessProbe:
      exec: { command: ["/bin/sh", "-c", "exec python /api/healthcheck.py"] }
      timeoutSeconds: 5
      periodSeconds: 10
      failureThreshold: 6
    livenessProbe:
      exec: { command: ["/bin/sh", "-c", "exec python /api/healthcheck.py"] }
      timeoutSeconds: 5
      periodSeconds: 30
      failureThreshold: 6
```

Install (connection URLs passed here so the DB password stays off disk):

```bash
helm install weather-agent langchain/langgraph-cloud -n weather -f values.yaml \
  --set-string postgres.external.connectionUrl="postgres://<user>:<pass>@<pg-host>:5432/<db>?sslmode=disable" \
  --set-string redis.external.connectionUrl="redis://<redis-host>:6379/1"

kubectl -n weather rollout status deploy/weather-agent-langgraph-cloud-api-server
```

### What gets created per agent

Each `helm install` (one per agent) creates the following in that agent's namespace,
where `<rel>` is the release name (e.g. `weather-agent`). Note there is **one workload
only** — the Agent Server; Postgres and Redis are **not** created here (they're external
and shared, from Step 4).

| Kind | Name (`<rel>` = release) | Created by | Purpose |
| --- | --- | --- | --- |
| **Deployment** | `<rel>-langgraph-cloud-api-server` | chart | the Agent Server — runs your image (1 replica by default) |
| Pod | `<rel>-langgraph-cloud-api-server-<hash>` | the Deployment | the running container |
| **Service** | `<rel>-langgraph-cloud-api-server` | chart | exposes the server (ports 80/443 → container 8000); type = `apiServer.service.type` |
| Ingress | `<rel>-langgraph-cloud-ingress` | chart | **only if** `ingress.enabled: true` |
| ServiceAccount | `<rel>-langgraph-cloud-api-server` | chart | identity for the api-server pod |
| ServiceAccount | `<rel>-langgraph-cloud-queue` | chart | identity for the background queue workers |
| Secret | `<rel>-langgraph-cloud-postgres` | chart | the Postgres connection URL you passed via `--set-string` |
| Secret | `<rel>-langgraph-cloud-redis` | chart | the Redis connection URL |
| Secret | `agent-secrets` | you (Step 5) | license / LangSmith / model keys (`existingSecretName`) |
| Secret | `<pull-secret>` (e.g. `regcred`) | you | image pull secret — **only for a private registry** |
| Secret | `sh.helm.release.v1.<rel>.v*` | Helm | release history/bookkeeping — ignore |

Inspect them any time with `kubectl -n <namespace> get all,ingress,secret,serviceaccount`.
Deploying a second agent repeats this entire set in its own namespace — fully
independent, pointing at the same shared Postgres/Redis.

---

## Step 6 — Reach it and verify

Get an address for the server, depending on how you exposed it:

```bash
# LoadBalancer:
kubectl -n weather get svc -l app.kubernetes.io/name=langgraph-cloud \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}'

# Or just port-forward from anywhere:
kubectl -n weather port-forward svc/weather-agent-langgraph-cloud-api-server 8123:80
# then use http://localhost:8123
```

```bash
export AGENT=http://<address>
curl -s $AGENT/ok         # {"ok":true}
curl -s -X POST $AGENT/assistants/search -H 'content-type: application/json' -d '{}' \
  | jq '.[].graph_id'     # -> "weather"  (empty [] means no graph baked in)

# run it (stateless)
curl -s -X POST $AGENT/runs/wait -H 'content-type: application/json' -d '{
  "assistant_id":"weather",
  "input":{"messages":[{"role":"user","content":"Weather in Tokyo?"}]}
}' | jq -r '.messages[-1].content'
```

For threads (persistent memory), streaming, the Python/JS SDK, and LangGraph Studio, use
the same REST API — full interactive docs are served at `$AGENT/docs`.

---

## Scaling to many agents

Three levels — reach for the cheapest that meets your isolation needs:

| You want… | Do this | Cost |
| --- | --- | --- |
| Same graph, different config (prompt/model) | Create an **assistant** via the API (`POST /assistants`) | Free, instant |
| Different graphs, shared lifecycle | Add entries to **`graphs`** in one `langgraph.json` | One rebuild + `helm upgrade` |
| Independent scaling / lifecycle / isolation | A separate **`helm install`** per deployment | New release |

Separate releases can **share** one Postgres/Redis (different database name + Redis DB
number each) or use fully dedicated instances.

---

## Day-2 operations

```bash
# new version: build a NEW tag, push, upgrade
langgraph build -t "<registry>/weather-agent:0.2" -- --network=host
docker push "<registry>/weather-agent:0.2"
helm upgrade weather-agent langchain/langgraph-cloud -n weather --reuse-values \
  --set images.apiServerImage.tag=0.2

# rollback
helm rollback weather-agent <REVISION> -n weather

# tear down
helm uninstall weather-agent -n weather && kubectl delete namespace weather
```

---

## Troubleshooting — the non-obvious ones

| Symptom | Cause & fix |
| --- | --- |
| `langgraph build` fails at `pip install` with `pypi.org ... Try again` | Docker build container has no egress — build with ` -- --network=host` (Step 2). |
| `CrashLoopBackOff`, logs say `License verification failed` / `No enterprise license key found` | Secret keys must be **`langgraph_cloud_license_key`** and **`api_key`** (Step 5); and the pod needs egress to `beacon.langchain.com`. |
| `CrashLoopBackOff`, events show `Startup probe failed: ... timed out` but logs say `Application startup complete` | Default probe `timeoutSeconds: 1` is too tight — set `5` (Step 5). |
| `ImagePullBackOff` / `pull access denied` | Private registry without a valid pull secret, or a tag that isn't pushed. Create `regcred` and reference it under `images.imagePullSecrets`. |
| Pod stuck `0/1`, DB connection errors | Wrong connection URL/password, Postgres not ready, or the per-deployment database doesn't exist. |
| `/assistants/search` returns `[]` | No graph baked into the image (you deployed the base image, or `langgraph.json` didn't resolve). Rebuild from the agent directory. |
| Model call returns 401 | Model key missing/invalid — check it's in the secret and wired through `apiServer.deployment.extraEnv`. |
