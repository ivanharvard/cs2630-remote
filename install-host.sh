#!/usr/bin/env bash
# Host installer: sets up Tailscale, OpenSSH, and VirtualBox on the machine
# that will actually run the CS2630 course VM. Supports Arch-based Linux
# (e.g. CachyOS), Ubuntu, and Intel macOS. Apple Silicon Macs cannot host
# VirtualBox (no official arm64 build) — use ./install-aws.sh instead on
# those, or on Windows.
# Safe to re-run. Run as a normal user with sudo access.

set -euo pipefail

###############################################################################
# Helpers
###############################################################################

info()  { printf '\e[1;34m[INFO]\e[0m  %s\n' "$*"; }
warn()  { printf '\e[1;33m[WARN]\e[0m  %s\n' "$*"; }
ok()    { printf '\e[1;32m[ OK ]\e[0m  %s\n' "$*"; }
fail()  { printf '\e[1;31m[FAIL]\e[0m  %s\n' "$*" >&2; exit 1; }
ask()   { printf '\e[1;36m[ ?? ]\e[0m  %s [y/N] ' "$*" >/dev/tty; read -r _ans </dev/tty; [[ "$_ans" =~ ^[Yy]$ ]]; }

# Extracts .Self.DNSName from `tailscale status --json`, preferring jq (most
# portable, and not assumed to be preinstalled) and falling back to python3.
tailscale_dns_name() {
    local json="$1"
    if command -v jq &>/dev/null; then
        printf '%s' "$json" | jq -r '.Self.DNSName // empty' | sed 's/\.$//'
    elif command -v python3 &>/dev/null; then
        printf '%s' "$json" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" \
            2>/dev/null
    fi
}

find_tailscale() {
    if command -v tailscale &>/dev/null; then
        command -v tailscale
    elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
        echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###############################################################################
# Phase 1: Validate environment
###############################################################################

info "Validating environment..."

detect_os() {
    case "$(uname -s)" in
        Linux)
            if [[ -f /etc/arch-release ]]; then
                echo arch; return
            fi
            if [[ -f /etc/os-release ]] && grep -q '^ID=ubuntu' /etc/os-release; then
                echo ubuntu; return
            fi
            fail "Unsupported Linux distro. This script supports Arch-based Linux (e.g. CachyOS) and Ubuntu. For anything else, consider ./install-aws.sh."
            ;;
        Darwin)
            if [[ "$(uname -m)" == "arm64" ]]; then
                fail "Apple Silicon Macs cannot host VirtualBox — Oracle ships no official arm64 build. Use an Intel Mac or an Ubuntu machine as the host, or run ./install-aws.sh instead."
            fi
            echo macos
            ;;
        *)
            fail "Unsupported OS: $(uname -s). Try ./install-aws.sh."
            ;;
    esac
}

HOST_OS="$(detect_os)"

case "$HOST_OS" in
    arch)  ok "Arch-based Linux detected." ;;
    ubuntu) ok "Ubuntu detected." ;;
    macos) ok "Intel macOS detected." ;;
esac

if [[ $EUID -eq 0 ]]; then
    fail "Do not run this script as root. Run as a normal user with sudo access."
fi

if ! sudo -n true 2>/dev/null; then
    info "sudo access required. You may be prompted for your password."
    sudo true || fail "Could not obtain sudo access."
fi

HOST_USER="${SUDO_USER:-$USER}"

SSHD_SERVICE="sshd"
case "$HOST_OS" in
    ubuntu) SSHD_SERVICE="ssh" ;;
    macos)  SSHD_SERVICE="com.openssh.sshd" ;;
esac

###############################################################################
# Phase 2: Ensure Tailscale is installed
###############################################################################

info "Checking Tailscale..."

TAILSCALE_BIN="$(find_tailscale || true)"

if [[ -z "$TAILSCALE_BIN" ]]; then
    warn "Tailscale is not installed."
    ask "Install it now?" || fail "Tailscale is required. Install it from https://tailscale.com/download and retry."
    case "$HOST_OS" in
        arch)
            sudo pacman -S --needed --noconfirm tailscale
            ;;
        ubuntu)
            info "Installing Tailscale via the official install script (tailscale.com/install.sh)..."
            curl -fsSL https://tailscale.com/install.sh | sh
            ;;
        macos)
            command -v brew &>/dev/null || fail "Homebrew not found. Install it from https://brew.sh and retry."
            brew install --cask tailscale
            ;;
    esac
    TAILSCALE_BIN="$(find_tailscale || true)"
    [[ -n "$TAILSCALE_BIN" ]] || fail "Tailscale installation did not complete."
fi

ok "Tailscale found: $TAILSCALE_BIN"

###############################################################################
# Phase 3: Install remaining host packages
###############################################################################

case "$HOST_OS" in
arch)
    info "Detecting kernel/headers..."

    KERNEL_RELEASE="$(uname -r)"
    info "Running kernel: $KERNEL_RELEASE"

    # Find installed headers that match the running kernel
    INSTALLED_HEADERS="$(pacman -Q 2>/dev/null | awk '{print $1}' | grep -E '^linux.*-headers$' || true)"

    HEADERS_PKG=""
    if [[ -n "$INSTALLED_HEADERS" ]]; then
        # Try to find a headers package matching the running kernel name
        while IFS= read -r pkg; do
            # e.g. linux-cachyos-headers -> linux-cachyos
            base="${pkg%-headers}"
            if pacman -Q "$base" &>/dev/null; then
                HEADERS_PKG="$pkg"
                break
            fi
        done <<< "$INSTALLED_HEADERS"
    fi

    if [[ -z "$HEADERS_PKG" ]]; then
        # Heuristic: map kernel flavour from uname -r to a headers package
        # CachyOS kernels look like: 6.x.y-N-cachyos, 6.x.y-N-cachyos-bore, etc.
        if [[ "$KERNEL_RELEASE" == *cachyos* ]]; then
            HEADERS_PKG="linux-cachyos-headers"
        elif [[ "$KERNEL_RELEASE" == *lts* ]]; then
            HEADERS_PKG="linux-lts-headers"
        elif [[ "$KERNEL_RELEASE" == *zen* ]]; then
            HEADERS_PKG="linux-zen-headers"
        elif [[ "$KERNEL_RELEASE" == *hardened* ]]; then
            HEADERS_PKG="linux-hardened-headers"
        else
            HEADERS_PKG="linux-headers"
        fi
        warn "Could not detect installed headers package; will attempt to install: $HEADERS_PKG"
    fi

    info "Headers package selected: $HEADERS_PKG"

    PACKAGES_TO_INSTALL=()
    for pkg in openssh virtualbox virtualbox-host-dkms "$HEADERS_PKG"; do
        if pacman -Q "$pkg" &>/dev/null; then
            ok "$pkg already installed."
        else
            PACKAGES_TO_INSTALL+=("$pkg")
        fi
    done

    if [[ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]]; then
        info "The following packages will be installed: ${PACKAGES_TO_INSTALL[*]}"
        ask "Proceed?" || fail "Aborted by user."
        sudo pacman -S --needed --noconfirm "${PACKAGES_TO_INSTALL[@]}"
    else
        ok "All required packages are already installed."
    fi
    ;;
ubuntu)
    info "Refreshing apt package index..."
    sudo apt-get update -qq

    HEADERS_PKG="linux-headers-$(uname -r)"
    PACKAGES_TO_INSTALL=()
    for pkg in openssh-server virtualbox virtualbox-dkms "$HEADERS_PKG"; do
        if dpkg -s "$pkg" &>/dev/null; then
            ok "$pkg already installed."
        else
            PACKAGES_TO_INSTALL+=("$pkg")
        fi
    done

    if [[ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]]; then
        info "The following packages will be installed: ${PACKAGES_TO_INSTALL[*]}"
        ask "Proceed?" || fail "Aborted by user."
        sudo apt-get install -y "${PACKAGES_TO_INSTALL[@]}"
    else
        ok "All required packages are already installed."
    fi
    ;;
macos)
    command -v brew &>/dev/null || fail "Homebrew not found. Install it from https://brew.sh and retry."

    if brew list --cask virtualbox &>/dev/null; then
        ok "virtualbox already installed."
    else
        info "Installing VirtualBox via Homebrew..."
        brew install --cask virtualbox
        warn "macOS requires a one-time manual approval for VirtualBox's system extension:"
        warn "  System Settings -> Privacy & Security -> scroll down -> \"Allow\" next to the Oracle/VirtualBox entry."
        warn "VBoxManage will not work until that's approved. Run ./scripts/verify.sh afterward to confirm."
    fi

    # OpenSSH ships with macOS; nothing to install. Enabled in Phase 4.
    ;;
esac

###############################################################################
# Phase 4: Enable services
###############################################################################

case "$HOST_OS" in
arch|ubuntu)
    for svc in tailscaled "$SSHD_SERVICE"; do
        info "Enabling and starting $svc..."
        sudo systemctl enable --now "$svc"
        if systemctl is-active --quiet "$svc"; then
            ok "$svc is active."
        else
            fail "$svc failed to start. Check: journalctl -eu $svc"
        fi
    done
    ;;
macos)
    info "Enabling Remote Login (sshd)..."
    sudo systemsetup -setremotelogin on >/dev/null
    if sudo systemsetup -getremotelogin | grep -qi "on"; then
        ok "Remote Login is on."
    else
        fail "Failed to enable Remote Login. Check System Settings -> General -> Sharing -> Remote Login."
    fi

    info "Launching Tailscale.app (approve its system extension if prompted)..."
    open -a Tailscale
    sleep 2
    ;;
esac

###############################################################################
# Phase 5: Tailscale enrollment
###############################################################################

info "Checking Tailscale enrollment..."

if "$TAILSCALE_BIN" status &>/dev/null; then
    ok "Tailscale is already enrolled."
    "$TAILSCALE_BIN" status
    TAILSCALE_IP="$("$TAILSCALE_BIN" ip -4 2>/dev/null || true)"
else
    warn "Tailscale is not enrolled. Opening authentication..."
    info "A URL will appear. Open it in a browser to authenticate this machine."
    if [[ "$HOST_OS" == macos ]]; then
        "$TAILSCALE_BIN" up
    else
        sudo "$TAILSCALE_BIN" up
    fi
    TAILSCALE_IP="$("$TAILSCALE_BIN" ip -4 2>/dev/null || true)"
fi

TAILSCALE_HOSTNAME="$(tailscale_dns_name "$("$TAILSCALE_BIN" status --json 2>/dev/null)" || true)"

if [[ -n "$TAILSCALE_HOSTNAME" ]]; then
    TAILSCALE_ADDR="$TAILSCALE_HOSTNAME"
    ok "Tailscale MagicDNS hostname: $TAILSCALE_ADDR"
elif [[ -n "$TAILSCALE_IP" ]]; then
    TAILSCALE_ADDR="$TAILSCALE_IP"
    ok "Tailscale IPv4: $TAILSCALE_ADDR"
else
    TAILSCALE_ADDR="<TAILSCALE_IP>"
    warn "Could not determine Tailscale address. Fill in manually."
fi

###############################################################################
# Phase 6: SSH host hardening
###############################################################################

SSHD_DROPIN="/etc/ssh/sshd_config.d/90-cs2630-remote.conf"
SSHD_CONFIG="/etc/ssh/sshd_config"

info "Configuring SSH host security..."

# Arch/Ubuntu's packaged sshd_config already includes sshd_config.d/*.conf;
# macOS's does not by default, so make sure it's actually picked up.
if ! sudo grep -qE '^Include[[:space:]]+/etc/ssh/sshd_config\.d/\*' "$SSHD_CONFIG" 2>/dev/null; then
    info "Adding Include directive to $SSHD_CONFIG for sshd_config.d/..."
    SSHD_CONFIG_BACKUP="$SSHD_CONFIG.bak.$(date +%Y%m%dT%H%M%S)"
    sudo cp "$SSHD_CONFIG" "$SSHD_CONFIG_BACKUP"
    info "Backed up existing sshd_config to: $SSHD_CONFIG_BACKUP"
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n\n' | sudo tee "$SSHD_CONFIG.new" > /dev/null
    sudo bash -c "cat '$SSHD_CONFIG' >> '$SSHD_CONFIG.new' && mv '$SSHD_CONFIG.new' '$SSHD_CONFIG'"
    ok "Include directive added."
fi

# Check for authorized keys before disabling password auth
AUTH_KEYS="$HOME/.ssh/authorized_keys"
HAS_PUBKEY=false
if [[ -s "$AUTH_KEYS" ]]; then
    HAS_PUBKEY=true
    ok "Authorized keys found at $AUTH_KEYS"
else
    warn "No authorized keys found at $AUTH_KEYS"
    warn "Password authentication will NOT be disabled until a public key is installed."
fi

if [[ -f "$SSHD_DROPIN" ]]; then
    info "SSH drop-in already exists: $SSHD_DROPIN"
else
    info "Creating $SSHD_DROPIN"
    if $HAS_PUBKEY; then
        sudo tee "$SSHD_DROPIN" > /dev/null <<'EOF'
PubkeyAuthentication yes
PermitRootLogin no
PasswordAuthentication no
EOF
        ok "SSH drop-in written (password auth disabled — public key detected)."
    else
        sudo tee "$SSHD_DROPIN" > /dev/null <<'EOF'
PubkeyAuthentication yes
PermitRootLogin no
# PasswordAuthentication no
# Uncomment the line above only after verifying public-key login works:
#   ssh-copy-id <your_user>@<tailscale_host>
#   ssh <your_user>@<tailscale_host>
EOF
        warn "SSH drop-in written; PasswordAuthentication is still enabled."
        warn "After adding your public key, uncomment the PasswordAuthentication line in:"
        warn "  $SSHD_DROPIN"
    fi
fi

info "Validating SSH configuration..."
sudo sshd -t || fail "sshd configuration test failed. Fix errors before continuing."
ok "sshd configuration is valid."

info "Reloading sshd..."
case "$HOST_OS" in
arch|ubuntu)
    sudo systemctl reload "$SSHD_SERVICE" || sudo systemctl restart "$SSHD_SERVICE"
    ;;
macos)
    sudo launchctl kickstart -k system/com.openssh.sshd
    ;;
esac
ok "sshd reloaded."

###############################################################################
# Phase 7: SSH alias for CS2630 VM (direct — no ProxyJump needed on this host)
###############################################################################

VM_HOST="${VM_HOST:-192.168.26.3}"
VM_USER="${VM_USER:-student}"

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
SSH_CONFIG_D="$SSH_DIR/config.d"
CS2630_CONF="$SSH_CONFIG_D/cs2630.conf"

mkdir -p "$SSH_CONFIG_D"
chmod 700 "$SSH_CONFIG_D"

INCLUDE_LINE="Include ~/.ssh/config.d/*"
if [[ -f "$SSH_CONFIG" ]] && grep -qF "config.d" "$SSH_CONFIG"; then
    ok "Main SSH config already includes config.d."
else
    if [[ -f "$SSH_CONFIG" ]]; then
        BACKUP="$SSH_CONFIG.bak.$(date +%Y%m%dT%H%M%S)"
        cp "$SSH_CONFIG" "$BACKUP"
        info "Backed up existing SSH config to: $BACKUP"
        TMP="$(mktemp)"
        { echo "$INCLUDE_LINE"; echo ""; cat "$SSH_CONFIG"; } > "$TMP"
        mv "$TMP" "$SSH_CONFIG"
    else
        echo "$INCLUDE_LINE" > "$SSH_CONFIG"
    fi
    chmod 600 "$SSH_CONFIG"
    ok "Added Include directive to $SSH_CONFIG"
fi

info "Writing $CS2630_CONF..."
cat > "$CS2630_CONF" <<EOF
Host cs2630
    HostName $VM_HOST
    User $VM_USER
    ForwardAgent yes
EOF
chmod 600 "$CS2630_CONF"
ok "SSH alias written: cs2630 -> ${VM_USER}@${VM_HOST}"

info "Validating effective SSH configuration for cs2630..."
ssh -G cs2630 2>/dev/null | grep -E '^(hostname|user)' | head -5
ok "SSH alias 'cs2630' configured for direct access."

###############################################################################
# Phase 8: VirtualBox group (Linux only — macOS VirtualBox has no vboxusers)
###############################################################################

if [[ "$HOST_OS" == macos ]]; then
    info "macOS VirtualBox does not use a vboxusers group; nothing to do here."
else
    info "Ensuring $HOST_USER is in vboxusers group..."
    if id -nG "$HOST_USER" | grep -qw vboxusers; then
        ok "$HOST_USER is already in vboxusers."
    else
        sudo usermod -aG vboxusers "$HOST_USER"
        ok "Added $HOST_USER to vboxusers."
        warn "You must log out and back in (or reboot) for the group change to take effect."
    fi
fi

###############################################################################
# Phase 9: VS Code Remote-SSH extension
###############################################################################

info "Checking for VS Code Remote-SSH extension..."
if command -v code &>/dev/null; then
    if code --list-extensions 2>/dev/null | grep -qi '^ms-vscode-remote\.remote-ssh$'; then
        ok "VS Code Remote-SSH extension is installed."
    else
        warn "VS Code Remote-SSH extension not found."
        if ask "Install it now via the code CLI?"; then
            code --install-extension ms-vscode-remote.remote-ssh
            ok "Remote-SSH extension installed."
        else
            warn "Install manually later: code --install-extension ms-vscode-remote.remote-ssh"
        fi
    fi
else
    warn "VS Code 'code' CLI not found."
    warn "Install VS Code and the Remote-SSH extension (ms-vscode-remote.remote-ssh) to connect to cs2630 from your editor."
fi

###############################################################################
# Phase 10: Install cs2630 CLI helper
###############################################################################

info "Installing cs2630 CLI helper..."
mkdir -p "$HOME/.local/bin"
if [[ -f "$SCRIPT_DIR/bin/cs2630" ]]; then
    chmod +x "$SCRIPT_DIR/bin/cs2630"
    ln -sf "$SCRIPT_DIR/bin/cs2630" "$HOME/.local/bin/cs2630"
    ok "cs2630 CLI linked: $HOME/.local/bin/cs2630 -> $SCRIPT_DIR/bin/cs2630"
else
    # Running via curl | bash: no local repo to symlink into, so fetch the
    # CLI script directly instead.
    info "No local repo found next to this script (likely running via curl | bash) — downloading the CLI standalone..."
    curl -fsSL https://raw.githubusercontent.com/ivanharvard/cs2630-remote/main/bin/cs2630 -o "$HOME/.local/bin/cs2630"
    chmod +x "$HOME/.local/bin/cs2630"
    ok "cs2630 CLI installed: $HOME/.local/bin/cs2630"
    warn "This is a standalone copy — 'cs2630 install client/aws', 'cs2630 verify', and 'cs2630 autostart' need"
    warn "the full repo. Clone it if you'll need those: git clone https://github.com/ivanharvard/cs2630-remote.git"
fi

case ":$PATH:" in
    *":$HOME/.local/bin:"*)
        ok '$HOME/.local/bin is already on PATH.'
        ;;
    *)
        warn '$HOME/.local/bin is not on your PATH.'
        warn 'Add this to your shell rc file: export PATH="$HOME/.local/bin:$PATH"'
        ;;
esac

###############################################################################
# Summary
###############################################################################

printf '\n'
printf '=%.0s' {1..70}
printf '\n'
ok "Host setup complete."
printf '\n'
info "Your Tailscale address: ${TAILSCALE_ADDR}"
info "Host username:          ${HOST_USER}"
info "Host OS:                ${HOST_OS}"
printf '\n'
info "You can SSH directly to the VM from this host with:"
info "    ssh cs2630"
printf '\n'
info "Or use the cs2630 CLI helper:"
info "    cs2630 sh              # ssh cs2630"
info "    cs2630 code <path>     # open <path> on the VM in VS Code"
info "    cs2630 poweron|poweroff"
info "    cs2630 verify"
printf '\n'
info "Next steps:"
info "  1. Import the CS2630 OVA in VirtualBox (follow course instructions)."
info "  2. Configure the VM network adapters:"
info "       Adapter 1: Host-only (192.168.26.0/24, host at 192.168.26.1)"
info "       Adapter 2: NAT"
info "  3. Run the autostart helper:"
info "       ./scripts/configure-vm-autostart.sh"
info "  4. On your remote client, run:"
info "       ./install-client.sh"
info "  5. Verify everything with:"
info "       ./scripts/verify.sh"
if [[ "$HOST_OS" == macos ]]; then
    printf '\n'
    warn "Reminder: VirtualBox needs its system extension approved once in"
    warn "System Settings -> Privacy & Security before VBoxManage will work."
fi
printf '\n'
if ! $HAS_PUBKEY; then
    warn "Password authentication is still enabled. Complete these steps to lock it down:"
    printf '\n'
    warn "  STEP A — On your remote client, copy your public key to this host:"
    warn "    ssh-copy-id ${HOST_USER}@${TAILSCALE_ADDR}"
    warn "  (If ssh-copy-id is unavailable, run this on the client instead:)"
    warn "    cat ~/.ssh/id_ed25519.pub | ssh ${HOST_USER}@${TAILSCALE_ADDR} \\"
    warn "      'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'"
    printf '\n'
    warn "  STEP B — Verify key login works (run from the remote client):"
    warn "    ssh -o BatchMode=yes ${HOST_USER}@${TAILSCALE_ADDR} true && echo 'Key auth works'"
    printf '\n'
    warn "  STEP C — Once key login is confirmed, disable password auth on THIS host:"
    if [[ "$HOST_OS" == macos ]]; then
        warn "    sudo sed -i '' 's/^# PasswordAuthentication no/PasswordAuthentication no/' $SSHD_DROPIN"
        warn "    sudo sshd -t && sudo launchctl kickstart -k system/com.openssh.sshd"
    else
        warn "    sudo sed -i 's/^# PasswordAuthentication no/PasswordAuthentication no/' $SSHD_DROPIN"
        warn "    sudo sshd -t && sudo systemctl reload $SSHD_SERVICE"
    fi
fi
