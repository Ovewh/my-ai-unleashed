#!/usr/bin/env bash
# First-boot provisioning for the KI development VM (Ubuntu 26.04).
# Runs as the default user while passwordless sudo is still available.
set -euo pipefail

: "${USER:=$(id -un)}"
: "${HOME:=$(getent passwd "$USER" | cut -d: -f6)}"
export USER HOME
cd "$HOME"

KI_DIR="$HOME/.config/ki"
ENV_FILE="$KI_DIR/env.sh"
CODE_SERVER_PORT=8080
DONE_MARKER="$HOME/.setup_done"
FAILED_MARKER="$HOME/.setup_failed"
CURRENT_STEP="init"

step() {
    CURRENT_STEP="$1"
    printf '\n=== [%s] %s\n' "$(date +%T)" "$1"
}

on_exit() {
    local rc=$?
    if (( rc != 0 )); then
        echo "!!! Setup failed in step '$CURRENT_STEP' (exit code $rc)"
        echo "$CURRENT_STEP" > "$FAILED_MARKER"
    fi
}
trap on_exit EXIT

apt_get() {
    sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -y "$@"
}

add_line_once() {
    grep -qxF "$2" "$1" 2>/dev/null || printf '%s\n' "$2" >> "$1"
}

rm -f "$DONE_MARKER" "$FAILED_MARKER"
echo "KI VM setup started $(date) as $USER"

step "apt packages"
apt_get update
apt_get upgrade
apt_get install git curl ca-certificates tmux build-essential neovim unzip

step "keyboard layout"
sudo localectl set-x11-keymap no || echo "warning: could not set keyboard layout"

step "shell environment"
mkdir -p "$KI_DIR" "$HOME/.npm-global" "$HOME/.local/bin"
chmod 700 "$KI_DIR"
# POSIX sh: also sourced from ~/.profile.
cat > "$ENV_FILE" <<'EOF'
# Managed by main.sh
for d in "$HOME/.local/bin" "$HOME/.npm-global/bin" "$HOME/.pixi/bin"; do
    case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
unset d
export PATH
if [ -s "$HOME/.config/ki/gh_token" ]; then
    GH_TOKEN="$(cat "$HOME/.config/ki/gh_token")"
    export GH_TOKEN
fi
EOF
add_line_once "$HOME/.bashrc" '. "$HOME/.config/ki/env.sh"'
add_line_once "$HOME/.profile" '. "$HOME/.config/ki/env.sh"'
# shellcheck source=/dev/null
. "$ENV_FILE"

step "pixi"
curl -fsSL https://pixi.sh/install.sh | PIXI_NO_PATH_UPDATE=1 bash
pixi global install nodejs gh ripgrep

step "GitHub Copilot CLI"
npm config set prefix "$HOME/.npm-global"
npm install -g @github/copilot

step "Claude Code CLI"
curl -fsSL https://claude.ai/install.sh | bash

step "git credentials via gh"
git config --global credential.https://github.com.helper ''
git config --global --add credential.https://github.com.helper "!$HOME/.pixi/bin/gh auth git-credential"

step "code-server"
curl -fsSL https://code-server.dev/install.sh | sh
mkdir -p "$HOME/.config/code-server"
if [[ ! -f "$HOME/.config/code-server/config.yaml" ]]; then
    (
        umask 077
        cat > "$HOME/.config/code-server/config.yaml" <<EOF
bind-addr: 127.0.0.1:$CODE_SERVER_PORT
auth: password
password: $(head -c 24 /dev/urandom | base64)
cert: false
EOF
    )
fi
code-server --install-extension anthropic.claude-code
sudo systemctl enable --now "code-server@$USER"

step "done"
touch "$DONE_MARKER"
echo "KI VM setup finished $(date)"
