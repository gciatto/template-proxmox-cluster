# Proxmox cluster configuration (template)

Template for the configuration repository of **one Proxmox VE cluster**, shared by its administrators and operated through the [proxmox-admin](https://github.com/gciatto/proxmox-admin) container image (Ansible, OpenTofu, the `px` CLI, Claude Code and Codex).

- **This repository** holds what the cluster's administrators share: API endpoint and TLS settings, inventory, playbooks, OpenTofu resources, CA bundle, and the rules for AI agents (`AGENTS.md`).
- **The image** holds the tools. It is pinned in `compose.yaml` and upgraded through Renovate pull requests.
- **Secrets stay personal**, on each administrator's workstation: SSH keys, the API token secret, AI logins.

## 1. Create the cluster repository (once per cluster)

1. Create a repository from this template (*Use this template* on GitHub), e.g. `proxmox-cluster-<name>`, private.
2. Edit `cluster.env`: `CLUSTER_NAME`, `PROXMOX_HOST`, TLS settings. For a private CA, commit the bundle as `config/certs/ca-bundle.pem` and set `PROXMOX_CA_BUNDLE=/workspace/config/certs/ca-bundle.pem`.
3. Edit `ansible/inventory/hosts.yml` with the real nodes.
4. Fill in *Cluster facts* in `AGENTS.md`: what agents must know before touching this cluster.
5. Before adding OpenTofu resources, configure the shared remote backend in `tofu/backend.tf`.
6. Install the [Renovate](https://docs.renovatebot.com/) app on the repository. If the admin image is private, grant this repository read access to the GHCR package (package settings → *Manage Actions access*), so that CI can pull it.

## 2. Set up a workstation (once per administrator)

Requirements: Docker with Compose ≥ 2.24, SSH access to the nodes, and an individual Proxmox API token (not needed for SSH-only work).

```bash
git clone <this repository> && cd <it>
cp .env.example .env            # your token ID, Proxmox user, SSH user
CLUSTER=$(sed -n 's/^CLUSTER_NAME=//p' cluster.env)
mkdir -p ~/.config/proxmox-admin/$CLUSTER && chmod 700 ~/.config/proxmox-admin/$CLUSTER
printf '%s' 'YOUR-TOKEN-SECRET' > ~/.config/proxmox-admin/$CLUSTER/token
chmod 600 ~/.config/proxmox-admin/$CLUSTER/token
```

Record the nodes' SSH host keys in `~/.ssh/known_hosts` after verifying their fingerprints: host-key checking is enabled. If the image is private, log in to GHCR once (`docker login ghcr.io`, with a token with `read:packages`).

Optionally, install the local Git hooks: `python3 scripts/githooks.py install` (Conventional Commits and no AI signatures on commit messages; `pve-validate` in the container before each commit).

## 3. Operate

```bash
./admin.sh                 # interactive shell (pve-help lists the helpers)
./admin.sh --pull          # pull the pinned image first
./admin.sh px nodes        # one-off command
./admin.sh claude          # AI assistant, following AGENTS.md
```

Inside the container: `px doctor` checks the local setup, `pve-ping` tests SSH, `px nodes` tests the API. See the [proxmox-admin README](https://github.com/gciatto/proxmox-admin) for all commands, the access model, and how AI configuration (`~/.claude`, `~/.codex`) is mounted.

Changes to the cluster go through pull requests to this repository whenever possible: playbooks in `ansible/playbooks/` (run with `pve-play NAME`), OpenTofu resources in `tofu/` (`pve-tofu plan` / `apply`). CI validates every push offline with the pinned image (`pve-validate`); it never contacts the cluster.

## Upgrading the tools

Renovate opens pull requests when a new admin image or OpenTofu provider version is published. Minor and patch upgrades are merged automatically once CI passes; majors wait for review. After merging, each administrator runs `./admin.sh --pull`. To try an unreleased image, put `services: {admin: {image: proxmox-admin:local}}` in an untracked `compose.override.yaml`.
