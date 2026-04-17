#!/usr/bin/env python3
"""
hydra-supervisor-escalate.py — Outbound MCP client for upstream-supervisor escalation.

Spec: docs/specs/2026-04-17-supervisor-escalate-client.md
Config: state/connectors/mcp.json:upstream_supervisor
Envelope shape: docs/specs/2026-04-16-mcp-agent-interface.md

Commander invokes this script when a worker returns a QUESTION: block that doesn't
match memory/escalation-faq.md. The script reads the full question envelope from
stdin, calls supervisor.resolve_question over MCP, and prints the response on
stdout.

Exit-code contract (authoritative — commander parses these):

    0  success — stdout is {"answer": "...", "confidence": 0.x, "human_involved": bool}
    1  configuration or runtime error — stdout is {"error": "<short>", ...}
    2  not-configured — upstream_supervisor.enabled=false or config missing; stdout
       is {"error": "not-configured"}. Commander falls through to legacy
       commander-stuck behavior.
    3  timeout — supervisor did not respond within timeout_sec
    4  usage error (bad CLI flags, stdin not valid JSON)

Runtime deps: Python 3 stdlib only. No pip install step. Same convention as
scripts/hydra-mcp-server.py.

CLI:
    hydra-supervisor-escalate.py [--check] [--config PATH]

    --check    Validate config + envelope and exit 0 without any network call.
               Used by CI self-tests.
    --config   Override the config path. Default: $HYDRA_MCP_CONFIG falling back
               to state/connectors/mcp.json.

Stdin:
    A JSON envelope matching the shape in docs/specs/2026-04-16-mcp-agent-interface.md:
        {
          "worker_id":       string (required),
          "question":        string (required),
          "context":         string (optional),
          "options":         array of string (optional),
          "recommendation":  string (optional),
          "nearest_memory_match": string or null (optional)
        }

Stdout:
    - On exit 0: the supervisor's response, verbatim {answer, confidence, human_involved}.
    - On any other exit: {"error": "<code>", ...} — never the raw bearer token,
      never the raw stdin (sanitized).

Env vars:
    HYDRA_MCP_CONFIG         Override the config path (same as --config).
    HYDRA_SUPERVISOR_TOKEN   (Or whatever upstream_supervisor.auth_token_env names.)
                             Bearer token to present to the supervisor. Required
                             when upstream_supervisor.enabled=true. NEVER logged.

Security:
    - Tokens are never interpolated into error output or stderr.
    - --check performs zero network I/O.
    - scope_granted is enforced at read time — anything other than
      exactly ["resolve_question"] is rejected with scope-overreach.
    - Phase 1 supports HTTP transport only; stdio is a non-goal for now
      (matches scripts/hydra-mcp-server.py per docs/specs/2026-04-17-mcp-server-binary.md).
"""

import argparse
import json
import os
import signal
import socket
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Exit codes — authoritative. Commander reads these.
EXIT_OK = 0
EXIT_ERROR = 1
EXIT_NOT_CONFIGURED = 2
EXIT_TIMEOUT = 3
EXIT_USAGE = 4

# Envelope shape.
ENVELOPE_REQUIRED = ("worker_id", "question")
ENVELOPE_OPTIONAL = ("context", "options", "recommendation", "nearest_memory_match")

# Default env-var name Commander will read for the bearer token if
# upstream_supervisor.auth_token_env is not set in the config.
DEFAULT_AUTH_TOKEN_ENV = "HYDRA_SUPERVISOR_TOKEN"

# Phase 1 only supports HTTP transport. stdio is a Phase 2 non-goal per
# docs/specs/2026-04-17-mcp-server-binary.md.
SUPPORTED_TRANSPORTS = ("http",)

# Hydra only ever grants the supervisor one scope. Anything broader is rejected.
REQUIRED_SCOPE_GRANTED = frozenset({"resolve_question"})


def _config_path(override: Optional[str]) -> Path:
    """Resolve the config path: --config arg > $HYDRA_MCP_CONFIG > default."""
    if override:
        return Path(override)
    env = os.environ.get("HYDRA_MCP_CONFIG")
    if env:
        return Path(env)
    # Default relative to cwd, same convention as hydra-mcp-server.py.
    return Path("state") / "connectors" / "mcp.json"


def _emit(obj: Dict[str, Any]) -> None:
    """Write a JSON object to stdout on its own line. Sole stdout emitter."""
    sys.stdout.write(json.dumps(obj, separators=(",", ":"), sort_keys=True) + "\n")
    sys.stdout.flush()


def _load_config(path: Path) -> Optional[Dict[str, Any]]:
    """
    Load the upstream_supervisor block from mcp.json.

    Returns None if:
    - the config file doesn't exist
    - upstream_supervisor is missing
    - upstream_supervisor.enabled is false

    In all three cases the caller exits with EXIT_NOT_CONFIGURED. We do not
    raise — "not configured" is a normal fall-through state, not an error.
    """
    if not path.exists():
        return None
    try:
        with path.open() as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError):
        # Malformed config is an error, not a "not-configured" state — bubble up.
        raise
    sup = cfg.get("upstream_supervisor")
    if not isinstance(sup, dict):
        return None
    if not sup.get("enabled"):
        return None
    return sup


def _validate_supervisor_cfg(sup: Dict[str, Any]) -> Tuple[Optional[str], Dict[str, Any]]:
    """
    Validate the upstream_supervisor block.

    Returns (error_code_or_None, normalized_cfg). The error_code is a short
    string suitable for stdout marker emission; normalized_cfg contains the
    fields we read downstream.
    """
    transport = str(sup.get("transport") or "").strip().lower()
    if transport not in SUPPORTED_TRANSPORTS:
        return ("unsupported-transport", {"transport": transport})

    connect_url = str(sup.get("connect_url") or "").strip()
    if not connect_url or connect_url.startswith("REPLACE_WITH"):
        return ("connect-url-missing", {})

    # Reject obviously placeholder URLs.
    if "example.com" in connect_url and "REPLACE" in connect_url:
        return ("connect-url-placeholder", {})

    scope_granted = sup.get("scope_granted") or []
    if not isinstance(scope_granted, list):
        return ("scope-granted-not-list", {})
    scope_set = set(str(s) for s in scope_granted)
    if scope_set != REQUIRED_SCOPE_GRANTED:
        return ("scope-overreach", {"granted": sorted(scope_set), "required": sorted(REQUIRED_SCOPE_GRANTED)})

    timeout_sec = sup.get("timeout_sec", 300)
    try:
        timeout_sec = int(timeout_sec)
    except (TypeError, ValueError):
        return ("bad-timeout-sec", {})
    if timeout_sec <= 0 or timeout_sec > 3600:
        return ("bad-timeout-sec", {"value": timeout_sec})

    auth_token_env = str(sup.get("auth_token_env") or DEFAULT_AUTH_TOKEN_ENV).strip()
    if not auth_token_env:
        auth_token_env = DEFAULT_AUTH_TOKEN_ENV

    return (None, {
        "transport": transport,
        "connect_url": connect_url,
        "auth_token_env": auth_token_env,
        "timeout_sec": timeout_sec,
        "name": str(sup.get("name") or "supervisor"),
    })


def _read_envelope(stream) -> Tuple[Optional[str], Dict[str, Any]]:
    """
    Parse + validate the question envelope from stdin.

    Returns (error_marker_or_None, envelope). error_marker is None on success.
    Never logs the envelope contents — they may contain repo snippets, and
    error output goes to stderr with a minimal description only.
    """
    raw = stream.read()
    if not raw.strip():
        return ("empty-stdin", {})
    try:
        env = json.loads(raw)
    except json.JSONDecodeError:
        return ("stdin-not-json", {})
    if not isinstance(env, dict):
        return ("stdin-not-object", {})

    for field in ENVELOPE_REQUIRED:
        val = env.get(field)
        if not isinstance(val, str) or not val.strip():
            return (f"missing required field: {field}", {})

    # Clean up shape — keep only declared fields to avoid leaking surprising
    # keys downstream.
    clean: Dict[str, Any] = {}
    for field in ENVELOPE_REQUIRED:
        clean[field] = env[field]
    for field in ENVELOPE_OPTIONAL:
        if field in env:
            clean[field] = env[field]
    return (None, clean)


def _build_jsonrpc_request(envelope: Dict[str, Any]) -> Dict[str, Any]:
    """Build the JSON-RPC 2.0 tools/call request for supervisor.resolve_question."""
    return {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": "supervisor.resolve_question",
            "arguments": envelope,
        },
    }


class _TimeoutError(Exception):
    """Raised when the supervisor does not respond within timeout_sec."""


def _alarm_handler(signum, frame):  # pragma: no cover — signal path
    raise _TimeoutError("supervisor response timeout")


def _call_supervisor_http(
    connect_url: str,
    token: str,
    envelope: Dict[str, Any],
    timeout_sec: int,
) -> Dict[str, Any]:
    """
    POST the JSON-RPC envelope to connect_url with bearer-token auth.

    Timeout enforcement is belt-and-suspenders: we set urllib's socket timeout
    AND wrap the whole call in signal.alarm() so a hanging socket read can't
    block past timeout_sec. signal.alarm is POSIX-portable; we only call this
    from the main thread.
    """
    req_body = json.dumps(_build_jsonrpc_request(envelope)).encode("utf-8")
    req = urllib.request.Request(
        connect_url,
        data=req_body,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    # signal.alarm is only available on POSIX and only from the main thread.
    # We check; if unavailable, we rely on urlopen's timeout parameter alone.
    has_alarm = hasattr(signal, "SIGALRM")
    old_handler = None
    if has_alarm:
        old_handler = signal.signal(signal.SIGALRM, _alarm_handler)
        signal.alarm(timeout_sec)

    try:
        with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except socket.timeout:
        raise _TimeoutError("socket read timeout")
    except urllib.error.URLError as e:
        # URLError wraps the underlying reason; extract without leaking the token.
        reason = getattr(e, "reason", e)
        if isinstance(reason, socket.timeout):
            raise _TimeoutError("url open timeout")
        raise RuntimeError(f"connect-failed: {type(reason).__name__}")
    finally:
        if has_alarm:
            signal.alarm(0)
            if old_handler is not None:
                signal.signal(signal.SIGALRM, old_handler)

    try:
        resp_obj = json.loads(raw)
    except json.JSONDecodeError:
        raise RuntimeError("malformed-response: not json")

    if not isinstance(resp_obj, dict):
        raise RuntimeError("malformed-response: not object")

    if "error" in resp_obj and resp_obj["error"]:
        err = resp_obj["error"]
        if isinstance(err, dict):
            msg = err.get("message", "unknown")
            raise RuntimeError(f"supervisor-error: {msg}")
        raise RuntimeError(f"supervisor-error: {err}")

    result = resp_obj.get("result")
    if not isinstance(result, dict):
        raise RuntimeError("malformed-response: missing result")

    # MCP tool-call results wrap the payload in structuredContent (preferred)
    # or content[].text (fallback). Accept either.
    if "structuredContent" in result and isinstance(result["structuredContent"], dict):
        payload = result["structuredContent"]
    else:
        content = result.get("content") or []
        if not content or not isinstance(content, list):
            raise RuntimeError("malformed-response: no content")
        first = content[0]
        if not isinstance(first, dict) or "text" not in first:
            raise RuntimeError("malformed-response: content[0] shape")
        try:
            payload = json.loads(first["text"])
        except json.JSONDecodeError:
            raise RuntimeError("malformed-response: content[0] text not json")

    if not isinstance(payload, dict):
        raise RuntimeError("malformed-response: payload not object")

    # Validate the response shape.
    if "answer" not in payload or not isinstance(payload["answer"], str):
        raise RuntimeError("malformed-response: missing answer")

    # confidence + human_involved are documented but we don't require them —
    # future-proof against supervisors that only send `answer`.
    out: Dict[str, Any] = {"answer": payload["answer"]}
    if "confidence" in payload:
        try:
            out["confidence"] = float(payload["confidence"])
        except (TypeError, ValueError):
            out["confidence"] = None
    if "human_involved" in payload:
        out["human_involved"] = bool(payload["human_involved"])

    return out


def _parse_args(argv: List[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="hydra-supervisor-escalate",
        description=(
            "Outbound MCP client for upstream-supervisor escalation. "
            "Reads a question envelope from stdin, calls supervisor.resolve_question, "
            "prints the response on stdout. See docs/specs/2026-04-17-supervisor-escalate-client.md."
        ),
        epilog=(
            "Exit codes: 0 success, 1 error, 2 not-configured, 3 timeout, 4 usage. "
            "Commander reads these to decide between legacy commander-stuck fallback "
            "and an actual supervisor answer."
        ),
    )
    p.add_argument(
        "--check", action="store_true",
        help="Validate config + envelope and exit 0 without any network call.",
    )
    p.add_argument(
        "--config", default=None,
        help="Override config path. Default: $HYDRA_MCP_CONFIG then state/connectors/mcp.json.",
    )
    return p.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    try:
        args = _parse_args(argv if argv is not None else sys.argv[1:])
    except SystemExit as e:
        # argparse exits 2 on usage error; our contract is 4.
        if e.code == 0:
            return 0
        return EXIT_USAGE

    cfg_path = _config_path(args.config)

    # Step 1 — load config. Not-configured is a normal state, not an error.
    try:
        sup = _load_config(cfg_path)
    except (OSError, json.JSONDecodeError) as e:
        _emit({"error": "config-malformed", "detail": type(e).__name__})
        return EXIT_ERROR

    if sup is None:
        _emit({"error": "not-configured"})
        return EXIT_NOT_CONFIGURED

    # Step 2 — validate supervisor config.
    err_code, normalized = _validate_supervisor_cfg(sup)
    if err_code is not None:
        payload: Dict[str, Any] = {"error": err_code}
        # Only include sanitized context, never raw config values.
        if err_code == "scope-overreach" and "granted" in normalized:
            payload["granted"] = normalized["granted"]
            payload["required"] = normalized["required"]
        elif err_code == "unsupported-transport":
            payload["supported"] = list(SUPPORTED_TRANSPORTS)
        _emit(payload)
        return EXIT_ERROR

    # Step 3 — parse envelope from stdin.
    err_code, envelope = _read_envelope(sys.stdin)
    if err_code is not None:
        sys.stderr.write(f"hydra-supervisor-escalate: envelope error: {err_code}\n")
        return EXIT_USAGE

    # Step 4 — resolve token. If --check, we don't need the token unless the
    # operator wanted to pre-flight the token presence; we DO check for
    # token-missing because "check" means "would this work right now?".
    auth_env = normalized["auth_token_env"]
    token = os.environ.get(auth_env, "")
    if not token:
        _emit({"error": "token-missing", "env_var": auth_env})
        return EXIT_ERROR

    # Step 5 — --check mode stops here. No network.
    if args.check:
        _emit({
            "status": "check-ok",
            "transport": normalized["transport"],
            "connect_url_host": _extract_host(normalized["connect_url"]),
            "timeout_sec": normalized["timeout_sec"],
            "envelope_worker_id": envelope["worker_id"],
        })
        return EXIT_OK

    # Step 6 — real call. HTTP only in Phase 1 (guard above already rejected others).
    try:
        response = _call_supervisor_http(
            connect_url=normalized["connect_url"],
            token=token,
            envelope=envelope,
            timeout_sec=normalized["timeout_sec"],
        )
    except _TimeoutError:
        _emit({"error": "timeout", "timeout_sec": normalized["timeout_sec"]})
        return EXIT_TIMEOUT
    except RuntimeError as e:
        # RuntimeError messages are pre-sanitized (they never contain the token).
        _emit({"error": str(e)})
        return EXIT_ERROR
    except Exception as e:  # pragma: no cover — defensive.
        _emit({"error": "unexpected", "detail": type(e).__name__})
        return EXIT_ERROR

    _emit(response)
    return EXIT_OK


def _extract_host(url: str) -> str:
    """Return the URL's scheme+host+port without path — for --check output so we never leak full URLs."""
    try:
        from urllib.parse import urlparse
        p = urlparse(url)
        if p.scheme and p.hostname:
            port = f":{p.port}" if p.port else ""
            return f"{p.scheme}://{p.hostname}{port}"
    except Exception:
        pass
    return "unknown"


if __name__ == "__main__":
    sys.exit(main())
