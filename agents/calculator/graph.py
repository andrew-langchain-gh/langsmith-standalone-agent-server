"""Calculator agent — a second minimal Claude agent, deployed as its own release.

Structurally identical to the weather agent (same ``create_agent`` pattern, one
tool, exposes a compiled ``graph``) but with different behavior — this is what lets
the demo show two *independent* Helm releases of the same chart.

See ``agents/weather/graph.py`` for the deployment notes on checkpointers and the
runtime-injected ``ANTHROPIC_API_KEY``; they apply here too.
"""

import ast
import operator
import os

from langchain.agents import create_agent
from langchain_core.tools import tool

MODEL = os.getenv("MODEL_NAME", "anthropic:claude-sonnet-5")

# A deliberately small, safe arithmetic evaluator. We parse the expression to an AST
# and walk only a whitelist of numeric operators — never Python's built-in eval(),
# which would let a model (or user) run arbitrary code.
_BIN_OPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.Div: operator.truediv,
    ast.FloorDiv: operator.floordiv,
    ast.Mod: operator.mod,
    ast.Pow: operator.pow,
}
_UNARY_OPS = {
    ast.UAdd: operator.pos,
    ast.USub: operator.neg,
}


def _eval_node(node: ast.AST) -> float:
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
        return node.value
    if isinstance(node, ast.BinOp) and type(node.op) in _BIN_OPS:
        return _BIN_OPS[type(node.op)](_eval_node(node.left), _eval_node(node.right))
    if isinstance(node, ast.UnaryOp) and type(node.op) in _UNARY_OPS:
        return _UNARY_OPS[type(node.op)](_eval_node(node.operand))
    raise ValueError("unsupported expression")


@tool
def calculate(expression: str) -> str:
    """Evaluate a basic arithmetic expression.

    Supports + - * / // % ** and parentheses over numbers. Use this for any math
    the user asks for, for example "2 + 2", "(3 * 4) / 6", or "2 ** 10".

    Args:
        expression: The arithmetic expression to evaluate.
    """
    try:
        tree = ast.parse(expression, mode="eval")
        return str(_eval_node(tree.body))
    except (SyntaxError, ValueError, ZeroDivisionError, TypeError):
        return f"Could not evaluate '{expression}'. Provide a plain arithmetic expression."


graph = create_agent(
    model=MODEL,
    tools=[calculate],
    system_prompt=(
        "You are a precise calculator assistant. For any arithmetic, call the "
        "calculate tool rather than doing the math yourself, then state the result "
        "clearly. Do not answer non-math questions."
    ),
)
