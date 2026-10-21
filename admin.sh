#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if ! command -v docker >/dev/null 2>&1; then
    echo 'Docker and Docker Compose v2 are required.' >&2
    exit 127
fi

if [[ "$(id -u)" -eq 0 ]]; then
    echo 'Run admin.sh as an unprivileged workstation user, not root.' >&2
    exit 2
fi

export ADMIN_UID="$(id -u)"
export ADMIN_GID="$(id -g)"
export HOST_SSH_DIR="${HOST_SSH_DIR:-${HOME}/.ssh}"
cluster_name=$(sed -n 's/^CLUSTER_NAME=//p' cluster.env)
if [[ ! "$cluster_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo 'Set CLUSTER_NAME in cluster.env (letters, digits, ".", "_", "-").' >&2
    exit 2
fi
export HOST_PROXMOX_TOKEN_FILE="${HOST_PROXMOX_TOKEN_FILE:-${HOME}/.config/proxmox-admin/${cluster_name}/token}"
# AI CLI configuration (read-write: logins, settings, sessions). Defaults to the user's own,
# falling back to a checkout-local directory for users without one.
if [[ -z "${HOST_CLAUDE_DIR:-}" ]]; then
    HOST_CLAUDE_DIR="${HOME}/.claude"
    [[ -d "$HOST_CLAUDE_DIR" ]] || HOST_CLAUDE_DIR="$PWD/.local/claude"
fi
if [[ -z "${HOST_CODEX_DIR:-}" ]]; then
    HOST_CODEX_DIR="${CODEX_HOME:-${HOME}/.codex}"
    [[ -d "$HOST_CODEX_DIR" ]] || HOST_CODEX_DIR="$PWD/.local/codex"
fi
export HOST_CLAUDE_DIR HOST_CODEX_DIR

if [[ ! -d "$HOST_SSH_DIR" ]]; then
    echo "SSH directory missing: $HOST_SSH_DIR" >&2
    echo 'Set HOST_SSH_DIR to a directory containing your SSH keys and known_hosts.' >&2
    exit 2
fi

umask 077
mkdir -p .local/cache/tofu/plugins "$HOST_CLAUDE_DIR" "$HOST_CODEX_DIR"
mkdir -p "$(dirname "$HOST_PROXMOX_TOKEN_FILE")"
if [[ ! -e "$HOST_PROXMOX_TOKEN_FILE" ]]; then
    : > "$HOST_PROXMOX_TOKEN_FILE"
fi
if [[ ! -f "$HOST_PROXMOX_TOKEN_FILE" ]]; then
    echo "Token file must be an ordinary file: $HOST_PROXMOX_TOKEN_FILE" >&2
    exit 2
fi

if [[ "${1:-}" == '--pull' ]]; then
    docker compose pull admin
    shift
fi

if [[ -t 0 && -t 1 ]]; then
    exec docker compose run --rm admin "$@"
else
    exec docker compose run --rm -T admin "$@"
fi
