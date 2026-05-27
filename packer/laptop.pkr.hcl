# Builds a throwaway macOS VM with Tart and runs install.sh inside it, to test
# provisioning end to end on a clean machine.
#
#   mise run test-vm                              # init + build with defaults
#   mise run test-vm -- -var project_dir=/path/to/laptop
#   mise run test-vm -- -var vm_base_name=ghcr.io/cirruslabs/macos-tahoe-vanilla:latest
#
# The repo is mounted read-only into the VM (Tart exposes it at
# "/Volumes/My Shared Files/laptop") and install.sh provisions straight from the
# mount, so the local working copy — including uncommitted changes — is what gets
# tested, no push required. install.sh runs with LAPTOP_VM=1, which makes it
# non-interactive: sudo/FileVault credentials come from the environment and App
# Store apps are skipped.

packer {
  required_plugins {
    tart = {
      version = ">= 0.5.3"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "vm_base_name" {
  type        = string
  default     = "ghcr.io/cirruslabs/macos-tahoe-vanilla:latest"
  description = "Base image to clone. The *-vanilla images ship the Command Line Tools (so install.sh's clang check passes) but no Homebrew, which install.sh installs — a faithful fresh-machine test."
}

variable "vm_name" {
  type    = string
  default = "laptop-test"
}

variable "project_dir" {
  type        = string
  default     = ""
  description = "Host path to the laptop repo to mount into the VM. Defaults to the repo root (the parent of this template)."
}

locals {
  project_dir = var.project_dir != "" ? var.project_dir : abspath("${path.root}/..")
}

source "tart-cli" "tart" {
  vm_base_name = var.vm_base_name
  vm_name      = var.vm_name
  cpu_count    = 4
  memory_gb    = 8
  disk_size_gb = 100
  ssh_username = "admin"
  ssh_password = "admin"
  ssh_timeout  = "120s"

  # Mount the repo read-only; install.sh provisions straight from the mount.
  run_extra_args = ["--dir=laptop:${local.project_dir}:ro"]
}

build {
  sources = ["source.tart-cli.tart"]

  # install.sh handles everything (FileVault, Command Line Tools, Homebrew,
  # packages, dotfiles, runtimes, settings). LAPTOP_VM makes it non-interactive;
  # NONINTERACTIVE lets the Homebrew installer run unattended on a vanilla image.
  provisioner "shell" {
    environment_vars = [
      "LAPTOP_VM=1",
      "LAPTOP_BECOME_PASS=admin",
      "NONINTERACTIVE=1",
    ]
    inline = [
      "set -euo pipefail",
      "bash '/Volumes/My Shared Files/laptop/install.sh'",
    ]
  }
}
