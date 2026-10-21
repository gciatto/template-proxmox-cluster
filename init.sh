#!/usr/bin/env bash
set -euo pipefail

# Interactive setup of this cluster repository. Safe to re-run: the answers of the last run
# (kept in .local/init.env, even if it failed), else the current values, are the defaults.
# Uses the same admin image as ./admin.sh: PVE_ADMIN_IMAGE from the environment, else from .env,
# else the pin in cluster.env (e.g. PVE_ADMIN_IMAGE=proxmox-admin:local in .env for a local build).
#
#   ./init.sh               first run: describe the cluster, then set up this workstation
#   ./init.sh cluster       (re)describe the cluster: cluster.env, inventory, CA bundle,
#                           README title, cluster facts in AGENTS.md (committed, shared)
#   ./init.sh workstation   set up this administrator: SSH host keys, .env, API token (personal)
#
# Needs Bash, Docker, ssh and curl on the workstation. No password is ever stored: nodes are
# reached with SSH keys, the API with a personal token kept outside the repository.

cd "$(dirname "${BASH_SOURCE[0]}")"

PLACEHOLDER_CLUSTER=example
NAME_RE='^[A-Za-z0-9._-]+$'
# The name may itself contain @ (e.g. LDAP/AD users: alice@example.org@example.org).
USER_RE='^[A-Za-z0-9._@-]+@[A-Za-z0-9._-]+$'
TOKEN_RE='^[A-Za-z][A-Za-z0-9._-]*$'
# SSH on the workstation uses the directory mounted into the container (HOST_SSH_DIR): its
# config, known_hosts and keys, so that both see the same nodes.
SSH_DIR=${HOST_SSH_DIR:-$HOME/.ssh}
SSH_OPTS=(-o "UserKnownHostsFile=$SSH_DIR/known_hosts")
[[ -f "$SSH_DIR/config" ]] && SSH_OPTS+=(-F "$SSH_DIR/config")
if [[ "$SSH_DIR" != "$HOME/.ssh" ]]; then
    for key in "$SSH_DIR"/id_*; do
        [[ -f "$key" && "$key" != *.pub ]] && SSH_OPTS+=(-i "$key")
    done
fi
INIT_SSH_USER=''
# Answers of previous runs, finished or not: defaults for the next run. Never holds secrets.
ANSWERS=.local/init.env

say() { printf '\n\033[1m%s\033[0m\n' "$*" >&2; }
note() { printf '  %s\n' "$*" >&2; }
die() { printf 'init.sh: %s\n' "$*" >&2; exit 1; }

ask() { # PROMPT [DEFAULT] [REGEX] [KEY]: prints the answer; KEY recalls and records it in ANSWERS
    local answer default=${2:-}
    if [[ -n "${4:-}" ]]; then
        answer=$(get_env "$ANSWERS" "$4")
        default=${answer:-$default}
    fi
    while true; do
        read -r -p "$1${default:+ [$default]}: " answer
        answer=${answer:-$default}
        if [[ -z "${3:-}" || "$answer" =~ $3 ]]; then
            if [[ -n "${4:-}" ]]; then
                mkdir -p "$(dirname "$ANSWERS")" && touch "$ANSWERS"
                set_env "$ANSWERS" "$4" "$answer"
            fi
            printf '%s' "$answer"
            return
        fi
        note "Invalid value: $answer"
    done
}

confirm() { # PROMPT DEFAULT(y|n)
    local answer
    read -r -p "$1 [$( [[ $2 == y ]] && echo Y/n || echo y/N )]: " answer
    answer=${answer:-$2}
    [[ "$answer" == [yY]* ]]
}

get_env() { # FILE KEY
    [[ -f "$1" ]] && sed -n "s/^$2=//p" "$1" | tail -n 1 || true
}

set_env() { # FILE KEY VALUE: replaces "KEY=" or "# KEY=", else appends
    local tmp
    tmp=$(mktemp)
    awk -v k="$2" -v v="$3" '
        $0 ~ "^(# )?" k "=" && !done { print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }' "$1" > "$tmp"
    cat "$tmp" > "$1"
    rm -f "$tmp"
}

comment_env() { # FILE KEY
    local tmp
    tmp=$(mktemp)
    awk -v k="$2" '$0 ~ "^" k "=" { print "# " $0; next } { print }' "$1" > "$tmp"
    cat "$tmp" > "$1"
    rm -f "$tmp"
}

image() { # the same rule as ./admin.sh: PVE_ADMIN_IMAGE from the environment, else .env, else the pin
    local image=${PVE_ADMIN_IMAGE:-$(get_env .env PVE_ADMIN_IMAGE)}
    printf '%s' "${image:-$(get_env cluster.env PVE_ADMIN_IMAGE)}"
}

jqi() { # jq from the admin image (pulled at startup), so that the workstation needs no jq
    docker run --rm -i --entrypoint jq "$(image)" "$@"
}

remote() { # USER HOST COMMAND...: runs COMMAND as root on the node (directly, or via sudo -n)
    local user=$1 host=$2
    shift 2
    local sudo=''
    [[ "$user" == root ]] || sudo='sudo -n '
    ssh -n "${SSH_OPTS[@]}" -o ConnectTimeout=10 "$user@$host" "$sudo$*"
}

trust_host() { # HOST: records its SSH host key in known_hosts, after the user checked it
    local host=$1 address port entry keys
    # Resolve aliases, HostName and Port from the SSH config, as ssh will.
    read -r address port <<<"$(ssh "${SSH_OPTS[@]}" -G "$host" | awk '$1 == "hostname" { h = $2 } $1 == "port" { p = $2 } END { print h, p }')"
    entry=$address
    [[ "$port" == 22 ]] || entry="[$address]:$port"
    ssh-keygen -F "$entry" -f "$SSH_DIR/known_hosts" >/dev/null 2>&1 && return 0
    keys=$(ssh-keyscan -T 5 -p "$port" "$address" 2>/dev/null) || true
    if [[ -z "$keys" ]]; then
        note "Cannot read the SSH host key of $host ($address:$port): is it reachable?"
        return 1
    fi
    note "SSH host key fingerprints of $host:"
    ssh-keygen -lf - <<<"$keys" | sed 's/^/    /' >&2
    note "Compare them on the node's console: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
    if confirm "  Do they match? Trust $host" n; then
        mkdir -p "$SSH_DIR"
        printf '%s\n' "$keys" >> "$SSH_DIR/known_hosts"
    else
        note "Not trusted: SSH to $host will be refused."
        return 1
    fi
}

inventory_addresses() {
    sed -n 's/^ *ansible_host: *//p' ansible/inventory/hosts.yml
}

cluster_phase() {
    say '== Cluster description (shared: cluster.env, inventory, AGENTS.md; commit the result)'

    local host port ssh_user json='' cluster_name='' names=() addrs=()
    host=$(get_env cluster.env PROXMOX_HOST)
    [[ "$host" == *.example.org ]] && host=''
    host=$(ask "Proxmox API endpoint: a node's hostname or IP (no https://, no port)" "$host" "$NAME_RE" PROXMOX_HOST)
    port=$(ask 'API port' "$(get_env cluster.env PROXMOX_PORT)" '^[0-9]+$' PROXMOX_PORT)
    ssh_user=$(ask 'Your SSH user on the nodes (root, or with passwordless sudo) to discover the cluster' \
        "$(get_env .env PROXMOX_SSH_USER)" "$NAME_RE" PROXMOX_SSH_USER)
    INIT_SSH_USER=$ssh_user # default for the workstation phase

    if trust_host "$host"; then
        say "Discovering the cluster through $ssh_user@$host (pvesh, read-only)..."
        json=$(remote "$ssh_user" "$host" pvesh get /cluster/status --output-format json) \
            || note 'Discovery failed (no SSH access, or no root/sudo): enter the nodes manually.'
    fi
    if [[ -n "$json" ]]; then
        cluster_name=$(jqi -r '.[] | select(.type == "cluster") | .name' <<<"$json")
        while read -r name ip; do
            [[ -n "$name" ]] && names+=("$name") && addrs+=("$ip")
        done <<<"$(jqi -r '.[] | select(.type == "node") | "\(.name) \(.ip)"' <<<"$json")"
        note "Found ${#names[@]} node(s)${cluster_name:+ in cluster $cluster_name}."
    fi
    if [[ ${#names[@]} -eq 0 ]]; then
        say 'Nodes (empty name to finish)'
        local name
        while name=$(ask '  Node name' '' '^([A-Za-z0-9._-]+)?$') && [[ -n "$name" ]]; do
            names+=("$name")
            addrs+=("$name")
        done
        [[ ${#names[@]} -gt 0 ]] || die 'At least one node is needed.'
    fi
    say 'Address Ansible and SSH use for each node (IP, or a resolvable name)'
    local i
    for i in "${!names[@]}"; do
        addrs[i]=$(ask "  ${names[i]}" "${addrs[i]}" "$NAME_RE" "ADDRESS_${names[i]//[^A-Za-z0-9_]/_}")
    done

    local current_name
    current_name=$(get_env cluster.env CLUSTER_NAME)
    [[ "$current_name" == "$PLACEHOLDER_CLUSTER" ]] && current_name=''
    cluster_name=$(ask 'Short name of this cluster (also names your token file)' \
        "${current_name:-${cluster_name:-$(basename "$PWD")}}" "$NAME_RE" CLUSTER_NAME)

    say 'TLS'
    local validate=true bundle=''
    if ! command -v curl >/dev/null 2>&1; then
        note 'curl not found: keeping certificate verification on, without a CA bundle.'
    elif curl -fsS -o /dev/null --max-time 10 "https://$host:$port/" 2>/dev/null; then
        note "The API certificate of $host is trusted by public CAs."
    else
        note "The API certificate of $host is not publicly trusted (Proxmox signs it with its own CA)."
        if confirm "  Fetch the cluster CA (/etc/pve/pve-root-ca.pem) over SSH and commit it" y \
            && remote "$ssh_user" "$host" cat /etc/pve/pve-root-ca.pem > config/certs/ca-bundle.pem.tmp \
            && mv config/certs/ca-bundle.pem.tmp config/certs/ca-bundle.pem \
            && curl -fsS -o /dev/null --max-time 10 --cacert config/certs/ca-bundle.pem "https://$host:$port/"; then
            bundle=/workspace/config/certs/ca-bundle.pem
            note 'Verified with config/certs/ca-bundle.pem.'
        else
            rm -f config/certs/ca-bundle.pem.tmp
            note "Not verified: the certificate may not name \"$host\" (use a name it lists, e.g. the node name)."
            if confirm '  Disable certificate verification (discouraged; re-run ./init.sh cluster to fix)' n; then
                validate=false
            fi
        fi
    fi

    set_env cluster.env CLUSTER_NAME "$cluster_name"
    set_env cluster.env PROXMOX_HOST "$host"
    set_env cluster.env PROXMOX_PORT "$port"
    set_env cluster.env PROXMOX_VALIDATE_CERTS "$validate"
    if [[ -n "$bundle" ]]; then
        set_env cluster.env PROXMOX_CA_BUNDLE "$bundle"
    else
        comment_env cluster.env PROXMOX_CA_BUNDLE
    fi

    if grep -q '\.example\.org' ansible/inventory/hosts.yml \
        || confirm 'Rewrite ansible/inventory/hosts.yml (manual edits there are lost)' y; then
        {
            echo '# Nodes of this cluster, shared by all its administrators (written by ./init.sh cluster).'
            echo 'all:'
            echo '  children:'
            echo '    proxmox_nodes:'
            echo '      hosts:'
            for i in "${!names[@]}"; do
                echo "        ${names[i]}:"
                echo "          ansible_host: ${addrs[i]}"
            done
            echo '      vars:'
            echo "        # Each administrator's own UNIX account, from PROXMOX_SSH_USER in their .env."
            echo "        ansible_user: \"{{ lookup('env', 'PROXMOX_SSH_USER') | default('root', true) }}\""
            echo '        # Privilege escalation can be set per host, if needed:'
            echo '        # ansible_become: true'
        } > ansible/inventory/hosts.yml
    fi

    sed -i.bak -e "1s/.*/# Proxmox cluster \`$cluster_name\`/" \
        -e 's/^Template for the configuration repository of/Configuration repository of/' README.md
    rm -f README.md.bak

    if grep -q '<!-- Fill in' AGENTS.md || confirm 'Rewrite the cluster facts in AGENTS.md' n; then
        say 'Cluster facts for AI agents and new administrators (one line each; empty if unknown)'
        local purpose protected windows contacts conventions nodes_line='' block
        purpose=$(ask '  What is the cluster for, and how critical is it' '' '' FACT_PURPOSE)
        protected=$(ask '  Guests or nodes never to stop, migrate or change without notice' '' '' FACT_PROTECTED)
        windows=$(ask '  Maintenance windows' '' '' FACT_WINDOWS)
        contacts=$(ask '  Contacts and escalation' '' '' FACT_CONTACTS)
        conventions=$(ask '  Conventions (VMID ranges, naming, storage and network usage)' '' '' FACT_CONVENTIONS)
        for i in "${!names[@]}"; do
            nodes_line+="${nodes_line:+, }${names[i]} (${addrs[i]})"
        done
        block=$(mktemp)
        {
            echo '## Cluster facts'
            echo
            echo '<!-- Written by ./init.sh cluster; keep up to date. Live state: pve-snapshot. -->'
            echo
            echo "- Cluster \`$cluster_name\`, API \`$host:$port\`."
            echo "- Nodes: $nodes_line."
            echo "- Purpose and criticality: ${purpose:-_unknown: ask the administrators_}."
            echo "- Never stop, migrate or change without notice: ${protected:-_unknown: ask the administrators_}."
            echo "- Maintenance windows: ${windows:-_unknown: ask the administrators_}."
            echo "- Contacts: ${contacts:-_unknown_}."
            echo "- Conventions: ${conventions:-_none recorded_}."
            echo
        } > "$block"
        local tmp
        tmp=$(mktemp)
        awk -v f="$block" '
            /^## Cluster facts/ { while ((getline line < f) > 0) print line; skip = 1; next }
            skip && /^## / { skip = 0 }
            !skip { print }' AGENTS.md > "$tmp"
        cat "$tmp" > AGENTS.md
        rm -f "$tmp" "$block"
    fi

    say 'Cluster description written. Review and commit it:'
    note 'git add -A && git commit -m "feat: describe the cluster"'
    note 'On GitHub: install Renovate on this repository; if the admin image is private, grant'
    note 'this repository read access to the GHCR package, so that CI can pull it.'
}

has_audit() { # reads `pveum ... permissions --path /` JSON: is Sys.Audit granted on /?
    jqi -e '.["/"]["Sys.Audit"] != null' >/dev/null 2>&1
}

check_privileges() { # SSH_USER HOST USER TOKEN_NAME: px needs Sys.Audit on /; offers to grant a role
    local ssh_user=$1 host=$2 user=$3 token_name=$4 privsep user_ok=1 token_ok=1 role args=()
    say "Privileges of $user!$token_name"
    privsep=$(remote "$ssh_user" "$host" pveum user token list "'$user'" --output-format json 2>/dev/null \
        | jqi -r --arg t "$token_name" '.[] | select(.tokenid == $t) | .privsep') || true
    if [[ -z "$privsep" ]]; then
        note 'Cannot read the token over SSH (no root/sudo?): privileges not checked.'
        return
    fi
    remote "$ssh_user" "$host" pveum user permissions "'$user'" --path / --output-format json | has_audit || user_ok=0
    if [[ "$privsep" == 1 ]]; then
        remote "$ssh_user" "$host" pveum user token permissions "'$user'" "'$token_name'" --path / --output-format json \
            | has_audit || token_ok=0
    fi
    if [[ $user_ok == 1 && $token_ok == 1 ]]; then
        note 'OK   Sys.Audit on / (enough for px; Ansible and OpenTofu changes need more).'
        return
    fi
    note 'No Sys.Audit on / for this token: px will get 403 errors.'
    [[ $user_ok == 1 ]] || args+=(--users "'$user'")
    [[ $token_ok == 1 ]] || args+=(--tokens "'$user!$token_name'")
    role=$(ask '  Role to grant on / (PVEAuditor: read-only; Administrator: also changes)' PVEAuditor \
        '^[A-Za-z]+$' GRANT_ROLE)
    if confirm "  Grant $role on / to ${args[*]}" y \
        && remote "$ssh_user" "$host" pveum acl modify / "${args[@]}" --roles "$role"; then
        note "Granted $role on /."
    else
        note "Not granted. On a node: pveum acl modify / ${args[*]} --roles $role"
    fi
}

workstation_phase() {
    local cluster_name
    cluster_name=$(get_env cluster.env CLUSTER_NAME)
    [[ "$cluster_name" != "$PLACEHOLDER_CLUSTER" ]] || die 'Describe the cluster first: ./init.sh cluster'
    say "== Workstation setup for cluster $cluster_name (personal: .env, token file, known_hosts)"

    local ssh_user host
    ssh_user=$(ask 'Your SSH user on the nodes' "${INIT_SSH_USER:-$(get_env .env PROXMOX_SSH_USER)}" "$NAME_RE" PROXMOX_SSH_USER)
    host=$(get_env cluster.env PROXMOX_HOST)

    say 'SSH host keys and access'
    local address
    for address in $(inventory_addresses); do
        if trust_host "$address" && ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=10 "$ssh_user@$address" true 2>/dev/null; then
            note "OK   $ssh_user@$address"
        else
            note "FAIL $ssh_user@$address: check your key is authorized there (ssh-copy-id), or load it in ssh-agent"
        fi
    done

    say 'Proxmox API identity (token-based; no password is stored)'
    local realms=''
    realms=$(remote "$ssh_user" "$host" pveum realm list --output-format json 2>/dev/null \
        | jqi -r '[.[] | "\(.realm) (\(.type))"] | join(", ")' 2>/dev/null) || true
    [[ -n "$realms" ]] && note "Realms of this cluster: $realms"
    local user token_name token_file token_id
    user=$(ask 'Your Proxmox user, name@realm (e.g. alice@pve, root@pam)' "$(get_env .env PROXMOX_USER)" "$USER_RE" PROXMOX_USER)
    token_name=$(get_env .env PROXMOX_TOKEN_ID)
    token_name=${token_name#*!}
    token_name=$(ask 'API token name' "${token_name:-admin-cli}" "$TOKEN_RE" PROXMOX_TOKEN_NAME)
    token_id="$user!$token_name"
    token_file=${HOST_PROXMOX_TOKEN_FILE:-$HOME/.config/proxmox-admin/$cluster_name/token}

    local secret='' choice
    if [[ -s "$token_file" && "$(get_env .env PROXMOX_TOKEN_ID)" == "$token_id" ]] \
        && confirm "Keep the existing secret of $token_id in $token_file" y; then
        secret=keep
    else
        note '1) create the token now over SSH (needs root or passwordless sudo on the node)'
        note '2) paste the secret of an existing token'
        note '3) skip: SSH-only use, no API access'
        choice=$(ask 'Choice' 1 '^[123]$')
        if [[ "$choice" == 1 ]]; then
            if ! remote "$ssh_user" "$host" pveum user list --output-format json \
                | jqi -e --arg u "$user" 'any(.[]; .userid == $u)' >/dev/null; then
                note "User $user does not exist, or cannot be listed. Create it on a node, e.g.:"
                note "  pveum user add $user && pveum acl modify / --users $user --roles Administrator"
                note '(for the pam realm, the UNIX user must exist on every node). Then re-run ./init.sh workstation.'
                choice=$(ask 'Meanwhile: 2) paste an existing secret, 3) skip' 3 '^[23]$')
            else
                local privsep=0 output
                if confirm "Privilege-separated token (needs its own ACLs; otherwise it has $user's permissions)" n; then
                    privsep=1
                fi
                if output=$(remote "$ssh_user" "$host" pveum user token add "$user" "$token_name" --privsep "$privsep" \
                    --comment "'proxmox-admin $(hostname -s 2>/dev/null || echo workstation)'" --output-format json); then
                    secret=$(jqi -r .value <<<"$output")
                    note "Created token $token_id."
                else
                    note "Creation failed (does $token_id already exist? remove it with: pveum user token remove $user $token_name)."
                    choice=$(ask '2) paste an existing secret, 3) skip' 3 '^[23]$')
                fi
            fi
        fi
        if [[ "$choice" == 2 ]]; then
            read -r -s -p "Secret of $token_id (input hidden): " secret
            echo >&2
        fi
    fi

    [[ -f .env ]] || cp .env.example .env
    set_env .env PROXMOX_SSH_USER "$ssh_user"
    set_env .env PROXMOX_USER "$user"
    set_env .env PROXMOX_TOKEN_ID "$token_id"
    if [[ "$secret" != keep ]]; then
        (umask 077 && mkdir -p "$(dirname "$token_file")" && printf '%s' "$secret" > "$token_file")
        [[ -n "$secret" ]] && note "Token secret saved to $token_file (mode 600, outside the repository)."
    fi

    [[ -n "$secret" ]] && check_privileges "$ssh_user" "$host" "$user" "$token_name"

    if command -v python3 >/dev/null 2>&1 && confirm 'Install the Git hooks (commit message checks, pve-validate)' y; then
        python3 scripts/githooks.py install >&2 || true
    fi

    say 'Checking the setup in the admin container'
    ./admin.sh px doctor || true
    if [[ -n "$secret" ]]; then
        ./admin.sh px snapshot --refresh || note 'API check failed: see the error above, then re-run ./init.sh workstation.'
    fi
    say "Done. Start working with ./admin.sh (or ./admin.sh claude, ./admin.sh codex)."
}

command -v docker >/dev/null 2>&1 || die 'Docker is required.'
docker info >/dev/null 2>&1 || die 'Docker is not running: start it (Docker Desktop, Colima, ...) and retry.'
PVE_ADMIN_IMAGE=$(image)
[[ -n "$PVE_ADMIN_IMAGE" ]] || die 'PVE_ADMIN_IMAGE is missing from cluster.env.'
export PVE_ADMIN_IMAGE # ./admin.sh below uses the same image
if [[ "$PVE_ADMIN_IMAGE" != "$(get_env cluster.env PVE_ADMIN_IMAGE)" ]]; then
    say "Using the admin image $PVE_ADMIN_IMAGE, not the pin in cluster.env"
elif docker image inspect proxmox-admin:local >/dev/null 2>&1; then
    note 'A local build proxmox-admin:local exists: set PVE_ADMIN_IMAGE=proxmox-admin:local in .env to use it.'
fi
if ! docker image inspect "$(image)" >/dev/null 2>&1; then
    say "Pulling the admin image $(image) (once; over 1 GB)..."
    docker pull "$(image)" >&2 || die "Cannot pull $(image): check the network, or docker login ghcr.io if private."
fi
case "${1:-}" in
    cluster) cluster_phase ;;
    workstation) workstation_phase ;;
    '')
        if [[ "$(get_env cluster.env CLUSTER_NAME)" == "$PLACEHOLDER_CLUSTER" ]]; then
            cluster_phase
        fi
        workstation_phase
        ;;
    *) die "unknown phase: $1 (expected: cluster, workstation)" ;;
esac
