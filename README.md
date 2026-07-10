# Standalone Agent Server Demo

Deploy LangGraph agents to a **self-hosted standalone Agent Server** on Kubernetes —
the lightweight deployment option with no LangSmith control plane. This demo builds
two Claude agents and runs them as two independent Helm releases sharing one Postgres
and one Redis.

## 👉 Start here: [`docs/portable-deployment-guide.md`](docs/portable-deployment-guide.md)

The **portable guide** is the cluster-agnostic, reproducible walkthrough — everything
you need to deploy a standalone Agent Server on *any* Kubernetes cluster, with the
non-obvious gotchas called out. Start here.

The other docs are supporting material for this specific demo:

- [`docs/deployment-guide.md`](docs/deployment-guide.md) — the full walkthrough as run
  on our demo cluster (two agents, shared datastores, Docker Hub).
- [`docs/interacting-with-agents.md`](docs/interacting-with-agents.md) — how to call the
  running agents (REST, threads, streaming, SDK, Studio).

## Layout

```
agents/
  weather/        Claude agent with a get_weather tool   (its own image + Helm release)
  calculator/     Claude agent with a calculate tool     (its own image + Helm release)
deploy/
  deploy-shared-datastores.sh   script: shared Postgres + Redis + per-agent databases
  deploy-agent.sh               script: deploy one agent (namespace, secrets, helm)
  shared-datastores.yaml        shared Postgres + Redis (namespace langgraph-shared)
  weather-values.yaml           Helm values for the weather release
  calculator-values.yaml        Helm values for the calculator release
docs/
  portable-deployment-guide.md  reproducible on any cluster  ← start here
  deployment-guide.md           this-cluster walkthrough
  interacting-with-agents.md    using the running agents
```

## The one-minute mental model

```
langgraph build   →  image in local Docker
docker push       →  image stored on Docker Hub          (nothing running yet)
helm install      →  Kubernetes pulls it and runs the pod  ← this makes it live
```

Pushing to a registry does not auto-deploy — Helm is what turns an image into a
running agent. Each agent is a self-contained buildable unit (its own `langgraph.json`),
so each maps to its own image and its own Helm release. To serve several agents from
*one* server instead, add more entries under `graphs` in a single `langgraph.json`
(see the guide's "Scaling to many agents").

## Local testing (optional, before deploying)

```bash
cd agents/weather
cp .env.example .env      # add your ANTHROPIC_API_KEY
uv run --python 3.13 langgraph dev    # runs the agent locally with a dev server
```
