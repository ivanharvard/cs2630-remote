# cachyos-cs263-remote

Reproducible remote-access setup for the CS263 course VM running in VirtualBox on a CachyOS host. Remote clients reach the VM through a Tailscale-private SSH tunnel — no router port-forwarding required.

```
Remote client
    |
    | Tailscale private network
    v
CachyOS host  (tailscaled + sshd)
    |
    | 192.168.26.0/24 host-only network
    v
CS263 VM  —  student@192.168.26.3
```

Final UX: `ssh cs263` from any Tailscale-connected client.

---

## Requirements

- **CachyOS host and remote client:** [VS Code](https://code.visualstudio.com/) with the [Remote - SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension (`ms-vscode-remote.remote-ssh`) installed. Both `install-host.sh` and `install-client.sh` check for it (via the `code` CLI) and offer to install it if missing.

---

## Quick start

### 1 — CachyOS host

Review the script, then run it as your normal (non-root) user:

```bash
git clone https://github.com/YOUR_USERNAME/cachyos-cs263-remote.git
cd cachyos-cs263-remote
./install-host.sh
```

Or pipe directly (review first):

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/cachyos-cs263-remote/main/install-host.sh | bash
```

The script will:
- Install `tailscale`, `openssh`, `virtualbox`, `virtualbox-host-dkms`, and the correct kernel headers
- Enable and start `tailscaled` and `sshd`
- Walk you through Tailscale enrollment if needed
- Harden SSH (drop-in config, no existing files overwritten)
- Add your user to `vboxusers`
- Check for the VS Code Remote-SSH extension and offer to install it

### 2 — Import the course VM

Follow the course instructions to import the CS263 OVA in VirtualBox. Configure:

- **Adapter 1:** Host-only Adapter — network `192.168.26.0/24`, host at `192.168.26.1`
- **Adapter 2:** NAT

Preferred static guest address: `192.168.26.3` (see course netplan instructions if not auto-assigned).

### 3 — VM autostart

After importing the OVA:

```bash
./scripts/configure-vm-autostart.sh
```

This creates `~/.config/systemd/user/cs263-vm.service` and enables it so the VM starts headlessly at login.

### 4 — Remote client

On any Linux or macOS machine you want to SSH from:

```bash
git clone https://github.com/YOUR_USERNAME/cachyos-cs263-remote.git
cd cachyos-cs263-remote
./install-client.sh
```

Or unattended:

```bash
CACHYOS_HOST=myhost.tailnet-name.ts.net \
CACHYOS_USER=alice \
./install-client.sh
```

The script generates `~/.ssh/config.d/cs263.conf` and installs your public key on both the host and the VM.

### 5 — Verify

```bash
./scripts/verify.sh
```

---

## Repository layout

```
cachyos-cs263-remote/
├── install-host.sh              # CachyOS host setup
├── install-client.sh            # Remote SSH client setup
├── bin/
│   └── cs263                    # Unified CLI helper (see below)
├── scripts/
│   ├── configure-vm-autostart.sh
│   └── verify.sh
├── systemd/
│   └── cs263-vm.service.template
└── docs/
    └── AGENT_SETUP.md           # Full design spec
```

---

## `cs263` CLI helper

Both `install-host.sh` and `install-client.sh` symlink [`bin/cs263`](bin/cs263) to `~/.local/bin/cs263`, giving you one command on either machine:

```bash
cs263 sh                # ssh cs263
cs263 code <path>       # code --remote ssh-remote+cs263 /home/student/<path>
cs263 poweron           # start the VM — hops to the host over SSH if run from a client
cs263 poweroff          # gracefully stop the VM (ACPI shutdown)
cs263 install host      # ./install-host.sh
cs263 install client    # ./install-client.sh
cs263 verify            # ./scripts/verify.sh
cs263 autostart         # ./scripts/configure-vm-autostart.sh
```

`poweron`/`poweroff` detect whether they're running on the CachyOS host (VirtualBox present) or a remote client; on a client they run the command over `ssh cachyos-home` instead. Make sure `~/.local/bin` is on your `PATH` — the installers warn if it isn't.

---

## Security notes

- Remote access uses Tailscale; no TCP/22 exposure on the home router.
- SSH private keys never leave their originating client.
- Password auth on the CachyOS host is disabled only after a public key is confirmed.
- Root SSH login is disabled.
- VM shutdown always uses ACPI (graceful), never a hard power-off.
- No secrets, keys, or credentials are committed to this repository.
- The course OVA is not included; treat it as course material.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| `ssh cs263` times out | `./scripts/verify.sh` — look for FAIL on Tailscale or VM reachability |
| `vboxdrv` not loaded | `sudo modprobe vboxdrv` or reboot after kernel headers install |
| Group change not effective | Log out and back in, or reboot |
| VM won't start headless | `systemctl --user status cs263-vm.service` + `journalctl --user -eu cs263-vm` |
| Tailscale not enrolled | `sudo tailscale up` |
