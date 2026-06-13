#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${1:?repo url required}"
REPO_REF="${2:?repo ref required}"
AWS_REGION="${3:?aws region required}"
SUBNET_ID="${4:?subnet id required}"
TRANSPORT="${5:?transport required}"
SCENARIO="${6:?scenario required}"
SOURCE_OS="${7:?source os required}"
ARCHITECTURE="${8:?architecture required}"
INSTANCE_TYPE="${9:?instance type required}"
TIMEOUT_MINUTES="${10:?timeout required}"
LINE_COUNT="${11:?line count required}"
SSM_INSTANCE_PROFILE="${12:?ssm instance profile required}"

export AWS_REGION
export PACKER_LOG=1

root_dir="/tmp/sshrelaybench-host"
repo_dir="${root_dir}/repo"
log_file="${root_dir}/repro.log"
plugin_versions=("1.8.0" "1.8.1")

mkdir -p "${root_dir}"

install_packages() {
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y git curl unzip tar gzip python3 python3-pip jq
    sudo dnf install -y ansible-core || python3 -m pip install --user ansible-core
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y git curl unzip tar gzip python3 python3-pip jq
    sudo yum install -y ansible-core || python3 -m pip install --user ansible-core
  fi
}

install_packer() {
  if command -v packer >/dev/null 2>&1; then
    return
  fi

  packer_version="$(python3 - <<'PY'
import re
import urllib.request

html = urllib.request.urlopen('https://releases.hashicorp.com/packer/').read().decode()
versions = re.findall(r'packer/([0-9]+\.[0-9]+\.[0-9]+)/', html)
if not versions:
    raise SystemExit('no packer versions found')

def key(v):
    return tuple(int(x) for x in v.split('.'))

print(sorted(set(versions), key=key, reverse=True)[0])
PY
)"

  arch="$(uname -m)"
  case "${arch}" in
    aarch64|arm64) arch=arm64 ;;
    x86_64|amd64) arch=amd64 ;;
    *) echo "Unsupported host architecture: ${arch}" >&2; exit 1 ;;
  esac

  tmpzip="${root_dir}/packer.zip"
  curl -fsSLo "${tmpzip}" "https://releases.hashicorp.com/packer/${packer_version}/packer_${packer_version}_linux_${arch}.zip"
  unzip -o -d /usr/local/bin "${tmpzip}"
  rm -f "${tmpzip}"
}

run_repro() {
  rm -rf "${repo_dir}"
  git clone --depth 1 --branch "${REPO_REF}" "${REPO_URL}" "${repo_dir}"

  cd "${repo_dir}"
  if [ "${SCENARIO}" = "ansible" ]; then
    sudo dnf install -y ansible-core || python3 -m pip install --user ansible-core
    template_dir=tools/sshrelaybench/repro-ansible
  else
    template_dir=tools/sshrelaybench/repro
  fi

  for plugin_version in "${plugin_versions[@]}"; do
    case_name="v${plugin_version//./}"
    echo "=== ${case_name} (${plugin_version}) ==="
    if [ "${SCENARIO}" = "ansible" ]; then
      cat > "${template_dir}/version.auto.pkr.hcl" <<EOF
packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "=${plugin_version}"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "=1.1.4"
    }
  }
}
EOF
    else
      cat > "${template_dir}/version.auto.pkr.hcl" <<EOF
packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "=${plugin_version}"
    }
  }
}
EOF
    fi

    packer init "${template_dir}"
    timeout --signal=INT "${TIMEOUT_MINUTES}m" \
      packer build -color=false \
        -var "region=${AWS_REGION}" \
        -var "subnet_id=${SUBNET_ID}" \
        -var "transport=${TRANSPORT}" \
        -var "run_id=host-${case_name}-${RANDOM}-${RANDOM}" \
        -var "line_count=${LINE_COUNT}" \
        -var "instance_type=${INSTANCE_TYPE}" \
        -var "source_os=${SOURCE_OS}" \
        -var "architecture=${ARCHITECTURE}" \
        -var "ssm_instance_profile=${SSM_INSTANCE_PROFILE}" \
        "${template_dir}" 2>&1 | tee -a "${log_file}"
  done
}

install_packages
install_packer
run_repro
