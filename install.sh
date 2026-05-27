#!/usr/bin/env bash
#
# Provisions a personal macOS laptop: Homebrew packages, dotfiles, mise-managed
# runtimes, and macOS preferences. This replaces the former Ansible playbook —
# it targets a single Apple Silicon machine set up once, and every step is
# individually idempotent, so re-running it is safe.
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
IFS=$'\n\t'

# --- configuration -----------------------------------------------------------

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BREWFILE="$SCRIPT_DIR/Brewfile"
DOTFILES_DIR="$HOME/Work/dotfiles"
DOTFILES_REPO="https://github.com/adrienkohlbecker/dotfiles.git"
HOMEBREW_PREFIX="/opt/homebrew"
SUDO_PASS="${LAPTOP_BECOME_PASS:-}"
ALL_SECTIONS=(bootstrap packages dotfiles runtimes settings)

# --- pretty output -----------------------------------------------------------

if [ -t 1 ]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'
  YELLOW=$'\e[33m'; BLUE=$'\e[34m'; RESET=$'\e[0m'
else
  BOLD='' DIM='' RED='' GREEN='' YELLOW='' BLUE='' RESET=''
fi

step() { CURRENT_STEP="$*"; printf '\n%s==>%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
info() { printf '    %s%s%s\n' "$DIM" "$*" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s⚠%s  %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { DIE_CALLED=1; printf '\n%s✗ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

# Escape XML metacharacters so a value can be safely interpolated into a plist.
xml_escape() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; printf '%s' "$s"; }

# On any non-zero exit before we finish, report which step was running — a bare
# `set -e` abort otherwise dies with only a numeric code.
CURRENT_STEP="startup"
INSTALL_DONE=""
DIE_CALLED=""
on_exit() {
  local rc=$?
  [ "$rc" -eq 0 ] && return
  [ -n "$INSTALL_DONE" ] && return
  # die() already printed a specific message; only report bare set -e aborts.
  [ -n "$DIE_CALLED" ] && return
  printf '\n%s✗ Failed during: %s (exit %d)%s\n' "$RED" "$CURRENT_STEP" "$rc" "$RESET" >&2
}
trap on_exit EXIT

# --- sudo --------------------------------------------------------------------

# Acquire sudo once up front and keep the timestamp warm so later steps never
# stop to prompt. In the VM the password comes from the environment.
establish_sudo() {
  step "Acquiring administrator rights"
  if [ -n "${LAPTOP_VM:-}" ]; then
    : "${SUDO_PASS:?LAPTOP_BECOME_PASS must be set in VM mode}"
    echo "$SUDO_PASS" | sudo -S -v 2>/dev/null || die "sudo authentication failed"
  else
    sudo -v || die "sudo authentication failed"
  fi
  # Keep the machine awake for the whole run; exits when this script does.
  caffeinate -s -w "$$" &
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
    # Feed the input plist on stdin so the password never lands on disk, and
    # XML-escape the credentials so metacharacters can't corrupt the plist.
    sudo fdesetup enable -inputplist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Username</key>
    <string>$(xml_escape "$(whoami)")</string>
    <key>Password</key>
    <string>$(xml_escape "$SUDO_PASS")</string>
</dict>
</plist>
PLIST
    ok "FileVault enabled"
  else
    info "Enabling FileVault — enter your login password when prompted"
    # Capture the recovery key to a file instead of letting it scroll past — it
    # is the only irreplaceable secret this run produces.
    local keyfile="$HOME/Desktop/FileVault-recovery-key.plist"
    # The redirect is opened by us (not root) on purpose, so the key file is
    # owned by the user.
    # shellcheck disable=SC2024
    sudo fdesetup enable -outputplist > "$keyfile"
    chmod 600 "$keyfile"
    ok "FileVault enabled — recovery key saved to $keyfile (store it somewhere safe)"
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
    case "$label" in
      "Command Line Tools for Xcode"*) ;;
      *) rm -f "$trigger"; die "Unexpected softwareupdate label, refusing to install: $label" ;;
    esac
    sudo softwareupdate --install "$label" --verbose
    rm -f "$trigger"
    ok "Command Line Tools installed"
  fi

  # Rosetta 2 — required to run x86_64 casks/binaries on Apple Silicon. A no-op
  # once oahd (the Rosetta daemon) is up.
  if /usr/bin/pgrep -q oahd; then
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

  # Dotfiles — a separate repo cloned to ~/Work/dotfiles, which the `dotfiles`
  # (stow) step deploys from. On a machine restored from backup the clone already
  # exists, so this just fast-forwards it.
  if [ -d "$DOTFILES_DIR/.git" ]; then
    info "Updating dotfiles clone"
    git -C "$DOTFILES_DIR" pull --ff-only origin master || warn "dotfiles pull failed; continuing with the existing clone"
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
  [ -x "$HOMEBREW_PREFIX/bin/brew" ] || die "Homebrew is missing — run the 'bootstrap' and 'packages' sections first"
  command -v mise >/dev/null 2>&1 || eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"
  # Delegate to the dotfiles repo's own restow task so it owns the stow
  # invocation (and the ~/.gnupg homedir hardening it does afterwards).
  # `mise trust` is needed because it's a fresh, not-yet-trusted clone.
  info "Restowing via the dotfiles repo's mise task"
  ( cd "$DOTFILES_DIR" && mise trust && mise run restow )
  ok "Dotfiles symlinked"
}

runtimes() {
  step "Runtimes (mise)"
  [ -x "$HOMEBREW_PREFIX/bin/brew" ] || die "Homebrew is missing — run the 'bootstrap' and 'packages' sections first"
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
  # Script-managed drop-in: rewritten on every run, so hand-edits won't persist.
  printf 'Host *\n  UseKeychain yes\n' > "$HOME/.ssh/config.d/keychain"
  chmod 600 "$HOME/.ssh/config.d/keychain"

  # Touch ID for sudo. /etc/pam.d/sudo_local is the Apple-sanctioned drop-in
  # (included from /etc/pam.d/sudo) that survives OS updates, unlike editing
  # sudo directly. Harmless in the VM: with no biometric, the "sufficient" line
  # just falls through to the password prompt.
  info "Enable Touch ID for sudo"
  if grep -qs 'pam_tid.so' /etc/pam.d/sudo_local; then
    ok "Touch ID for sudo already enabled"
  else
    printf 'auth       sufficient     pam_tid.so\n' | sudo tee /etc/pam.d/sudo_local >/dev/null
    ok "Touch ID for sudo enabled"
  fi

  # Application firewall (the System Settings → Network → Firewall toggle):
  # blocks unsolicited incoming connections per-app. Stealth mode left off.
  info "Enable the application firewall"
  sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on >/dev/null

  info "Enable automatic software-update checks"
  sudo softwareupdate --schedule on

  info "Unhide the ~/Library folder"
  chflags nohidden "$HOME/Library"

  info "Preferences: appearance, keyboard, Finder, Dock, trackpad, clock"

  # Appearance & keyboard (NSGlobalDomain). ApplePressAndHoldEnabled false swaps
  # the accent popup for key repeat; these keyboard prefs apply on next login.
  defaults write NSGlobalDomain AppleInterfaceStyle Dark
  defaults write NSGlobalDomain AppleShowAllExtensions -bool true
  defaults write NSGlobalDomain AppleKeyboardUIMode -int 2
  defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false
  defaults write NSGlobalDomain AppleShowScrollBars Always
  defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false
  defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false
  defaults write NSGlobalDomain KeyRepeat -int 2
  defaults write NSGlobalDomain InitialKeyRepeat -int 15

  # Screenshots → ~/Downloads
  defaults write com.apple.screencapture location "$HOME/Downloads"

  # Finder: path/status bars, list view, search current folder, folders first,
  # new windows open ~/Downloads.
  defaults write com.apple.finder ShowPathbar -bool true
  defaults write com.apple.finder ShowStatusBar -bool true
  defaults write com.apple.finder FXPreferredViewStyle Nlsv
  defaults write com.apple.finder FXDefaultSearchScope SCcf
  defaults write com.apple.finder _FXSortFoldersFirst -bool true
  defaults write com.apple.finder NewWindowTarget PfLo
  defaults write com.apple.finder NewWindowTargetPath "file://$HOME/Downloads/"

  # Dock: anchored right, small tiles, no recents; bottom-right hot corner (14)
  # is Quick Note, with no modifier key required.
  defaults write com.apple.dock orientation right
  defaults write com.apple.dock tilesize -int 40
  defaults write com.apple.dock show-recents -bool false
  defaults write com.apple.dock wvous-br-corner -int 14
  defaults write com.apple.dock wvous-br-modifier -int 0

  # Trackpad tap-to-click. Both trackpad domains plus the per-host tapBehavior
  # key are needed for it to stick across the login window and the desktop.
  defaults write com.apple.AppleMultitouchTrackpad Clicking -bool true
  defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
  defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1

  # Menu-bar clock: weekday + AM/PM, no date.
  defaults write com.apple.menuextra.clock ShowDayOfWeek -bool true
  defaults write com.apple.menuextra.clock ShowAMPM -bool true
  defaults write com.apple.menuextra.clock ShowDate -int 0

  # tart recommends shortening the bootpd DHCP lease from 86400s to 600s so
  # running many VMs daily doesn't exhaust the lease pool.
  info "Shorten the bootpd DHCP lease for tart VMs"
  sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.InternetSharing.default.plist \
    bootpd -dict DHCPLeaseTimeSecs -int 600

  # Apply the prefs that have a live-reload path by restarting their owners:
  # Finder (view/sidebar), Dock (orientation, hot corner), SystemUIServer
  # (screenshot location, clock). The NSGlobalDomain keyboard prefs have none and
  # take effect on next login. || true so a not-running process (e.g. in the
  # headless VM) doesn't fail the run.
  info "Restart Finder, Dock and SystemUIServer to apply prefs"
  killall Finder 2>/dev/null || true
  killall Dock 2>/dev/null || true
  killall SystemUIServer 2>/dev/null || true

  ok "Settings applied"
  warn "Log out and back in to apply the keyboard prefs (key repeat, accent popup)."
}

# --- main --------------------------------------------------------------------

# Join array elements with a single space, independent of $IFS.
join_spaces() { local IFS=' '; echo "$*"; }

usage() {
  cat <<EOF
Usage: install.sh [section ...]

Provisions an Apple Silicon macOS laptop. With no arguments, runs every
section in order: $(join_spaces "${ALL_SECTIONS[@]}")
Pass one or more section names to run only those.

Environment:
  LAPTOP_VM           non-interactive VM mode (credentials from the environment)
  LAPTOP_BECOME_PASS  sudo/FileVault password, required in VM mode
EOF
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
  esac

  local sections=("$@")
  [ ${#sections[@]} -gt 0 ] || sections=("${ALL_SECTIONS[@]}")

  for s in "${sections[@]}"; do
    local known=""
    for a in "${ALL_SECTIONS[@]}"; do [ "$s" = "$a" ] && { known=1; break; }; done
    [ -n "$known" ] || die "Unknown section '$s' (valid: $(join_spaces "${ALL_SECTIONS[@]}"))"
  done

  [ "$(uname -m)" = "arm64" ] || die "This script targets Apple Silicon only."

  printf '%s%s━━ laptop install ━━%s\n' "$BOLD" "$BLUE" "$RESET"
  info "sections: $(join_spaces "${sections[@]}")"
  [ -n "${LAPTOP_VM:-}" ] && info "LAPTOP_VM set — non-interactive VM mode"

  establish_sudo
  for s in "${sections[@]}"; do
    "$s"
  done

  INSTALL_DONE=1
  step "Done"
  ok "Provisioning complete in ${SECONDS}s"
}

main "$@"
