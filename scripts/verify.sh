#!/usr/bin/env bash
# Reports the state of all components without making changes.
# Outputs PASS / WARN / FAIL for each check.

set -uo pipefail

###############################################################################
# Helpers
###############################################################################

PASS=0; WARN=0; FAIL=0

pass() { printf '\e[1;32m[PASS]\e[0m  %s\n' "$*"; (( PASS++ )) || true; }
warn() { printf '\e[1;33m[WARN]\e[0m  %s\n' "$*"; (( WARN++ )) || true; }
fail() { printf '\e[1;31m[FAIL]\e[0m  %s\n' "$*"; (( FAIL++ )) || true; }
hdr()  { printf '\n\e[1;37m--- %s\e[0m\n' "$*"; }

###############################################################################
# Services
###############################################################################

hdr "System services"

for svc in tailscaled sshd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        pass "$svc is active"
    else
        fail "$svc is NOT active"
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        pass "$svc is enabled"
    else
        warn "$svc is not enabled (will not start at boot)"
    fi
done

###############################################################################
# Tailscale
###############################################################################

hdr "Tailscale"

if command -v tailscale &>/dev/null; then
    pass "tailscale binary found"
    if tailscale status &>/dev/null; then
        TS_IP="$(tailscale ip -4 2>/dev/null || true)"
        pass "Tailscale is connected (IPv4: ${TS_IP:-unknown})"
        TS_HOST="$(tailscale status --json 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Self',{}).get('DNSName','').rstrip('.'))" \
            2>/dev/null || true)"
        [[ -n "$TS_HOST" ]] && pass "MagicDNS hostname: $TS_HOST" || warn "MagicDNS hostname not available"
    else
        fail "Tailscale is NOT connected (run: sudo tailscale up)"
    fi
else
    fail "tailscale not found"
fi

###############################################################################
# VirtualBox
###############################################################################

hdr "VirtualBox"

if command -v VBoxManage &>/dev/null; then
    VB_VER="$(VBoxManage --version 2>/dev/null || true)"
    pass "VBoxManage found (version: ${VB_VER:-unknown})"
else
    fail "VBoxManage not found — VirtualBox may not be installed"
fi

# Kernel modules
if lsmod 2>/dev/null | grep -q '^vboxdrv'; then
    pass "vboxdrv kernel module is loaded"
else
    warn "vboxdrv kernel module is NOT loaded (VirtualBox may still load it on demand)"
fi

# vboxusers group
CURRENT_USER="${SUDO_USER:-$USER}"
if id -nG "$CURRENT_USER" 2>/dev/null | grep -qw vboxusers; then
    pass "$CURRENT_USER is in vboxusers group"
else
    fail "$CURRENT_USER is NOT in vboxusers group (run: sudo usermod -aG vboxusers $CURRENT_USER)"
fi

###############################################################################
# VMs
###############################################################################

hdr "VirtualBox VMs"

if command -v VBoxManage &>/dev/null; then
    VM_LIST="$(VBoxManage list vms 2>/dev/null || true)"
    if [[ -n "$VM_LIST" ]]; then
        VM_COUNT="$(echo "$VM_LIST" | grep -c '"' || true)"
        pass "$VM_COUNT VM(s) registered"
        echo "$VM_LIST" | sed 's/^/        /'
    else
        warn "No VMs registered (import the CS263 OVA to proceed)"
    fi

    RUNNING="$(VBoxManage list runningvms 2>/dev/null || true)"
    if [[ -n "$RUNNING" ]]; then
        pass "Running VMs:"
        echo "$RUNNING" | sed 's/^/        /'
    else
        warn "No VMs are currently running"
    fi
fi

###############################################################################
# cs263-vm systemd service
###############################################################################

hdr "cs263-vm user service"

SERVICE_FILE="$HOME/.config/systemd/user/cs263-vm.service"
if [[ -f "$SERVICE_FILE" ]]; then
    pass "Service file exists: $SERVICE_FILE"
    if systemctl --user is-active --quiet cs263-vm.service 2>/dev/null; then
        pass "cs263-vm.service is active"
    else
        warn "cs263-vm.service is NOT active"
    fi
    if systemctl --user is-enabled --quiet cs263-vm.service 2>/dev/null; then
        pass "cs263-vm.service is enabled"
    else
        warn "cs263-vm.service is NOT enabled"
    fi
else
    warn "cs263-vm.service not configured yet (run: ./scripts/configure-vm-autostart.sh)"
fi

###############################################################################
# Network reachability to CS263 VM
###############################################################################

hdr "CS263 VM network (192.168.26.3)"

VM_HOST="${VM_HOST:-192.168.26.3}"
VM_USER="${VM_USER:-student}"

if ping -c1 -W2 "$VM_HOST" &>/dev/null; then
    pass "$VM_HOST is reachable (ICMP)"
else
    warn "$VM_HOST is NOT reachable via ICMP (VM may be off or network not configured)"
fi

if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
       "${VM_USER}@${VM_HOST}" true 2>/dev/null; then
    pass "SSH to ${VM_USER}@${VM_HOST} succeeded"
else
    warn "SSH to ${VM_USER}@${VM_HOST} failed (VM may be off, or key not installed yet)"
fi

###############################################################################
# SSH configuration (client-side, if applicable)
###############################################################################

hdr "SSH client configuration"

CS263_CONF="$HOME/.ssh/config.d/cs263.conf"
if [[ -f "$CS263_CONF" ]]; then
    pass "cs263.conf found: $CS263_CONF"
    if ssh -G cs263 &>/dev/null; then
        EFFECTIVE_HOST="$(ssh -G cs263 2>/dev/null | awk '/^hostname /{print $2}')"
        pass "cs263 SSH alias resolves (hostname: ${EFFECTIVE_HOST:-unknown})"
    else
        warn "ssh -G cs263 failed — check $CS263_CONF"
    fi
else
    warn "cs263 SSH alias not configured (run: ./install-client.sh)"
fi

###############################################################################
# Summary
###############################################################################

printf '\n'
printf '=%.0s' {1..70}
printf '\n'
printf '\e[1;32mPASS: %d\e[0m  \e[1;33mWARN: %d\e[0m  \e[1;31mFAIL: %d\e[0m\n' "$PASS" "$WARN" "$FAIL"
printf '\n'

if [[ $FAIL -gt 0 ]]; then
    printf '\e[1;31mSome checks failed. Review the FAIL items above.\e[0m\n'
    exit 1
elif [[ $WARN -gt 0 ]]; then
    printf '\e[1;33mAll critical checks passed, but review WARNings above.\e[0m\n'
    exit 0
else
    printf '\e[1;32mAll checks passed.\e[0m\n'
    exit 0
fi
