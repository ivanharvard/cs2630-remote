#!/usr/bin/env bash
# Entry point: installs just the `cs2630` CLI helper, so you can then pick
# what to set up (host, client, or the AWS fallback) from the CLI itself.
# Safe to re-run.
#
# Recommended flow:
#   ./install.sh              # installs the cs2630 CLI onto your PATH
#   cs2630 install host       # or: client, or aws — pick your path
#
# The individual installers also work standalone — each installs the CLI
# itself too, so running one of these directly (without ./install.sh first)
# is equally valid:
#   ./install-host.sh
#   ./install-client.sh
#   ./install-aws.sh

set -euo pipefail

info()  { printf '\e[1;34m[INFO]\e[0m  %s\n' "$*"; }
warn()  { printf '\e[1;33m[WARN]\e[0m  %s\n' "$*"; }
ok()    { printf '\e[1;32m[ OK ]\e[0m  %s\n' "$*"; }
fail()  { printf '\e[1;31m[FAIL]\e[0m  %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f "$SCRIPT_DIR/bin/cs2630" ]] || fail "bin/cs2630 not found next to this script."

info "Installing cs2630 CLI helper..."
mkdir -p "$HOME/.local/bin"
chmod +x "$SCRIPT_DIR/bin/cs2630"
ln -sf "$SCRIPT_DIR/bin/cs2630" "$HOME/.local/bin/cs2630"
ok "cs2630 CLI linked: $HOME/.local/bin/cs2630 -> $SCRIPT_DIR/bin/cs2630"

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
ok "cs2630 CLI installed."
printf '\n'
info "Next, pick what to set up:"
info "    cs2630 install host      # this machine runs the VirtualBox VM"
info "    cs2630 install client    # SSH in from elsewhere to a VM hosted on another host"
info "    cs2630 install aws       # no local VirtualBox — provision an EC2 instance instead"
printf '\n'
info "Run 'cs2630 help' any time to see the rest of the commands."
