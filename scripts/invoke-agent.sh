#!/usr/bin/env bash
#
# Invoke a deployed standalone Agent Server and print its reply.
#
# Examples:
#   scripts/invoke-agent.sh -n weather    "What is the weather in Tokyo?"
#   scripts/invoke-agent.sh -n calculator "What is (12 * 8) + 5?"
#   scripts/invoke-agent.sh -u http://localhost:8123 -a weather "Weather in Paris?"
#   scripts/invoke-agent.sh -n weather --stream "Weather in London?"
#   scripts/invoke-agent.sh -n weather -t "$THREAD_ID" "and warmer than London?"
#
# Options:
#   -n, --namespace NS    Kubernetes namespace of the agent; its LoadBalancer address
#                         is looked up automatically. Also the default assistant id.
#   -u, --url URL         Agent base URL (skip the kubectl lookup), e.g. http://host:port
#   -a, --assistant ID    Assistant / graph id to run (default: the namespace name)
#   -t, --thread ID       Run on an existing thread (stateful, remembers the conversation)
#       --new-thread      Create a fresh thread, use it, and print its id at the end
#       --stream          Stream the response (SSE) instead of waiting for the final text
#   -h, --help            Show this help
#
# Requires: curl, jq (and kubectl when using --namespace).
set -euo pipefail

NS=""; URL=""; ASSISTANT=""; THREAD=""; NEW_THREAD=false; STREAM=false

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NS="${2:?}"; shift 2 ;;
    -u|--url)       URL="${2:?}"; shift 2 ;;
    -a|--assistant) ASSISTANT="${2:?}"; shift 2 ;;
    -t|--thread)    THREAD="${2:?}"; shift 2 ;;
    --new-thread)   NEW_THREAD=true; shift ;;
    --stream)       STREAM=true; shift ;;
    -h|--help)      usage 0 ;;
    --) shift; break ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) break ;;
  esac
done

MESSAGE="${*:-}"
[[ -n "$MESSAGE" ]] || die "no message given. Example: $(basename "$0") -n weather \"Weather in Tokyo?\""
command -v curl >/dev/null || die "curl is required"
command -v jq   >/dev/null || die "jq is required"

# Resolve the agent's base URL from the namespace's LoadBalancer if --url wasn't given.
if [[ -z "$URL" ]]; then
  [[ -n "$NS" ]] || die "pass --url, or --namespace to look one up"
  command -v kubectl >/dev/null || die "kubectl is required for --namespace lookups"
  addr=$(kubectl -n "$NS" get svc -l app.kubernetes.io/name=langgraph-cloud \
    -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [[ -n "$addr" ]] || addr=$(kubectl -n "$NS" get svc -l app.kubernetes.io/name=langgraph-cloud \
    -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  [[ -n "$addr" ]] || die "no LoadBalancer address in namespace '$NS'. Either expose the Service, or:
  kubectl -n $NS port-forward svc/${NS}-agent-langgraph-cloud-api-server 8123:80
then re-run with:  --url http://localhost:8123"
  URL="http://$addr"
fi
URL="${URL%/}"

# Default the assistant id to the namespace name (weather -> "weather", etc.).
[[ -n "$ASSISTANT" ]] || ASSISTANT="${NS:-}"
[[ -n "$ASSISTANT" ]] || die "pass --assistant <graph-id> (couldn't default it without --namespace)"

# Optionally create a fresh thread for a stateful conversation.
if $NEW_THREAD; then
  THREAD=$(curl -fsS -X POST "$URL/threads" -H 'content-type: application/json' -d '{}' | jq -r .thread_id)
  [[ -n "$THREAD" && "$THREAD" != "null" ]] || die "failed to create a thread at $URL"
fi

# Build the request body safely (jq handles quoting/escaping of the message).
payload=$(jq -n --arg a "$ASSISTANT" --arg m "$MESSAGE" \
  '{assistant_id:$a, input:{messages:[{role:"user", content:$m}]}}')

# Pick the endpoint: threaded (stateful) vs stateless, streaming vs wait.
base="$URL"; [[ -n "$THREAD" ]] && base="$URL/threads/$THREAD"

if $STREAM; then
  curl -fsS -N -X POST "$base/runs/stream" -H 'content-type: application/json' \
    -d "$(echo "$payload" | jq '. + {stream_mode:"messages"}')"
else
  curl -fsS -X POST "$base/runs/wait" -H 'content-type: application/json' -d "$payload" \
    | jq -r '.messages[-1].content'
fi

[[ -n "$THREAD" ]] && echo "(thread: $THREAD)" >&2
exit 0
