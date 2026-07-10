"""Weather agent — a minimal Claude ReAct agent for the standalone Agent Server demo.

This module exposes a compiled graph named ``graph``. The Agent Server loads it via
``langgraph.json`` (``"weather": "./graph.py:graph"``) and serves it over HTTP.

Deployment notes:
- Do NOT attach a checkpointer here. When this graph runs inside the Agent Server,
  the platform supplies its own Postgres-backed persistence (threads, checkpoints,
  long-term memory). Compiling a checkpointer in would conflict with it.
- The Anthropic API key is read from the ``ANTHROPIC_API_KEY`` environment variable
  at runtime. In Kubernetes it is injected by the Helm chart (``apiServer.deployment.extraEnv``)
  from a Secret — it is never baked into the image.
"""

import os

from langchain.agents import create_agent
from langchain_core.tools import tool

# Model is configurable so the same image can target different Claude models per
# environment. Defaults to the latest Sonnet. Format: "<provider>:<model-id>".
MODEL = os.getenv("MODEL_NAME", "anthropic:claude-sonnet-5")

# Canned data keeps the demo self-contained (no external weather API / key needed).
# Swap this stub for a real weather API call in a production agent.
_DEMO_CONDITIONS = {
    "paris": "18°C, light rain",
    "tokyo": "24°C, clear skies",
    "new york": "21°C, partly cloudy",
    "london": "15°C, overcast",
    "san francisco": "17°C, foggy",
}


@tool
def get_weather(city: str) -> str:
    """Get the current weather for a city.

    Use this whenever the user asks about current conditions, temperature, or
    whether it is raining somewhere.

    Args:
        city: Name of the city, for example "Paris" or "Tokyo".
    """
    return _DEMO_CONDITIONS.get(
        city.strip().lower(), f"22°C, sunny (demo default for {city})"
    )


graph = create_agent(
    model=MODEL,
    tools=[get_weather],
    system_prompt=(
        "You are a friendly weather assistant. When asked about the weather, call "
        "the get_weather tool for the requested city, then answer in one short, "
        "natural sentence. If no city is given, ask which city they mean."
    ),
)
