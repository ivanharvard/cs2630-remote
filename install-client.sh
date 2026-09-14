#!/usr/bin/env bash
# Client installer: configures SSH on a remote machine to reach the CS263 VM
# through a CachyOS host via Tailscale.
# Safe to re-run. Supports Linux and macOS.

set -euo pipefail

###############################################################################
# Helpers
###############################################################################

info()  { printf '\e[1;34m[INFO]\e[0m  %s\n' "$*"; }
warn()  { printf '\e[1;33m[WARN]\e[0m  %s\n' "$*"; }
ok()    { printf '\e[1;32m[ OK ]\e[0m  %s\n' "$*"; }
fail()  { printf '\e[1;31m[FAIL]\e[0m  %s\n' "$*" >&2; exit 1; }
ask()   { printf '\e[1;36m[ ?? ]\e[0m  %s ' "$*" >/dev/tty; read -r _ans </dev/tty; echo "$_ans"; }

###############################################################################
# Phase 1: Check SSH availability
###############################################################################

info "Checking SSH availability..."
command -v ssh &>/dev/null || fail "ssh not found. Install OpenSSH and retry."
ok "ssh is available."

###############################################################################
# Phase 2: Ensure Tailscale is installed and connected
###############################################################################

info "Checking Tailscale..."

find_tailscale() {
    if command -v tailscale &>/dev/null; then
        command -v tailscale
    elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
        echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
    fi
}

TAILSCALE_BIN="$(find_tailscale || true)"

if [[ -z "$TAILSCALE_BIN" ]]; then
    warn "Tailscale is not installed."
    case "$(uname -s)" in
        Darwin)
            if command -v brew &>/dev/null; then
                _install="$(ask "[??] Install Tailscale via Homebrew now? [Y/n]:")"
                if [[ -z "$_install" || "$_install" =~ ^[Yy]$ ]]; then
                    brew install --cask tailscale
                    info "Launching Tailscale.app..."
                    open -a Tailscale
                    sleep 2
                else
                    fail "Tailscale is required. Install it from https://tailscale.com/download and retry."
                fi
            else
                fail "Homebrew not found. Install Tailscale from https://tailscale.com/download (or install Homebrew) and retry."
            fi
            ;;
        Linux)
            _install="$(ask "[??] Install Tailscale now via the official install script (tailscale.com/install.sh)? [Y/n]:")"
            if [[ -z "$_install" || "$_install" =~ ^[Yy]$ ]]; then
                curl -fsSL https://tailscale.com/install.sh | sh
            else
                fail "Tailscale is required. Install it from https://tailscale.com/download and retry."
            fi
            ;;
        *)
            fail "Unsupported OS for automatic Tailscale install. Install it manually from https://tailscale.com/download."
            ;;
    esac
    TAILSCALE_BIN="$(find_tailscale || true)"
    [[ -n "$TAILSCALE_BIN" ]] || fail "Tailscale installation did not complete. Install manually and retry."
fi

ok "Tailscale found: $TAILSCALE_BIN"

if "$TAILSCALE_BIN" status &>/dev/null; then
    ok "Tailscale is connected."
else
    warn "Tailscale is installed but not connected."
    _up="$(ask "[??] Run 'tailscale up' now to connect? [Y/n]:")"
    if [[ -z "$_up" || "$_up" =~ ^[Yy]$ ]]; then
        info "A login URL will open in your browser. Authenticate this machine to your tailnet."
        if [[ "$(uname -s)" == "Linux" ]]; then
            sudo "$TAILSCALE_BIN" up
        else
            "$TAILSCALE_BIN" up
        fi
    else
        fail "Tailscale must be connected to reach the CachyOS host. Run 'tailscale up' and retry."
    fi
fi

###############################################################################
# Phase 3: Gather host parameters
###############################################################################

# Parameters can be supplied via environment variables for unattended runs:
#   CACHYOS_HOST=myhost.ts.net CACHYOS_USER=alice VM_HOST=192.168.26.3 VM_USER=student ./install-client.sh

if [[ -z "${CACHYOS_HOST:-}" ]]; then
    CACHYOS_HOST="$(ask "[??] CachyOS Tailscale hostname or IP:")"
fi
[[ -n "$CACHYOS_HOST" ]] || fail "CACHYOS_HOST must not be empty."

if [[ -z "${CACHYOS_USER:-}" ]]; then
    DEFAULT_USER="$(whoami)"
    _input="$(ask "[??] CachyOS username [$DEFAULT_USER]:")"
    CACHYOS_USER="${_input:-$DEFAULT_USER}"
fi
[[ -n "$CACHYOS_USER" ]] || fail "CACHYOS_USER must not be empty."

VM_HOST="${VM_HOST:-192.168.26.3}"
VM_USER="${VM_USER:-student}"

info "Configuration:"
info "  CachyOS host:  $CACHYOS_HOST"
info "  CachyOS user:  $CACHYOS_USER"
info "  VM host:       $VM_HOST"
info "  VM user:       $VM_USER"

###############################################################################
# Phase 4: Ensure an SSH key exists
###############################################################################

SSH_DIR="$HOME/.ssh"
KEY_FILE="$SSH_DIR/id_ed25519"
PUB_KEY_FILE="$KEY_FILE.pub"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -f "$KEY_FILE" ]]; then
    ok "SSH key already exists: $KEY_FILE"
else
    warn "No SSH key found at $KEY_FILE."
    _gen="$(ask "[??] Generate a new ed25519 key? [Y/n]:")"
    if [[ -z "$_gen" || "$_gen" =~ ^[Yy]$ ]]; then
        ssh-keygen -t ed25519 -f "$KEY_FILE"
        ok "New SSH key generated: $KEY_FILE"
    else
        fail "No SSH key available. Please create one and retry."
    fi
fi

###############################################################################
# Phase 5: SSH config — preserve existing, use config.d
###############################################################################

SSH_CONFIG="$SSH_DIR/config"
SSH_CONFIG_D="$SSH_DIR/config.d"
CS263_CONF="$SSH_CONFIG_D/cs263.conf"

mkdir -p "$SSH_CONFIG_D"
chmod 700 "$SSH_CONFIG_D"

# Ensure main config includes config.d
INCLUDE_LINE="Include ~/.ssh/config.d/*"
if [[ -f "$SSH_CONFIG" ]] && grep -qF "config.d" "$SSH_CONFIG"; then
    ok "Main SSH config already includes config.d."
else
    if [[ -f "$SSH_CONFIG" ]]; then
        BACKUP="$SSH_CONFIG.bak.$(date +%Y%m%dT%H%M%S)"
        cp "$SSH_CONFIG" "$BACKUP"
        info "Backed up existing SSH config to: $BACKUP"
        # Prepend Include line
        TMP="$(mktemp)"
        { echo "$INCLUDE_LINE"; echo ""; cat "$SSH_CONFIG"; } > "$TMP"
        mv "$TMP" "$SSH_CONFIG"
    else
        echo "$INCLUDE_LINE" > "$SSH_CONFIG"
    fi
    chmod 600 "$SSH_CONFIG"
    ok "Added Include directive to $SSH_CONFIG"
fi

# Write or update cs263.conf
info "Writing $CS263_CONF..."
cat > "$CS263_CONF" <<EOF
Host cachyos-home
    HostName $CACHYOS_HOST
    User $CACHYOS_USER
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ForwardAgent yes

Host cs263
    HostName $VM_HOST
    User $VM_USER
    ProxyJump cachyos-home
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ForwardAgent yes
EOF
chmod 600 "$CS263_CONF"
ok "SSH config written: $CS263_CONF"

# Validate effective configuration
info "Validating effective SSH configuration for cs263..."
ssh -G cs263 2>/dev/null | grep -E '^(hostname|user|proxyjump|identityfile)' | head -10
ok "SSH config is valid."

###############################################################################
# Phase 6: Install public key on CachyOS host
###############################################################################

info "Installing public key on CachyOS host ($CACHYOS_HOST)..."

if command -v ssh-copy-id &>/dev/null; then
    ssh-copy-id -i "$PUB_KEY_FILE" "${CACHYOS_USER}@${CACHYOS_HOST}" \
        || warn "ssh-copy-id to host failed. You may need to add the key manually."
else
    # Fallback: append via SSH
    PUB_KEY_CONTENT="$(cat "$PUB_KEY_FILE")"
    ssh "${CACHYOS_USER}@${CACHYOS_HOST}" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$PUB_KEY_CONTENT' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
        || warn "Manual key installation failed. Add the following to ~/.ssh/authorized_keys on the host:"$'\n'"  $(cat "$PUB_KEY_FILE")"
fi

###############################################################################
# Phase 7: Verify host connectivity
###############################################################################

info "Testing SSH connection to CachyOS host (batch mode)..."
if ssh -o BatchMode=yes -o ConnectTimeout=10 cachyos-home true 2>/dev/null; then
    ok "Host connection successful."
else
    warn "Host connection failed. Ensure:"
    warn "  - Tailscale is running on both machines"
    warn "  - Your public key is in ~/.ssh/authorized_keys on the host"
    warn "  - sshd is running on the host"
    warn "You can retry verification later with: ./scripts/verify.sh"
    printf '\n'
    info "Your public key to add on the host:"
    cat "$PUB_KEY_FILE"
    exit 1
fi

###############################################################################
# Phase 8: Install public key on CS263 VM (via ProxyJump)
###############################################################################

info "Installing public key on CS263 VM ($VM_HOST) via ProxyJump..."

if command -v ssh-copy-id &>/dev/null; then
    ssh-copy-id -i "$PUB_KEY_FILE" \
        -o "ProxyJump=cachyos-home" \
        -o "ConnectTimeout=10" \
        "${VM_USER}@${VM_HOST}" \
        || warn "ssh-copy-id to VM failed. The VM may not be running yet. Run ./scripts/verify.sh after starting it."
else
    PUB_KEY_CONTENT="$(cat "$PUB_KEY_FILE")"
    ssh -o ProxyJump=cachyos-home -o ConnectTimeout=10 "${VM_USER}@${VM_HOST}" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$PUB_KEY_CONTENT' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
        || warn "Manual key installation to VM failed. The VM may not be running yet."
fi

###############################################################################
# Phase 9: Verify VM connectivity
###############################################################################

info "Testing SSH connection to CS263 VM (batch mode)..."
if ssh -o BatchMode=yes -o ConnectTimeout=10 cs263 true 2>/dev/null; then
    ok "VM connection successful."
else
    warn "VM connection failed. This may be expected if the VM is not running yet."
    warn "Start the VM and retry with: ./scripts/verify.sh"
fi

###############################################################################
# Summary
###############################################################################

printf '\n'
printf '=%.0s' {1..70}
printf '\n'
ok "Setup complete."
printf '\n'
printf 'Connect to the CachyOS host:\n'
printf '    ssh cachyos-home\n'
printf '\n'
printf 'Connect directly to CS263 through the host:\n'
printf '    ssh cs263\n'
printf '\n'
