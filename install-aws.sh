#!/usr/bin/env bash
# AWS EC2 fallback: automates the course's own documented "AWS setup" path
# for students whose laptop can't (or shouldn't) run VirtualBox locally —
# Windows, Apple Silicon Macs, or an underpowered machine. Provisions a
# free-tier-eligible EC2 instance from the course-provided AMI, waits for it
# to boot, and installs the same software the course VM ships with.
#
# Safe to re-run — reuses an existing key pair / security group / instance
# instead of creating duplicates — but DOES create real, billable AWS
# resources on your account. See the confirmation prompt below.

set -euo pipefail

###############################################################################
# Helpers
###############################################################################

info()  { printf '\e[1;34m[INFO]\e[0m  %s\n' "$*"; }
warn()  { printf '\e[1;33m[WARN]\e[0m  %s\n' "$*"; }
ok()    { printf '\e[1;32m[ OK ]\e[0m  %s\n' "$*"; }
fail()  { printf '\e[1;31m[FAIL]\e[0m  %s\n' "$*" >&2; exit 1; }
ask()   { printf '\e[1;36m[ ?? ]\e[0m  %s [y/N] ' "$*" >/dev/tty; read -r _ans </dev/tty; [[ "$_ans" =~ ^[Yy]$ ]]; }

###############################################################################
# Parameters (override via environment variables for unattended use)
###############################################################################

AWS_REGION="${AWS_REGION:-us-east-1}"
COURSE_AMI_ID="${COURSE_AMI_ID:-ami-00a23c404b272db44}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
VOLUME_SIZE_GB="${VOLUME_SIZE_GB:-16}"
KEY_NAME="${KEY_NAME:-cs2630-$(whoami)}"
SG_NAME="${SG_NAME:-cs2630-aws-sg}"
INSTANCE_TAG="${INSTANCE_TAG:-cs2630-aws}"
VM_USER="${VM_USER:-student}"

AWS=(aws --region "$AWS_REGION")

if [[ "$AWS_REGION" != "us-east-1" ]]; then
    warn "AWS_REGION is set to '$AWS_REGION'. The course AMI ($COURSE_AMI_ID) is a us-east-1"
    warn "community AMI and likely won't exist in other regions unless you've copied it there."
fi

###############################################################################
# Phase 1: Prerequisites
###############################################################################

info "Checking AWS CLI..."
command -v aws &>/dev/null || fail "AWS CLI not found. Install it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
ok "AWS CLI found."

info "Checking AWS credentials..."
ACCOUNT_ID="$("${AWS[@]}" sts get-caller-identity --query Account --output text 2>/dev/null)" \
    || fail "AWS credentials not configured or invalid. Run: aws configure"
ok "Authenticated to AWS account: $ACCOUNT_ID (region: $AWS_REGION)"

###############################################################################
# Phase 2: Confirm cost/consequences
###############################################################################

warn "This will create REAL AWS resources on account $ACCOUNT_ID:"
warn "  - One $INSTANCE_TYPE EC2 instance (usually free-tier eligible, but still billable)"
warn "  - A ${VOLUME_SIZE_GB}GB gp2 EBS volume"
warn "  - A security group allowing inbound SSH (port 22) from 0.0.0.0/0 — anywhere on the internet"
warn "This mirrors the course's own AWS setup instructions. You are responsible for any AWS"
warn "charges and for stopping/terminating the instance when done (the summary below shows how)."
ask "Proceed?" || fail "Aborted by user."

###############################################################################
# Phase 3: SSH key pair
###############################################################################

PEM_FILE="$HOME/.ssh/$KEY_NAME.pem"

info "Checking for existing key pair: $KEY_NAME..."
if "${AWS[@]}" ec2 describe-key-pairs --key-names "$KEY_NAME" &>/dev/null; then
    ok "Key pair '$KEY_NAME' already exists in AWS."
    if [[ ! -f "$PEM_FILE" ]]; then
        fail "AWS has key pair '$KEY_NAME' but no local .pem was found at $PEM_FILE (AWS never re-exports
private key material). Delete the AWS-side key pair and re-run to generate a new one:
  aws ec2 delete-key-pair --key-name $KEY_NAME --region $AWS_REGION"
    fi
else
    [[ -f "$PEM_FILE" ]] && fail "$PEM_FILE already exists locally but AWS has no such key pair. Refusing to overwrite — remove it or set KEY_NAME to something else."
    info "Creating key pair '$KEY_NAME'..."
    "${AWS[@]}" ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "$PEM_FILE"
    chmod 400 "$PEM_FILE"
    ok "Key pair created and saved: $PEM_FILE"
fi

###############################################################################
# Phase 4: Security group
###############################################################################

info "Checking for existing security group: $SG_NAME..."
SG_ID="$("${AWS[@]}" ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"

if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
    ok "Security group already exists: $SG_ID"
else
    info "Creating security group '$SG_NAME'..."
    VPC_ID="$("${AWS[@]}" ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
    [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] || fail "No default VPC found in $AWS_REGION. Create one first, or set up a VPC manually."
    SG_ID="$("${AWS[@]}" ec2 create-security-group --group-name "$SG_NAME" \
        --description "CS2630 AWS fallback: SSH access" --vpc-id "$VPC_ID" \
        --query 'GroupId' --output text)"
    "${AWS[@]}" ec2 authorize-security-group-ingress --group-id "$SG_ID" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
    ok "Security group created: $SG_ID (SSH open to 0.0.0.0/0, matching the course's own instructions)"
fi

###############################################################################
# Phase 5: Launch (or reuse/restart) the instance
###############################################################################

info "Checking for an existing '$INSTANCE_TAG' instance..."
INSTANCE_ID="$("${AWS[@]}" ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_TAG" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"

if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
    ok "Found existing instance: $INSTANCE_ID"
    STATE="$("${AWS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' --output text)"
    if [[ "$STATE" == "stopped" ]]; then
        info "Instance is stopped. Starting it..."
        "${AWS[@]}" ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
    fi
else
    info "Looking up the root device name for AMI $COURSE_AMI_ID..."
    ROOT_DEVICE="$("${AWS[@]}" ec2 describe-images --image-ids "$COURSE_AMI_ID" \
        --query 'Images[0].BlockDeviceMappings[0].DeviceName' --output text 2>/dev/null || true)"
    [[ -n "$ROOT_DEVICE" && "$ROOT_DEVICE" != "None" ]] || fail "Could not find AMI $COURSE_AMI_ID in $AWS_REGION."

    info "Launching $INSTANCE_TYPE instance from $COURSE_AMI_ID..."
    INSTANCE_ID="$("${AWS[@]}" ec2 run-instances \
        --image-id "$COURSE_AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SG_ID" \
        --block-device-mappings "[{\"DeviceName\":\"$ROOT_DEVICE\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE_GB,\"VolumeType\":\"gp2\"}}]" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_TAG}]" \
        --query 'Instances[0].InstanceId' --output text)"
    ok "Instance launched: $INSTANCE_ID"
fi

###############################################################################
# Phase 6: Wait for the instance to boot
###############################################################################

info "Waiting for the instance to enter 'running' state..."
"${AWS[@]}" ec2 wait instance-running --instance-ids "$INSTANCE_ID"
ok "Instance is running."

PUBLIC_DNS="$("${AWS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicDnsName' --output text)"
[[ -n "$PUBLIC_DNS" && "$PUBLIC_DNS" != "None" ]] \
    || fail "Instance has no public DNS name. Check that its subnet has auto-assign public IP enabled."
ok "Public DNS: $PUBLIC_DNS"

###############################################################################
# Phase 7: Wait for SSH to come up
###############################################################################

info "Waiting for SSH to become reachable (can take a minute or two after boot)..."
SSH_READY=false
for _ in $(seq 1 30); do
    if ssh -i "$PEM_FILE" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
           "${VM_USER}@${PUBLIC_DNS}" true 2>/dev/null; then
        SSH_READY=true
        break
    fi
    sleep 10
done
$SSH_READY || fail "SSH did not become reachable after 5 minutes. Check the instance status in the AWS console."
ok "SSH is reachable."

###############################################################################
# Phase 8: Install course software packages
###############################################################################

info "Installing course software packages on the instance (takes a few minutes)..."
if ssh -i "$PEM_FILE" -o StrictHostKeyChecking=accept-new "${VM_USER}@${PUBLIC_DNS}" 'bash -s' <<'REMOTE'
set -euo pipefail
sudo dpkg --add-architecture i386
sudo rm -f /etc/apt/sources.list.d/nodesource.list
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs
sudo apt update
sudo apt install -y libc6=2.35-0ubuntu3.14 libc6:i386=2.35-0ubuntu3.14
sudo apt install --assume-yes execstack libc6-dev-i386 libssl-dev:i386 python2 python3 python-pip
pip2 install sqlalchemy flask
REMOTE
then
    ok "Course software installed."
else
    warn "Package installation failed partway through (the pinned package versions in this script"
    warn "come from the course's own docs and may have since changed). SSH in and finish manually:"
    warn "  ssh -i $PEM_FILE ${VM_USER}@${PUBLIC_DNS}"
fi

###############################################################################
# Phase 9: SSH config alias
###############################################################################

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
SSH_CONFIG_D="$SSH_DIR/config.d"
AWS_CONF="$SSH_CONFIG_D/cs2630-aws.conf"

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

info "Writing $AWS_CONF..."
cat > "$AWS_CONF" <<EOF
Host cs2630-aws
    HostName $PUBLIC_DNS
    User $VM_USER
    IdentityFile $PEM_FILE
    IdentitiesOnly yes
    ForwardAgent yes
EOF
chmod 600 "$AWS_CONF"
ok "SSH alias written: cs2630-aws -> ${VM_USER}@${PUBLIC_DNS}"

###############################################################################
# Summary
###############################################################################

printf '\n'
printf '=%.0s' {1..70}
printf '\n'
ok "AWS instance ready."
printf '\n'
info "Instance ID:  $INSTANCE_ID"
info "Public DNS:   $PUBLIC_DNS"
info "SSH key:      $PEM_FILE"
printf '\n'
info "Connect (matches the course's own AWS instructions):"
info "    ssh -A -L 8080:localhost:8080 cs2630-aws"
printf '\n'
warn "This is a real, billable AWS resource. When you're done with it:"
warn "  Stop (keep, restartable):   aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $AWS_REGION"
warn "  Terminate (delete for good): aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $AWS_REGION"
warn "Stopping/restarting assigns a new public DNS name — re-run this script afterward to refresh"
warn "the cs2630-aws SSH alias."
