#!/usr/bin/env python3
"""
hydra-webhook-receiver.py — GitHub webhook receiver for Hydra commander.

Spec: docs/specs/2026-04-17-github-webhook-receiver.md (ticket #41)

Phase 1 scope per the spec:

- HTTP (loopback-default) server, Python stdlib only — same pattern as
  scripts/hydra-mcp-server.py (ticket #72).
- Single route: POST /webhook/github. Everything else → 404.
- HMAC-SHA256 validation against X-Hub-Signature-256, constant-time compare.
- Event filter: only `X-GitHub-Event: issues` with body `action == "assigned"`
  produces a sentinel. Anything else → 204 No Content (not 400; GitHub's
  delivery UI treats 2xx as acknowledged).
- Sentinel drop: state/webhook-triggers/<ts>-<owner>-<repo>-<issue>.json with
  a minimal envelope. No issue body text is persisted (security invariant).
- Body never logged; secret never logged.

Commander's autopickup tick will consume the sentinel directory in a follow-up
PR. This script is purely the producer.

Runtime deps: Python 3 stdlib only. The Fly image already has python3 for the
/health server and the MCP server; this rides on that.

CLI:
    hydra-webhook-receiver.py [--port 8766] [--bind 127.0.0.1] [--check]

Env overrides (used by infra/entrypoint.sh on Fly — follow-up ticket):
    HYDRA_ROOT                 Default: cwd
    HYDRA_WEBHOOK_SECRET       REQUIRED. Raw HMAC secret (32+ bytes random).
    HYDRA_WEBHOOK_PORT         Default: 8766
    HYDRA_WEBHOOK_BIND         Default: 127.0.0.1 (NEVER 0.0.0.0 without TLS in front)
    HYDRA_WEBHOOK_SENTINEL_DIR Default: $HYDRA_ROOT/state/webhook-triggers
    HYDRA_WEBHOOK_MAX_BODY     Default: 1048576 (1 MiB)
"""

import argparse
import datetime as _dt
import hashlib
import hmac
import http.server
import json
import os
import re
import socket
import socketserver
import sys
import threading
from pathlib import Path
from typing import Any, Dict, List, Optional

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

DEFAULT_PORT = 8766
DEFAULT_BIND = "127.0.0.1"
DEFAULT_MAX_BODY = 1024 * 1024  # 1 MiB — GitHub issue payloads max ~100 KiB.
SIGNATURE_HEADER = "X-Hub-Signature-256"
EVENT_HEADER = "X-GitHub-Event"
DELIVERY_HEADER = "X-GitHub-Delivery"
TARGET_EVENT = "issues"
TARGET_ACTION = "assigned"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------


def _hydra_root() -> Path:
    return Path(os.environ.get("HYDRA_ROOT") or os.getcwd()).resolve()


def _sentinel_dir() -> Path:
    override = os.environ.get("HYDRA_WEBHOOK_SENTINEL_DIR")
    if override:
        return Path(override)
    return _hydra_root() / "state" / "webhook-triggers"


def _max_body() -> int:
    raw = os.environ.get("HYDRA_WEBHOOK_MAX_BODY")
    if not raw:
        return DEFAULT_MAX_BODY
    try:
        v = int(raw)
        if v <= 0:
            return DEFAULT_MAX_BODY
        return v
    except ValueError:
        return DEFAULT_MAX_BODY


def load_secret() -> str:
    """
    Read HYDRA_WEBHOOK_SECRET from env. Refuse if absent or empty — serving
    an unauthenticated webhook receiver would let anyone on the internet drop
    a sentinel file and bypass Commander's tier classification.
    """
    secret = os.environ.get("HYDRA_WEBHOOK_SECRET", "")
    if not secret:
        raise SystemExit(
            "✗ HYDRA_WEBHOOK_SECRET env var is not set.\n"
            "  Generate one: `openssl rand -hex 32`\n"
            "  On Fly:        `fly secrets set HYDRA_WEBHOOK_SECRET=... --app <app>`\n"
            "  Locally:       `export HYDRA_WEBHOOK_SECRET=...`\n"
            "  Refusing to serve an unauthenticated webhook receiver."
        )
    return secret


# -----------------------------------------------------------------------------
# HMAC validation
# -----------------------------------------------------------------------------


def compute_signature(secret: str, body: bytes) -> str:
    """Return the `sha256=<hex>` value GitHub would put in X-Hub-Signature-256."""
    digest = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
    return f"sha256={digest}"


def signature_matches(secret: str, body: bytes, provided: str) -> bool:
    """
    Constant-time compare of the provided signature against the expected one.
    `hmac.compare_digest` handles the timing-oracle concern (ticket #41 security note).
    """
    if not provided:
        return False
    expected = compute_signature(secret, body)
    return hmac.compare_digest(expected, provided)


# -----------------------------------------------------------------------------
# Sentinel file drop
# -----------------------------------------------------------------------------

_SENTINEL_LOCK = threading.Lock()

# Strict: owner/repo characters GitHub actually permits, plus . / - / _. Any
# surprise character trips validation and the envelope is dropped. Prevents
# path-traversal via a malformed payload.
_SLUG_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def _safe_slug(s: Optional[str]) -> Optional[str]:
    if not s or not isinstance(s, str):
        return None
    if not _SLUG_RE.match(s):
        return None
    return s


def write_sentinel(
    sentinel_dir: Path,
    *,
    ts: str,
    repo_owner: str,
    repo_name: str,
    issue_num: int,
    event: str,
    action: str,
    assignee_login: Optional[str],
    delivery_id: Optional[str],
) -> Path:
    """
    Drop a sentinel file at <sentinel_dir>/<ts>-<owner>-<repo>-<issue>.json.

    The file is written 0o600 (readable only by commander). Deliberately
    NO issue body content is persisted — per ticket #41 security notes,
    webhook payloads may contain proprietary issue bodies.
    """
    sentinel_dir.mkdir(parents=True, exist_ok=True)

    # ts is ISO8601Z; use a filename-safe variant (colons are fine on Linux
    # but macOS HFS / some tooling dislikes them — prefer hyphens).
    fs_ts = ts.replace(":", "").replace("-", "")
    fname = f"{fs_ts}-{repo_owner}-{repo_name}-{issue_num}.json"
    path = sentinel_dir / fname

    envelope = {
        "ts": ts,
        "repo": f"{repo_owner}/{repo_name}",
        "issue_num": issue_num,
        "event": event,
        "action": action,
        "assignee": {"login": assignee_login} if assignee_login else None,
        "source": "github-webhook",
    }
    if delivery_id:
        envelope["delivery_id"] = delivery_id

    with _SENTINEL_LOCK:
        # O_EXCL so two deliveries with identical timestamps can't collide.
        # If the (extremely unlikely) collision happens, add a short suffix.
        attempt = 0
        while True:
            candidate = path if attempt == 0 else sentinel_dir / f"{path.stem}-{attempt}.json"
            try:
                fd = os.open(str(candidate), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                attempt += 1
                if attempt > 9:
                    # Give up; caller will log the failure.
                    raise
                continue
            try:
                os.write(fd, json.dumps(envelope, separators=(",", ":"), sort_keys=True).encode("utf-8"))
                os.write(fd, b"\n")
            finally:
                os.close(fd)
            return candidate


# -----------------------------------------------------------------------------
# HTTP handler
# -----------------------------------------------------------------------------


class WebhookHandler(http.server.BaseHTTPRequestHandler):
    # Set by the factory below.
    secret: str
    sentinel_dir: Path
    max_body: int

    # Override the default stderr line so we don't accidentally log query
    # strings or bodies.
    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
        sys.stderr.write(
            f"[hydra-webhook {_dt.datetime.utcnow().isoformat()}Z] "
            f"{fmt % args}\n"
        )

    def do_GET(self) -> None:  # noqa: N802 (stdlib naming)
        if self.path == "/":
            body = b"hydra-webhook-receiver: POST /webhook/github\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path in ("/webhook/github", "/webhook/github/"):
            self.send_error(405, "Method Not Allowed - POST only")
            return
        self.send_error(404, "Not Found")

    def do_POST(self) -> None:  # noqa: N802 (stdlib naming)
        if self.path not in ("/webhook/github", "/webhook/github/"):
            self.send_error(404, "Not Found - POST /webhook/github")
            return

        # Body size cap.
        length_hdr = self.headers.get("Content-Length")
        try:
            length = int(length_hdr or "0")
        except ValueError:
            length = 0
        if length <= 0 or length > self.max_body:
            self._log_result("-", "-", f"reject-body-size:{length}")
            self._send_json(400, {"error": "missing or oversized body"})
            return

        raw = self.rfile.read(length)

        # HMAC check FIRST — before we parse the body, before we look at any
        # other header. No secret → no trust → no further processing.
        provided_sig = self.headers.get(SIGNATURE_HEADER, "")
        if not signature_matches(self.secret, raw, provided_sig):
            event_hdr = self.headers.get(EVENT_HEADER, "-")
            self._log_result(event_hdr, "-", "reject-hmac")
            # Opaque 401 — no timing oracle, no hint about which half mismatched.
            self._send_json(401, {"error": "signature verification failed"})
            return

        # Event header gate — we only care about `issues` events in Phase 1.
        event = self.headers.get(EVENT_HEADER, "")
        if event != TARGET_EVENT:
            self._log_result(event or "-", "-", "ignore-event")
            self._send_204_accepted()
            return

        # Parse body now that we trust the signature.
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            self._log_result(event, "-", "reject-json")
            self._send_json(400, {"error": "body is not valid JSON"})
            return

        if not isinstance(payload, dict):
            self._log_result(event, "-", "reject-json-shape")
            self._send_json(400, {"error": "body is not a JSON object"})
            return

        action = payload.get("action", "")
        if action != TARGET_ACTION:
            self._log_result(event, str(action), "ignore-action")
            self._send_204_accepted()
            return

        # Extract the fields we need for the sentinel. Any malformation here
        # is the sender's fault (the signature matched) but we still refuse
        # to write a malformed sentinel — conservative.
        issue = payload.get("issue") or {}
        repo = payload.get("repository") or {}
        assignee = payload.get("assignee") or {}

        issue_num = issue.get("number")
        if not isinstance(issue_num, int) or issue_num < 1:
            self._log_result(event, action, "reject-issue-num")
            self._send_json(400, {"error": "missing or invalid issue.number"})
            return

        owner_login = _safe_slug(((repo.get("owner") or {}).get("login")))
        repo_name = _safe_slug(repo.get("name"))
        if not owner_login or not repo_name:
            self._log_result(event, action, "reject-repo-slug")
            self._send_json(400, {"error": "missing or invalid repository.owner.login / repository.name"})
            return

        assignee_login = _safe_slug(assignee.get("login"))  # may be None; that's fine.

        ts = _dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
        delivery_id = self.headers.get(DELIVERY_HEADER) or None
        if delivery_id and not re.match(r"^[A-Za-z0-9._-]+$", delivery_id):
            delivery_id = None  # belt-and-suspenders: don't echo attacker-controlled junk

        try:
            sentinel = write_sentinel(
                self.sentinel_dir,
                ts=ts,
                repo_owner=owner_login,
                repo_name=repo_name,
                issue_num=issue_num,
                event=event,
                action=action,
                assignee_login=assignee_login,
                delivery_id=delivery_id,
            )
        except OSError as e:
            self._log_result(event, action, f"sentinel-write-error:{type(e).__name__}")
            self._send_json(500, {"error": "failed to write sentinel"})
            return

        self._log_result(event, action, f"accept:{sentinel.name}")
        self._send_json(200, {"accepted": True, "sentinel": sentinel.name})

    # -- internals -------------------------------------------------------------

    def _send_json(self, status: int, body: Dict[str, Any]) -> None:
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _send_204_accepted(self) -> None:
        """
        No-sentinel acknowledgement. 204 lets GitHub's delivery UI show a green
        check instead of retrying — we've seen the event, we just don't act on
        this subtype in Phase 1.
        """
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _log_result(self, event: str, action: str, result: str) -> None:
        """
        Single-line stderr log per request. Deliberately excludes:
        - Request body (may contain proprietary issue text — ticket #41 security)
        - Secret / signature (never log authn material)
        - Delivery ID (low-value; rely on GitHub's own delivery UI for that)

        Includes: event type, action, high-level result verb.
        """
        self.log_message(
            "POST /webhook/github event=%s action=%s result=%s",
            event, action, result,
        )


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def make_handler(secret: str, sentinel_dir: Path, max_body: int):
    """Return a WebhookHandler subclass with config baked in."""
    class _H(WebhookHandler):
        pass
    _H.secret = secret
    _H.sentinel_dir = sentinel_dir
    _H.max_body = max_body
    return _H


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------


def _parse_args(argv: List[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="hydra-webhook-receiver",
        description="GitHub webhook receiver for Hydra commander (ticket #41)",
    )
    p.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("HYDRA_WEBHOOK_PORT", str(DEFAULT_PORT))),
        help=f"HTTP port (default {DEFAULT_PORT})",
    )
    p.add_argument(
        "--bind",
        default=os.environ.get("HYDRA_WEBHOOK_BIND", DEFAULT_BIND),
        help=f"Bind address (default {DEFAULT_BIND}). NEVER 0.0.0.0 without TLS in front.",
    )
    p.add_argument(
        "--check",
        action="store_true",
        help="Validate config (env var) and exit 0 without binding.",
    )
    return p.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])

    try:
        secret = load_secret()
    except SystemExit as e:
        sys.stderr.write(str(e) + "\n")
        return 1

    sentinel_dir = _sentinel_dir()
    max_body = _max_body()

    if args.check:
        sys.stdout.write(
            "✓ HYDRA_WEBHOOK_SECRET is set\n"
            f"✓ sentinel dir: {sentinel_dir}\n"
            f"✓ max body: {max_body} bytes\n"
        )
        return 0

    handler_cls = make_handler(secret, sentinel_dir, max_body)
    try:
        server = ThreadingHTTPServer((args.bind, args.port), handler_cls)
    except (OSError, socket.error) as e:
        sys.stderr.write(f"✗ Failed to bind {args.bind}:{args.port}: {e}\n")
        return 1

    sys.stderr.write(
        f"[hydra-webhook] listening on http://{args.bind}:{args.port}/webhook/github "
        f"(sentinel_dir={sentinel_dir}, max_body={max_body}B)\n"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("[hydra-webhook] shutdown\n")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
