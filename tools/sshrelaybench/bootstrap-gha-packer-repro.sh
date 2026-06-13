#!/usr/bin/env bash
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${REPO_OWNER:=teddylear}"
: "${REPO_NAME:=packer-plugin-amazon}"
: "${AUTH_MODE:=oidc}"
: "${ROLE_NAME:=gha-packer-amazon-repro}"
: "${POLICY_NAME:=gha-packer-amazon-repro-policy}"
: "${CREATE_SSM_PROFILE:=false}"
: "${SSM_ROLE_NAME:=packer-amazon-repro-ssm-role}"
: "${SSM_INSTANCE_PROFILE_NAME:=packer-amazon-repro-ssm-profile}"
: "${SUBNET_ID:=}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
SSM_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${SSM_ROLE_NAME}"

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

echo "Using AWS account: ${ACCOUNT_ID}"
echo "Using AWS region:  ${AWS_REGION}"
echo "Auth mode:         ${AUTH_MODE}"

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

echo "Using subnet:      ${SUBNET_ID}"

if [ "${AUTH_MODE}" = "oidc" ]; then
  if ! aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" >/dev/null 2>&1; then
    echo "Creating GitHub OIDC provider..."
    aws iam create-open-id-connect-provider \
      --url "https://token.actions.githubusercontent.com" \
      --client-id-list "sts.amazonaws.com" \
      --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" >/dev/null
  else
    echo "GitHub OIDC provider already exists."
  fi
fi

if [ "${AUTH_MODE}" = "oidc" ]; then
  cat > "${tmpdir}/trust-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${REPO_OWNER}/${REPO_NAME}:*"
        }
      }
    }
  ]
}
EOF

  if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
    echo "Updating assume-role policy for ${ROLE_NAME}..."
    aws iam update-assume-role-policy \
      --role-name "${ROLE_NAME}" \
      --policy-document "file://${tmpdir}/trust-policy.json" >/dev/null
  else
    echo "Creating IAM role ${ROLE_NAME}..."
    aws iam create-role \
      --role-name "${ROLE_NAME}" \
      --assume-role-policy-document "file://${tmpdir}/trust-policy.json" >/dev/null
  fi
fi

if [ "${CREATE_SSM_PROFILE}" = "true" ]; then
  cat > "${tmpdir}/ssm-trust-policy.json" <<EOF
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

  if aws iam get-role --role-name "${SSM_ROLE_NAME}" >/dev/null 2>&1; then
    echo "SSM role ${SSM_ROLE_NAME} already exists."
  else
    echo "Creating SSM EC2 role ${SSM_ROLE_NAME}..."
    aws iam create-role \
      --role-name "${SSM_ROLE_NAME}" \
      --assume-role-policy-document "file://${tmpdir}/ssm-trust-policy.json" >/dev/null
  fi

  aws iam attach-role-policy \
    --role-name "${SSM_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" >/dev/null || true

  if aws iam get-instance-profile --instance-profile-name "${SSM_INSTANCE_PROFILE_NAME}" >/dev/null 2>&1; then
    echo "SSM instance profile ${SSM_INSTANCE_PROFILE_NAME} already exists."
  else
    echo "Creating SSM instance profile ${SSM_INSTANCE_PROFILE_NAME}..."
    aws iam create-instance-profile \
      --instance-profile-name "${SSM_INSTANCE_PROFILE_NAME}" >/dev/null
    aws iam add-role-to-instance-profile \
      --instance-profile-name "${SSM_INSTANCE_PROFILE_NAME}" \
      --role-name "${SSM_ROLE_NAME}" >/dev/null
  fi
fi

if [ "${AUTH_MODE}" = "oidc" ] && [ "${CREATE_SSM_PROFILE}" = "true" ]; then
  cat > "${tmpdir}/repro-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Repro",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:CreateKeyPair",
        "ec2:DeleteKeyPair",
        "ec2:Describe*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SSMRepro",
      "Effect": "Allow",
      "Action": [
        "ssm:StartSession",
        "ssm:TerminateSession",
        "ssm:DescribeSessions",
        "ec2-instance-connect:SendSSHPublicKey"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassSSMRole",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": "${SSM_ROLE_ARN}"
    }
  ]
}
EOF
elif [ "${AUTH_MODE}" = "oidc" ]; then
  cat > "${tmpdir}/repro-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Repro",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:CreateKeyPair",
        "ec2:DeleteKeyPair",
        "ec2:Describe*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
fi

if [ "${AUTH_MODE}" = "oidc" ]; then
  echo "Putting inline policy ${POLICY_NAME} on ${ROLE_NAME}..."
  aws iam put-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-name "${POLICY_NAME}" \
    --policy-document "file://${tmpdir}/repro-policy.json" >/dev/null
fi

echo
echo "Done."
echo
echo "Repo variable values:"
if [ "${AUTH_MODE}" = "oidc" ]; then
  echo "AWS_ROLE_ARN=${ROLE_ARN}"
else
  echo "AWS_ROLE_ARN=<leave unset or set to empty in GitHub repo variables>"
fi
echo "PACKER_REPRO_REGION=${AWS_REGION}"
echo "PACKER_REPRO_SUBNET_ID=${SUBNET_ID}"
if [ "${CREATE_SSM_PROFILE}" = "true" ]; then
  echo "PACKER_REPRO_SSM_INSTANCE_PROFILE=${SSM_INSTANCE_PROFILE_NAME}"
fi

if [ "${AUTH_MODE}" = "static" ]; then
  echo
  echo "GitHub secrets required for static auth:"
  echo "AWS_ACCESS_KEY_ID=<your access key id>"
  echo "AWS_SECRET_ACCESS_KEY=<your secret access key>"
  echo "AWS_SESSION_TOKEN=<optional, only if using temporary credentials>"
fi
