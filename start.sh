#!/bin/bash
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
IFS=$'\n\t'
set -euxo pipefail

# FileVault can't be enabled headlessly, so skip it inside the Tart test VM
# (packer/laptop.pkr.hcl sets LAPTOP_VM). Real laptops still get it.
if [ -z "${LAPTOP_VM:-}" ]; then
    sudo fdesetup status | grep "is On" || (sudo fdesetup enable -forcerestart; echo "Reboot then restart this script"; exit 1)
fi

[ -e /Library/Developer/CommandLineTools/usr/bin/clang ] || (/usr/bin/xcode-select --install; echo "Restart script when xcode CLT installed"; exit 1)

if [ -n "${LAPTOP_VM:-}" ]; then
    # Provisioned from a working copy that packer/laptop.pkr.hcl mounts read-only
    # at /Volumes/My Shared Files/laptop. Copy it to a space-free path (paths with
    # spaces break ansible's command module) and run from there, so the mounted
    # working copy — including uncommitted changes — is what gets tested.
    LAPTOP_DIR="$HOME/Desktop/laptop"
    rm -rf "$LAPTOP_DIR"
    mkdir -p "$LAPTOP_DIR"
    cp -R "${LAPTOP_MOUNT:-/Volumes/My Shared Files/laptop}/." "$LAPTOP_DIR/"
else
    LAPTOP_DIR="$HOME/Desktop/laptop"
    if [ -d "$LAPTOP_DIR" ]; then
        ( cd "$LAPTOP_DIR" && git pull --ff-only )
    else
        mkdir -p "$LAPTOP_DIR"
        git clone -q https://github.com/adrienkohlbecker/laptop.git "$LAPTOP_DIR" -b master
    fi
fi

# Bootstrap clone of the dotfiles into ~/Desktop (a fresh machine has no SSH key
# yet, hence https). The playbook's stow.yml deploys the symlinks from here, so
# provisioning doesn't depend on ~/Work — the canonical working copies of
# dotfiles, compta, backup, ... — being restored from backup first.
if [ -d $HOME/Desktop/dotfiles ]; then
    ( cd $HOME/Desktop/dotfiles && git pull --ff-only )
else
    git clone -q https://github.com/adrienkohlbecker/dotfiles.git $HOME/Desktop/dotfiles -b master
fi

if ! which brew; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# The installer doesn't touch the current shell's PATH, so put brew on it before
# the rest of the script uses it (needed on a fresh machine with no brew yet).
eval "$(/opt/homebrew/bin/brew shellenv)"

if ! which ansible; then
    brew install ansible
fi

(
    cd "$LAPTOP_DIR" || exit 1

    if [ -n "${LAPTOP_VM:-}" ]; then
        # Headless VM run: the sudo password comes from the environment
        # (LAPTOP_BECOME_PASS, default "admin") instead of an interactive prompt.
        ansible-playbook -i hosts.ini site.yml -e ansible_become_password="${LAPTOP_BECOME_PASS:-admin}"
    else
        ansible-playbook -i hosts.ini site.yml --ask-become-pass
    fi
)
