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
├── scripts/
│   ├── configure-vm-autostart.sh
│   └── verify.sh
├── systemd/
│   └── cs263-vm.service.template
└── docs/
    └── AGENT_SETUP.md           # Full design spec
```

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
