#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Trigger the AWS SSH relay repro workflow twice:

1. direct SSH
2. session_manager

Usage:
  run-aws-ssh-relay-repro-workflows.sh [options]

Options:
  --repo OWNER/REPO          GitHub repo to run in
                             default: teddylear/packer-plugin-amazon
  --ref REF                  Git ref/branch to run from
                             default: test-fix-181-regression
  --line-count COUNT         Provisioner line count
                             default: 4000
  --source-os NAME           Source image family: ubuntu or amazonlinux
                             default: ubuntu
  --workload NAME            Workload to run: apt, bursty, or loop
                             default: apt
  --instance-type TYPE       EC2 instance type
                             default: t3.micro
  --timeout-minutes MINUTES  Hard timeout for packer build step
                             default: 6
  --ssh-only                 Only trigger the direct SSH run
  --ssm-only                 Only trigger the session_manager run
  -h, --help                 Show this help

Examples:
  ./run-aws-ssh-relay-repro-workflows.sh
  ./run-aws-ssh-relay-repro-workflows.sh --ref my-branch
  ./run-aws-ssh-relay-repro-workflows.sh --ssh-only
EOF
}

repo="teddylear/packer-plugin-amazon"
ref="test-fix-181-regression"
line_count="4000"
source_os="ubuntu"
workload_name="apt"
instance_type="t3.micro"
timeout_minutes="6"
ssh_only=false
ssm_only=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      repo="${2:-}"
      shift 2
      ;;
    --ref)
      ref="${2:-}"
      shift 2
      ;;
    --line-count)
      line_count="${2:-}"
      shift 2
      ;;
    --source-os)
      source_os="${2:-}"
      shift 2
      ;;
    --workload)
      workload_name="${2:-}"
      shift 2
      ;;
    --instance-type)
      instance_type="${2:-}"
      shift 2
      ;;
    --timeout-minutes)
      timeout_minutes="${2:-}"
      shift 2
      ;;
    --ssh-only)
      ssh_only=true
      shift
      ;;
    --ssm-only)
      ssm_only=true
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

if [ "$ssh_only" = true ] && [ "$ssm_only" = true ]; then
  echo "--ssh-only and --ssm-only are mutually exclusive" >&2
  exit 1
fi

workflow=".github/workflows/aws-ssh-relay-repro.yml"

if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

run_workflow() {
  local transport="$1"

  echo
  echo "Triggering ${transport} repro in ${repo} at ref ${ref}"
  gh workflow run "$workflow" \
    --repo "$repo" \
    --ref "$ref" \
    -f transport="$transport" \
    -f line_count="$line_count" \
    -f source_os="$source_os" \
    -f workload="$workload_name" \
    -f instance_type="$instance_type" \
    -f timeout_minutes="$timeout_minutes"
}

if [ "$ssm_only" = false ]; then
  run_workflow ssh
fi

if [ "$ssh_only" = false ]; then
  run_workflow session_manager
fi

echo
echo "Done. View runs with:"
echo "  gh run list --repo $repo"
echo "  gh run watch --repo $repo"
