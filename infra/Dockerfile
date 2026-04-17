# Hydra commander — Phase 2 VPS image.
#
# Runs the commander loop inside a long-lived container:
#   - Claude Code CLI (the brain)
#   - gh / git / jq / curl / tmux / openssh-client (worker toolbelt)
#   - tiny python3 http.server on :8080 serving /health for Fly.io + external probes
#   - ENTRYPOINT hands off to infra/entrypoint.sh, which launches claude under tmux
#
# Built for Fly.io Machines (shared-cpu-1x / 512MB) but works on any Debian VPS
# that can run Docker. See docs/phase2-vps-runbook.md.
#
# Auth: at runtime, pass CLAUDE_CODE_OAUTH_TOKEN (preferred — 1yr token from
# `claude setup-token`) OR ANTHROPIC_API_KEY (metered fallback). GITHUB_TOKEN
# is always required so workers can open PRs.

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH="/hydra/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ---------- System packages ----------
# Pinned to bookworm-slim's default stream; we don't pin exact versions because
# bookworm receives security updates we want to inherit automatically.
RUN apt-get update && apt-get install -y --no-install-recommends \
        adduser \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        openssh-client \
        passwd \
        python3 \
        python3-venv \
        tmux \
        tini \
    && rm -rf /var/lib/apt/lists/*

# ---------- GitHub CLI (`gh`) ----------
# Installed from the official cli.github.com apt repo so version tracks upstream.
RUN set -eux; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*

# ---------- Claude Code CLI ----------
# Install method: the official installer script (see https://claude.com/claude-code).
# We intentionally do NOT pin a version here because the installer always
# resolves to latest stable and commander picks up upstream fixes between
# image rebuilds. If a specific version is required, set CLAUDE_VERSION at
# build time and pass it through:
#   docker build --build-arg CLAUDE_VERSION=1.2.3 -f infra/Dockerfile .
#
# NOTE FOR MAINTAINERS: verify the installer URL matches the current docs
# (claude.com/claude-code → "Install on Linux") before a production rebuild.
# The URL below is the documented entry point as of 2026-04; if Anthropic
# changes it, update here.
ARG CLAUDE_VERSION=""
RUN set -eux; \
    curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh; \
    chmod +x /tmp/claude-install.sh; \
    if [ -n "${CLAUDE_VERSION}" ]; then \
        /tmp/claude-install.sh --version "${CLAUDE_VERSION}" || /tmp/claude-install.sh; \
    else \
        /tmp/claude-install.sh; \
    fi; \
    rm -f /tmp/claude-install.sh; \
    # The installer drops binaries into /root/.local/share/claude when run as
    # root, and /root is mode 0700 — non-root users can't traverse it. Move
    # the whole installation into /opt/claude (world-readable) and link it
    # into /usr/local/bin so both root and the `hydra` user can run `claude`.
    if [ -d /root/.local/share/claude ]; then \
        mkdir -p /opt/claude; \
        cp -a /root/.local/share/claude/. /opt/claude/; \
        # The installer's "latest stable" binary lives at versions/<semver>.
        # Drop a stable symlink and expose it on PATH.
        latest="$(ls -1 /opt/claude/versions | sort -V | tail -n1)"; \
        ln -sfn "/opt/claude/versions/${latest}" /opt/claude/claude; \
        ln -sf /opt/claude/claude /usr/local/bin/claude; \
        chmod -R a+rX /opt/claude; \
    fi; \
    rm -rf /root/.local/share/claude /root/.local/bin/claude 2>/dev/null || true; \
    command -v claude

# ---------- Non-root user ----------
# UID 1000 lines up with most host UIDs for bind-mount workflows; `hydra` home
# is /hydra which doubles as WORKDIR.
# bookworm-slim omits both `passwd` (groupadd/useradd) and `adduser` by default —
# we install them explicitly above. `groupadd`/`useradd` are preferred because
# they don't randomize the UID on system accounts.
RUN set -eux; \
    groupadd --gid 1000 hydra; \
    useradd --uid 1000 --gid 1000 --home-dir /hydra --shell /bin/bash hydra; \
    mkdir -p /hydra/data /hydra/state /hydra/memory /hydra/logs; \
    chown -R hydra:hydra /hydra

WORKDIR /hydra

# Copy the full hydra framework into the image. At runtime, /hydra/{state,memory,logs}
# are symlinked back to /hydra/data/{state,memory,logs} so a Fly volume persists them.
COPY --chown=hydra:hydra . /hydra/

# Ensure shipped shell scripts are executable (git preserves +x, but be defensive).
RUN find /hydra -type f -name "*.sh" -exec chmod +x {} + || true

USER hydra

# ---------- Health check ----------
# Fly.io also probes this via [[http_service]] in fly.toml. Docker-level check
# exists so `docker run` works standalone too.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/health || exit 1

EXPOSE 8080

# tini is PID 1 so signals propagate to tmux + the /health server cleanly.
ENTRYPOINT ["/usr/bin/tini", "--", "/hydra/infra/entrypoint.sh"]
