#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Check whether the current AWS credentials have the minimum permissions
needed for the direct-SSH GitHub Actions repro workflow.

Usage:
  check-aws-repro-permissions.sh --region REGION --subnet-id SUBNET_ID [options]

Options:
  --region REGION            AWS region to test
  --subnet-id SUBNET_ID      Public subnet ID to use for dry-run launch
  --instance-type TYPE       EC2 instance type to test (default: t3.micro)
  --source-ami AMI_ID        Source AMI to test. If omitted, resolves latest
                             Amazon Linux 2023 x86_64 in the region.
  --help                     Show this help

Examples:
  ./check-aws-repro-permissions.sh --region us-east-1 --subnet-id subnet-1234
  ./check-aws-repro-permissions.sh --region us-east-1 --subnet-id subnet-1234 --source-ami ami-abc

This script checks:
  - sts:GetCallerIdentity
  - ec2:DescribeVpcs
  - ec2:DescribeSubnets
  - ec2:DescribeImages
  - ec2:RunInstances (dry-run)
  - ec2:CreateKeyPair (dry-run)
  - ec2:CreateSecurityGroup (dry-run)
  - ec2:CreateTags (dry-run)

It does not create any resources.
EOF
}

region=""
subnet_id=""
instance_type="t3.micro"
source_ami=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --region)
      region="${2:-}"
      shift 2
      ;;
    --subnet-id)
      subnet_id="${2:-}"
      shift 2
      ;;
    --instance-type)
      instance_type="${2:-}"
      shift 2
      ;;
    --source-ami)
      source_ami="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "$region" ] || [ -z "$subnet_id" ]; then
  echo "--region and --subnet-id are required" >&2
  usage >&2
  exit 1
fi

cleanup_files=()
cleanup() {
  if [ "${#cleanup_files[@]}" -gt 0 ]; then
    rm -f "${cleanup_files[@]}"
  fi
}
trap cleanup EXIT

note() {
  printf '\n[%s]\n' "$1"
}

pass() {
  printf 'PASS  %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1" >&2
}

run_and_capture() {
  local outfile
  outfile="$(mktemp)"
  cleanup_files+=("$outfile")
  if "$@" >"$outfile" 2>&1; then
    cat "$outfile"
    return 0
  fi
  cat "$outfile"
  return 1
}

check_dry_run() {
  local label="$1"
  shift

  local output
  if output="$(run_and_capture "$@")"; then
    pass "$label"
    return 0
  fi

  if printf '%s' "$output" | grep -q 'DryRunOperation'; then
    pass "$label"
    return 0
  fi

  fail "$label"
  printf '%s\n' "$output" >&2
  return 1
}

note "Checking AWS identity"
identity_json="$(aws sts get-caller-identity --region "$region" --output json)"
printf '%s\n' "$identity_json"

note "Checking default VPC visibility"
default_vpc="$(aws ec2 describe-vpcs \
  --region "$region" \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' \
  --output text)"
if [ -z "$default_vpc" ] || [ "$default_vpc" = "None" ]; then
  fail "ec2:DescribeVpcs (default VPC lookup)"
  exit 1
fi
pass "ec2:DescribeVpcs (default VPC lookup)"
printf 'Default VPC: %s\n' "$default_vpc"

note "Checking subnet visibility"
subnet_summary="$(aws ec2 describe-subnets \
  --region "$region" \
  --subnet-ids "$subnet_id" \
  --query 'Subnets[0].{SubnetId:SubnetId,VpcId:VpcId,AZ:AvailabilityZone,PublicIps:MapPublicIpOnLaunch}' \
  --output json)"
printf '%s\n' "$subnet_summary"
pass "ec2:DescribeSubnets"

if [ -z "$source_ami" ]; then
  note "Resolving latest Amazon Linux 2023 source AMI"
  source_ami="$(aws ec2 describe-images \
    --region "$region" \
    --owners 137112412989 \
    --filters \
      Name=name,Values='al2023-ami-2023*-x86_64' \
      Name=root-device-type,Values=ebs \
      Name=virtualization-type,Values=hvm \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
    --output text)"
fi

if [ -z "$source_ami" ] || [ "$source_ami" = "None" ]; then
  fail "ec2:DescribeImages / source AMI resolution"
  exit 1
fi
pass "ec2:DescribeImages / source AMI resolution"
printf 'Source AMI: %s\n' "$source_ami"

tmp_name="ssh-relay-repro-check-$(date +%s)"

note "Checking dry-run EC2 permissions"
check_dry_run \
  "ec2:RunInstances" \
  aws ec2 run-instances \
    --region "$region" \
    --image-id "$source_ami" \
    --instance-type "$instance_type" \
    --subnet-id "$subnet_id" \
    --associate-public-ip-address \
    --tag-specifications "ResourceType=instance,Tags=[{Key=ssh-relay-repro-check,Value=true}]" \
    --dry-run

check_dry_run \
  "ec2:CreateKeyPair" \
  aws ec2 create-key-pair \
    --region "$region" \
    --key-name "$tmp_name" \
    --dry-run

check_dry_run \
  "ec2:CreateSecurityGroup" \
  aws ec2 create-security-group \
    --region "$region" \
    --group-name "$tmp_name" \
    --description "dry-run permission check" \
    --vpc-id "$default_vpc" \
    --dry-run

check_dry_run \
  "ec2:CreateTags" \
  aws ec2 create-tags \
    --region "$region" \
    --resources "$subnet_id" \
    --tags Key=ssh-relay-repro-check,Value=true \
    --dry-run

note "Summary"
echo "The current credentials appear sufficient for the direct-SSH repro workflow."
echo
echo "GitHub secrets to set:"
echo "  gh secret set AWS_ACCESS_KEY_ID --repo teddylear/packer-plugin-amazon"
echo "  gh secret set AWS_SECRET_ACCESS_KEY --repo teddylear/packer-plugin-amazon"
echo
echo "GitHub variables to set:"
echo "  gh variable set PACKER_REPRO_REGION --repo teddylear/packer-plugin-amazon --body \"$region\""
echo "  gh variable set PACKER_REPRO_SUBNET_ID --repo teddylear/packer-plugin-amazon --body \"$subnet_id\""
