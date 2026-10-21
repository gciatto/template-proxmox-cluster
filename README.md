# Proxmox cluster configuration (template)

Template for the configuration repository of **one Proxmox VE cluster**, shared by its administrators and operated through the [proxmox-admin](https://github.com/gciatto/proxmox-admin) container image (Ansible, OpenTofu, the `px` CLI, Claude Code and Codex).

- **This repository** holds what the cluster's administrators share: API endpoint and TLS settings, inventory, playbooks, OpenTofu resources, CA bundle, and the rules for AI agents (`AGENTS.md`).
- **The image** holds the tools and the launcher. It is pinned in `cluster.env` and upgraded through Renovate pull requests; `admin.sh` is a stub that extracts the launcher (`admin.sh` + `compose.yaml`) from the pinned image and runs it, so the launcher always matches the image.
- **Secrets stay personal**, on each administrator's workstation: SSH keys, the API token secret, AI logins.

## 1. Create the cluster repository (once per cluster)

Create a repository from this template (*Use this template* on GitHub), e.g. `proxmox-cluster-<name>`, private, clone it and run:

```bash
./init.sh
```

It first describes the cluster, in files shared by all its administrators (commit them):

- asks for the API endpoint and your SSH user, checks the node's SSH host key fingerprint with you, then **discovers the cluster name and nodes** over SSH (`pvesh`, read-only; root or passwordless sudo), or lets you enter them;
- checks the API's TLS certificate and, as Proxmox signs it with its own CA, offers to fetch the cluster CA (`/etc/pve/pve-root-ca.pem`) into `config/certs/` and verify against it;
- writes `cluster.env`, `ansible/inventory/hosts.yml`, the README title, and the *Cluster facts* in `AGENTS.md` (purpose, protected guests, maintenance windows, contacts, conventions), which AI agents read first.

Then it sets up your workstation (next section). `./init.sh cluster` repeats the first part, e.g. when nodes change.

On GitHub: install the [Renovate](https://docs.renovatebot.com/) app on the repository. If the admin image is private, grant this repository read access to the GHCR package (package settings → *Manage Actions access*), so that CI can pull it. Before adding OpenTofu resources, configure the shared remote backend in `tofu/backend.tf`.

## 2. Set up a workstation (once per administrator)

Requirements: Bash, Docker with Compose ≥ 2.24, ssh, curl, SSH access to the nodes, and (for API work) a Proxmox user. Clone the cluster repository and run:

```bash
./init.sh workstation
```

It records the nodes' SSH host keys after you compare the fingerprints and tests SSH to every node, asks your Proxmox user (`name@realm`, listing the cluster's realms) and API token name, then either **creates the token over SSH** (`pveum user token add`; root or passwordless sudo), takes the secret of an existing token (hidden input), or skips it for SSH-only work. It writes your `.env` and the secret to `~/.config/proxmox-admin/<CLUSTER_NAME>/token` (mode 600, outside the repository), offers to install the Git hooks, and checks everything in the container (`px doctor`, `px snapshot`). **No password is stored anywhere.** Re-run it any time: current values are the defaults.

If `HOST_SSH_DIR` is set, `init.sh` uses that directory's `config`, `known_hosts` and keys, like the container. If the image is private, log in to GHCR first (`docker login ghcr.io`, with a token with `read:packages`).

## 3. Operate

```bash
./admin.sh                 # interactive shell (pve-help lists the helpers)
./admin.sh --pull          # pull the pinned image first
./admin.sh px nodes        # one-off command
./admin.sh claude          # AI assistant, following AGENTS.md
```

Inside the container: `px doctor` checks the local setup, `pve-ping` tests SSH, `pve-snapshot` summarizes the cluster (storage, networks, realms, users, ACLs, HA, backups; cached in the container). See the [proxmox-admin README](https://github.com/gciatto/proxmox-admin) for all commands, the access model, and how AI configuration (`~/.claude`, `~/.codex`) is mounted.

Changes to the cluster go through pull requests to this repository whenever possible: playbooks in `ansible/playbooks/` (run with `pve-play NAME`), OpenTofu resources in `tofu/` (`pve-tofu plan` / `apply`). CI validates every push offline with the pinned image (`pve-validate`); it never contacts the cluster.

## Upgrading the tools

Renovate opens pull requests when a new admin image or OpenTofu provider version is published. Minor and patch upgrades are merged automatically once CI passes; majors wait for review. The next `./admin.sh` pulls the new image and uses its launcher. To try an unreleased image (and its launcher): `PVE_ADMIN_IMAGE=proxmox-admin:local ./admin.sh`, or set `PVE_ADMIN_IMAGE=proxmox-admin:local` in `.env` to keep using it (`init.sh` follows the same rule). An untracked `compose.override.yaml` can still customize the container (extra mounts, environment).
