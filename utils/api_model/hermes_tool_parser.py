"""
Hermes-style <tool_call> parser, ported from vLLM's Hermes2ProToolParser.
Handles: nested JSON, multiple tool calls, empty arguments, malformed JSON.
"""
import json
import re
import uuid
from dataclasses import dataclass

try:
    import partial_json_parser
    from partial_json_parser.core.options import Allow
    HAS_PARTIAL_JSON = True
except ImportError:
    HAS_PARTIAL_JSON = False


@dataclass
class ParsedToolCall:
    name: str
    arguments: str  # JSON string
    call_id: str


def parse_hermes_tool_calls(text: str) -> list[ParsedToolCall]:
    """
    Extract tool calls from Hermes-format text.
    Handles: <tool_call>{"name": "...", "arguments": {...}}</tool_call>
    Also handles: multiple tool calls, nested JSON, empty arguments,
    arguments-before-name key ordering, and malformed JSON (via partial_json_parser).
    """
    matches = re.findall(r'<tool_call>\s*(.*?)\s*</tool_call>', text, re.DOTALL)

    results = []
    for raw in matches:
        tc = _try_parse_json(raw)
        if tc is None or not isinstance(tc, dict):
            continue

        name = tc.get("name")
        if not name:
            continue

        arguments = tc.get("arguments")
        arguments_str = json.dumps(arguments) if arguments is not None else "{}"

        results.append(ParsedToolCall(
            name=name,
            arguments=arguments_str,
            call_id=f"call_{uuid.uuid4().hex[:24]}",
        ))

    return results


def strip_tool_call_tags(text: str) -> str:
    """Remove <tool_call>...</tool_call> blocks from text."""
    return re.sub(r'<tool_call>\s*.*?\s*</tool_call>', '', text, flags=re.DOTALL).strip()


def _try_parse_json(raw: str) -> dict | None:
    """Try to parse JSON, falling back to partial_json_parser for robustness."""
    raw = raw.strip()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        pass
    if HAS_PARTIAL_JSON:
        try:
            return partial_json_parser.loads(raw, Allow.ALL)
        except Exception:
            pass
    return None
