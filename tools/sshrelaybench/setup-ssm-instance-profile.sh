#!/usr/bin/env bash
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${ROLE_NAME:=packer-amazon-repro-ssm-role}"
: "${INSTANCE_PROFILE_NAME:=packer-amazon-repro-ssm-profile}"
: "${REPO_OWNER:=teddylear}"
: "${REPO_NAME:=packer-plugin-amazon}"
: "${UPDATE_GH_VARIABLE:=false}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

cat > "${tmpdir}/trust-policy.json" <<EOF
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

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "Role ${ROLE_NAME} already exists"
else
  echo "Creating role ${ROLE_NAME}"
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "file://${tmpdir}/trust-policy.json" >/dev/null
fi

echo "Attaching AmazonSSMManagedInstanceCore"
aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" >/dev/null || true

if aws iam get-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" >/dev/null 2>&1; then
  echo "Instance profile ${INSTANCE_PROFILE_NAME} already exists"
else
  echo "Creating instance profile ${INSTANCE_PROFILE_NAME}"
  aws iam create-instance-profile \
    --instance-profile-name "${INSTANCE_PROFILE_NAME}" >/dev/null
fi

if ! aws iam get-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
  --query 'InstanceProfile.Roles[?RoleName==`'"${ROLE_NAME}"'`]' \
  --output text 2>/dev/null | grep -q .; then
  echo "Adding role ${ROLE_NAME} to instance profile ${INSTANCE_PROFILE_NAME}"
  aws iam add-role-to-instance-profile \
    --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
    --role-name "${ROLE_NAME}" >/dev/null
fi

echo
echo "PACKER_REPRO_SSM_INSTANCE_PROFILE=${INSTANCE_PROFILE_NAME}"
echo "ROLE_ARN=${ROLE_ARN}"

if [ "${UPDATE_GH_VARIABLE}" = "true" ]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh not found; skipping GitHub variable update"
  else
    gh variable set PACKER_REPRO_SSM_INSTANCE_PROFILE \
      --repo "${REPO_OWNER}/${REPO_NAME}" \
      --body "${INSTANCE_PROFILE_NAME}"
  fi
fi
