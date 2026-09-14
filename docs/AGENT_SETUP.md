# Cross-Platform VirtualBox CS2630 Remote-Access Setup

## Goal

Build a reproducible setup around the **course-provided VirtualBox VM**,
independent of what OS the physical/cloud host happens to run:

-   The host can be Arch-based Linux (e.g. CachyOS), Ubuntu, or an Intel
    Mac — the automation detects which and branches accordingly.
-   The CS2630 VM remains on the course-required VirtualBox networking.
-   Tailscale provides private remote connectivity to the host.
-   OpenSSH runs on the host.
-   SSH uses `ProxyJump` so a remote client can reach the VM through the
    host.
-   The VM starts headlessly at host boot/login.
-   The resulting GitHub repository should provide:
    -   a **one-command host installer**
    -   a **one-command SSH-client installer**
-   Do **not** automate importing/configuring the course OVA yet. The
    user is waiting for that download.
-   Scripts must be safe to re-run (idempotent where practical) and must
    not overwrite existing SSH configuration without preserving it.

## Course constraints from `Write A Story!.pdf`

The course requires the supplied Linux environment and specifically
describes VirtualBox with:

-   Adapter 1: **Host-only Adapter / Host-only Network**
-   Host network: `192.168.26.0/24`
-   Host-side address: `192.168.26.1`
-   Netmask: `255.255.255.0`
-   Adapter 2: **NAT**
-   Guest is expected to be reachable over a `192.168.26.X` address.
-   The example static guest address is `192.168.26.3/24`.
-   SSH username is `student`.
-   SSH keys are preferred/acceptable.
-   Be conservative about installing packages **inside the course VM**,
    because the course warns that future assignments can depend on exact
    installed libraries.

The automation in this repository therefore belongs primarily on the
**host machine and remote SSH clients**, not inside the course VM.

------------------------------------------------------------------------

# Target architecture

``` text
Remote client
    |
    | Tailscale private network
    v
Host machine (Arch-based Linux, Ubuntu, or Intel macOS)
    |-- tailscaled
    |-- sshd
    |-- VirtualBox
    |
    | 192.168.26.0/24 host-only network
    v
CS2630 VM
192.168.26.3 (preferred)
student@192.168.26.3
```

The desired remote UX is:

``` bash
ssh cs2630
```

The client SSH configuration should effectively be:

``` sshconfig
Host cs2630-host
    HostName <TAILSCALE_HOSTNAME_OR_IP>
    User <HOST_USER>
    IdentityFile ~/.ssh/id_ed25519

Host cs2630
    HostName 192.168.26.3
    User student
    ProxyJump cs2630-host
    IdentityFile ~/.ssh/id_ed25519
```

Do not expose TCP/22 on the home router merely to make this work.

------------------------------------------------------------------------

# Repository to create

Suggested repository name:

``` text
cs2630-remote
```

Suggested structure:

``` text
cs2630-remote/
├── README.md
├── install-host.sh
├── install-client.sh
├── scripts/
│   ├── configure-vm-autostart.sh
│   └── verify.sh
├── systemd/
│   └── cs2630-vm.service.template
└── docs/
    └── AGENT_SETUP.md
```

This file can become `docs/AGENT_SETUP.md`.

------------------------------------------------------------------------

# Phase 1 --- Host installer (Arch-based Linux)

This phase documents the original, single-OS implementation. Phase 6
below generalizes it to also support Ubuntu and Intel macOS as host
platforms — the Arch/CachyOS behavior described here is unchanged, just
no longer the only path.

Create `install-host.sh`.

It should be executable and intended to run as:

``` bash
curl -fsSL <RAW_GITHUB_URL>/install-host.sh | bash
```

For a safer alternative, README should also show:

``` bash
git clone <REPO_URL>
cd cs2630-remote
./install-host.sh
```

## Host installer responsibilities

### 1. Validate environment

Confirm this is an Arch/CachyOS-like system before changing anything.

Useful checks:

``` bash
test -f /etc/arch-release
command -v pacman
```

Print what will happen before making changes.

Use:

``` bash
set -euo pipefail
```

### 2. Install host dependencies

Install:

``` text
tailscale
openssh
virtualbox
virtualbox-host-dkms
```

Before blindly installing kernel headers, inspect:

``` bash
uname -r
pacman -Q | grep -E 'linux.*headers'
```

CachyOS may use a CachyOS-specific kernel. Determine the correct
installed kernel/header pairing rather than hardcoding `linux-headers`.

If VirtualBox is already installed, do not unnecessarily replace working
packages.

### 3. Enable services

Enable and start:

``` bash
sudo systemctl enable --now tailscaled
sudo systemctl enable --now sshd
```

Check both afterward:

``` bash
systemctl is-active tailscaled
systemctl is-active sshd
```

### 4. Tailscale enrollment

Do not attempt to embed credentials or auth keys in the repository.

If the host is not already enrolled, run:

``` bash
sudo tailscale up
```

Allow Tailscale to display its authentication URL.

After enrollment, display:

``` bash
tailscale status
tailscale ip -4
```

Prefer a stable Tailscale/MagicDNS hostname for generated client
configuration when available; otherwise use the Tailscale IPv4 address.

### 5. SSH host security

The host should use public-key authentication.

Do **not** lock the user out.

Before disabling password authentication, verify that an authorized key
exists for the intended host account.

Prefer a drop-in such as:

``` text
/etc/ssh/sshd_config.d/90-cs2630-remote.conf
```

rather than destructively editing `/etc/ssh/sshd_config`.

A reasonable hardened configuration is:

``` text
PubkeyAuthentication yes
PermitRootLogin no
```

Only set:

``` text
PasswordAuthentication no
```

after confirming usable public-key authentication is configured.

Validate before restart/reload:

``` bash
sudo sshd -t
```

Then reload/restart SSH safely.

### 6. VirtualBox group

Ensure the invoking non-root user is a member of:

``` text
vboxusers
```

For example:

``` bash
sudo usermod -aG vboxusers "$USER"
```

Explain that a logout/login or reboot may be necessary for the group
membership to take effect.

### 7. Do not configure the OVA yet

The installer may detect whether VirtualBox is usable, but it must
**not** invent the course VM name or silently modify arbitrary VMs.

At completion, tell the user that after importing the OVA they should
run:

``` bash
./scripts/configure-vm-autostart.sh
```

------------------------------------------------------------------------

# Phase 2 --- VirtualBox setup

This portion should primarily be documented because the OVA is not
available yet.

The course VM should ultimately have:

``` text
Adapter 1:
    Host-only Adapter / Host-only Network
    network 192.168.26.0/24
    host address 192.168.26.1

Adapter 2:
    NAT
```

Inside the guest, verify:

``` bash
ping google.com
ip addr
```

The preferred guest address for this automation is:

``` text
192.168.26.3
```

If the guest does not automatically acquire the expected host-only
address, follow the course-provided netplan instructions rather than
introducing a different network topology.

Verify from the host machine:

``` bash
ssh student@192.168.26.3
```

Use SSH keys rather than relying on the default `student` password for
routine access.

------------------------------------------------------------------------

# Phase 3 --- VM autostart helper

Create:

``` text
scripts/configure-vm-autostart.sh
```

Do not assume the VM is named `CS2630`.

Enumerate VMs:

``` bash
VBoxManage list vms
```

If there is exactly one plausible VM, show it and request confirmation.
If there are multiple VMs, prompt the user to choose one.

Then create:

``` text
~/.config/systemd/user/cs2630-vm.service
```

from a template.

Template:

``` ini
[Unit]
Description=CS2630 VirtualBox VM
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/VBoxManage startvm "__VM_NAME__" --type headless
ExecStop=/usr/bin/VBoxManage controlvm "__VM_NAME__" acpipowerbutton
TimeoutStopSec=120

[Install]
WantedBy=default.target
```

Escape/validate the VM name appropriately.

Then:

``` bash
systemctl --user daemon-reload
systemctl --user enable cs2630-vm.service
sudo loginctl enable-linger "$USER"
```

Do not automatically start the VM if doing so could conflict with an
already-running GUI instance. Detect state first:

``` bash
VBoxManage list runningvms
```

The helper should provide a verification command:

``` bash
systemctl --user status cs2630-vm.service
```

and:

``` bash
VBoxManage list runningvms
```

The course warns about clean VM shutdowns, so use an ACPI shutdown
rather than forcibly powering off the guest.

------------------------------------------------------------------------

# Phase 4 --- Client installer

Create:

``` text
install-client.sh
```

This is for a Linux/macOS machine from which the user wants to SSH.

Desired invocation:

``` bash
curl -fsSL <RAW_GITHUB_URL>/install-client.sh | bash
```

However, because a piped script cannot interactively modify things
recklessly, design it carefully and document the clone-and-run
alternative.

## Client installer responsibilities

### 1. Check SSH

Require:

``` bash
ssh
```

### 2. Ensure an SSH key exists

Prefer:

``` text
~/.ssh/id_ed25519
```

If no suitable key exists, offer to create one:

``` bash
ssh-keygen -t ed25519
```

Never overwrite an existing private key.

Set correct permissions:

``` bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/config
```

as applicable.

### 3. Gather host parameters

The installer needs:

``` text
Host machine's Tailscale hostname/IP
Host machine username
VM IP (default: 192.168.26.3)
VM username (default: student)
```

Support both interactive flags and environment variables so an agent can
run it unattended.

Example:

``` bash
HOST_ADDR=myhost.tailnet-name.ts.net \
HOST_USER=alice \
VM_HOST=192.168.26.3 \
VM_USER=student \
./install-client.sh
```

### 4. Preserve existing SSH config

Do not replace `~/.ssh/config`.

Prefer generating:

``` text
~/.ssh/config.d/cs2630.conf
```

and ensure the main config contains:

``` text
Include ~/.ssh/config.d/*
```

If adding the Include directive, make a timestamped backup first.

Generated configuration:

``` sshconfig
Host cs2630-host
    HostName __HOST_ADDR__
    User __HOST_USER__
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes

Host cs2630
    HostName __VM_HOST__
    User __VM_USER__
    ProxyJump cs2630-host
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

Validate the effective configuration using:

``` bash
ssh -G cs2630
```

### 5. Key installation

The public key needs to be authorized on:

1.  The host machine
2.  CS2630 guest

Do not copy a private key anywhere.

For the host, the installer can use:

``` bash
ssh-copy-id <HOST_USER>@<HOST_ADDR>
```

when available.

For the guest, after host connectivity works:

``` bash
ssh-copy-id -o ProxyJump=cs2630-host student@192.168.26.3
```

If `ssh-copy-id` is unavailable (e.g. some macOS installations),
implement/document a safe fallback that appends the **public** key to
`~/.ssh/authorized_keys` remotely.

The script should not disable password auth until key authentication has
been tested.

### 6. Verification

Test host:

``` bash
ssh -o BatchMode=yes cs2630-host true
```

Then VM:

``` bash
ssh -o BatchMode=yes cs2630 true
```

On success print:

``` text
Setup complete.

Connect to the host:
    ssh cs2630-host

Connect directly to CS2630 through the host:
    ssh cs2630
```

------------------------------------------------------------------------

# Phase 5 --- Verification script

Create:

``` text
scripts/verify.sh
```

It should report, rather than silently change, the state of:

``` text
tailscaled
sshd
Tailscale IP/status
VirtualBox installation
VirtualBox kernel modules
vboxusers membership
known VMs
running VMs
cs2630-vm.service
192.168.26.3 reachability
SSH reachability to student@192.168.26.3
```

Use clear PASS/WARN/FAIL output.

Do not require VM checks to pass before the OVA has been imported.

------------------------------------------------------------------------

# Phase 6 --- Multi-OS host support + AWS fallback

This phase was added after the initial build. The host role no longer
assumes CachyOS specifically, and a separate cloud fallback was added for
platforms where a local VirtualBox host isn't practical.

## Motivation

-   `install-host.sh` originally hard-required `/etc/arch-release` +
    `pacman`. The host machine should also be allowed to be **Ubuntu**
    (native, apt-based) or an **Intel Mac** (Homebrew-based) — Arch/CachyOS
    support is unchanged, not replaced.
-   **Apple Silicon (arm64) Macs cannot host VirtualBox** — Oracle ships no
    official arm64 build. `install-host.sh` must detect this and fail with
    a clear explanation rather than attempting an install.
-   **Windows/WSL is out of scope as a local VirtualBox host.** VirtualBox
    cannot load its kernel driver inside a WSL2 guest, so there is no
    working "Ubuntu via WSL" story. Route Windows users to the AWS fallback
    instead of building a native Windows installer.
-   The course itself documents an AWS EC2 fallback for students whose
    laptop can't run the VM locally. Automating that (rather than forcing
    local virtualization to work everywhere) is the practical answer for
    Windows and Apple Silicon Macs.

## `install-host.sh`: OS detection

Detect the OS before any phase runs, and branch each phase on the result:

``` bash
detect_os() {
    case "$(uname -s)" in
        Linux)
            [[ -f /etc/arch-release ]] && { echo arch; return; }
            grep -q '^ID=ubuntu' /etc/os-release 2>/dev/null && { echo ubuntu; return; }
            fail "Unsupported Linux distro. Supports Arch/CachyOS and Ubuntu. Try ./install-aws.sh."
            ;;
        Darwin)
            [[ "$(uname -m)" == arm64 ]] && fail "Apple Silicon can't host VirtualBox. Try ./install-aws.sh."
            echo macos
            ;;
        *) fail "Unsupported OS. Try ./install-aws.sh." ;;
    esac
}
```

Per-OS differences that matter, phase by phase:

-   **Tailscale install**: Arch keeps its native `pacman` package as the
    fast path; Ubuntu and macOS reuse the same Tailscale-detection/install
    logic already proven in `install-client.sh`
    (`find_tailscale()` + `tailscale.com/install.sh` on Linux, Homebrew
    cask on macOS) — don't reinvent it, lift it.
-   **Packages**: Arch keeps its existing kernel-header-detection logic
    verbatim. Ubuntu installs `openssh-server virtualbox virtualbox-dkms
    linux-headers-$(uname -r)` via `apt`. macOS installs
    `--cask virtualbox` via Homebrew — no headers/dkms concept, but macOS
    requires a one-time **manual** system-extension approval in System
    Settings before `VBoxManage` works; this cannot be scripted, only
    explained clearly (`warn()` + point at `./scripts/verify.sh`).
-   **Services**: Arch's sshd unit is `sshd`; Debian/Ubuntu's is `ssh`.
    macOS has no systemd — enable Remote Login via
    `sudo systemsetup -setremotelogin on`, reload via
    `sudo launchctl kickstart -k system/com.openssh.sshd`.
-   **sshd_config.d Include**: Arch/Ubuntu's packaged `sshd_config` already
    includes `sshd_config.d/*.conf`; macOS's does not by default — check
    and add it (with a timestamped backup) before relying on the drop-in.
-   **vboxusers group**: Linux only (Arch/Ubuntu); skip entirely on macOS,
    which has no such group.

## `scripts/configure-vm-autostart.sh`: launchd on macOS

Linux keeps the existing systemd `--user` service. macOS gets a
`~/Library/LaunchAgents/com.cs2630.vm.plist` LaunchAgent, generated from
`launchd/cs2630-vm.plist.template` with the same `__VM_NAME__`
substitution pattern as the systemd template, loaded via
`launchctl bootstrap gui/$(id -u) <plist>` + `launchctl enable`.

Both branches additionally persist the chosen VM name to
`~/.config/cs2630/vm-name` — this is what lets `bin/cs2630` drive
`VBoxManage` directly (see below) instead of depending on whichever
service manager the host happens to use.

## `bin/cs2630`: direct VBoxManage control

`poweron`/`poweroff` no longer go through `systemctl --user
start/stop cs2630-vm.service`. They read `~/.config/cs2630/vm-name` on
the host (hopping over SSH via `run_on_host` if invoked from a client, as
before) and call `VBoxManage startvm`/`controlvm ... acpipowerbutton`
directly. `VBoxManage` itself is already cross-platform, so this one
change makes on-demand power control work identically on Linux and macOS
— only "start automatically at login" remains OS-specific
(systemd vs. launchd).

## `scripts/verify.sh`: OS-aware checks

Branch on `uname -s`. On Linux: detect whether the sshd unit is named
`sshd` or `ssh` (`systemctl cat sshd.service` — success means `sshd`),
keep the `lsmod`/`vboxusers` checks. On macOS: check sshd via
`nc -z -G2 localhost 22` (unprivileged — `systemsetup -getremotelogin`
needs root), skip the kernel-module/vboxusers checks (no equivalent) and
instead run `VBoxManage list hostinfo`, checking its stderr for a
"kernel driver not installed" style message to catch the un-approved
system-extension case. Tailscale's own health is already covered by the
dedicated Tailscale section (`tailscale status`) for every OS — don't
duplicate it with a process-name check, since the daemon's process name
varies by install method (confirmed empirically: macOS's cask install
runs `io.tailscale.ipn.macsys.network-extension`, not a plain
`tailscaled`).

## `install-aws.sh`: AWS EC2 fallback

A new, separate script — not a variant of `install-host.sh`, since the
architecture is fundamentally different (no host/guest split, no
Tailscale, no `ProxyJump`; just a direct SSH connection to a public EC2
instance). Automates the course's own documented AWS setup end-to-end:

1.  **Prereqs**: `aws` CLI present, `aws sts get-caller-identity`
    succeeds (credentials configured).
2.  **Confirm consequences**: explicitly state this creates a real,
    billable EC2 instance and a security group open to SSH from
    `0.0.0.0/0` (matching the course's own instructions) — default-no
    confirmation prompt before creating anything.
3.  **Key pair**: `aws ec2 create-key-pair` if one doesn't already exist
    for this key name; save the `.pem` under `~/.ssh/`, `chmod 400`. Never
    silently overwrite a local `.pem` or an AWS-side key pair.
4.  **Security group**: create-if-missing, authorize inbound tcp/22 from
    `0.0.0.0/0`.
5.  **Launch**: default region `us-east-1`, default AMI the course-provided
    community AMI, default instance type `t3.micro`, 16GB gp2 root volume
    — look up the AMI's actual root device name via `describe-images`
    rather than hardcoding `/dev/sda1`. Reuse/restart an existing tagged
    instance instead of creating duplicates on re-run.
6.  **Wait** for `instance-running`, then for SSH to actually answer
    (retry loop, matches the course docs' "wait a few minutes").
7.  **Install packages**: pipe the exact course-documented sequence over
    SSH as one script — i386 multiarch, Node.js 24.x via nodesource, the
    pinned `libc6` version, Python 2/3, `pip2 install sqlalchemy flask`.
    Preserve the course's literal command order (including the pinned
    package versions) rather than "improving" it — it's copied from the
    course's own tested instructions.
8.  **SSH alias**: write `~/.ssh/config.d/cs2630-aws.conf` (`Host
    cs2630-aws`), reusing the same Include-directive-preserving pattern
    already used for `cs2630.conf` elsewhere in this repo.
9.  **Summary**: print the connect command
    (`ssh -A -L 8080:localhost:8080 cs2630-aws`, matching the course docs
    exactly) and the `stop-instances`/`terminate-instances` commands to
    clean up — note that stopping/restarting reassigns a new public DNS
    name, so re-running the script refreshes the SSH alias.

`bin/cs2630 install aws` execs this script, alongside the existing
`install host`/`install client`.

------------------------------------------------------------------------

# README

README should make the normal workflow obvious.

## Host

After reviewing the script:

``` bash
curl -fsSL <RAW_GITHUB_URL>/install-host.sh | bash
```

Then import/configure the OVA manually according to the course
instructions.

Then:

``` bash
git clone <REPO_URL>
cd cs2630-remote
./scripts/configure-vm-autostart.sh
./scripts/verify.sh
```

## Remote client

After reviewing the script:

``` bash
curl -fsSL <RAW_GITHUB_URL>/install-client.sh | bash
```

After successful setup:

``` bash
ssh cs2630
```

------------------------------------------------------------------------

# GitHub repository requirements

Initialize Git:

``` bash
git init
git add .
git commit -m "Initial CS2630 remote access setup"
```

Create a GitHub repository named:

``` text
cs2630-remote
```

Prefer a **private repository initially**, because this is
machine/network configuration. The repository must contain no:

-   private SSH keys
-   Tailscale auth keys
-   passwords
-   GitHub tokens
-   `.pem` credentials
-   machine-specific secrets

Include a `.gitignore` that defensively ignores:

``` gitignore
*.pem
*.key
id_rsa
id_rsa.*
id_ed25519
id_ed25519.*
.env
.env.*
secrets/
```

Do not commit the course OVA unless the course explicitly permits
redistribution. Treat the supplied VM image as course material, not
repository content.

Use GitHub CLI if already installed/authenticated:

``` bash
gh auth status
gh repo create cs2630-remote --private --source=. --remote=origin --push
```

If `gh` is unavailable or unauthenticated, stop at the local Git
repository and give the user the exact next action rather than embedding
credentials.

------------------------------------------------------------------------

# Security invariants

The implementation must preserve these properties:

1.  **No public router SSH port-forward is required.**
2.  Remote access to the host occurs through Tailscale.
3.  SSH private keys never leave their originating client.
4.  Password authentication on the host is disabled only after key access
    has been verified.
5.  Root SSH login is disabled.
6.  Existing SSH configuration is backed up/preserved.
7.  Scripts are safe to re-run.
8.  No Tailscale, GitHub, or SSH secrets are committed.
9.  The course VM is not polluted with unnecessary packages.
10. The VirtualBox network remains compatible with the course's
    `192.168.26.0/24` host-only + NAT design.
11. VM shutdown uses ACPI/graceful shutdown, not `poweroff`/hard
    power-off through VirtualBox.
12. Every destructive or potentially connectivity-breaking action should
    either require confirmation or have a rollback path.

------------------------------------------------------------------------

# Agent acceptance criteria

Do not consider the project complete until these applicable checks pass.

On a Linux host (Arch-based or Ubuntu):

``` bash
systemctl is-active tailscaled
systemctl is-enabled tailscaled
systemctl is-active sshd
systemctl is-enabled sshd
tailscale status
VBoxManage --version
```

(On a macOS host, the equivalent checks are `tailscale status`, `sudo systemsetup -getremotelogin`, and `VBoxManage --version` — see `scripts/verify.sh`.)

After the OVA is available/configured:

``` bash
VBoxManage list vms
VBoxManage list runningvms
systemctl --user status cs2630-vm.service
ssh student@192.168.26.3 true
```

On a configured remote client:

``` bash
ssh -G cs2630
ssh -o BatchMode=yes cs2630-host true
ssh -o BatchMode=yes cs2630 true
```

The final user experience must be:

``` bash
ssh cs2630
```

from a Tailscale-connected remote client.

------------------------------------------------------------------------

# Important implementation note

Do not blindly optimize for a literal one-line installer at the expense
of security. The one-line commands are entry points; enrollment,
first-time key authorization, and VirtualBox OVA import may legitimately
require interactive steps.

The scripts should print exactly what remains to be done when an
interactive dependency prevents full automation.
