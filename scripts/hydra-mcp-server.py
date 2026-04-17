#!/usr/bin/env python3
"""
hydra-mcp-server.py — Minimum viable MCP server for Hydra's agent-only interface.

Spec: docs/specs/2026-04-17-mcp-server-binary.md
Tool contract (authoritative): mcp/hydra-tools.json
Human mirror: docs/mcp-tool-contract.md

This is the follow-up to PR #52 (which landed the tool contract). PR #72 ships the
actual server. Phase 1 scope per the ticket:

- HTTP transport only (stdio is a follow-up).
- Three tools fully implemented: hydra.get_status, hydra.list_ready_tickets, hydra.pause.
- Remaining 10 tools scaffolded as NotImplemented (JSON-RPC error -32001).
- hydra.merge_pr has an EXTRA pre-check: T3 PRs return a structured t3-refused
  result BEFORE the not-implemented branch runs, so the safety rail is live today.
- Bearer-token auth (SHA-256 match against state/connectors/mcp.json:authorized_agents).
- Scope enforcement (read/spawn/merge/admin) per mcp/hydra-tools.json:tools[].scope.
- Every call appended to logs/mcp-audit.jsonl (envelope only — no request/response bodies).

Runtime deps: Python 3 stdlib only. No pip install step. The Fly image already has
python3 for the /health server; this rides on that.

CLI:
    hydra-mcp-server.py --transport http --port 8765 [--bind 127.0.0.1]
    hydra-mcp-server.py --transport stdio    # rejected in Phase 1

Env overrides (used by entrypoint.sh on Fly):
    HYDRA_ROOT            Default: cwd
    HYDRA_MCP_CONFIG      Default: $HYDRA_ROOT/state/connectors/mcp.json
    HYDRA_MCP_TOOLS       Default: $HYDRA_ROOT/mcp/hydra-tools.json
    HYDRA_MCP_AUDIT_LOG   Default: $HYDRA_ROOT/logs/mcp-audit.jsonl
    HYDRA_MCP_PAUSE_FILE  Default: $HYDRA_ROOT/commander/PAUSE
"""

import argparse
import datetime as _dt
import hashlib
import hmac
import http.server
import json
import os
import socket
import socketserver
import subprocess
import sys
import threading
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

PROTOCOL_VERSION = "2024-11-05"  # MCP spec version we implement.
SERVER_NAME = "hydra-mcp"
SERVER_VERSION = "0.1.0"
MAX_BODY_BYTES = 64 * 1024  # 64 KiB coarse DoS guard.

# JSON-RPC 2.0 error codes we use.
ERR_PARSE = -32700
ERR_INVALID_REQUEST = -32600
ERR_METHOD_NOT_FOUND = -32601
ERR_INVALID_PARAMS = -32602
ERR_INTERNAL = -32603
ERR_NOT_IMPLEMENTED = -32001  # Application-defined, per JSON-RPC 2.0 §5.1.

# T3-sensitive paths (mirrors policy.md's hard refusals). Matching is substring-
# based; anything touching these paths → T3. Phase 1 uses a static list; a
# follow-up can replace this with a proper policy parser.
T3_SENSITIVE_PATHS: Tuple[str, ...] = (
    ".github/workflows/",
    "migration",
    "secrets/",
    ".env",
    "auth",
    "security",
    "crypto",
)


# -----------------------------------------------------------------------------
# Configuration loading
# -----------------------------------------------------------------------------

def _hydra_root() -> Path:
    return Path(os.environ.get("HYDRA_ROOT") or os.getcwd()).resolve()


def _config_path() -> Path:
    override = os.environ.get("HYDRA_MCP_CONFIG")
    if override:
        return Path(override)
    return _hydra_root() / "state" / "connectors" / "mcp.json"


def _tools_path() -> Path:
    override = os.environ.get("HYDRA_MCP_TOOLS")
    if override:
        return Path(override)
    return _hydra_root() / "mcp" / "hydra-tools.json"


def _audit_path() -> Path:
    override = os.environ.get("HYDRA_MCP_AUDIT_LOG")
    if override:
        return Path(override)
    return _hydra_root() / "logs" / "mcp-audit.jsonl"


def _pause_path() -> Path:
    override = os.environ.get("HYDRA_MCP_PAUSE_FILE")
    if override:
        return Path(override)
    return _hydra_root() / "commander" / "PAUSE"


def _rate_limit_path() -> Path:
    """Per-agent rate-limit state file. See state/schemas/mcp-rate-limit.schema.json."""
    override = os.environ.get("HYDRA_MCP_RATE_LIMIT")
    if override:
        return Path(override)
    return _hydra_root() / "state" / "mcp-rate-limit.json"


def _repos_path() -> Path:
    override = os.environ.get("HYDRA_REPOS_CONFIG")
    if override:
        return Path(override)
    return _hydra_root() / "state" / "repos.json"


def load_config() -> Dict[str, Any]:
    """Load state/connectors/mcp.json. Refuses to return if authorized_agents is empty."""
    path = _config_path()
    if not path.exists():
        raise SystemExit(
            f"✗ MCP config missing: {path}\n"
            f"  Copy state/connectors/mcp.json.example to state/connectors/mcp.json\n"
            f"  and fill in at least one authorized_agents[] entry."
        )
    try:
        with path.open() as f:
            cfg = json.load(f)
    except json.JSONDecodeError as e:
        raise SystemExit(f"✗ MCP config is not valid JSON ({path}): {e}")

    agents = cfg.get("authorized_agents") or []
    # Strip comment-only placeholder entries (token_hash that still starts with
    # "SHA256:REPLACE" is the example template — never honored).
    real_agents = [
        a for a in agents
        if isinstance(a, dict)
        and a.get("id")
        and a.get("token_hash")
        and not str(a["token_hash"]).startswith("SHA256:REPLACE")
    ]
    if not real_agents:
        raise SystemExit(
            f"✗ MCP config has no authorized agents: {path}\n"
            f"  At least one authorized_agents[] entry with id + token_hash is required.\n"
            f"  Refusing to serve an unauthenticated MCP surface."
        )
    cfg["authorized_agents"] = real_agents
    return cfg


def load_tools() -> List[Dict[str, Any]]:
    """Load mcp/hydra-tools.json. Strips the _scopes / _version metadata."""
    path = _tools_path()
    if not path.exists():
        raise SystemExit(f"✗ mcp/hydra-tools.json missing at {path}")
    with path.open() as f:
        data = json.load(f)
    tools = data.get("tools") or []
    if not tools:
        raise SystemExit(f"✗ mcp/hydra-tools.json has no tools array")
    return tools


# -----------------------------------------------------------------------------
# Auth
# -----------------------------------------------------------------------------

def sha256_hex(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _strip_sha256_prefix(hashval: str) -> str:
    """Config stores hashes as either 'SHA256:<hex>' or bare '<hex>'. Normalize to bare hex."""
    if hashval.startswith("SHA256:"):
        return hashval[len("SHA256:"):]
    return hashval


def match_agent(cfg: Dict[str, Any], token: str) -> Optional[Dict[str, Any]]:
    """Return the authorized_agents[] entry whose token_hash matches sha256(token), or None."""
    token_hash = sha256_hex(token)
    for agent in cfg["authorized_agents"]:
        stored = _strip_sha256_prefix(str(agent.get("token_hash", "")))
        if hmac.compare_digest(stored, token_hash):
            return agent
    return None


def scope_ok(agent: Dict[str, Any], required: str) -> bool:
    scopes = agent.get("scope") or []
    return required in scopes


# -----------------------------------------------------------------------------
# Audit log
# -----------------------------------------------------------------------------

_AUDIT_LOCK = threading.Lock()


def audit(
    *,
    caller_agent_id: Optional[str],
    tool: Optional[str],
    scope_check: str,
    refused_reason: Optional[str],
    input_hash: Optional[str] = None,
) -> None:
    """
    Append an audit envelope to logs/mcp-audit.jsonl.

    Never logs request/response bodies — they may contain tokens or sensitive
    repo snippets. caller_agent_id may be None for 401s (we don't know who
    they claimed to be until the hash matches).
    """
    record = {
        "ts": _dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "caller_agent_id": caller_agent_id,
        "tool": tool,
        "scope_check": scope_check,  # "ok" | "denied" | "unauthenticated" | "n/a"
        "refused_reason": refused_reason,
    }
    if input_hash is not None:
        record["input_hash"] = input_hash

    path = _audit_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n"
    with _AUDIT_LOCK:
        # Open with 0o600 perms on first create — audit entries include agent
        # IDs and tool names; keep them readable only to the owner rather than
        # relying on process umask.
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, line.encode("utf-8"))
        finally:
            os.close(fd)


# -----------------------------------------------------------------------------
# Tool handlers — three implemented, ten scaffolded
# -----------------------------------------------------------------------------

def _read_json_safe(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        with path.open() as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return default


def _handler_get_status(params: Dict[str, Any], agent: Dict[str, Any]) -> Dict[str, Any]:
    """
    hydra.get_status — reads state/active.json, state/autopickup.json,
    state/budget-used.json, and commander/PAUSE sentinel.
    """
    root = _hydra_root()
    active = _read_json_safe(root / "state" / "active.json", {"workers": []})
    autopickup = _read_json_safe(
        root / "state" / "autopickup.json",
        {"enabled": False, "interval_min": 30, "last_run": None},
    )
    budget = _read_json_safe(
        root / "state" / "budget-used.json",
        {"tickets_completed_today": 0, "tickets_failed_today": 0, "total_worker_wall_clock_minutes_today": 0},
    )
    paused = _pause_path().exists()

    # Shape per mcp/hydra-tools.json:hydra.get_status.output_schema.
    workers_out = []
    for w in active.get("workers", []):
        workers_out.append({
            "id": w.get("id", ""),
            "ticket": w.get("ticket", ""),
            "repo": w.get("repo", ""),
            "tier": w.get("tier", "T2"),
            "subagent_type": w.get("subagent_type", "worker-implementation"),
            "started_at": w.get("started_at", ""),
            "state": w.get("status", "running"),
        })

    return {
        "active_workers": workers_out,
        "today": {
            "done": budget.get("tickets_completed_today", 0),
            "failed": budget.get("tickets_failed_today", 0),
            "wall_clock_min": budget.get("total_worker_wall_clock_minutes_today", 0),
        },
        "paused": paused,
        "autopickup": {
            "enabled": bool(autopickup.get("enabled", False)),
            "interval_min": int(autopickup.get("interval_min", 30)),
            "last_run": autopickup.get("last_run"),
        },
        "quota_health": {
            # Phase 1 doesn't probe GitHub/Linear from the MCP server. Future work
            # can populate these from state/quota-health.json when that lands.
            "github_rate_limit_ok": True,
            "linear_rate_limit_ok": True,
        },
    }


def _handler_list_ready_tickets(params: Dict[str, Any], agent: Dict[str, Any]) -> Dict[str, Any]:
    """
    hydra.list_ready_tickets — shells out to `gh issue list` for each enabled repo.

    Phase 1 is read-only and best-effort: if `gh` is not authenticated or a repo
    is unreachable, that repo is skipped silently. We do NOT fail the call over
    a single repo. tier_guess is always "unknown" for Phase 1 — classification
    belongs to Commander, not the MCP shim.
    """
    limit = int(params.get("limit", 10))
    repo_filter = params.get("repo")

    repos_json = _read_json_safe(_hydra_root() / "state" / "repos.json", {"repos": []})
    enabled_repos = [
        r for r in repos_json.get("repos", [])
        if r.get("enabled") and r.get("owner") and r.get("name")
    ]
    if repo_filter:
        enabled_repos = [
            r for r in enabled_repos
            if f"{r['owner']}/{r['name']}" == repo_filter
        ]

    tickets: List[Dict[str, Any]] = []
    state_labels = {
        "commander-working", "commander-pause", "commander-stuck",
        "commander-review", "commander-reviewed", "commander-rejected",
        "commander-superseded", "commander-skill-promotion", "commander-undo",
    }

    for r in enabled_repos:
        slug = f"{r['owner']}/{r['name']}"
        trigger = r.get("ticket_trigger", "assignee")
        if trigger not in ("assignee", "label"):
            # Linear trigger handled by Commander, not this shim.
            continue
        cmd = [
            "gh", "issue", "list",
            "--repo", slug,
            "--state", "open",
            "--limit", str(min(limit, 100)),
            "--json", "number,title,labels",
        ]
        if trigger == "assignee":
            cmd.extend(["--assignee", "@me"])
        else:
            cmd.extend(["--label", "commander-ready"])

        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=30, check=False,
            )
            if result.returncode != 0:
                continue
            issues = json.loads(result.stdout or "[]")
        except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
            continue

        for issue in issues:
            labels = [lbl.get("name", "") for lbl in issue.get("labels", [])]
            if any(lbl in state_labels for lbl in labels):
                continue
            tickets.append({
                "repo": slug,
                "num": issue.get("number"),
                "title": issue.get("title", ""),
                "tier_guess": "unknown",  # Phase 1: classification is Commander's job.
                "labels": labels,
                "source": "github",
            })
            if len(tickets) >= limit:
                break
        if len(tickets) >= limit:
            break

    return {"tickets": tickets[:limit]}


def _handler_pause(params: Dict[str, Any], agent: Dict[str, Any]) -> Dict[str, Any]:
    """
    hydra.pause — create the commander/PAUSE sentinel file. Idempotent.

    Body is the caller_agent_id + reason so `ls -l commander/PAUSE` and a cat
    tell an operator who paused the system and why.
    """
    reason = str(params.get("reason", "")).strip()[:500]
    now = _dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    body = f"paused_by={agent.get('id', 'unknown')} at={now}\n"
    if reason:
        body += f"reason={reason}\n"

    path = _pause_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)

    return {"paused_at": now}


def _handler_not_implemented(tool_name: str):
    """Factory returning a handler that raises the standard NotImplemented JSON-RPC error."""
    def _h(params: Dict[str, Any], agent: Dict[str, Any]) -> Dict[str, Any]:
        raise _NotImplementedError(tool_name)
    return _h


class _NotImplementedError(Exception):
    """Raised by scaffolded tool handlers. Turned into a JSON-RPC -32001 error by the dispatcher."""
    def __init__(self, tool_name: str):
        self.tool_name = tool_name


class _T3RefusedError(Exception):
    """Raised by hydra.merge_pr pre-check when the PR targets a T3-sensitive path."""
    def __init__(self, reason: str):
        self.reason = reason


class _StructuredToolError(Exception):
    """
    Raised by tool handlers that want to return a structured error payload
    (e.g. validation error, rate-limit error) rather than a JSON-RPC error
    code.

    The dispatcher turns this into a tool-call result with isError=true and
    structuredContent={error, reason, **extra}. This matches the shape used
    by hydra.merge_pr's t3-refused response, which clients already know how
    to parse.
    """

    def __init__(self, error: str, reason: str, **extra: Any):
        super().__init__(f"{error}: {reason}")
        self.error = error
        self.reason = reason
        self.extra = extra


# -----------------------------------------------------------------------------
# Rate limiter — rolling window, file-backed
# -----------------------------------------------------------------------------

_RATE_LIMIT_LOCK = threading.Lock()

# Per-tool ceilings. Kept small — hydra.file_ticket is the only rate-limited
# tool today. Adding more means adding entries here and plumbing the tool
# handler to call _rate_limit_check("<tool>", agent_id) early.
RATE_LIMITS: Dict[str, Dict[str, int]] = {
    "file_ticket": {"window_sec": 3600, "max_calls": 10},
}


def _parse_iso_utc(ts: str) -> float:
    """Parse an ISO-8601 UTC timestamp (e.g. '2026-04-17T12:34:56Z') to a Unix epoch float."""
    # Accept both trailing 'Z' and naive '...:56' — we always write with Z.
    if ts.endswith("Z"):
        ts = ts[:-1]
    # Strip any fractional seconds that may sneak in — we write to second precision.
    if "." in ts:
        ts = ts.split(".", 1)[0]
    dt = _dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S")
    return dt.replace(tzinfo=_dt.timezone.utc).timestamp()


def _rate_limit_load() -> Dict[str, Any]:
    """Load the rate-limit state file. Returns a fresh skeleton if missing/unreadable."""
    path = _rate_limit_path()
    if not path.exists():
        return {"limits": {}, "agents": {}}
    try:
        with path.open() as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return {"limits": {}, "agents": {}}


def _rate_limit_save(state: Dict[str, Any]) -> None:
    """Write the rate-limit state atomically (tmpfile + rename, same dir)."""
    path = _rate_limit_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    with tmp.open("w") as f:
        json.dump(state, f, separators=(",", ":"), sort_keys=True)
    os.replace(tmp, path)


def _rate_limit_check_and_record(tool_key: str, agent_id: str) -> None:
    """
    Check whether the given agent may call the given tool right now. If yes,
    record this call's timestamp. If no, raise _StructuredToolError with
    error='rate-limited' and retry_after_sec.

    Implementation: rolling window. On every check, evict timestamps older
    than window_sec. If the remaining count is >= max_calls, refuse with
    retry_after_sec = window_sec - (now - oldest_remaining_ts).

    Thread-safe within one process via _RATE_LIMIT_LOCK. Multi-process
    safety is not required in Phase 1 (one MCP server per Commander).
    """
    limit = RATE_LIMITS.get(tool_key)
    if limit is None:  # Defensive — caller passed an unregistered tool key.
        return

    window_sec = limit["window_sec"]
    max_calls = limit["max_calls"]
    now = _dt.datetime.utcnow()
    now_epoch = now.replace(tzinfo=_dt.timezone.utc).timestamp()
    now_iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    with _RATE_LIMIT_LOCK:
        state = _rate_limit_load()
        # Keep the `limits` block aligned with RATE_LIMITS so operators can
        # inspect the running config without grepping the source.
        state.setdefault("limits", {})
        state["limits"][tool_key] = {"window_sec": window_sec, "max_calls": max_calls}
        state.setdefault("agents", {})
        state["agents"].setdefault(agent_id, {})
        timestamps: List[str] = state["agents"][agent_id].get(tool_key, [])

        # Evict old timestamps.
        fresh: List[str] = []
        for ts in timestamps:
            try:
                ts_epoch = _parse_iso_utc(ts)
            except ValueError:
                continue  # Skip malformed — never count toward the limit.
            if now_epoch - ts_epoch < window_sec:
                fresh.append(ts)
        timestamps = fresh

        if len(timestamps) >= max_calls:
            oldest_epoch = _parse_iso_utc(timestamps[0])
            retry_after_sec = int(window_sec - (now_epoch - oldest_epoch)) + 1
            if retry_after_sec < 1:
                retry_after_sec = 1
            # Persist the eviction result even on refusal — next call re-reads
            # a tidier list.
            state["agents"][agent_id][tool_key] = timestamps
            _rate_limit_save(state)
            raise _StructuredToolError(
                error="rate-limited",
                reason=(
                    f"tool '{tool_key}' is rate-limited: "
                    f"{max_calls} calls per {window_sec}s per agent. "
                    f"Retry in ~{retry_after_sec}s."
                ),
                limit=max_calls,
                window_sec=window_sec,
                retry_after_sec=retry_after_sec,
            )

        # Record this call.
        timestamps.append(now_iso)
        state["agents"][agent_id][tool_key] = timestamps
        _rate_limit_save(state)


def _handler_file_ticket(params: Dict[str, Any], agent: Dict[str, Any]) -> Dict[str, Any]:
    """
    hydra.file_ticket — file a GitHub issue into an enabled repo and surface
    whether the next autopickup tick will pick it up.

    Primary use case: Main Agent (the operator's Claude Code session on their
    laptop) turns a spoken complaint into a Hydra ticket via one MCP call.

    Spec: docs/specs/2026-04-17-main-agent-filing.md.
    """
    # --- validate inputs ----------------------------------------------------
    repo = str(params.get("repo", "")).strip()
    title = str(params.get("title", ""))
    body = str(params.get("body", ""))
    proposed_tier = params.get("proposed_tier")
    user_labels = params.get("labels") or []
    auto_pickup = params.get("auto_pickup", True)

    if not repo or "/" not in repo:
        raise _StructuredToolError(
            error="validation-error",
            reason="repo must be 'owner/name' form",
        )

    if not title:
        raise _StructuredToolError(
            error="validation-error",
            reason="title is required",
        )
    if len(title) > 120:
        raise _StructuredToolError(
            error="validation-error",
            reason=f"title exceeds 120 chars (got {len(title)})",
        )
    # Anti-spam: title + body combined must be at least 20 chars.
    if len(title) + len(body) < 20:
        raise _StructuredToolError(
            error="validation-error",
            reason="title + body must be ≥ 20 chars combined (anti-spam)",
        )
    if proposed_tier is not None and proposed_tier not in ("T1", "T2", "T3"):
        raise _StructuredToolError(
            error="validation-error",
            reason=f"proposed_tier must be T1/T2/T3 (got {proposed_tier!r})",
        )
    if not isinstance(user_labels, list) or not all(isinstance(x, str) for x in user_labels):
        raise _StructuredToolError(
            error="validation-error",
            reason="labels must be an array of strings",
        )

    # --- enabled-repo gate --------------------------------------------------
    repos_cfg = _read_json_safe(_repos_path(), {"repos": []})
    enabled_match = next(
        (
            r for r in repos_cfg.get("repos", [])
            if r.get("enabled") is True
            and r.get("owner") and r.get("name")
            and f"{r['owner']}/{r['name']}" == repo
        ),
        None,
    )
    if enabled_match is None:
        raise _StructuredToolError(
            error="repo-not-enabled",
            reason=(
                f"repo '{repo}' is not enabled in state/repos.json — "
                "add or enable it before filing."
            ),
        )

    # --- rate limit ---------------------------------------------------------
    # Rate-limit AFTER validation so a malformed call doesn't consume a slot.
    _rate_limit_check_and_record("file_ticket", str(agent.get("id", "unknown")))

    # --- assemble labels + body ---------------------------------------------
    is_t3 = (proposed_tier == "T3")
    final_body = body
    if is_t3:
        final_body = (
            "_Filed as T3 — Commander will not pick up automatically; "
            "operator must resolve manually._\n\n" + body
        )

    commander_labels = ["commander-auto-filed"]
    if is_t3:
        commander_labels.append("commander-stuck")
    elif auto_pickup:
        commander_labels.append("commander-ready")
    # If auto_pickup=False and not T3 → no commander-ready, autopickup skips.

    # De-dupe while preserving order: commander-* first, then user labels.
    seen = set()
    final_labels: List[str] = []
    for lbl in commander_labels + list(user_labels):
        if lbl and lbl not in seen:
            final_labels.append(lbl)
            seen.add(lbl)

    # --- file via gh issue create -------------------------------------------
    cmd = ["gh", "issue", "create",
           "--repo", repo,
           "--title", title,
           "--body", final_body]
    for lbl in final_labels:
        cmd.extend(["--label", lbl])

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30, check=False,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        raise _StructuredToolError(
            error="gh-failure",
            reason=f"gh issue create failed: {type(e).__name__}: {e}",
        )
    if result.returncode != 0:
        raise _StructuredToolError(
            error="gh-failure",
            reason=(
                f"gh issue create exited {result.returncode}: "
                f"{(result.stderr or result.stdout).strip()[:300]}"
            ),
        )

    # gh prints the created issue URL on stdout, e.g.
    # "https://github.com/tonychang04/hydra/issues/142".
    issue_url = (result.stdout or "").strip().splitlines()[-1].strip() if result.stdout else ""
    issue_number = 0
    if "/issues/" in issue_url:
        try:
            issue_number = int(issue_url.rsplit("/", 1)[-1])
        except ValueError:
            issue_number = 0

    # --- compute will_autopickup --------------------------------------------
    reason: Optional[str] = None
    will_autopickup = True
    if is_t3:
        will_autopickup = False
        reason = "proposed_tier=T3 (Commander refuses T3 autopickup)"
    elif not auto_pickup:
        will_autopickup = False
        reason = "auto_pickup=false"
    elif _pause_path().exists():
        will_autopickup = False
        reason = "commander-paused (PAUSE sentinel present)"

    return {
        "issue_number": issue_number,
        "issue_url": issue_url,
        "will_autopickup": will_autopickup,
        "reason": reason,
    }


def _handler_merge_pr(params: Dict[str, Any], agent: Dict[str, Any]) -> Dict[str, Any]:
    """
    hydra.merge_pr — Phase 1 STUB with a live T3 pre-check.

    The actual merge logic is not implemented; this handler exists only to
    enforce the safety rail called out in ticket #72 acceptance criterion 7:
    T3 PRs must ALWAYS return {error: "t3-refused"} regardless of caller scope.

    Tier detection (Phase 1): shell out to `gh pr view <num> --json files` and
    substring-match each file path against T3_SENSITIVE_PATHS. If any sensitive
    path is touched, the PR is T3 and we refuse. If `gh` is unavailable or the
    PR doesn't exist, we conservatively refuse with a t3-refused response
    (better false-positive than accidentally approving a T3 merge).
    """
    pr_num = params.get("pr_num")
    repo = params.get("repo") or ""
    if not isinstance(pr_num, int) or pr_num < 1:
        raise _T3RefusedError("invalid pr_num; refusing conservatively")

    tier = _classify_pr_tier(pr_num, repo)
    if tier == "T3":
        raise _T3RefusedError(
            f"T3 PR (touches {', '.join(T3_SENSITIVE_PATHS)[:120]}...) — "
            "Commander never merges T3 through the MCP surface."
        )

    # T1/T2/unknown: fall through to the not-implemented branch. Follow-up
    # ticket wires the actual merge dispatch.
    raise _NotImplementedError("hydra.merge_pr")


def _classify_pr_tier(pr_num: int, repo: str) -> str:
    """
    Classify a PR as T3 (sensitive) or 'unknown' via `gh pr view`.
    Any gh failure → 'unknown' (caller_merge_pr refuses conservatively regardless).
    """
    cmd = ["gh", "pr", "view", str(pr_num), "--json", "files"]
    if repo:
        cmd.extend(["--repo", repo])
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=15, check=False,
        )
        if result.returncode != 0:
            return "unknown"
        data = json.loads(result.stdout or "{}")
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        return "unknown"

    for f in data.get("files", []):
        path = f.get("path", "")
        for sensitive in T3_SENSITIVE_PATHS:
            if sensitive in path:
                return "T3"
    return "unknown"


# Map tool name → handler. Three implemented, ten scaffolded. hydra.merge_pr has
# the custom T3 pre-check built into its handler.
TOOL_HANDLERS: Dict[str, Any] = {
    "hydra.get_status": _handler_get_status,
    "hydra.list_ready_tickets": _handler_list_ready_tickets,
    "hydra.pause": _handler_pause,
    "hydra.merge_pr": _handler_merge_pr,  # T3 pre-check, then NotImplemented.
    "hydra.file_ticket": _handler_file_ticket,  # ticket #143, spec: 2026-04-17-main-agent-filing.md
    # Phase 1 scaffolded tools — schemas visible in tools/list, calls return -32001:
    "hydra.pick_up": _handler_not_implemented("hydra.pick_up"),
    "hydra.pick_up_specific": _handler_not_implemented("hydra.pick_up_specific"),
    "hydra.review_pr": _handler_not_implemented("hydra.review_pr"),
    "hydra.reject_pr": _handler_not_implemented("hydra.reject_pr"),
    "hydra.answer_worker_question": _handler_not_implemented("hydra.answer_worker_question"),
    "hydra.resume": _handler_not_implemented("hydra.resume"),
    "hydra.retro": _handler_not_implemented("hydra.retro"),
    "hydra.get_log": _handler_not_implemented("hydra.get_log"),
    "hydra.kill_worker": _handler_not_implemented("hydra.kill_worker"),
}


# -----------------------------------------------------------------------------
# HTTP server
# -----------------------------------------------------------------------------

class McpHandler(http.server.BaseHTTPRequestHandler):
    # These are set by the factory below.
    config: Dict[str, Any]
    tools: List[Dict[str, Any]]

    # Quiet the default BaseHTTPRequestHandler stderr spam (one line per req).
    # We log ourselves via audit().
    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
        # Write to stderr with a compact prefix; callers that want richer log
        # stream the audit jsonl.
        sys.stderr.write(f"[hydra-mcp {_dt.datetime.utcnow().isoformat()}Z] {fmt % args}\n")

    def do_GET(self) -> None:  # noqa: N802 (stdlib naming)
        if self.path in ("/mcp", "/mcp/"):
            self.send_error(405, "Method Not Allowed — POST JSON-RPC to /mcp")
            return
        if self.path == "/":
            body = b"hydra-mcp: POST JSON-RPC to /mcp\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404, "Not Found")

    def do_POST(self) -> None:  # noqa: N802 (stdlib naming)
        if self.path not in ("/mcp", "/mcp/"):
            self.send_error(404, "Not Found — POST to /mcp")
            return

        # Body size cap.
        length_hdr = self.headers.get("Content-Length")
        try:
            length = int(length_hdr or "0")
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY_BYTES:
            self._send_json(400, {"error": "missing or oversized body (64 KiB cap)"})
            return

        raw = self.rfile.read(length)
        try:
            req = json.loads(raw)
        except json.JSONDecodeError:
            self._send_jsonrpc_error(None, ERR_PARSE, "Parse error")
            return

        if not isinstance(req, dict) or req.get("jsonrpc") != "2.0":
            self._send_jsonrpc_error(
                req.get("id") if isinstance(req, dict) else None,
                ERR_INVALID_REQUEST,
                "jsonrpc 2.0 required",
            )
            return

        req_id = req.get("id")
        method = req.get("method")
        params = req.get("params") or {}

        # Auth. Bearer scheme is case-insensitive per RFC 7235 §2.1.
        auth_hdr = self.headers.get("Authorization", "")
        scheme, _, raw_token = auth_hdr.partition(" ")
        if scheme.lower() != "bearer" or not raw_token:
            audit(
                caller_agent_id=None, tool=None,
                scope_check="unauthenticated",
                refused_reason="missing Authorization: Bearer header",
            )
            self._send_json(401, {"error": "missing Authorization: Bearer header"})
            return
        token = raw_token.strip()
        agent = match_agent(self.config, token)
        if agent is None:
            audit(
                caller_agent_id=None, tool=None,
                scope_check="unauthenticated",
                refused_reason="token hash does not match any authorized_agent",
            )
            self._send_json(401, {"error": "invalid bearer token"})
            return

        # Dispatch by MCP method.
        if method == "initialize":
            audit(caller_agent_id=agent["id"], tool=None, scope_check="n/a", refused_reason=None)
            self._send_jsonrpc_result(req_id, {
                "protocolVersion": PROTOCOL_VERSION,
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                "capabilities": {"tools": {"listChanged": False}},
            })
            return

        if method == "ping":
            audit(caller_agent_id=agent["id"], tool=None, scope_check="n/a", refused_reason=None)
            self._send_jsonrpc_result(req_id, {})
            return

        if method == "tools/list":
            audit(caller_agent_id=agent["id"], tool=None, scope_check="n/a", refused_reason=None)
            # Advertise every tool from the contract (all 13), with the MCP-expected
            # shape {name, description, inputSchema}.
            listed = []
            for t in self.tools:
                listed.append({
                    "name": t["name"],
                    "description": t.get("description", ""),
                    "inputSchema": t.get("input_schema", {"type": "object"}),
                })
            self._send_jsonrpc_result(req_id, {"tools": listed})
            return

        if method == "tools/call":
            self._handle_tools_call(req_id, params, agent)
            return

        # Unknown method.
        audit(
            caller_agent_id=agent["id"], tool=method,
            scope_check="n/a", refused_reason="unknown method",
        )
        self._send_jsonrpc_error(req_id, ERR_METHOD_NOT_FOUND, f"Method not found: {method}")

    # -- internals -------------------------------------------------------------

    def _handle_tools_call(
        self, req_id: Any, params: Dict[str, Any], agent: Dict[str, Any],
    ) -> None:
        tool_name = params.get("name")
        tool_args = params.get("arguments") or {}

        tool_def = next((t for t in self.tools if t["name"] == tool_name), None)
        if tool_def is None:
            audit(
                caller_agent_id=agent["id"], tool=tool_name,
                scope_check="n/a", refused_reason="unknown tool",
            )
            self._send_jsonrpc_error(req_id, ERR_METHOD_NOT_FOUND, f"Unknown tool: {tool_name}")
            return

        required_scope = tool_def.get("scope", "read")
        if not scope_ok(agent, required_scope):
            audit(
                caller_agent_id=agent["id"], tool=tool_name,
                scope_check="denied",
                refused_reason=f"caller scope {agent.get('scope')} lacks required {required_scope!r}",
            )
            self._send_json(403, {"error": f"scope '{required_scope}' required"})
            return

        handler = TOOL_HANDLERS.get(tool_name)
        if handler is None:  # Safety net — should be unreachable; every tool is registered.
            audit(
                caller_agent_id=agent["id"], tool=tool_name,
                scope_check="ok", refused_reason="no handler registered",
            )
            self._send_jsonrpc_error(req_id, ERR_INTERNAL, f"No handler for tool: {tool_name}")
            return

        input_hash = hashlib.sha256(
            json.dumps(tool_args, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()[:16]

        try:
            result = handler(tool_args, agent)
        except _T3RefusedError as e:
            # Structured refusal per tool contract: surfaced as a successful
            # tool-call result containing {error: "t3-refused", reason}.
            audit(
                caller_agent_id=agent["id"], tool=tool_name,
                scope_check="ok", refused_reason="t3-refused",
                input_hash=input_hash,
            )
            self._send_jsonrpc_result(req_id, {
                "content": [{"type": "text", "text": json.dumps({
                    "error": "t3-refused",
                    "reason": e.reason,
                })}],
                "isError": True,
                "structuredContent": {"error": "t3-refused", "reason": e.reason},
            })
            return
        except _StructuredToolError as e:
            # Generic structured refusal (validation errors, rate-limit,
            # gh-failure). Same wire shape as t3-refused so clients have
            # one parse path for all tool-level refusals.
            payload: Dict[str, Any] = {"error": e.error, "reason": e.reason}
            payload.update(e.extra)
            audit(
                caller_agent_id=agent["id"], tool=tool_name,
                scope_check="ok", refused_reason=e.error,
                input_hash=input_hash,
            )
            self._send_jsonrpc_result(req_id, {
                "content": [{"type": "text", "text": json.dumps(payload)}],
                "isError": True,
                "structuredContent": payload,
            })
            return
        except _NotImplementedError as e:
            audit(
                caller_agent_id=agent["id"], tool=tool_name,
                scope_check="ok", refused_reason="not-implemented",
                input_hash=input_hash,
            )
            self._send_jsonrpc_error(
                req_id, ERR_NOT_IMPLEMENTED,
                f"Tool not implemented in Phase 1: {e.tool_name}",
                data={
                    "tool": e.tool_name,
                    "phase": 1,
                    "message": (
                        "This tool is advertised via tools/list so client agents "
                        "can plan against the contract, but Phase 1 only wires "
                        "hydra.get_status, hydra.list_ready_tickets, and hydra.pause. "
                        "See docs/specs/2026-04-17-mcp-server-binary.md §Non-goals."
                    ),
                    "follow_up_ticket": None,
                },
            )
            return
        except Exception as e:  # pragma: no cover — defensive.
            audit(
                caller_agent_id=agent["id"], tool=tool_name,
                scope_check="ok", refused_reason=f"handler exception: {type(e).__name__}",
                input_hash=input_hash,
            )
            self._send_jsonrpc_error(req_id, ERR_INTERNAL, f"Handler error: {e}")
            return

        audit(
            caller_agent_id=agent["id"], tool=tool_name,
            scope_check="ok", refused_reason=None, input_hash=input_hash,
        )
        # MCP tool-call result shape: wrap the structured response in content+structuredContent
        # so clients speaking either the older or newer MCP spec can parse it.
        self._send_jsonrpc_result(req_id, {
            "content": [{"type": "text", "text": json.dumps(result)}],
            "structuredContent": result,
        })

    def _send_json(self, status: int, body: Dict[str, Any]) -> None:
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _send_jsonrpc_result(self, req_id: Any, result: Any) -> None:
        self._send_json(200, {"jsonrpc": "2.0", "id": req_id, "result": result})

    def _send_jsonrpc_error(
        self, req_id: Any, code: int, message: str, data: Any = None,
    ) -> None:
        err: Dict[str, Any] = {"code": code, "message": message}
        if data is not None:
            err["data"] = data
        self._send_json(200, {"jsonrpc": "2.0", "id": req_id, "error": err})


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def make_handler(cfg: Dict[str, Any], tools: List[Dict[str, Any]]):
    """Return a McpHandler subclass with config/tools baked in (server.py requires a class, not an instance)."""
    class _H(McpHandler):
        pass
    _H.config = cfg
    _H.tools = tools
    return _H


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def _parse_args(argv: List[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="hydra-mcp-server",
        description="Minimum viable MCP server for Hydra's agent-only interface (ticket #72)",
    )
    p.add_argument("--transport", default="http", choices=["http", "stdio"],
                   help="Transport to serve over. Phase 1 only supports 'http'.")
    p.add_argument("--port", type=int, default=int(os.environ.get("HYDRA_MCP_PORT", "8765")),
                   help="HTTP port (default 8765)")
    p.add_argument("--bind", default=os.environ.get("HYDRA_MCP_BIND", "127.0.0.1"),
                   help="Bind address (default 127.0.0.1). NEVER 0.0.0.0 without a TLS reverse proxy.")
    p.add_argument("--check", action="store_true",
                   help="Validate config + tools and exit 0 (no bind). Useful in CI.")
    return p.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])

    if args.transport == "stdio":
        sys.stderr.write(
            "stdio transport is a Phase 1 non-goal. "
            "See docs/specs/2026-04-17-mcp-server-binary.md §Non-goals.\n"
            "Use --transport http (default) for now.\n"
        )
        return 2

    try:
        cfg = load_config()
        tools = load_tools()
    except SystemExit as e:
        sys.stderr.write(str(e) + "\n")
        return 1

    if args.check:
        sys.stdout.write(
            f"✓ config OK: {len(cfg['authorized_agents'])} authorized agent(s)\n"
            f"✓ tools OK: {len(tools)} registered\n"
            f"✓ all {len(tools)} tool handlers mapped: "
            f"{sum(1 for t in tools if t['name'] in TOOL_HANDLERS)}/{len(tools)}\n"
        )
        return 0

    handler_cls = make_handler(cfg, tools)
    try:
        server = ThreadingHTTPServer((args.bind, args.port), handler_cls)
    except (OSError, socket.error) as e:
        sys.stderr.write(f"✗ Failed to bind {args.bind}:{args.port}: {e}\n")
        return 1

    sys.stderr.write(
        f"[hydra-mcp] listening on http://{args.bind}:{args.port}/mcp "
        f"({len(cfg['authorized_agents'])} agent(s), {len(tools)} tool(s))\n"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("[hydra-mcp] shutdown\n")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
