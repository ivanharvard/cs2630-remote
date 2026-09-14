# cs2630-remote

Reproducible remote-access setup for the CS2630 course VM running in VirtualBox on a host machine you control. Remote clients reach the VM through a Tailscale-private SSH tunnel — no router port-forwarding required.

```
Remote client
    |
    | Tailscale private network
    v
Host  (Arch-based Linux, Ubuntu, or Intel macOS — tailscaled + sshd)
    |
    | 192.168.26.0/24 host-only network
    v
CS2630 VM  —  student@192.168.26.3
```

Final UX: `ssh cs2630` from any Tailscale-connected client.

Can't or don't want to run VirtualBox locally (Windows, an Apple Silicon Mac, or an underpowered laptop)? Skip straight to [AWS EC2 instead](#alternative-aws-ec2-no-local-virtualbox) — no host machine needed at all.

**Recommended way to start:** run `./install.sh` once — it just installs the [`cs2630`](#cs2630-cli-helper) CLI helper onto your `PATH`. From there, pick your path with `cs2630 install host`, `cs2630 install client`, or `cs2630 install aws`. Prefer not to go through the CLI? Each of `install-host.sh`, `install-client.sh`, and `install-aws.sh` also works fine run directly — they install the CLI themselves too.

---

## Requirements

- **Host machine:** Arch-based Linux (e.g. CachyOS), Ubuntu, or an **Intel** Mac. VirtualBox has no official Apple Silicon (arm64) build — `install-host.sh` detects arm64 Macs and stops with an explanation. Windows isn't supported as a local host either (VirtualBox can't load its kernel driver inside WSL2) — use the AWS path instead.
- **Host and remote client:** [VS Code](https://code.visualstudio.com/) with the [Remote - SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension (`ms-vscode-remote.remote-ssh`) installed. Both `install-host.sh` and `install-client.sh` check for it (via the `code` CLI) and offer to install it if missing.

---

## Quick start

### 1 — Host machine

Review the script, then run it as your normal (non-root) user:

```bash
git clone https://github.com/YOUR_USERNAME/cs2630-remote.git
cd cs2630-remote
./install-host.sh
```

Or pipe directly (review first):

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/cs2630-remote/main/install-host.sh | bash
```

The script detects your OS (Arch-based Linux, Ubuntu, or Intel macOS) and will:
- Install `tailscale`, OpenSSH, VirtualBox, and (on Linux) the matching kernel headers
- Enable and start Tailscale and sshd
- Walk you through Tailscale enrollment if needed
- Harden SSH (drop-in config, no existing files overwritten)
- Add your user to `vboxusers` (Linux only — macOS VirtualBox has no such group)
- Check for the VS Code Remote-SSH extension and offer to install it

On macOS, VirtualBox and Tailscale each require a one-time manual approval in **System Settings → Privacy & Security** before they'll work — the script tells you when this is needed; it can't be scripted around.

### 2 — Import the course VM

Follow the course instructions to import the CS2630 OVA in VirtualBox. Configure:

- **Adapter 1:** Host-only Adapter — network `192.168.26.0/24`, host at `192.168.26.1`
- **Adapter 2:** NAT

Preferred static guest address: `192.168.26.3` (see course netplan instructions if not auto-assigned).

### 3 — VM autostart

After importing the OVA:

```bash
./scripts/configure-vm-autostart.sh
```

Linux: creates `~/.config/systemd/user/cs2630-vm.service`. macOS: creates a `~/Library/LaunchAgents/com.cs2630.vm.plist` LaunchAgent. Either way, the VM starts headlessly at login, and the selected VM's name is recorded to `~/.config/cs2630/vm-name` so `cs2630 poweron`/`poweroff` can drive it directly.

### 4 — Remote client

On any Linux or macOS machine you want to SSH from:

```bash
git clone https://github.com/YOUR_USERNAME/cs2630-remote.git
cd cs2630-remote
./install-client.sh
```

Or unattended:

```bash
HOST_ADDR=myhost.tailnet-name.ts.net \
HOST_USER=alice \
./install-client.sh
```

The script generates `~/.ssh/config.d/cs2630.conf` and installs your public key on both the host and the VM.

### 5 — Verify

```bash
./scripts/verify.sh
```

---

## Alternative: AWS EC2 (no local VirtualBox)

The course documents a fallback: run the course environment on a free-tier-eligible AWS EC2 instance instead of locally. `install-aws.sh` automates that end-to-end — useful on Windows, an Apple Silicon Mac, or any machine where local VirtualBox isn't practical. No host machine, Tailscale, or VirtualBox needed; it's a direct SSH connection to a public EC2 instance.

**Prerequisite:** the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), authenticated with credentials that can create EC2 instances. If you don't have an access key yet: AWS Console → search **IAM** → **Users** → your user → **Security credentials** tab → **Create access key**. Then store it locally with:

```bash
aws configure
```

This writes the key ID/secret to `~/.aws/credentials` and the default region to `~/.aws/config` — the standard location the AWS CLI (and `install-aws.sh`) reads from automatically. Verify it worked with `aws sts get-caller-identity`.

```bash
./install-aws.sh
```

It provisions an EC2 instance from the course AMI (region `us-east-1` by default), waits for it to boot, installs the same course software packages the local VM ships with, and writes an `ssh cs2630-aws` alias. Connect with:

```bash
ssh -A -L 8080:localhost:8080 cs2630-aws
```

This creates **real, billable AWS resources** (usually free-tier eligible, but still your responsibility) and a security group open to SSH from anywhere — the script asks for confirmation before creating anything, and prints the `aws ec2 stop-instances`/`terminate-instances` commands to clean up when you're done. See `cs2630 install aws` / the script itself for the full list of overridable parameters (`AWS_REGION`, `INSTANCE_TYPE`, etc).

**Using this from a second machine?** The `.pem` private key `install-aws.sh` generates can't be copied between machines — AWS never re-exports it. Instead, generate a normal SSH keypair on the second machine (`ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519` if it doesn't have one yet), then from a machine that **already has access**, run:

```bash
GRANT_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" ./install-aws.sh   # paste the *other* machine's public key here
```

That appends the given public key to the instance's `authorized_keys` over the existing working connection — safe to do, since a public key isn't secret. The second machine can then connect directly with its own key, no `.pem` needed there.

---

## Repository layout

```
cs2630-remote/
├── install.sh                   # Recommended entry point: installs just the cs2630 CLI
├── install-host.sh              # Host setup (Arch-based Linux, Ubuntu, Intel macOS)
├── install-client.sh            # Remote SSH client setup
├── install-aws.sh               # AWS EC2 fallback (no local VirtualBox needed)
├── bin/
│   └── cs2630                   # Unified CLI helper (see below)
├── scripts/
│   ├── configure-vm-autostart.sh
│   └── verify.sh
├── systemd/
│   └── cs2630-vm.service.template   # Linux autostart
├── launchd/
│   └── cs2630-vm.plist.template     # macOS autostart
└── docs/
    └── AGENT_SETUP.md           # Full design spec
```

---

## `cs2630` CLI helper

`install.sh` and all three of `install-host.sh`/`install-client.sh`/`install-aws.sh` symlink [`bin/cs2630`](bin/cs2630) to `~/.local/bin/cs2630`, giving you one command everywhere:

```bash
cs2630 sh                # ssh cs2630 (or cs2630-aws, depending on your access mode)
cs2630 code <path>       # code --remote ssh-remote+cs2630(-aws) /home/student/<path>
cs2630 poweron           # start the VM — local: hops to the host over SSH if run from a client
                          #                aws: aws ec2 start-instances
cs2630 poweroff          # gracefully stop the VM (ACPI shutdown locally; ec2 stop-instances on AWS)
cs2630 config            # choose which VM cs2630 talks to: AWS, local VirtualBox, or ask every time
cs2630 install host      # ./install-host.sh
cs2630 install client    # ./install-client.sh
cs2630 install aws       # ./install-aws.sh
cs2630 verify            # ./scripts/verify.sh
cs2630 autostart         # ./scripts/configure-vm-autostart.sh
```

If you've set up both a local VM and an AWS instance, `sh`/`code`/`poweron`/`poweroff` need to know which one you mean — `cs2630` asks the first time (AWS, local, or ask-every-time) and remembers your answer in `~/.config/cs2630/access-mode`; change it anytime with `cs2630 config`. If you've only ever set up one path, there's nothing to think about — it's just used automatically once chosen.

`poweron`/`poweroff` in local mode detect whether they're running on the host (VirtualBox present locally) or a remote client; on a client they run the command over `ssh cs2630-host` instead, driving `VBoxManage` directly on whichever OS the host happens to be. Make sure `~/.local/bin` is on your `PATH` — the installers warn if it isn't.

---

## Security notes

- Remote access uses Tailscale; no TCP/22 exposure on the home router.
- SSH private keys never leave their originating client.
- Password auth on the host is disabled only after a public key is confirmed.
- Root SSH login is disabled.
- VM shutdown always uses ACPI (graceful), never a hard power-off.
- No secrets, keys, or credentials are committed to this repository (`.gitignore` excludes `*.pem` and friends).
- The course OVA is not included; treat it as course material.
- The AWS path (`install-aws.sh`) is a different security model by necessity: it opens SSH to `0.0.0.0/0`, matching the course's own AWS instructions, protected only by key-based auth. It asks for explicit confirmation before creating anything.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| `ssh cs2630` times out | `./scripts/verify.sh` — look for FAIL on Tailscale or VM reachability |
| `vboxdrv` not loaded (Linux) | `sudo modprobe vboxdrv` or reboot after kernel headers install |
| VirtualBox error about kernel driver (macOS) | Approve the system extension: System Settings → Privacy & Security → Allow |
| Group change not effective (Linux) | Log out and back in, or reboot |
| VM won't start headless (Linux) | `systemctl --user status cs2630-vm.service` + `journalctl --user -eu cs2630-vm` |
| VM won't start headless (macOS) | `launchctl print gui/$(id -u)/com.cs2630.vm` |
| Tailscale not enrolled | `sudo tailscale up` (Linux) or `tailscale up` (macOS) |
| VirtualBox won't run at all | Apple Silicon Mac or Windows/WSL — not supported locally, use `./install-aws.sh` |
