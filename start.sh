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

if [ -d $HOME/.dotfiles ]; then
    git --git-dir=$HOME/.dotfiles --work-tree=$HOME pull --ff-only
    git --git-dir=$HOME/.dotfiles --work-tree=$HOME checkout master
else
    git clone -q --separate-git-dir=$HOME/.dotfiles https://github.com/adrienkohlbecker/dotfiles.git $HOME/temp-dotfiles -b master
    git --git-dir=$HOME/.dotfiles --work-tree=$HOME reset --hard
    rm -rf $HOME/temp-dotfiles
fi

if ! which brew; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

if ! which ansible; then
    brew install ansible
fi

(
    cd $HOME/Desktop/laptop || exit 1

    ansible-playbook -i hosts.ini site.yml --ask-become-pass
)
