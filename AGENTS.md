# AGENTS.md

Rules for AI agents (Claude Code, Codex) helping the administrators of **this Proxmox VE cluster**. You run inside the [proxmox-admin](https://github.com/gciatto/proxmox-admin) container started by `./admin.sh`, in `/workspace` (this repository), with the administrator's own SSH keys and Proxmox API token, on a live cluster.

## Cluster facts

<!-- Fill in when creating the cluster repository, and keep up to date. -->

- Purpose and criticality: _e.g. production for the X department; pve3 hosts the backups_.
- Nodes and roles: _see `ansible/inventory/hosts.yml`_.
- Guests that must never be stopped or migrated without notice: _..._.
- Maintenance windows, contacts, naming conventions (VMIDs, storage, networks): _..._.

## Operating

- Inspect with read-only commands first: `px [--json] status|nodes|guests|storage|version`, `px doctor`, `pve-inventory`, `pve-ping`, `pve-play node-facts|cluster-status|guests`, `pve-tofu plan`.
- **Ask before any change**: anything that starts, stops, migrates, creates, deletes or reconfigures guests, nodes, storage, users or the network; `pve-shell` / `ansible -m shell` commands that are not read-only; `pve-tofu apply`; playbook runs that change state (run them with `--check --diff` first and show the result). State what will change, on which hosts or guests, and how to undo it.
- Prefer changes through a playbook under `ansible/playbooks/` or an OpenTofu resource under `tofu/` over ad-hoc commands, so they are reviewed, versioned and repeatable. Playbooks must be idempotent.
- OpenTofu: never `apply` with local state; a shared remote backend (`tofu/backend.tf`) must be configured first. Import existing resources before managing them, and agree which resources are OpenTofu-owned versus Ansible-owned.
- Never print, copy or commit secrets: the token file (`/run/secrets/proxmox-token`), `PROXMOX_TOKEN_SECRET`, `PROXMOX_VE_API_TOKEN`, SSH private keys, `.env`.
- After changing files, run `pve-validate` (offline: inventory, playbook syntax, OpenTofu formatting).

## Repository

| Path | Content |
| --- | --- |
| `cluster.env` | Shared, non-secret settings: pinned admin image (`PVE_ADMIN_IMAGE`, updated by Renovate), API endpoint, TLS, `CLUSTER_NAME`. |
| `.env` (untracked, from `.env.example`) | Personal settings: token ID, user, SSH user. |
| `ansible/inventory/hosts.yml` | Cluster nodes. |
| `ansible/playbooks/` | Cluster-specific playbooks; `pve-play NAME` also finds the image's built-in ones (`ping`, `node-facts`, `cluster-status`, `guests`). A same-named file here overrides a built-in. |
| `ansible/ansible.cfg` (optional) | Overrides the image's Ansible configuration. |
| `tofu/` | OpenTofu configuration (`bpg/proxmox`) and its remote backend. |
| `config/certs/` | Trusted CA bundle of the cluster, if it uses a private CA. |
| `admin.sh` | Stub: extracts the launcher from the pinned image (`.local/launcher/`) and runs it. |

## Git

- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary`, e.g. `feat(ansible): add backup job playbook`, `fix(inventory): ...`.
- No AI attribution in commits: no `Co-Authored-By:` trailers for agents, no "Generated with ..." lines.
- Agents may commit on their own initiative, but must **always ask before pushing**.
