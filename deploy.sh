#!/usr/bin/env bash
#set -euo pipefail

# =========================
# CONFIG (edit these)
# =========================
AWS_REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-enterprise-web-platform}"
KEY_NAME="${KEY_NAME:-enterprise-key}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"

# REQUIRED: set your email (SNS subscription)
ALERT_EMAIL="${ALERT_EMAIL:-you@example.com}"

# Optional: My IP CIDR for SSH
MY_IP_CIDR="${MY_IP_CIDR:-$(curl -s ifconfig.me)/32}"

# Paths (as you provided)
PACKER_DIR="packer"
PACKER_TEMPLATE="packer/web-ami.pkr.hcl"
CFN_TEMPLATE="infra/cloudformation/main.yaml"

# =========================
# Helpers
# =========================
log() { echo -e "\n=== $* ==="; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }
}

stack_exists() {
  aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK_NAME" >/dev/null 2>&1
}

stack_status() {
  aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK_NAME" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null || true
}

wait_stack() {
  # cloudformation deploy can create or update
  # wait for either create-complete or update-complete
  if aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK_NAME" >/dev/null 2>&1; then
    local status
    status="$(stack_status)"
    if [[ "$status" == *"IN_PROGRESS"* ]]; then
      log "Waiting for stack to finish (current: $status)"
    fi
    # try update waiter first (if it fails, try create waiter)
    aws cloudformation wait stack-update-complete --region "$AWS_REGION" --stack-name "$STACK_NAME" 2>/dev/null \
      || aws cloudformation wait stack-create-complete --region "$AWS_REGION" --stack-name "$STACK_NAME"
  fi
}

get_output() {
  local key="$1"
  aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue | [0]" --output text
}

get_asg_name() {
  aws cloudformation describe-stack-resource --region "$AWS_REGION" \
    --stack-name "$STACK_NAME" \
    --logical-resource-id AutoScalingGroup \
    --query "StackResourceDetail.PhysicalResourceId" \
    --output text
}

# =========================
# Preflight
# =========================
require_cmd aws
require_cmd packer
require_cmd curl

log "Using region=$AWS_REGION stack=$STACK_NAME instance_type=$INSTANCE_TYPE key=$KEY_NAME"

if [[ "$ALERT_EMAIL" == "you@example.com" ]]; then
  echo "ERROR: Set ALERT_EMAIL env var (example: export ALERT_EMAIL='me@gmail.com')"
  exit 1
fi

# =========================
# Step 1) Build AMI with Packer
# =========================
AMI_NAME="enterprise-web-ami-$(date +%Y%m%d%H%M%S)"

log "Packer init"
( cd "$PACKER_DIR" && packer init . )

log "Packer build (AMI name: $AMI_NAME)"
( cd "$PACKER_DIR" && packer build \
  -var "aws_region=${AWS_REGION}" \
  -var "ami_name=${AMI_NAME}" \
  "$(basename "$PACKER_TEMPLATE")"
)

# =========================
# Step 2) Find the AMI ID we just created
# =========================
log "Finding new AMI ID by name: $AMI_NAME"
NEW_AMI_ID="$(aws ec2 describe-images --region "$AWS_REGION" --owners self \
  --filters "Name=name,Values=${AMI_NAME}" \
  --query "Images[0].ImageId" --output text)"

if [[ -z "$NEW_AMI_ID" || "$NEW_AMI_ID" == "None" ]]; then
  echo "ERROR: Could not find AMI by name '$AMI_NAME'"
  exit 1
fi

log "New AMI ID: $NEW_AMI_ID"

# =========================
# Step 3) Deploy CloudFormation with the new AMI
# =========================
log "Deploy CloudFormation stack (create/update) with new AMI"
aws cloudformation deploy --region "$AWS_REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$CFN_TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    AmiId="$NEW_AMI_ID" \
    InstanceType="$INSTANCE_TYPE" \
    KeyName="$KEY_NAME" \
    AlertEmail="$ALERT_EMAIL" \
    MyIpCidr="$MY_IP_CIDR"

log "Waiting for stack completion"
wait_stack

# =========================
# Step 4) Force ASG to roll to new Launch Template / AMI
# =========================
ASG_NAME="$(get_asg_name || true)"
log "ASG Name: $ASG_NAME"

# Start instance refresh (best way)
log "Starting ASG Instance Refresh to replace instances with the new AMI"
aws autoscaling start-instance-refresh --region "$AWS_REGION" \
  --auto-scaling-group-name "$ASG_NAME" \
  --preferences MinHealthyPercentage=50,InstanceWarmup=120 >/dev/null

# =========================
# Step 5) Test ALB endpoint
# =========================
ALB_DNS="$(get_output AlbDnsName)"
log "ALB DNS: $ALB_DNS"

log "Testing /health"
curl -i "http://$ALB_DNS/health" || true

log "Testing /"
curl -i "http://$ALB_DNS/" || true

log "DONE ✅"
echo "If you still see 403, it means nginx root and artifact layout still mismatch."
echo "Next check: what file exists on instances (/var/www/html/index.html vs /var/www/html/dist/index.html)."
