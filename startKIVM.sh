#!/usr/bin/env bash
# Create (if needed) and connect to the KI development VM from the laptop.
# Usage: ./startKIVM.sh [--new-token] [--recreate] [--mount] [--umount]
#   --new-token   replace the GitHub work token stored on the VM
#   --recreate    destroy the current VM (after confirmation) and create a new one
#   --mount       also mount the VM's home at ~/kivm_home with sshfs (hardened, see mount_vm_home)
#   --umount      unmount ~/kivm_home and exit
# Env overrides: KI_REPO_URL, KI_SETUP_TOKEN, KI_WORK_TOKEN, KI_LOCAL_PORT, KI_DESTROY_CMD, KI_TUNNEL_USER, KI_MOUNT_POINT
set -euo pipefail
set -o noclobber
shopt -s nullglob

KEY="$HOME/.ssh/ostack_vm_ki"
USERFACING_DAT="$HOME/.config/ki_userfacing_ip.dat"
DEV_DAT="$HOME/.config/ki_utvikling_ip.dat"
DEFAULT_USERFACING_IP="157.249.97.102"
KI_SSH_CONF="$HOME/.ssh/config.d/ki.conf"
TUNNEL_SOCK="$HOME/.ssh/ki-tunnel.sock"
# Port-forward-only account provided by the platform (as used by IT's user_vsc.sh).
TUNNEL_USER="${KI_TUNNEL_USER:-tunnel}"
LOCAL_PORT="${KI_LOCAL_PORT:-8080}"
REMOTE_PORT=8080
CREATE_TIMEOUT=900
SETUP_TIMEOUT=1800
POLL_INTERVAL=10
# An existing VM whose setup log has not changed for this long is treated as not provisioned.
STALE_AFTER=600
# Assumed name of the user-facing host's destroy command; override if different.
DESTROY_CMD="${KI_DESTROY_CMD:-delete}"
MOUNT_POINT="${KI_MOUNT_POINT:-$HOME/kivm_home}"

NEW_TOKEN=false
RECREATE=false
MOUNT=false
UMOUNT=false
VM_MODE="existing"
for arg in "$@"; do
    case "$arg" in
        --new-token) NEW_TOKEN=true ;;
        --recreate) RECREATE=true ;;
        --mount) MOUNT=true ;;
        --umount|--unmount) UMOUNT=true ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

info() { printf '>>> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Output from the VM is untrusted: drop control characters (terminal escape codes) except tab and newline.
sanitize() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }

port_open() {
    timeout 5 bash -c ">/dev/tcp/$1/$2" 2>/dev/null
}

# --- Copied from IT's shared block (user_vsc.sh); keep in sync with upstream. ---

# Safety goal: the VM must never be able to act on this machine. Every ssh call below uses these options.
# -F /dev/null: ignore ~/.ssh/config and /etc/ssh/ssh_config (a ForwardAgent, ForwardX11, RemoteForward, LocalCommand,
#   ProxyCommand or ControlMaster set there for "Host *" would otherwise apply to the VM).
# -a, -x: no ssh agent forwarding, no X11 forwarding. The agent can still sign the login here; it is just not exposed to the VM.
# UpdateHostKeys=no: the VM cannot add host keys to known_hosts after login.
SSH_SAFE_OPTS=(-F /dev/null -a -x -o ForwardAgent=no -o ForwardX11=no -o ForwardX11Trusted=no -o PermitLocalCommand=no
  -o ControlMaster=no -o ControlPath=none -o UpdateHostKeys=no -o StrictHostKeyChecking=yes)

# Print the hash body, or nothing if this is not an OpenSSH SHA256 fingerprint (or a bare hash of that alphabet).
fingerprint_hash() {
  local raw="$1"
  # A full `ssh-keygen -lf` line is "256 SHA256:<hash> comment (ED25519)". Match before stripping spaces, or the
  # comment is glued onto the hash.
  if [[ "$raw" =~ SHA256:([A-Za-z0-9+/]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  raw="${raw//[[:space:]]/}"
  raw="${raw#SHA256:}"
  if [[ "$raw" =~ ^[A-Za-z0-9+/]+$ ]]; then
    printf '%s\n' "$raw"
    return 0
  fi
  printf '\n'
}

# verify_vm_host_key IP: make sure the ed25519 host key of the VM is in known_hosts, and only after the user
# has pasted the fingerprint printed by `create` (or by `status` / `floating-ip`). Unlike the ssh prompt, a plain
# "yes" is not accepted. Once the key is in known_hosts, the ssh calls use StrictHostKeyChecking=yes.
#
# The user pastes the "SHA256:<hash>" line printed by `create`. A bare hash and a full `ssh-keygen -lf` line
# are accepted too. Both sides are reduced to the hash body before they are compared.
verify_vm_host_key() {
  local ip="$1" known_hosts="$HOME/.ssh/known_hosts" scanned scanned_fp expected
  local expected_hash scanned_hash

  # already known: ssh itself refuses a changed key (StrictHostKeyChecking=yes)
  if ssh-keygen -F "$ip" -f "$known_hosts" 2>/dev/null | grep -q ' ssh-ed25519 '; then
    return 0
  fi

  scanned=$(ssh-keyscan -T 5 -t ed25519 "$ip" 2>/dev/null | grep ' ssh-ed25519 ' | head -n 1) || true
  if [ -z "$scanned" ]; then
    echo "Could not read the ed25519 host key of $ip."
    echo "  - Is the VM up and finished setting itself up (wait a few minutes after create)?"
    echo "  - Are you on VPN?"
    return 1
  fi
  scanned_fp=$(ssh-keygen -lf - <<<"$scanned" | awk '{print $2}')

  echo "First connection to $ip: its ed25519 host key must be checked."
  echo "Paste the SHA256:... line printed by 'create' (or by 'ssh <admin VM> status')."
  read -r -p "Fingerprint: " expected || {
    echo "No input; abort."
    return 1
  }
  expected_hash=$(fingerprint_hash "$expected")
  scanned_hash=$(fingerprint_hash "$scanned_fp")
  if [ -z "$scanned_hash" ]; then
    echo "Could not read an ed25519 SHA256 fingerprint for $ip; abort."
    return 1
  fi

  if [ -z "$expected_hash" ] || [ "$expected_hash" != "$scanned_hash" ]; then
    echo ""
    echo "The fingerprint does NOT match; abort."
    echo "This VM presented:"
    echo "  SHA256:$scanned_hash"
    echo "Do not connect unless you understand why: it may not be your VM."
    return 1
  fi

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  printf '%s\n' "$scanned" >>"$known_hosts"
  echo "Fingerprint matches; host key saved to $known_hosts."
  echo ""
}

# --- End of copied block. ---

KEY_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o ConnectTimeout=10)
UF_OPTS=("${SSH_SAFE_OPTS[@]}" "${KEY_OPTS[@]}")
DEV_OPTS=("${SSH_SAFE_OPTS[@]}" "${KEY_OPTS[@]}" -o HostKeyAlgorithms=ssh-ed25519)

uf()  { ssh "${UF_OPTS[@]}" "$VM_USERFACING_IP" "$@"; }
dev() { ssh "${DEV_OPTS[@]}" "$VM_KI_IP" "$@"; }

load_userfacing_config() {
    if [[ ! -f "$USERFACING_DAT" ]]; then
        mkdir -p "$(dirname "$USERFACING_DAT")"
        echo "VM_USERFACING_IP=$DEFAULT_USERFACING_IP" > "$USERFACING_DAT"
        info "Created $USERFACING_DAT"
    fi
    # shellcheck source=/dev/null
    source "$USERFACING_DAT"
    if [[ ! "${VM_USERFACING_IP:-}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        die "VM_USERFACING_IP in $USERFACING_DAT is not a valid IPv4 address"
    fi
}

check_vpn() {
    if ! port_open "$VM_USERFACING_IP" 22; then
        die "Cannot reach $VM_USERFACING_IP:22. Are you connected to the MET VPN?"
    fi
    if ! ssh-keygen -F "$VM_USERFACING_IP" >/dev/null 2>&1; then
        die "Host key of $VM_USERFACING_IP is not in ~/.ssh/known_hosts. Connect once with 'ssh -F /dev/null $VM_USERFACING_IP status' and check the fingerprint with IT"
    fi
}

ensure_key_loaded() {
    [[ -f "$KEY" ]] || die "SSH key $KEY not found"
    local fp=""
    if [[ -f "$KEY.pub" ]]; then
        fp=$(ssh-keygen -lf "$KEY.pub" | awk '{print $2}')
    fi
    if [[ -n "$fp" ]] && ssh-add -l 2>/dev/null | grep -qF "$fp"; then
        return 0
    fi
    ssh-add "$KEY" || warn "Could not add key to ssh-agent; you may be asked for the passphrase repeatedly"
}

repo_url() {
    if [[ -n "${KI_REPO_URL:-}" ]]; then
        printf '%s\n' "$KI_REPO_URL"
        return 0
    fi
    local url
    url=$(git -C "$(dirname "$(readlink -f "$0")")" remote get-url origin 2>/dev/null) \
        || die "Set KI_REPO_URL (could not read git remote 'origin')"
    if [[ "$url" =~ ^git@github\.com:(.+)$ ]]; then
        url="https://github.com/${BASH_REMATCH[1]}"
    fi
    printf '%s\n' "$url"
}

floating_ip() {
    uf floating-ip 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1 || true
}

create_vm() {
    local url token="${KI_SETUP_TOKEN:-}"
    url=$(repo_url)
    if [[ -z "$token" ]]; then
        read -rsp "Setup token for $url (blank if public): " token
        echo
    fi
    info "Creating VM from $url"
    # The create interface only accepts the token as an argument; use a read-only setup token.
    if [[ -n "$token" ]]; then
        uf create "$url" "$token" | sanitize
    else
        uf create "$url" | sanitize
    fi
    info "Keep the SHA256:... fingerprint printed above; you will be asked for it"
}

wait_for_floating_ip() {
    local ip="" waited=0
    while [[ -z "$ip" ]]; do
        (( waited < CREATE_TIMEOUT )) || die "No floating IP after ${CREATE_TIMEOUT}s"
        sleep "$POLL_INTERVAL"
        waited=$(( waited + POLL_INTERVAL ))
        ip=$(floating_ip)
    done
    printf '%s\n' "$ip"
}

save_dev_ip() {
    echo "VM_KI_IP=$VM_KI_IP" >| "$DEV_DAT"
    # A new VM may reuse the IP of a destroyed one; its key is verified by fingerprint afterwards.
    if [[ "$1" == "new" ]]; then
        ssh-keygen -R "$VM_KI_IP" >/dev/null 2>&1 || true
    fi
}

write_ssh_config() {
    mkdir -p "$(dirname "$KI_SSH_CONF")"
    chmod 700 "$(dirname "$KI_SSH_CONF")"
    cat >| "$KI_SSH_CONF" <<EOF
# Generated by startKIVM.sh, do not edit
Host kiuser kiwm
    IdentityFile $KEY
    IdentitiesOnly yes
    ForwardAgent no
    ForwardX11 no
    PermitLocalCommand no
    ControlMaster no
    ControlPath none
    UpdateHostKeys no
    StrictHostKeyChecking yes

Host kiuser
    HostName $VM_USERFACING_IP

Host kiwm
    HostName $VM_KI_IP
    HostKeyAlgorithms ssh-ed25519
EOF
    if ! grep -qE '^[[:space:]]*Include[[:space:]].*config\.d/(ki\.conf|\*)' "$HOME/.ssh/config" 2>/dev/null; then
        warn "Add 'Include ~/.ssh/config.d/ki.conf' at the top of ~/.ssh/config to use 'ssh kiwm'"
    fi
}

wait_for_port() {
    local waited=0
    info "Waiting for $1:$2"
    until port_open "$1" "$2"; do
        (( waited < CREATE_TIMEOUT )) || die "$1:$2 not reachable after ${CREATE_TIMEOUT}s"
        sleep "$POLL_INTERVAL"
        waited=$(( waited + POLL_INTERVAL ))
    done
}

# Returns 1 if the VM is not usable (provisioning failed or never ran).
wait_for_setup() {
    local state step waited=0
    info "Waiting for main.sh to finish on the VM (log: ~/user_setup.log)"
    while :; do
        state=$(dev "if [ -f ~/.setup_done ]; then echo done
            elif [ -f ~/.setup_failed ]; then echo failed
            elif [ -f ~/user_setup.log ] && [ \$(( \$(date +%s) - \$(stat -c %Y ~/user_setup.log) )) -lt $STALE_AFTER ]; then echo running
            else echo stale; fi" 2>/dev/null) \
            || state="unreachable"
        case "$state" in
            done|failed|running|stale|unreachable) ;;
            *) state="unknown" ;;
        esac
        case "$state" in
            done) return 0 ;;
            failed)
                dev 'tail -n 40 ~/user_setup.log' 2>/dev/null | sanitize || true
                step=$(dev 'cat ~/.setup_failed' 2>/dev/null) || true
                [[ "$step" =~ ^[A-Za-z0-9\ ._-]+$ ]] || step="unknown"
                warn "Provisioning failed in step '$step'"
                return 1
                ;;
            stale)
                # A fresh VM may not have started main.sh yet.
                if [[ "$VM_MODE" == "existing" ]]; then
                    warn "This VM was not provisioned by main.sh (no ~/.setup_done, setup log missing or idle)"
                    return 1
                fi
                ;;
        esac
        if (( waited >= SETUP_TIMEOUT )); then
            dev 'tail -n 20 ~/user_setup.log' 2>/dev/null | sanitize || true
            die "Provisioning not finished after ${SETUP_TIMEOUT}s (state: $state)"
        fi
        sleep "$POLL_INTERVAL"
        waited=$(( waited + POLL_INTERVAL ))
    done
}

ensure_work_token() {
    if ! $NEW_TOKEN && dev 'test -s ~/.config/ki/gh_token'; then
        return 0
    fi
    local token="${KI_WORK_TOKEN:-}"
    if [[ -z "$token" ]]; then
        read -rsp "GitHub work token (blank to skip): " token
        echo
    fi
    if [[ -z "$token" ]]; then
        warn "No work token stored on the VM; gh, git push and Copilot CLI will need manual login"
        return 0
    fi
    # Sent via stdin so the token never appears in a command line.
    printf '%s\n' "$token" | dev 'umask 077 && mkdir -p ~/.config/ki && cat > ~/.config/ki/gh_token'
    local login
    if login=$(dev 'GH_TOKEN=$(cat ~/.config/ki/gh_token) ~/.pixi/bin/gh api user --jq .login' 2>/dev/null) \
        && [[ "$login" =~ ^[A-Za-z0-9-]+$ ]]; then
        info "Work token stored; authenticated as $login"
    else
        warn "Work token stored but GitHub rejected it; rerun with --new-token"
    fi
}

ensure_interactive_login() {
    local output
    output=$(dev 'printf "KIVM_SHELL_OK\\n"' 2>&1 | sanitize) || true
    if printf '%s\n' "$output" | grep -Fxq 'KIVM_SHELL_OK'; then
        return 0
    fi

    if [[ -n "$output" ]]; then
        printf '%s\n' "$output"
    fi
    [[ -t 0 ]] || die "First login requires a terminal; rerun ./startKIVM.sh from a terminal"

    info "Complete the VM's first-login password setup. That SSH session will end when setup is complete."
    ssh -t "${DEV_OPTS[@]}" "$VM_KI_IP"

    output=$(dev 'printf "KIVM_SHELL_OK\\n"' 2>&1 | sanitize) || true
    if ! printf '%s\n' "$output" | grep -Fxq 'KIVM_SHELL_OK'; then
        [[ -z "$output" ]] || printf '%s\n' "$output"
        die "The VM did not start a normal shell after first-login setup; check VPN/connectivity and rerun ./startKIVM.sh"
    fi
}

start_tunnel() {
    local opt tunnel_opts=()
    # The tunnel is a control master (-M/-S), so drop the ControlMaster/ControlPath overrides.
    for opt in "${DEV_OPTS[@]}"; do
        case "$opt" in
            ControlMaster=no|ControlPath=none) unset 'tunnel_opts[-1]' ;;
            *) tunnel_opts+=("$opt") ;;
        esac
    done
    ssh -F /dev/null -S "$TUNNEL_SOCK" -O exit "$VM_KI_IP" 2>/dev/null || true
    rm -f "$TUNNEL_SOCK"
    if port_open 127.0.0.1 "$LOCAL_PORT"; then
        die "Local port $LOCAL_PORT is in use; set KI_LOCAL_PORT to another port"
    fi
    if ! ssh "${tunnel_opts[@]}" -f -N -T -M -S "$TUNNEL_SOCK" \
        -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
        -L "127.0.0.1:$LOCAL_PORT:localhost:$REMOTE_PORT" "$TUNNEL_USER@$VM_KI_IP"; then
        die "Could not start the tunnel as '$TUNNEL_USER'. If this VM has no such user, rerun with KI_TUNNEL_USER=$USER (less isolated)"
    fi
}

connect_vm() {
    VM_MODE="$1"
    info "Development VM: $VM_KI_IP"
    save_dev_ip "$VM_MODE"
    write_ssh_config
    wait_for_port "$VM_KI_IP" 22
    verify_vm_host_key "$VM_KI_IP" || die "Host key of $VM_KI_IP not verified"
}

new_vm() {
    create_vm
    info "Waiting for floating IP"
    VM_KI_IP=$(wait_for_floating_ip)
    connect_vm new
}

destroy_vm() {
    local answer waited=0
    read -rp "Destroy VM $VM_KI_IP and create a new one? All data on it is lost. Type 'yes': " answer
    [[ "$answer" == "yes" ]] || die "Aborted; VM left untouched"
    # A mount of a vanished VM hangs everything that touches it.
    unmount_vm_home
    info "Destroying VM ($DESTROY_CMD)"
    uf "$DESTROY_CMD"
    while [[ -n "$(floating_ip)" ]]; do
        (( waited < CREATE_TIMEOUT )) || die "VM still present after ${CREATE_TIMEOUT}s"
        sleep "$POLL_INTERVAL"
        waited=$(( waited + POLL_INTERVAL ))
    done
}

# /proc/self/mountinfo writes a space in a path as \040
is_mounted() {
    grep -qF " ${MOUNT_POINT// /\\040} " /proc/self/mountinfo
}

unmount_vm_home() {
    is_mounted || return 0
    # -z: lazy, so that it also works when the VM is gone and the mount hangs
    fusermount3 -uz "$MOUNT_POINT" 2>/dev/null || fusermount -uz "$MOUNT_POINT"
    info "Unmounted $MOUNT_POINT"
}

# Adapted from IT's user_sshfs.sh. The VM must never be able to act on this machine:
#   - ssh uses SSH_SAFE_OPTS (no agent, no X11, no config files, no local commands, no known_hosts updates)
#   - follow_symlinks: symlinks are resolved on the VM, so they can never point at a file of this machine
#   - noexec,nosuid,nodev: nothing from the VM can be executed, or act as a device or setuid file
#   - no allow_other: only your user sees the mount; idmap=user: files show as yours
# Mount problems only warn: they must not stop the SSH session.
mount_vm_home() {
    local word ssh_words ssh_command
    if ! command -v sshfs >/dev/null || { ! command -v fusermount3 >/dev/null && ! command -v fusermount >/dev/null; }; then
        warn "sshfs is not installed (sudo apt install sshfs); not mounting"
        return 0
    fi
    if is_mounted; then
        info "$MOUNT_POINT is already mounted"
        return 0
    fi
    if [[ ! -e "$MOUNT_POINT" ]]; then
        mkdir -m 700 "$MOUNT_POINT"
    fi
    if [[ -L "$MOUNT_POINT" || ! -d "$MOUNT_POINT" || ! -O "$MOUNT_POINT" ]]; then
        warn "$MOUNT_POINT must be a real directory that belongs to you; not mounting"
        return 0
    fi
    if [[ -n "$(ls -A "$MOUNT_POINT")" ]]; then
        warn "$MOUNT_POINT is not empty; the mount would hide its content. Not mounting"
        return 0
    fi
    # sshfs splits ssh_command on spaces: refuse a word that contains one (e.g. a key path with a space)
    ssh_words=(ssh "${DEV_OPTS[@]}" -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
    for word in "${ssh_words[@]}"; do
        if [[ "$word" =~ [[:space:],] ]]; then
            warn "The ssh option '$word' contains a space or a comma, which sshfs cannot handle; not mounting"
            return 0
        fi
    done
    ssh_command="${ssh_words[*]}"
    if sshfs "$USER@$VM_KI_IP:" "$MOUNT_POINT" \
        -o "ssh_command=$ssh_command" \
        -o reconnect -o follow_symlinks -o idmap=user -o noexec,nosuid,nodev; then
        info "VM home mounted at $MOUNT_POINT (untrusted content; unmount with: $0 --umount)"
    else
        warn "Could not mount the VM home at $MOUNT_POINT"
    fi
}

main() {
    if $UMOUNT; then
        unmount_vm_home
        exit 0
    fi
    load_userfacing_config
    check_vpn
    ensure_key_loaded

    info "VM status:"
    uf status | sanitize || warn "status command failed"

    VM_KI_IP=$(floating_ip)
    if [[ -n "$VM_KI_IP" ]] && $RECREATE; then
        destroy_vm
        VM_KI_IP=""
    fi
    if [[ -z "$VM_KI_IP" ]]; then
        new_vm
    else
        connect_vm existing
    fi

    if ! wait_for_setup; then
        [[ -t 0 ]] || die "VM not usable; rerun with --recreate"
        destroy_vm
        new_vm
        wait_for_setup || die "Provisioning of the new VM failed; see ~/user_setup.log on the VM"
    fi
    ensure_interactive_login
    ensure_work_token
    start_tunnel
    if $MOUNT; then
        mount_vm_home
    fi

    local password
    # Only the marked line counts, so a login banner cannot pose as the password.
    password=$(dev 'printf "KIVSC_PASSWORD:%s\n" "$(sed -n "s/^password: *//p" ~/.config/code-server/config.yaml)"' 2>/dev/null \
        | sed -n 's/^KIVSC_PASSWORD://p' | tail -n 1) || true
    if [[ ! "$password" =~ ^[[:graph:]]+$ ]]; then
        warn "Could not read a valid code-server password; see ~/.config/code-server/config.yaml on the VM"
        password="(unavailable)"
    fi
    echo
    info "code-server: http://localhost:$LOCAL_PORT"
    info "password:    $password"
    info "Stop tunnel: ssh -S $TUNNEL_SOCK -O exit kiwm"
    echo

    exec ssh "${DEV_OPTS[@]}" "$VM_KI_IP"
}

main
