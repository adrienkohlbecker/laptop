# Builds a throwaway macOS VM with Tart and runs the laptop bootstrap (start.sh)
# inside it, to test provisioning end to end on a clean machine.
#
#   mise run test-vm                              # init + build with defaults
#   mise run test-vm -- -var project_dir=/path/to/laptop
#   mise run test-vm -- -var vm_base_name=ghcr.io/cirruslabs/macos-tahoe-vanilla:latest
#
# The repo is mounted read-only into the VM (Tart exposes it at
# "/Volumes/My Shared Files/laptop"); start.sh copies it to ~/Desktop/laptop and
# provisions from there, so the local working copy — including uncommitted
# changes — is what gets tested, no push required. start.sh runs with LAPTOP_VM=1,
# which makes it skip the FileVault gate and take the sudo password from the
# environment instead of prompting.

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
  description = "Base image to clone. The *-vanilla images ship the Command Line Tools (so start.sh's clang check passes) but no Homebrew, which start.sh installs — a faithful fresh-machine test."
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

  # Mount the repo read-only; start.sh copies it out before provisioning.
  run_extra_args = ["--dir=laptop:${local.project_dir}:ro"]
}

build {
  sources = ["source.tart-cli.tart"]

  provisioner "shell" {
    inline = [
      "set -euxo pipefail",
      # Install command-line tools
      "touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress",
      "softwareupdate --list | sed -n 's/.*Label: \\(Command Line Tools for Xcode.*\\)/\\1/p' | xargs -I {} softwareupdate --install '{}'",
      "rm /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress",
      "clang --version",
    ]
  }

  # Enable FileVault. On Apple Silicon the data volume is always encrypted, so
  # this just wraps the volume key with the user's password — effective
  # immediately, no conversion and no reboot. Credentials are supplied via
  # -inputplist (no interactive prompt, no `expect`); admin/admin matches the
  # base image. The plist is written to a temp file so sudo's -S password and
  # fdesetup's plist don't fight over stdin, and is removed right after.
  provisioner "shell" {
    inline = [<<SHELL
set -euxo pipefail
cat > /tmp/fv.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Username</key>
    <string>admin</string>
    <key>Password</key>
    <string>admin</string>
</dict>
</plist>
PLIST
echo admin | sudo -S fdesetup enable -inputplist /tmp/fv.plist
rm -f /tmp/fv.plist
fdesetup status
SHELL
    ]
  }

  provisioner "shell" {
    environment_vars = [
      "LAPTOP_VM=1",
      "LAPTOP_BECOME_PASS=admin",
      "NONINTERACTIVE=1",
    ]
    inline = [
      "set -euxo pipefail",
      "bash '/Volumes/My Shared Files/laptop/start.sh'",
    ]
  }
}
