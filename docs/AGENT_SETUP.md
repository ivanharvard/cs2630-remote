# CachyOS + VirtualBox CS263 Remote-Access Setup

## Goal

Build a reproducible setup around the **course-provided VirtualBox VM**:

-   CachyOS is the physical host.
-   The CS263 VM remains on the course-required VirtualBox networking.
-   Tailscale provides private remote connectivity to the CachyOS host.
-   OpenSSH runs on the CachyOS host.
-   SSH uses `ProxyJump` so a remote client can reach the VM through the
    CachyOS host.
-   The VM starts headlessly at CachyOS boot.
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
**CachyOS host and remote SSH clients**, not inside the course VM.

------------------------------------------------------------------------

# Target architecture

``` text
Remote client
    |
    | Tailscale private network
    v
CachyOS host
    |-- tailscaled
    |-- sshd
    |-- VirtualBox
    |
    | 192.168.26.0/24 host-only network
    v
CS263 VM
192.168.26.3 (preferred)
student@192.168.26.3
```

The desired remote UX is:

``` bash
ssh cs263
```

The client SSH configuration should effectively be:

``` sshconfig
Host cachyos-home
    HostName <TAILSCALE_HOSTNAME_OR_IP>
    User <CACHYOS_USER>
    IdentityFile ~/.ssh/id_ed25519

Host cs263
    HostName 192.168.26.3
    User student
    ProxyJump cachyos-home
    IdentityFile ~/.ssh/id_ed25519
```

Do not expose TCP/22 on the home router merely to make this work.

------------------------------------------------------------------------

# Repository to create

Suggested repository name:

``` text
cachyos-cs263-remote
```

Suggested structure:

``` text
cachyos-cs263-remote/
├── README.md
├── install-host.sh
├── install-client.sh
├── scripts/
│   ├── configure-vm-autostart.sh
│   └── verify.sh
├── systemd/
│   └── cs263-vm.service.template
└── docs/
    └── AGENT_SETUP.md
```

This file can become `docs/AGENT_SETUP.md`.

------------------------------------------------------------------------

# Phase 1 --- CachyOS host installer

Create `install-host.sh`.

It should be executable and intended to run as:

``` bash
curl -fsSL <RAW_GITHUB_URL>/install-host.sh | bash
```

For a safer alternative, README should also show:

``` bash
git clone <REPO_URL>
cd cachyos-cs263-remote
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
exists for the intended CachyOS account.

Prefer a drop-in such as:

``` text
/etc/ssh/sshd_config.d/90-cs263-remote.conf
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

Verify from CachyOS:

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

Do not assume the VM is named `CS263`.

Enumerate VMs:

``` bash
VBoxManage list vms
```

If there is exactly one plausible VM, show it and request confirmation.
If there are multiple VMs, prompt the user to choose one.

Then create:

``` text
~/.config/systemd/user/cs263-vm.service
```

from a template.

Template:

``` ini
[Unit]
Description=CS263 VirtualBox VM
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
systemctl --user enable cs263-vm.service
sudo loginctl enable-linger "$USER"
```

Do not automatically start the VM if doing so could conflict with an
already-running GUI instance. Detect state first:

``` bash
VBoxManage list runningvms
```

The helper should provide a verification command:

``` bash
systemctl --user status cs263-vm.service
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
CachyOS Tailscale hostname/IP
CachyOS username
VM IP (default: 192.168.26.3)
VM username (default: student)
```

Support both interactive flags and environment variables so an agent can
run it unattended.

Example:

``` bash
CACHYOS_HOST=myhost.tailnet-name.ts.net \
CACHYOS_USER=alice \
VM_HOST=192.168.26.3 \
VM_USER=student \
./install-client.sh
```

### 4. Preserve existing SSH config

Do not replace `~/.ssh/config`.

Prefer generating:

``` text
~/.ssh/config.d/cs263.conf
```

and ensure the main config contains:

``` text
Include ~/.ssh/config.d/*
```

If adding the Include directive, make a timestamped backup first.

Generated configuration:

``` sshconfig
Host cachyos-home
    HostName __CACHYOS_HOST__
    User __CACHYOS_USER__
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes

Host cs263
    HostName __VM_HOST__
    User __VM_USER__
    ProxyJump cachyos-home
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

Validate the effective configuration using:

``` bash
ssh -G cs263
```

### 5. Key installation

The public key needs to be authorized on:

1.  CachyOS host
2.  CS263 guest

Do not copy a private key anywhere.

For the host, the installer can use:

``` bash
ssh-copy-id <CACHYOS_USER>@<CACHYOS_HOST>
```

when available.

For the guest, after host connectivity works:

``` bash
ssh-copy-id -o ProxyJump=cachyos-home student@192.168.26.3
```

If `ssh-copy-id` is unavailable (e.g. some macOS installations),
implement/document a safe fallback that appends the **public** key to
`~/.ssh/authorized_keys` remotely.

The script should not disable password auth until key authentication has
been tested.

### 6. Verification

Test host:

``` bash
ssh -o BatchMode=yes cachyos-home true
```

Then VM:

``` bash
ssh -o BatchMode=yes cs263 true
```

On success print:

``` text
Setup complete.

Connect to the host:
    ssh cachyos-home

Connect directly to CS263 through the host:
    ssh cs263
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
cs263-vm.service
192.168.26.3 reachability
SSH reachability to student@192.168.26.3
```

Use clear PASS/WARN/FAIL output.

Do not require VM checks to pass before the OVA has been imported.

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
cd cachyos-cs263-remote
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
ssh cs263
```

------------------------------------------------------------------------

# GitHub repository requirements

Initialize Git:

``` bash
git init
git add .
git commit -m "Initial CachyOS CS263 remote access setup"
```

Create a GitHub repository named:

``` text
cachyos-cs263-remote
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
gh repo create cachyos-cs263-remote --private --source=. --remote=origin --push
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
4.  Password authentication on CachyOS is disabled only after key access
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

On CachyOS:

``` bash
systemctl is-active tailscaled
systemctl is-enabled tailscaled
systemctl is-active sshd
systemctl is-enabled sshd
tailscale status
VBoxManage --version
```

After the OVA is available/configured:

``` bash
VBoxManage list vms
VBoxManage list runningvms
systemctl --user status cs263-vm.service
ssh student@192.168.26.3 true
```

On a configured remote client:

``` bash
ssh -G cs263
ssh -o BatchMode=yes cachyos-home true
ssh -o BatchMode=yes cs263 true
```

The final user experience must be:

``` bash
ssh cs263
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
