#!/usr/bin/env bash
#
# Provisions a personal macOS laptop: Homebrew packages, dotfiles, mise-managed
# runtimes, and macOS preferences. This replaces the former Ansible playbook —
# it targets a single machine set up once, and every step is individually
# idempotent, so re-running it is safe.
#
# Usage:
#   ./install.sh                  # run every section, in order
#   ./install.sh settings         # run only the named section(s)
#
# Sections: bootstrap packages dotfiles runtimes settings
#
# In the Tart test VM (packer/laptop.pkr.hcl) it runs with LAPTOP_VM=1, which
# makes it non-interactive: sudo and FileVault credentials come from
# LAPTOP_BECOME_PASS (default "admin"), and App Store apps are skipped.

set -euo pipefail

# --- configuration -----------------------------------------------------------

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BREWFILE="$SCRIPT_DIR/Brewfile"
DOTFILES_DIR="$HOME/Desktop/dotfiles"
DOTFILES_REPO="https://github.com/adrienkohlbecker/dotfiles.git"
HOMEBREW_PREFIX="/opt/homebrew"
SUDO_PASS="${LAPTOP_BECOME_PASS:-admin}"
ALL_SECTIONS=(bootstrap packages dotfiles runtimes settings)

# --- pretty output -----------------------------------------------------------

if [ -t 1 ]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'
  YELLOW=$'\e[33m'; BLUE=$'\e[34m'; RESET=$'\e[0m'
else
  BOLD='' DIM='' RED='' GREEN='' YELLOW='' BLUE='' RESET=''
fi

step() { printf '\n%s==>%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
info() { printf '    %s%s%s\n' "$DIM" "$*" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s⚠%s  %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '\n%s✗ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

# --- sudo --------------------------------------------------------------------

# Acquire sudo once up front and keep the timestamp warm so later steps never
# stop to prompt. In the VM the password comes from the environment.
establish_sudo() {
  step "Acquiring administrator rights"
  if [ -n "${LAPTOP_VM:-}" ]; then
    echo "$SUDO_PASS" | sudo -S -v 2>/dev/null || die "sudo authentication failed"
  else
    sudo -v || die "sudo authentication failed"
  fi
  while true; do
    sudo -n true
    sleep 60
    kill -0 "$$" 2>/dev/null || exit 0
  done 2>/dev/null &
  ok "sudo ready"
}

# --- sections ----------------------------------------------------------------

bootstrap() {
  step "Bootstrap"

  # FileVault. On Apple Silicon the data volume is always encrypted, so enabling
  # just wraps the volume key with the account password — instant, no reboot.
  if fdesetup status | grep -q "FileVault is On"; then
    ok "FileVault already enabled"
  elif [ -n "${LAPTOP_VM:-}" ]; then
    info "Enabling FileVault (non-interactive)"
    local plist
    plist=$(mktemp)
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Username</key>
    <string>$(whoami)</string>
    <key>Password</key>
    <string>$SUDO_PASS</string>
</dict>
</plist>
PLIST
    # $plist is user-readable, so the redirect (opened by us) is fine — fdesetup
    # reads it as root via the inherited descriptor.
    # shellcheck disable=SC2024
    sudo fdesetup enable -inputplist < "$plist"
    rm -f "$plist"
    ok "FileVault enabled"
  else
    info "Enabling FileVault — enter your login password when prompted"
    sudo fdesetup enable
    ok "FileVault enabled (note the recovery key above)"
  fi

  # Command Line Tools — install headlessly via softwareupdate when clang is
  # missing (the GUI `xcode-select --install` can't run unattended).
  if [ -x "/Library/Developer/CommandLineTools/usr/bin/clang" ]; then
    ok "Command Line Tools present"
  else
    info "Installing Command Line Tools"
    local trigger="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
    local label
    touch "$trigger"
    label=$(softwareupdate --list 2>/dev/null \
      | sed -n 's/.*Label: \(Command Line Tools for Xcode.*\)/\1/p' | tail -1)
    [ -n "$label" ] || { rm -f "$trigger"; die "No Command Line Tools package offered by softwareupdate"; }
    sudo softwareupdate --install "$label" --verbose
    rm -f "$trigger"
    ok "Command Line Tools installed"
  fi

  # Rosetta 2 — required to run x86_64 casks/binaries on Apple Silicon. Skipped
  # on Intel (no Rosetta there); a no-op once oahd (the Rosetta daemon) is up.
  if [ "$(uname -m)" != "arm64" ]; then
    ok "Rosetta not needed (not Apple Silicon)"
  elif /usr/bin/pgrep -q oahd; then
    ok "Rosetta already installed"
  else
    info "Installing Rosetta 2"
    sudo softwareupdate --install-rosetta --agree-to-license
    ok "Rosetta installed"
  fi

  # Homebrew.
  if [ -x "$HOMEBREW_PREFIX/bin/brew" ]; then
    ok "Homebrew present"
  else
    info "Installing Homebrew"
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    ok "Homebrew installed"
  fi
  eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"

  # Dotfiles — a separate repo, cloned to ~/Desktop so `dotfiles` (stow) can
  # deploy from it without depending on ~/Work being restored from backup first.
  if [ -d "$DOTFILES_DIR/.git" ]; then
    info "Updating dotfiles clone"
    git -C "$DOTFILES_DIR" pull --ff-only || warn "dotfiles pull failed; continuing with the existing clone"
  else
    info "Cloning dotfiles into $DOTFILES_DIR"
    git clone -q "$DOTFILES_REPO" "$DOTFILES_DIR" -b master
  fi
  ok "Dotfiles ready"
}

packages() {
  step "Homebrew packages"
  [ -f "$BREWFILE" ] || die "Brewfile not found at $BREWFILE"
  command -v brew >/dev/null 2>&1 || eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"
  info "brew bundle from $BREWFILE (this streams below)"
  # HOMEBREW_LAPTOP_VM (HOMEBREW_-prefixed so it survives brew's env scrub) lets
  # the Brewfile skip its App Store apps in the headless VM. --no-upgrade keeps
  # already-installed packages pinned.
  HOMEBREW_LAPTOP_VM="${LAPTOP_VM:-}" brew bundle install --no-upgrade --file="$BREWFILE"
  ok "Packages installed"
}

dotfiles() {
  step "Dotfiles (stow)"
  [ -d "$DOTFILES_DIR" ] || die "$DOTFILES_DIR is missing — run the 'bootstrap' section first"
  command -v stow >/dev/null 2>&1 || eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"
  info "Symlinking every package into \$HOME"
  # stow wants bare package directory names (config/ vim/ ...), not ./*/.
  # shellcheck disable=SC2035
  ( cd "$DOTFILES_DIR" && stow --verbose --target="$HOME" --no-folding --restow */ )
  ok "Dotfiles symlinked"
}

runtimes() {
  step "Runtimes (mise)"
  command -v mise >/dev/null 2>&1 || eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"
  # Run from $HOME so the repo-local mise.toml (the packer test harness) is not
  # loaded; this installs the global tools declared in the stowed mise config.
  info "Installing mise-managed CLI tools and language runtimes"
  ( cd "$HOME" && MISE_ENV=mac mise install )
  ok "Runtimes installed"
}

settings() {
  step "macOS settings"

  info "SSH config directories and Keychain stanza"
  mkdir -p "$HOME/.ssh/config.d"
  chmod 700 "$HOME/.ssh" "$HOME/.ssh/config.d"
  printf 'Host *\n  UseKeychain yes\n' > "$HOME/.ssh/config.d/keychain"
  chmod 600 "$HOME/.ssh/config.d/keychain"

  info "Enable automatic software-update checks"
  sudo softwareupdate --schedule on

  info "Unhide the ~/Library folder"
  chflags nohidden "$HOME/Library"

  info "Preferences: screenshots, key repeat, dock, accented keys"
  defaults write com.apple.screencapture location "$HOME/Downloads"
  defaults write NSGlobalDomain KeyRepeat -int 2
  defaults write NSGlobalDomain InitialKeyRepeat -int 15
  defaults write com.apple.dock autohide-delay -float 0
  defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false

  # tart recommends shortening the bootpd DHCP lease from 86400s to 600s so
  # running many VMs daily doesn't exhaust the lease pool.
  info "Shorten the bootpd DHCP lease for tart VMs"
  sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.InternetSharing.default.plist \
    bootpd -dict DHCPLeaseTimeSecs -int 600

  ok "Settings applied"
}

# --- main --------------------------------------------------------------------

main() {
  local sections=("$@")
  [ ${#sections[@]} -gt 0 ] || sections=("${ALL_SECTIONS[@]}")

  for s in "${sections[@]}"; do
    case " ${ALL_SECTIONS[*]} " in
      *" $s "*) ;;
      *) die "Unknown section '$s' (valid: ${ALL_SECTIONS[*]})" ;;
    esac
  done

  printf '%s%s━━ laptop install ━━%s\n' "$BOLD" "$BLUE" "$RESET"
  info "sections: ${sections[*]}"
  [ -n "${LAPTOP_VM:-}" ] && info "LAPTOP_VM set — non-interactive VM mode"

  establish_sudo
  for s in "${sections[@]}"; do
    "$s"
  done

  step "Done"
  ok "Provisioning complete in ${SECONDS}s"
}

main "$@"
