variable "region" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "transport" {
  type    = string
  default = "ssh"

  validation {
    condition     = contains(["ssh", "session_manager"], var.transport)
    error_message = "Transport must be either ssh or session_manager."
  }
}

variable "run_id" {
  type = string
}

variable "line_count" {
  type    = number
  default = 4000
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "ssh_timeout" {
  type    = string
  default = "5m"
}

variable "source_ami" {
  type    = string
  default = ""
}

variable "source_os" {
  type    = string
  default = "ubuntu"

  validation {
    condition     = contains(["amazonlinux", "ubuntu"], var.source_os)
    error_message = "Source OS must be either amazonlinux or ubuntu."
  }
}

variable "architecture" {
  type    = string
  default = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "Architecture must be either x86_64 or arm64."
  }
}

variable "workload" {
  type    = string
  default = "apt"

  validation {
    condition     = contains(["loop", "bursty", "apt"], var.workload)
    error_message = "Workload must be one of loop, bursty, or apt."
  }
}

variable "ssm_instance_profile" {
  type    = string
  default = ""
}

locals {
  use_ssm           = var.transport == "session_manager"
  ssh_username      = var.source_os == "ubuntu" ? "ubuntu" : "ec2-user"
  ami_arch          = var.architecture == "x86_64" ? "amd64" : "arm64"
  source_ami_name   = var.source_os == "ubuntu" ? "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${local.ami_arch}-server-*" : "al2023-ami-2023*-${var.architecture}"
  source_ami_owners = var.source_os == "ubuntu" ? ["099720109477"] : ["137112412989"]
  provisioner_inline = var.workload == "apt" ? [
    "set -euxo pipefail",
    "export DEBIAN_FRONTEND=noninteractive",
    "sudo apt-get update",
    "sudo apt-get install -y unzip",
    "mapfile -t pkgs < <(apt-cache pkgnames)",
    "for i in \"$${!pkgs[@]}\"; do line=$((i + 1)); if [ \"$line\" -gt ${var.line_count} ]; then break; fi; pkg=$${pkgs[$i]}; printf 'relay-line %06d %s\\n' \"$line\" \"$pkg\"; if [ $((line % 50)) -eq 0 ]; then sleep 0.2; fi; done",
    "echo relay-finished"
  ] : var.workload == "bursty" ? [
    "set -euxo pipefail",
    "for i in $(seq 1 ${var.line_count}); do printf 'relay-line %06d %s\\n' \"$i\" 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; if [ $((i % 50)) -eq 0 ]; then sleep 0.2; fi; done",
    "echo relay-finished"
  ] : [
    "set -eu",
    "for i in $(seq 1 ${var.line_count}); do printf 'relay-line %06d %s\\n' \"$i\" 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done",
    "echo relay-finished"
  ]
}

source "amazon-ebs" "repro" {
  region                      = var.region
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true
  instance_type               = var.instance_type

  communicator = "ssh"
  ssh_username = local.ssh_username
  ssh_timeout  = var.ssh_timeout
  ssh_interface = local.use_ssm ? "session_manager" : "public_ip"

  iam_instance_profile = var.ssm_instance_profile

  source_ami = var.source_ami
  source_ami_filter {
    filters = {
      name                = local.source_ami_name
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = local.source_ami_owners
    most_recent = true
  }

  ami_name                = "ssh-relay-repro-${var.run_id}"
  skip_create_ami         = true
  temporary_key_pair_name = "ssh-relay-repro-${var.run_id}"

  temporary_security_group_source_public_ip = true

  run_tags = {
    "ssh-relay-repro"        = "true"
    "ssh-relay-repro-run-id" = var.run_id
  }
}

build {
  sources = ["source.amazon-ebs.repro"]

  provisioner "shell" {
    inline_shebang = "/bin/bash -e"
    inline = local.provisioner_inline
  }
}
