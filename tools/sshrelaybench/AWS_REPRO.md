# AWS GitHub Runner Repro Setup

This is the minimal safe setup for the workflow in:

- `.github/workflows/aws-ssh-relay-repro.yml`

The workflow is intentionally conservative:

- `workflow_dispatch` only
- `skip_create_ami = true`
- `timeout` around `packer build`
- cleanup step for tagged instances, keypairs, and security groups

## What To Add To The Repo

### Preferred: OIDC, no long-lived AWS secrets

Add these repository **variables**:

- `AWS_ROLE_ARN`
- `PACKER_REPRO_REGION`
- `PACKER_REPRO_SUBNET_ID`

Optional repository **variables**:

- `PACKER_REPRO_SOURCE_AMI`
  - leave empty to use the built-in Amazon Linux 2023 filter
- `PACKER_REPRO_SSM_INSTANCE_PROFILE`
  - only needed for `transport = session_manager`

If you do not want to use OIDC, leave `AWS_ROLE_ARN` empty and instead add
repository **secrets**:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN` (optional)

If you are using static credentials only, you still need these repository
**variables**:

- `PACKER_REPRO_REGION`
- `PACKER_REPRO_SUBNET_ID`

Optional for static credentials too:

- `PACKER_REPRO_SOURCE_AMI`
- `PACKER_REPRO_SSM_INSTANCE_PROFILE`

In the static-credentials path, `AWS_ROLE_ARN` should be left unset or set to
an empty value.

## AWS Side Setup

### 1. Create or choose a public subnet

The simplest test path is a public subnet that can:

- assign public IPs to launched instances
- reach the internet

Add that subnet ID to the repo as:

- `PACKER_REPRO_SUBNET_ID`

### 2. Create the GitHub Actions IAM role

Use GitHub OIDC if possible.

Trust policy template:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<OWNER>/<REPO>:*"
        }
      }
    }
  ]
}
```

Then put that role ARN into the repo variable:

- `AWS_ROLE_ARN`

If you are not using OIDC, you can skip this entire step.

### 3. Permissions for the role

Fastest path for a sandbox account:

- `AmazonEC2FullAccess`

If you also want `session_manager` transport, add:

- `iam:PassRole` on the role used by your SSM instance profile

This is a repro workflow, not a production pipeline, so the safest operational
choice is to use a dedicated sandbox AWS account or dedicated sandbox role.

If you are using static credentials instead of OIDC, the IAM user or role that
issued those credentials needs equivalent EC2 permissions.

## Additional Setup For `session_manager`

If you want to test `transport = session_manager`, create a normal EC2 instance
profile whose role includes:

- `AmazonSSMManagedInstanceCore`

Then add the instance profile name to the repo variable:

- `PACKER_REPRO_SSM_INSTANCE_PROFILE`

The workflow passes that through to Packer only when you choose the
`session_manager` input.

## Safety / Cost Controls

Already built into the workflow:

- job timeout: `15` minutes
- explicit `timeout` wrapper for `packer build`
- `skip_create_ami = true`
- resource tagging using the GitHub run ID
- cleanup of tagged instances, keypairs, and security groups

Practical cost controls:

- keep `instance_type` at `t3.micro`
- keep transport to `ssh` for the first run
- do not increase line count until the base case is working

## Recommended First Run

Use the workflow with:

- `transport = ssh`
- `line_count = 1200`
- `instance_type = t3.micro`
- `timeout_minutes = 6`

That will run two cases automatically:

- plugin `1.8.0`
- plugin `1.8.1`

## What To Look For In The Logs

The workflow uploads a log artifact for each matrix case.

You are looking for:

- very slow `relay-line` emission in `1.8.1`
- `exit status: 123`
- `EOF`
- `Error accepting response stream ... timeout waiting for accept`

If the `ssh` transport repros cleanly, only then move to:

- `transport = session_manager`

## Next-Step Ansible Repro

For the higher-signal path discussed in the issue comments, use:

- `.github/workflows/aws-ssh-relay-repro-ansible.yml`
- `transport = session_manager`
- `source_os = ubuntu`

That workflow installs `ansible-core` on the GitHub runner and uses an Ansible
playbook to generate the temp-file exec/copy/remove pattern seen in the
reports.

## AWS-Hosted Host Repro

If the GitHub-hosted runner paths stay clean, the next fidelity step is to run
Packer from an AWS Graviton host and keep the target build instance on the same
session_manager + Ansible path.

Use:

```bash
tools/sshrelaybench/run-aws-hosted-packer-repro.sh
```

Defaults:

- host instance type: `t4g.micro`
- host architecture: `arm64`
- target transport: `session_manager`
- target scenario: `ansible`
- target source OS: `ubuntu`
- target architecture: `x86_64`

The launcher creates a temporary AWS host, runs the host-side runner via SSM,
and cleans up the instance and security group when it exits.

## Bootstrap Script Modes

The bootstrap helper supports both auth paths.

OIDC mode:

```bash
AUTH_MODE=oidc CREATE_SSM_PROFILE=false tools/sshrelaybench/bootstrap-gha-packer-repro.sh
```

Static-credentials mode:

```bash
AUTH_MODE=static CREATE_SSM_PROFILE=false tools/sshrelaybench/bootstrap-gha-packer-repro.sh
```

Static mode does not create the GitHub OIDC provider or GitHub IAM role. It
only helps discover or validate the subnet and optionally creates the SSM EC2
instance profile if you ask for it.
