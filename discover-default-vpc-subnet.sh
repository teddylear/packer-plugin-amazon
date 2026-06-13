#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Discover a usable public subnet in the default VPC.

Usage:
  discover-default-vpc-subnet.sh [--region REGION] [--id-only]

Examples:
  ./discover-default-vpc-subnet.sh
  ./discover-default-vpc-subnet.sh --region us-east-1
  ./discover-default-vpc-subnet.sh --id-only

Environment:
  AWS_REGION    Used if --region is not provided.
  AWS_DEFAULT_REGION
EOF
}

region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
id_only=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --region)
      if [ "$#" -lt 2 ]; then
        echo "missing value for --region" >&2
        exit 1
      fi
      region="$2"
      shift 2
      ;;
    --id-only)
      id_only=true
      shift
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

aws_args=()
if [ -n "$region" ]; then
  aws_args+=(--region "$region")
fi

if ! aws sts get-caller-identity "${aws_args[@]}" >/dev/null; then
  echo "aws cli is not authenticated for the selected region/account" >&2
  exit 1
fi

vpc_id="$(aws ec2 describe-vpcs \
  "${aws_args[@]}" \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' \
  --output text)"

if [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ]; then
  echo "no default VPC found" >&2
  exit 1
fi

public_subnet_id="$(aws ec2 describe-subnets \
  "${aws_args[@]}" \
  --filters Name=vpc-id,Values="$vpc_id" Name=map-public-ip-on-launch,Values=true \
  --query 'Subnets[0].SubnetId' \
  --output text)"

if [ -z "$public_subnet_id" ] || [ "$public_subnet_id" = "None" ]; then
  echo "no public subnet found in default VPC $vpc_id" >&2
  exit 1
fi

if [ "$id_only" = true ]; then
  printf '%s\n' "$public_subnet_id"
  exit 0
fi

echo "Default VPC: $vpc_id"
echo
aws ec2 describe-subnets \
  "${aws_args[@]}" \
  --filters Name=vpc-id,Values="$vpc_id" \
  --query 'Subnets[].{SubnetId:SubnetId,AZ:AvailabilityZone,PublicIps:MapPublicIpOnLaunch,CIDR:CidrBlock}' \
  --output table
echo
echo "Recommended public subnet: $public_subnet_id"
echo
echo "GitHub variable commands:"
if [ -n "$region" ]; then
  echo "gh variable set PACKER_REPRO_REGION --repo teddylear/packer-plugin-amazon --body \"$region\""
fi
echo "gh variable set PACKER_REPRO_SUBNET_ID --repo teddylear/packer-plugin-amazon --body \"$public_subnet_id\""
