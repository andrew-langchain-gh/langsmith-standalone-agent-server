# Deploying LangGraph Agents to a Self-Hosted Standalone Agent Server

A step-by-step guide to building LangGraph agents and running them on Kubernetes as
**standalone Agent Servers** — the lightweight, self-hosted deployment option that
needs no LangSmith control plane. We deploy **two** agents as **two independent Helm
releases** that share one Postgres and one Redis, then show how the model scales to
many agents.

> Reference: [Self-host standalone servers](https://docs.langchain.com/langsmith/deploy-standalone-server).

---

## 1. Overview & architecture

A standalone Agent Server is a **data plane you own**: the server container plus its
backing Postgres and Redis. There is no control plane — you build the image, you push
it, you deploy it.

```
┌─ your build host ─┐        ┌─ Docker Hub ──────┐        ┌─── Kubernetes cluster ───┐
│ agent code        │        │ <you>/weather-    │        │  weather ns:             │
│   │               │        │        agent:0.1  │        │    Agent Server ─┐       │
│   ▼ langgraph build│  push │ <you>/calculator- │  pull  │  calculator ns:  │       │
│ docker image ─────┼──────▶ │        agent:0.1  │ ─────▶ │    Agent Server ─┤       │
│   │               │        └───────────────────┘        │  langgraph-shared ns:    │
│   ▼ helm install ─┼──────────────────────────────────────▶  Postgres  Redis ◀┘     │
└───────────────────┘                                     └──────────────────────────┘
```

**The mental model that trips people up:** building an image and running an agent are
two separate steps, connected by a registry — here, **Docker Hub**.

```
langgraph build   →  image in local Docker
docker push       →  image stored on Docker Hub          (nothing running yet!)
helm install      →  Kubernetes pulls it and starts the pod   ← this makes it "live"
```

Pushing to the registry does **not** auto-deploy. Nothing watches the registry. The
agent only runs when Helm tells Kubernetes to run that image. (Auto-deploy on push is
a *control plane* feature; standalone servers deliberately leave the deploy trigger to
you / your CI.)

---

## 2. Prerequisites & cluster confirmation

Confirm your cluster can support standalone Agent Servers with these read-only commands:

```bash
kubectl get nodes                         # all Ready
helm repo list | grep langchain           # langchain repo present (else: helm repo add — see below)
kubectl get ingressclass                  # an ingress controller, if you want Ingress
kubectl get storageclass                  # a default StorageClass for in-cluster Postgres
kubectl get svc -A | grep -i loadbalancer # confirm you can get external addresses (or use NodePort / port-forward)
```

You also need, on the build host:

| Requirement | Notes |
| --- | --- |
| `kubectl` + `helm` 3 | configured for your cluster |
| `langgraph` CLI (`pip install langgraph-cli`) | on the build host |
| Docker (for `langgraph build`) | installed in Step 3 |
| **Docker Hub account** + access token (to push images) | Have it ready |
| **LangSmith license key** (`LANGGRAPH_CLOUD_LICENSE_KEY`) | Have it ready |
| **LangSmith API key** (`LANGSMITH_API_KEY`) | Have it ready |
| **Anthropic API key** (`ANTHROPIC_API_KEY`) | Have it ready |
| Egress to `https://beacon.langchain.com` (license check) + `docker.io` | from cluster/build host |

Set them once in your shell (they are used throughout; nothing is written to disk):

```bash
export LICENSE_KEY="<your LANGGRAPH_CLOUD_LICENSE_KEY>"
export LANGSMITH_API_KEY="<your LangSmith API key>"
export ANTHROPIC_API_KEY="<your Anthropic API key>"
export DOCKERHUB_USER="<your Docker Hub username>"   # images go to docker.io/$DOCKERHUB_USER/...
export DOCKERHUB_TOKEN="<your Docker Hub access token>"
```

---

## 3. Build the agent images

Install Docker (the `langgraph` CLI shells out to `docker build`):

```bash
sudo apt update && sudo apt install -y docker.io
sudo usermod -aG docker "$USER" && newgrp docker   # run docker without sudo
```

Build each agent from its own directory. Each has its own `langgraph.json`, so each
becomes its own image, tagged for your Docker Hub account:

```bash
cd agents/weather     && langgraph build -t "docker.io/$DOCKERHUB_USER/weather-agent:0.1"     -- --network=host
cd ../calculator      && langgraph build -t "docker.io/$DOCKERHUB_USER/calculator-agent:0.1"  -- --network=host
cd ../..
```

> **Why `-- --network=host`?** Everything after `--` is passed straight to
> `docker build`. On this build host the default Docker bridge has no outbound
> connectivity, so the image's `pip install` step can't reach `pypi.org` and the build
> fails with a DNS/`Try again` error. Building on the host network sidesteps that. On a
> host whose Docker bridge already has egress you can drop the ` -- --network=host`.

`langgraph build` bakes your graph onto the official `langchain/langgraph-api` base
image. Verify:

```bash
docker images | grep -E 'weather-agent|calculator-agent'
```

> **Tip:** to inspect what would be built without a Docker daemon, run
> `langgraph dockerfile Dockerfile` inside an agent dir — it validates `langgraph.json`
> and emits the Dockerfile.

---

## 4. Push the images to Docker Hub

Log in and push both images. Your cluster nodes already pull from `docker.io`, so no
registry setup or per-node config is needed — this is the simplest distribution path.

```bash
echo "$DOCKERHUB_TOKEN" | docker login docker.io -u "$DOCKERHUB_USER" --password-stdin

docker push "docker.io/$DOCKERHUB_USER/weather-agent:0.1"
docker push "docker.io/$DOCKERHUB_USER/calculator-agent:0.1"
```

Confirm on Docker Hub that both repos exist. **Keep them private** unless you're fine
publishing your agent code — a private repo is assumed below (the deploy steps add an
`imagePullSecret`). If you make the repos **public**, you can skip creating the
`dockerhub` secret and remove `imagePullSecrets` from the values files.

> **Production note:** most teams use a private org registry (Harbor, ECR/GCR/ACR, or a
> Docker Hub org) with a robot/service account rather than a personal Docker Hub login.
> The mechanics — push, then reference an `imagePullSecret` — are identical.

---

## 5. Deploy the shared Postgres + Redis

Both agents share one datastore pair, isolated by database name and Redis DB number.

> **Shortcut:** the commands below are packaged as a re-runnable script —
> `deploy/deploy-shared-datastores.sh`. It creates the namespace, password secret,
> Postgres + Redis, and both databases, then prints the `export PG_PASSWORD=...` line
> you need for Steps 6 and 8.

```bash
# 1) generate a strong Postgres password and store it as a secret
export PG_PASSWORD=$(openssl rand -hex 16)
kubectl create namespace langgraph-shared
kubectl -n langgraph-shared create secret generic postgres-credentials \
  --from-literal=password="$PG_PASSWORD"

# 2) deploy Postgres + Redis
kubectl apply -f deploy/shared-datastores.yaml
kubectl -n langgraph-shared rollout status statefulset/postgres
kubectl -n langgraph-shared rollout status deploy/redis

# 3) create one database per agent (isolation within the shared instance)
kubectl -n langgraph-shared exec -it postgres-0 -- \
  psql -U postgres -c "CREATE DATABASE weather;" -c "CREATE DATABASE calculator;"
```

**How the sharing stays safe:** the two deployments never collide because each uses a
different Postgres **database** (`weather` vs `calculator`) and a different Redis **DB
number** (`/1` vs `/2`) on the same shared hosts.

---

## 6. Deploy agent #1 (weather)

> **Shortcut:** `deploy/deploy-agent.sh <agent> <redis-db>` does everything below for
> one agent (namespace, both secrets, `helm upgrade --install`, rollout wait). With
> `PG_PASSWORD` and the key/Docker Hub env vars exported, just run:
> `deploy/deploy-agent.sh weather 1`. The full commands are shown here for reference.

```bash
kubectl create namespace weather

# per-namespace secret: license + LangSmith + Anthropic keys
kubectl -n weather create secret generic agent-secrets \
  --from-literal=langgraph_cloud_license_key="$LICENSE_KEY" \
  --from-literal=api_key="$LANGSMITH_API_KEY" \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"

# pull secret so the node can pull your PRIVATE Docker Hub image
# (skip this if your repo is public — and drop imagePullSecrets from the values file)
kubectl -n weather create secret docker-registry dockerhub \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username="$DOCKERHUB_USER" --docker-password="$DOCKERHUB_TOKEN"

# install the release. The image repo and the password-bearing connection URLs are
# passed here so no account name or credentials live in the values file on disk.
helm install weather-agent langchain/langgraph-cloud \
  -n weather -f deploy/weather-values.yaml \
  --set images.apiServerImage.repository="docker.io/$DOCKERHUB_USER/weather-agent" \
  --set-string postgres.external.connectionUrl="postgres://postgres:${PG_PASSWORD}@postgres.langgraph-shared.svc.cluster.local:5432/weather?sslmode=disable" \
  --set-string redis.external.connectionUrl="redis://redis.langgraph-shared.svc.cluster.local:6379/1"

kubectl -n weather rollout status deploy/weather-agent-langgraph-cloud-api-server
```

---

## 7. Test agent #1

```bash
# get the LoadBalancer IP MetalLB assigned to this server
export WEATHER_IP=$(kubectl -n weather get svc -l app.kubernetes.io/name=langgraph-cloud \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}')
echo "weather server: http://$WEATHER_IP"

# health + info
curl -s http://$WEATHER_IP/ok        # -> {"ok":true}
curl -s http://$WEATHER_IP/info      # server version, flags

# the baked-in graph now shows up as an assistant (no longer [])
curl -s -X POST http://$WEATHER_IP/assistants/search \
  -H 'content-type: application/json' -d '{"limit":10}' | jq '.[].graph_id'
#  -> "weather"

# run it: create a thread, then a run, and read the answer
export WTHREAD=$(curl -s -X POST http://$WEATHER_IP/threads -H 'content-type: application/json' -d '{}' | jq -r .thread_id)
curl -s -X POST http://$WEATHER_IP/threads/$WTHREAD/runs/wait \
  -H 'content-type: application/json' \
  -d '{"assistant_id":"weather","input":{"messages":[{"role":"user","content":"What is the weather in Tokyo?"}]}}' \
  | jq -r '.messages[-1].content'
#  -> a one-sentence answer that used the get_weather tool
```

---

## 8. Deploy agent #2 (calculator) — the multi-deployment payoff

The exact same procedure with a second release, second namespace, second image, and
`calculator` database / Redis `/2` — i.e. `deploy/deploy-agent.sh calculator 2`, or
the explicit commands:

```bash
kubectl create namespace calculator
kubectl -n calculator create secret generic agent-secrets \
  --from-literal=langgraph_cloud_license_key="$LICENSE_KEY" \
  --from-literal=api_key="$LANGSMITH_API_KEY" \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"

kubectl -n calculator create secret docker-registry dockerhub \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username="$DOCKERHUB_USER" --docker-password="$DOCKERHUB_TOKEN"

helm install calculator-agent langchain/langgraph-cloud \
  -n calculator -f deploy/calculator-values.yaml \
  --set images.apiServerImage.repository="docker.io/$DOCKERHUB_USER/calculator-agent" \
  --set-string postgres.external.connectionUrl="postgres://postgres:${PG_PASSWORD}@postgres.langgraph-shared.svc.cluster.local:5432/calculator?sslmode=disable" \
  --set-string redis.external.connectionUrl="redis://redis.langgraph-shared.svc.cluster.local:6379/2"

kubectl -n calculator rollout status deploy/calculator-agent-langgraph-cloud-api-server
```

You now have **two independent releases of the same chart**, backed by one shared
datastore pair:

```bash
helm list -A | grep -E 'weather-agent|calculator-agent'
```

Test it:

```bash
export CALC_IP=$(kubectl -n calculator get svc -l app.kubernetes.io/name=langgraph-cloud \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}')
export CTHREAD=$(curl -s -X POST http://$CALC_IP/threads -H 'content-type: application/json' -d '{}' | jq -r .thread_id)
curl -s -X POST http://$CALC_IP/threads/$CTHREAD/runs/wait \
  -H 'content-type: application/json' \
  -d '{"assistant_id":"calculator","input":{"messages":[{"role":"user","content":"What is (12 * 8) + 5?"}]}}' \
  | jq -r '.messages[-1].content'
#  -> "101" (computed via the calculate tool)
```

---

## 9. Scaling to many agents

"Many agents" has **three levels** — only the outermost is a separate `helm install`.
Reach for the cheapest one that meets your isolation needs.

| You want… | Do this | Cost |
| --- | --- | --- |
| Same graph, different config (prompt/model/tools) | Create an **assistant** via the runtime API | Free, instant, no rebuild |
| Different graphs, shared lifecycle/scaling | Add graphs to **`langgraph.json`** in one image/release | One rebuild + `helm upgrade` |
| Independent scaling / lifecycle / isolation | A separate **`helm install`** per deployment | New release (this demo) |

**Level 1 — Assistants (runtime, zero rebuild).** One deployed graph can back many
assistants, each a saved configuration:

```bash
curl -s -X POST http://$WEATHER_IP/assistants -H 'content-type: application/json' \
  -d '{"graph_id":"weather","name":"terse-weather","config":{"configurable":{"model":"anthropic:claude-haiku-4-5"}}}'
```

**Level 2 — Many graphs in one server.** Add entries to one `langgraph.json` — all
served by a single release, sharing its Postgres/Redis:

```json
{
  "dependencies": ["."],
  "graphs": {
    "weather": "./graph.py:graph",
    "calculator": "./calc.py:graph",
    "billing": "./billing.py:graph"
  }
}
```

**Level 3 — Separate releases (what this demo shows).** A `helm install` each, for
independent scaling, upgrade/rollback lifecycle, and tenant/blast-radius isolation.
They can **share** one Postgres/Redis (different database name + Redis DB number per
release, as here) or run fully dedicated instances.

Most teams land on **a handful of releases** (per team or environment), each serving
**several graphs**, each spawning **many assistants** — not one release per agent.

---

## 10. Day-2 operations

**Ship a new version.** Rebuild with a **new tag** (a reused tag won't be re-pulled),
push, and upgrade:

```bash
cd agents/weather \
  && langgraph build -t "docker.io/$DOCKERHUB_USER/weather-agent:0.2" -- --network=host \
  && docker push "docker.io/$DOCKERHUB_USER/weather-agent:0.2"
helm upgrade weather-agent langchain/langgraph-cloud -n weather --reuse-values \
  --set images.apiServerImage.tag=0.2
```

**Rollback:**

```bash
helm history weather-agent -n weather
helm rollback weather-agent <REVISION> -n weather
```

**Tear down:**

```bash
helm uninstall weather-agent -n weather && kubectl delete namespace weather
helm uninstall calculator-agent -n calculator && kubectl delete namespace calculator
kubectl delete -f deploy/shared-datastores.yaml && kubectl delete namespace langgraph-shared
```

---

## 11. Troubleshooting

| Symptom | Likely cause & fix |
| --- | --- |
| `langgraph build` fails at `pip install` with `Failed to fetch pypi.org` / `dns error: Try again` | The Docker build container has no network egress (bridge lacks outbound). Build on the host network: append ` -- --network=host` to the `langgraph build` command (Step 3). |
| `ImagePullBackOff` / `pull access denied` / `401 Unauthorized` | Private repo without a valid pull secret — recreate the `dockerhub` secret in that namespace (Step 6), confirm `imagePullSecrets` is in the values file, and that the image name/tag exists on Docker Hub. |
| `CrashLoopBackOff`, log says `License verification failed` / `No enterprise license key ... found` | The `agent-secrets` keys must be named **`langgraph_cloud_license_key`** and **`api_key`** (that's what the chart's `existingSecretName` wiring reads) — not `langGraphCloudLicenseKey`/`apiKey`. Also check egress to `beacon.langchain.com`. |
| `CrashLoopBackOff`, events show `Startup probe failed: ... timed out` while logs show `Application startup complete` | The chart's default probe `timeoutSeconds: 1` is too tight for `python /api/healthcheck.py`. The values files set `timeoutSeconds: 5` — make sure that block is present (`apiServer.deployment.startupProbe`). |
| Pod stuck `0/1`, DB connection refused | Shared Postgres not ready, wrong `PG_PASSWORD`, or the per-agent database wasn't created (**Step 5.3**). |
| `/assistants/search` returns `[]` | The image has no graph baked in (you deployed the base image, or `langgraph.json` didn't resolve). Rebuild from the agent dir. |
| Model call fails / 401 from Anthropic | `ANTHROPIC_API_KEY` missing or wrong in `agent-secrets`; confirm it's in `apiServer.deployment.extraEnv`. |
| Two deployments interfering | They must use **different** Postgres databases and Redis DB numbers — verify the `--set-string` URLs (`/weather`+`/1` vs `/calculator`+`/2`). |

---

## Files in this repo

```
agents/weather/       weather agent  (graph.py, langgraph.json, pyproject.toml, .env.example)
agents/calculator/    calculator agent (same shape)
deploy/shared-datastores.yaml shared Postgres + Redis (namespace langgraph-shared)
deploy/weather-values.yaml    Helm values for the weather release (Docker Hub image + pull secret)
deploy/calculator-values.yaml Helm values for the calculator release
```
