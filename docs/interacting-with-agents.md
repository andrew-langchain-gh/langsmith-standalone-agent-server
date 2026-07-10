# Interacting with your deployed agents

Each agent is a standalone **Agent Server** with a REST API at its own address. Find an
agent's address with:

```bash
# LoadBalancer:
kubectl -n weather get svc -l app.kubernetes.io/name=langgraph-cloud \
  -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}'

# Or port-forward from anywhere:
kubectl -n weather port-forward svc/weather-agent-langgraph-cloud-api-server 8123:80
# then use http://localhost:8123
```

Set a variable to follow along (substitute your own agent's address):

```bash
export AGENT=http://<your-agent-address>
```

## Key mental model

- **`assistant_id`** = which agent/graph to run (`weather`, `calculator`). You can also
  create configured variants ("assistants") over the same graph.
- **thread** = a conversation with persistent memory (stored in the shared Postgres).
  Omit it for a one-shot, stateless call.
- Every agent exposes the **same API surface** — only the URL differs.

---

## 0. Quick start: the invoke script

The repo ships a helper that finds the agent's address and runs a prompt:

```bash
scripts/invoke-agent.sh -n weather    "What is the weather in Tokyo?"
scripts/invoke-agent.sh -n calculator "What is (12 * 8) + 5?"

# stateful conversation (remembers previous turns):
scripts/invoke-agent.sh -n weather --new-thread "Weather in Tokyo?"     # prints a thread id
scripts/invoke-agent.sh -n weather -t <thread-id> "Warmer than London?"

# streaming, or point at any URL (e.g. a port-forward):
scripts/invoke-agent.sh -n weather --stream "Weather in London?"
scripts/invoke-agent.sh -u http://localhost:8123 -a weather "Weather in Paris?"
```

The rest of this doc shows the raw API the script is built on.

## 1. Interactive API docs (easiest to explore)

Open **`$AGENT/docs`** in a browser for a full Swagger UI with "Try it out" buttons for
every endpoint. The raw spec is at `$AGENT/openapi.json`.

## 2. curl — the core patterns

**Health & discovery:**

```bash
curl -s $AGENT/ok        # {"ok":true}
curl -s $AGENT/info      # version / flags
curl -s -X POST $AGENT/assistants/search -H 'content-type: application/json' -d '{}' \
  | jq '.[].graph_id'
```

**Stateless run** — one-shot, no memory:

```bash
curl -s -X POST $AGENT/runs/wait -H 'content-type: application/json' -d '{
  "assistant_id":"weather",
  "input":{"messages":[{"role":"user","content":"Weather in Paris?"}]}
}' | jq -r '.messages[-1].content'
```

**Stateful run** — a **thread** gives the conversation memory:

```bash
TH=$(curl -s -X POST $AGENT/threads -H 'content-type: application/json' -d '{}' | jq -r .thread_id)

# first turn
curl -s -X POST $AGENT/threads/$TH/runs/wait -H 'content-type: application/json' \
  -d '{"assistant_id":"weather","input":{"messages":[{"role":"user","content":"Weather in Tokyo?"}]}}' \
  | jq -r '.messages[-1].content'

# follow-up on the SAME thread — it remembers Tokyo
curl -s -X POST $AGENT/threads/$TH/runs/wait -H 'content-type: application/json' \
  -d '{"assistant_id":"weather","input":{"messages":[{"role":"user","content":"Is it warmer than London?"}]}}' \
  | jq -r '.messages[-1].content'
```

**Streaming** — token-by-token / event stream (SSE):

```bash
curl -N -X POST $AGENT/runs/stream -H 'content-type: application/json' -d '{
  "assistant_id":"weather","stream_mode":"messages",
  "input":{"messages":[{"role":"user","content":"Weather in Tokyo?"}]}
}'
```

## 3. Python SDK (the ergonomic way)

```bash
pip install langgraph-sdk
```

```python
from langgraph_sdk import get_client
import asyncio

client = get_client(url="http://<your-agent-address>")

async def main():
    # stateless
    res = await client.runs.wait(
        None, "weather",
        input={"messages": [{"role": "user", "content": "Weather in Paris?"}]},
    )
    print(res["messages"][-1]["content"])

    # stateful thread + streaming
    thread = await client.threads.create()
    async for chunk in client.runs.stream(
        thread["thread_id"], "weather",
        input={"messages": [{"role": "user", "content": "Weather in Tokyo?"}]},
        stream_mode="messages",
    ):
        print(chunk.event, chunk.data)

asyncio.run(main())
```

There is a matching JS/TS SDK (`@langchain/langgraph-sdk`) with the same shape.

## 4. LangGraph Studio (visual UI)

Point Studio at a deployment URL to chat with the agent, inspect state, and
time-travel through threads:

```
https://smith.langchain.com/studio/?baseUrl=$AGENT
```

The browser needs network access to the agent's address — use it from a machine on the
same network, or expose the agent via an Ingress host.

---

## Quick reference

| Action | Endpoint |
| --- | --- |
| Health | `GET /ok`, `GET /info` |
| List graphs/assistants | `POST /assistants/search` |
| One-shot run (stateless) | `POST /runs/wait` |
| Streaming run (stateless) | `POST /runs/stream` |
| Create a conversation | `POST /threads` |
| Run on a thread (stateful) | `POST /threads/{thread_id}/runs/wait` |
| Read thread state/history | `GET /threads/{thread_id}/state` |
| API docs (Swagger) | `GET /docs` |
