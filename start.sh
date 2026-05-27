#!/bin/bash
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
IFS=$'\n\t'
set -euxo pipefail

sudo fdesetup status | grep "is On" || (sudo fdesetup enable -forcerestart; echo "Reboot then restart this script"; exit 1)

[ -e /Library/Developer/CommandLineTools/usr/bin/clang ] || (/usr/bin/xcode-select --install; echo "Restart script when xcode CLT installed"; exit 1)

if [ -d $HOME/Desktop/laptop ]; then
    ( cd $HOME/Desktop/laptop && git pull --ff-only )
else
    mkdir -p $HOME/Desktop/laptop
    git clone -q https://github.com/adrienkohlbecker/laptop.git $HOME/Desktop/laptop -b master
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

if ! which ansible; then
    brew install ansible
fi

(
    cd $HOME/Desktop/laptop || exit 1

    ansible-playbook -i hosts.ini site.yml --ask-become-pass
)
