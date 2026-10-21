#!/usr/bin/env bash
set -euo pipefail

# Runs the launcher (admin.sh + compose.yaml) shipped in the admin image pinned in cluster.env,
# so the launcher always matches the image. PVE_ADMIN_IMAGE in the environment, else in .env,
# overrides the pin, e.g. PVE_ADMIN_IMAGE=proxmox-admin:local to use a locally built image.
# init.sh follows the same rule.
cd "$(dirname "${BASH_SOURCE[0]}")"
image=${PVE_ADMIN_IMAGE:-$(sed -n 's/^PVE_ADMIN_IMAGE=//p' .env 2>/dev/null | tail -n 1 || true)}
image=${image:-$(sed -n 's/^PVE_ADMIN_IMAGE=//p' cluster.env)}
if [[ -z "$image" ]]; then
    echo 'Set PVE_ADMIN_IMAGE in cluster.env.' >&2
    exit 2
fi
id=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null) \
    || { docker pull "$image" >&2 && id=$(docker image inspect --format '{{.Id}}' "$image"); }
launcher=".local/launcher/${id#sha256:}"
if [[ ! -f "$launcher/admin.sh" ]]; then
    mkdir -p "$launcher"
    container=$(docker create "$image")
    docker cp "$container:/opt/proxmox-admin/launcher/." "$launcher"
    docker rm "$container" >/dev/null
fi
PVE_WORKSPACE=$PWD PVE_ADMIN_IMAGE=$image exec bash "$launcher/admin.sh" "$@"
