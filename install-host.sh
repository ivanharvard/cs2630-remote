#!/usr/bin/env bash
# Host installer: sets up Tailscale, OpenSSH, and VirtualBox on CachyOS.
# Safe to re-run. Run as a normal user with sudo access.

set -euo pipefail

###############################################################################
# Helpers
###############################################################################

info()  { printf '\e[1;34m[INFO]\e[0m  %s\n' "$*"; }
warn()  { printf '\e[1;33m[WARN]\e[0m  %s\n' "$*"; }
ok()    { printf '\e[1;32m[ OK ]\e[0m  %s\n' "$*"; }
fail()  { printf '\e[1;31m[FAIL]\e[0m  %s\n' "$*" >&2; exit 1; }
ask()   { printf '\e[1;36m[ ?? ]\e[0m  %s [y/N] ' "$*"; read -r _ans; [[ "$_ans" =~ ^[Yy]$ ]]; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###############################################################################
# Phase 1: Validate environment
###############################################################################

info "Validating environment..."

if [[ ! -f /etc/arch-release ]]; then
    fail "This script is intended for Arch Linux / CachyOS. /etc/arch-release not found."
fi

if ! command -v pacman &>/dev/null; then
    fail "pacman not found. This script requires an Arch-based system."
fi

ok "Arch/CachyOS detected."

if [[ $EUID -eq 0 ]]; then
    fail "Do not run this script as root. Run as a normal user with sudo access."
fi

if ! sudo -n true 2>/dev/null; then
    info "sudo access required. You may be prompted for your password."
    sudo true || fail "Could not obtain sudo access."
fi

###############################################################################
# Phase 2: Determine kernel headers package
###############################################################################

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

###############################################################################
# Phase 3: Install packages
###############################################################################

PACKAGES_TO_INSTALL=()

for pkg in tailscale openssh virtualbox virtualbox-host-dkms "$HEADERS_PKG"; do
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

###############################################################################
# Phase 4: Enable services
###############################################################################

for svc in tailscaled sshd; do
    info "Enabling and starting $svc..."
    sudo systemctl enable --now "$svc"
    if systemctl is-active --quiet "$svc"; then
        ok "$svc is active."
    else
        fail "$svc failed to start. Check: journalctl -eu $svc"
    fi
done

###############################################################################
# Phase 5: Tailscale enrollment
###############################################################################

info "Checking Tailscale enrollment..."

if tailscale status &>/dev/null; then
    ok "Tailscale is already enrolled."
    tailscale status
    TAILSCALE_IP="$(tailscale ip -4 2>/dev/null || true)"
else
    warn "Tailscale is not enrolled. Opening authentication..."
    info "A URL will appear. Open it in a browser to authenticate this machine."
    sudo tailscale up
    TAILSCALE_IP="$(tailscale ip -4 2>/dev/null || true)"
fi

TAILSCALE_HOSTNAME="$(tailscale status --json 2>/dev/null | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" \
    2>/dev/null || true)"

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

SSHD_DROPIN="/etc/ssh/sshd_config.d/90-cs263-remote.conf"

info "Configuring SSH host security..."

# Check for authorized keys before disabling password auth
CACHYOS_USER="${SUDO_USER:-$USER}"
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
sudo systemctl reload sshd || sudo systemctl restart sshd
ok "sshd reloaded."

###############################################################################
# Phase 7: VirtualBox group
###############################################################################

info "Ensuring $CACHYOS_USER is in vboxusers group..."
if id -nG "$CACHYOS_USER" | grep -qw vboxusers; then
    ok "$CACHYOS_USER is already in vboxusers."
else
    sudo usermod -aG vboxusers "$CACHYOS_USER"
    ok "Added $CACHYOS_USER to vboxusers."
    warn "You must log out and back in (or reboot) for the group change to take effect."
fi

###############################################################################
# Summary
###############################################################################

printf '\n'
printf '=%.0s' {1..70}
printf '\n'
ok "Host setup complete."
printf '\n'
info "Your Tailscale address: ${TAILSCALE_ADDR}"
info "CachyOS username:       ${CACHYOS_USER}"
printf '\n'
info "Next steps:"
info "  1. Import the CS263 OVA in VirtualBox (follow course instructions)."
info "  2. Configure the VM network adapters:"
info "       Adapter 1: Host-only (192.168.26.0/24, host at 192.168.26.1)"
info "       Adapter 2: NAT"
info "  3. Run the autostart helper:"
info "       ./scripts/configure-vm-autostart.sh"
info "  4. On your remote client, run:"
info "       ./install-client.sh"
info "  5. Verify everything with:"
info "       ./scripts/verify.sh"
printf '\n'
if ! $HAS_PUBKEY; then
    warn "Password authentication is still enabled. Complete these steps to lock it down:"
    printf '\n'
    warn "  STEP A — On your remote client, copy your public key to this host:"
    warn "    ssh-copy-id ${CACHYOS_USER}@${TAILSCALE_ADDR}"
    warn "  (If ssh-copy-id is unavailable, run this on the client instead:)"
    warn "    cat ~/.ssh/id_ed25519.pub | ssh ${CACHYOS_USER}@${TAILSCALE_ADDR} \\"
    warn "      'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'"
    printf '\n'
    warn "  STEP B — Verify key login works (run from the remote client):"
    warn "    ssh -o BatchMode=yes ${CACHYOS_USER}@${TAILSCALE_ADDR} true && echo 'Key auth works'"
    printf '\n'
    warn "  STEP C — Once key login is confirmed, disable password auth on THIS host:"
    warn "    sudo sed -i 's/^# PasswordAuthentication no/PasswordAuthentication no/' $SSHD_DROPIN"
    warn "    sudo sshd -t && sudo systemctl reload sshd"
fi
