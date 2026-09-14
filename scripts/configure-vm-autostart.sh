#!/usr/bin/env bash
# Configures the CS2630 VirtualBox VM to start headlessly at login/boot:
# a systemd --user service on Linux, a LaunchAgent on macOS. Safe to re-run.

set -euo pipefail

###############################################################################
# Helpers
###############################################################################

info()  { printf '\e[1;34m[INFO]\e[0m  %s\n' "$*"; }
warn()  { printf '\e[1;33m[WARN]\e[0m  %s\n' "$*"; }
ok()    { printf '\e[1;32m[ OK ]\e[0m  %s\n' "$*"; }
fail()  { printf '\e[1;31m[FAIL]\e[0m  %s\n' "$*" >&2; exit 1; }
ask()   { printf '\e[1;36m[ ?? ]\e[0m  %s ' "$*" >/dev/tty; read -r _ans </dev/tty; echo "$_ans"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

case "$(uname -s)" in
    Darwin) HOST_OS=macos ;;
    Linux)  HOST_OS=linux ;;
    *)      fail "Unsupported OS: $(uname -s)." ;;
esac

CS2630_STATE_DIR="$HOME/.config/cs2630"
VM_NAME_FILE="$CS2630_STATE_DIR/vm-name"

###############################################################################
# Validate environment
###############################################################################

command -v VBoxManage &>/dev/null || fail "VBoxManage not found. Is VirtualBox installed?"

if [[ "$HOST_OS" == linux ]]; then
    TEMPLATE="$REPO_DIR/systemd/cs2630-vm.service.template"
    SERVICE_DIR="$HOME/.config/systemd/user"
    SERVICE_FILE="$SERVICE_DIR/cs2630-vm.service"
else
    TEMPLATE="$REPO_DIR/launchd/cs2630-vm.plist.template"
    SERVICE_DIR="$HOME/Library/LaunchAgents"
    SERVICE_FILE="$SERVICE_DIR/com.cs2630.vm.plist"
fi
[[ -f "$TEMPLATE" ]] || fail "Service template not found: $TEMPLATE"

###############################################################################
# Choose VM
###############################################################################

info "Enumerating VirtualBox VMs..."
VM_LIST="$(VBoxManage list vms 2>/dev/null)"

if [[ -z "$VM_LIST" ]]; then
    fail "No VirtualBox VMs found. Import the CS2630 OVA first, then re-run this script."
fi

printf '\n%s\n\n' "$VM_LIST"

# Count VMs
VM_COUNT="$(echo "$VM_LIST" | grep -c '"')"

if [[ "$VM_COUNT" -eq 1 ]]; then
    VM_NAME="$(echo "$VM_LIST" | sed 's/^"\(.*\)" {.*}/\1/')"
    info "Found one VM: $VM_NAME"
    _confirm="$(ask "[??] Use this VM? [Y/n]:")"
    if [[ -n "$_confirm" && ! "$_confirm" =~ ^[Yy]$ ]]; then
        fail "Aborted by user."
    fi
else
    info "Multiple VMs found. Enter the exact VM name from the list above:"
    VM_NAME="$(ask "[??] VM name:")"
    # Verify the entered name exists
    echo "$VM_LIST" | grep -qF "\"$VM_NAME\"" \
        || fail "VM '$VM_NAME' not found in VBoxManage list vms output."
fi

ok "Selected VM: $VM_NAME"

# Persisted so `cs2630 poweron`/`poweroff` can drive VBoxManage directly
# without depending on the host's service manager.
mkdir -p "$CS2630_STATE_DIR"
printf '%s\n' "$VM_NAME" > "$VM_NAME_FILE"
ok "Recorded VM name in $VM_NAME_FILE"

###############################################################################
# Check if VM is already running
###############################################################################

RUNNING="$(VBoxManage list runningvms 2>/dev/null)"
if echo "$RUNNING" | grep -qF "\"$VM_NAME\""; then
    warn "VM '$VM_NAME' is currently running."
    warn "The service will manage future starts. The currently running instance is unaffected."
fi

###############################################################################
# Write service file
###############################################################################

mkdir -p "$SERVICE_DIR"

# Escape special characters in VM name for sed substitution
VM_NAME_ESCAPED="${VM_NAME//\//\\/}"

info "Writing $SERVICE_FILE..."
sed "s/__VM_NAME__/$VM_NAME_ESCAPED/g" "$TEMPLATE" > "$SERVICE_FILE"
ok "Service file written."

###############################################################################
# Enable service
###############################################################################

if [[ "$HOST_OS" == linux ]]; then
    systemctl --user daemon-reload
    systemctl --user enable cs2630-vm.service
    ok "cs2630-vm.service enabled."

    info "Enabling linger for $USER (allows user services to run at boot)..."
    sudo loginctl enable-linger "$USER"
    ok "Linger enabled for $USER."
else
    # bootstrap fails if already loaded from a previous run — that's fine.
    launchctl bootstrap "gui/$(id -u)" "$SERVICE_FILE" 2>/dev/null || true
    launchctl enable "gui/$(id -u)/com.cs2630.vm"
    ok "com.cs2630.vm LaunchAgent enabled."
fi

###############################################################################
# Start the VM if not already running
###############################################################################

if echo "$RUNNING" | grep -qF "\"$VM_NAME\""; then
    warn "VM is already running; skipping start."
else
    _start="$(ask "[??] Start the VM now in headless mode? [Y/n]:")"
    if [[ -z "$_start" || "$_start" =~ ^[Yy]$ ]]; then
        if [[ "$HOST_OS" == linux ]]; then
            systemctl --user start cs2630-vm.service
        else
            launchctl kickstart -k "gui/$(id -u)/com.cs2630.vm"
        fi
        ok "VM started."
    else
        info "You can start the VM later with:"
        info "  cs2630 poweron"
    fi
fi

###############################################################################
# Summary
###############################################################################

printf '\n'
printf '=%.0s' {1..70}
printf '\n'
ok "VM autostart configured for: $VM_NAME"
printf '\n'
info "Useful commands:"
if [[ "$HOST_OS" == linux ]]; then
    info "  Status:  systemctl --user status cs2630-vm.service"
    info "  Start:   cs2630 poweron   (or: systemctl --user start cs2630-vm.service)"
    info "  Stop:    cs2630 poweroff  (or: systemctl --user stop  cs2630-vm.service)"
else
    info "  Status:  launchctl print gui/$(id -u)/com.cs2630.vm"
    info "  Start:   cs2630 poweron"
    info "  Stop:    cs2630 poweroff"
fi
info "  Running: VBoxManage list runningvms"
printf '\n'
info "The VM will start headlessly on next login/boot."
info "To verify full connectivity, run:"
info "  ./scripts/verify.sh"
