#!/usr/bin/env bash
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${REPO_URL:=https://github.com/teddylear/packer-plugin-amazon.git}"
: "${REPO_REF:=test-fix-181-regression}"
: "${HOST_INSTANCE_TYPE:=t4g.micro}"
: "${HOST_AMI_FILTER:=al2023-ami-2023*-arm64}"
: "${HOST_ARCHITECTURE:=arm64}"
: "${TARGET_TRANSPORT:=session_manager}"
: "${TARGET_SCENARIO:=ansible}"
: "${TARGET_SOURCE_OS:=ubuntu}"
: "${TARGET_ARCHITECTURE:=x86_64}"
: "${TARGET_INSTANCE_TYPE:=t3.micro}"
: "${TARGET_TIMEOUT_MINUTES:=6}"
: "${TARGET_LINE_COUNT:=1000}"
: "${HOST_ROLE_NAME:=packer-amazon-host-repro-role}"
: "${HOST_INSTANCE_PROFILE_NAME:=packer-amazon-host-repro-profile}"
: "${HOST_POLICY_NAME:=packer-amazon-host-repro-policy}"
: "${SUBNET_ID:=}"
: "${TARGET_SSM_INSTANCE_PROFILE:=packer-amazon-repro-ssm-profile}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
HOST_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${HOST_ROLE_NAME}"

tmpdir="$(mktemp -d)"
cleanup() {
  set +e
  if [ -n "${INSTANCE_ID:-}" ]; then
    aws ec2 terminate-instances --region "${AWS_REGION}" --instance-ids "${INSTANCE_ID}" >/dev/null 2>&1 || true
  fi
  if [ -n "${SG_ID:-}" ]; then
    aws ec2 delete-security-group --region "${AWS_REGION}" --group-id "${SG_ID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

if [ -z "${SUBNET_ID}" ]; then
  SUBNET_ID="$(aws ec2 describe-subnets \
    --region "${AWS_REGION}" \
    --filters Name=default-for-az,Values=true Name=map-public-ip-on-launch,Values=true \
    --query 'Subnets[0].SubnetId' \
    --output text)"
fi

if [ -z "${SUBNET_ID}" ] || [ "${SUBNET_ID}" = "None" ]; then
  echo "Could not auto-discover a public default subnet. Set SUBNET_ID explicitly and rerun."
  exit 1
fi

host_trust="${tmpdir}/host-trust.json"
cat > "${host_trust}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

host_policy="${tmpdir}/host-policy.json"
cat > "${host_policy}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Repro",
      "Effect": "Allow",
      "Action": [
        "ec2:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassAnyRoleForSandboxRepro",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": "*"
    }
  ]
}
EOF

if aws iam get-role --role-name "${HOST_ROLE_NAME}" >/dev/null 2>&1; then
  echo "Host role ${HOST_ROLE_NAME} already exists"
else
  aws iam create-role \
    --role-name "${HOST_ROLE_NAME}" \
    --assume-role-policy-document "file://${host_trust}" >/dev/null
fi

aws iam attach-role-policy \
  --role-name "${HOST_ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" >/dev/null || true

aws iam put-role-policy \
  --role-name "${HOST_ROLE_NAME}" \
  --policy-name "${HOST_POLICY_NAME}" \
  --policy-document "file://${host_policy}" >/dev/null

if aws iam get-instance-profile --instance-profile-name "${HOST_INSTANCE_PROFILE_NAME}" >/dev/null 2>&1; then
  echo "Host instance profile ${HOST_INSTANCE_PROFILE_NAME} already exists"
else
  aws iam create-instance-profile \
    --instance-profile-name "${HOST_INSTANCE_PROFILE_NAME}" >/dev/null
  aws iam add-role-to-instance-profile \
    --instance-profile-name "${HOST_INSTANCE_PROFILE_NAME}" \
    --role-name "${HOST_ROLE_NAME}" >/dev/null
fi

host_ami="$(aws ec2 describe-images \
  --region "${AWS_REGION}" \
  --owners amazon \
  --filters "Name=name,Values=${HOST_AMI_FILTER}" "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)"

if [ -z "${host_ami}" ] || [ "${host_ami}" = "None" ]; then
  echo "Could not find a host AMI for filter ${HOST_AMI_FILTER}"
  exit 1
fi

sg_name="sshrelaybench-host-${RANDOM}"
SG_ID="$(aws ec2 create-security-group \
  --region "${AWS_REGION}" \
  --group-name "${sg_name}" \
  --description "SSH relay bench host" \
  --vpc-id "$(aws ec2 describe-vpcs --region "${AWS_REGION}" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)" \
  --query GroupId --output text)"

instance_id="$(aws ec2 run-instances \
  --region "${AWS_REGION}" \
  --image-id "${host_ami}" \
  --instance-type "${HOST_INSTANCE_TYPE}" \
  --iam-instance-profile Name="${HOST_INSTANCE_PROFILE_NAME}" \
  --subnet-id "${SUBNET_ID}" \
  --security-group-ids "${SG_ID}" \
  --associate-public-ip-address \
  --metadata-options HttpTokens=required \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=sshrelaybench-host-repro},{Key=sshrelaybench,Value=true}]" \
  --query 'Instances[0].InstanceId' \
  --output text)"

echo "Launched host instance: ${instance_id}"
aws ec2 wait instance-status-ok --region "${AWS_REGION}" --instance-ids "${instance_id}"

while :; do
  managed_state="$(aws ssm describe-instance-information \
    --region "${AWS_REGION}" \
    --filters "Key=InstanceIds,Values=${instance_id}" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || true)"
  if [ "${managed_state}" = "Online" ]; then
    break
  fi
  sleep 10
done

command_url="https://raw.githubusercontent.com/teddylear/packer-plugin-amazon/${REPO_REF}/tools/sshrelaybench/host-repro-runner.sh"
command_id="$(aws ssm send-command \
  --region "${AWS_REGION}" \
  --document-name AWS-RunShellScript \
  --instance-ids "${instance_id}" \
  --comment "sshrelaybench host repro" \
  --parameters "commands=[\"curl -fsSL ${command_url} -o /tmp/host-repro-runner.sh\",\"bash /tmp/host-repro-runner.sh ${REPO_URL} ${REPO_REF} ${AWS_REGION} ${SUBNET_ID} ${TARGET_TRANSPORT} ${TARGET_SCENARIO} ${TARGET_SOURCE_OS} ${TARGET_ARCHITECTURE} ${TARGET_INSTANCE_TYPE} ${TARGET_TIMEOUT_MINUTES} ${TARGET_LINE_COUNT} ${TARGET_SSM_INSTANCE_PROFILE}\"]" \
  --query 'Command.CommandId' \
  --output text)"

echo "SSM command id: ${command_id}"

while :; do
  status="$(aws ssm get-command-invocation \
    --region "${AWS_REGION}" \
    --command-id "${command_id}" \
    --instance-id "${instance_id}" \
    --query Status \
    --output text 2>/dev/null || true)"
  case "${status}" in
    Pending|InProgress|Delayed|CancelledToWait|Cancelling|TimedOut)
      sleep 15
      ;;
    Success|Cancelled|Failed|TimedOut|Undeliverable|Terminated)
      break
      ;;
    *)
      sleep 15
      ;;
  esac
done

aws ssm get-command-invocation \
  --region "${AWS_REGION}" \
  --command-id "${command_id}" \
  --instance-id "${instance_id}" \
  --query '{Status:Status,StdOut:StandardOutputContent,StdErr:StandardErrorContent}' \
  --output json
