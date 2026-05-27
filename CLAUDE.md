# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repo provisions a personal macOS laptop (developer machine of `adrienkohlbecker`) with a single bash script, `install.sh`. There is no application code, build step, or test suite — running the script *is* the deliverable. It targets one machine set up once; it is not built for fleet-wide convergence, but every step is individually idempotent, so re-running is safe.

(It was previously an Ansible playbook; that was dropped in favour of one readable, streamed script. There is no longer any `ansible.cfg`, `site.yml`, `roles/`, or `start.sh`.)

This repo is one of several that together set up the machine; it owns Homebrew packages, GUI/App Store apps, macOS defaults, and bootstrapping the runtime/dotfiles managers. It deliberately does **not** own:
- **dotfiles** — a separate repo, deployed with GNU stow. `install.sh` clones it to `~/Work/dotfiles`, and that is the directory the `dotfiles` step stows from.
- **runtime/CLI tool versions** — declared in mise config that lives *in the dotfiles repo*, not here.

## Running it

```bash
./install.sh                  # run every section, in order
./install.sh settings         # run only the named section(s)
```

`install.sh` is run from a checkout (your `~/Desktop/laptop`, or the read-only VM mount); it provisions from its own directory (`SCRIPT_DIR`) and uses the `Brewfile` next to it. On a fresh machine, `git clone` the repo first (cloning triggers the Command Line Tools install), then run it. Some steps need sudo — on a real machine it prompts once up front and keeps the timestamp warm; in the VM the password comes from the environment (see below).

## Architecture

`install.sh` is a single script with one function per concern. `main "$@"` runs the requested sections (all of them by default) in this order — **order matters**:

1. `bootstrap` — FileVault (instant on Apple Silicon, no reboot; `fdesetup -inputplist` in the VM, interactive prompt otherwise), Command Line Tools (headless via the `softwareupdate` install-on-demand trick), Homebrew (installs + `brew shellenv` onto PATH), and cloning the dotfiles repo to `~/Work/dotfiles`.
2. `packages` — `brew bundle install --no-upgrade` against the repo's `Brewfile` (taps, CLI formulae incl. `mise`/`stow`, casks, App Store apps). Streams live. `brew bundle` is idempotent and orders taps → brews → casks → mas itself.
3. `dotfiles` — delegates to the dotfiles repo's own `mise run restow` task (which runs `stow --restow */` from `~/Work/dotfiles` into `$HOME` and hardens `~/.gnupg` to `0700`); `install.sh` just `mise trust`s the fresh clone first. **Must follow `packages`** (needs `mise`/`stow`) and **precede `runtimes`** (deploys `~/.config/mise/config.toml` + `config.mac.toml` and the `~/.default-*` lists mise reads).
4. `runtimes` — `MISE_ENV=mac mise install`, run **from `$HOME`** so the repo-local `mise.toml` (the test harness, see below) is not loaded. The global `config.toml` holds cross-platform CLI tools; `config.mac.toml` (gated by `MISE_ENV=mac`) adds language runtimes (python, ruby, node, go) and mac-only tools.
5. `settings` — SSH config dir + Keychain stanza (`0700`/`0600`), `softwareupdate --schedule on`, unhide `~/Library`, macOS preferences via `defaults write` (screenshots, key repeat, dock, accented keys), and a shorter bootpd DHCP lease for tart VMs.

### What is and isn't configured here

- **Tool/runtime versions are NOT in this repo.** To change a CLI tool or language version, edit the mise config in the **dotfiles repo** (`config/.config/mise/config.toml` for cross-platform tools, `config.mac.toml` for runtimes/mac-only). The `runtimes` step just triggers the install.
- **GUI apps and CLI packages installed via Homebrew** are the editable list in the repo-root `Brewfile`: `brew` (CLI formulae), `cask` (GUI), `mas` (App Store, by numeric ID). Add/remove by editing the `Brewfile`.
- **The `mas` block is wrapped in `if ENV["HOMEBREW_LAPTOP_VM"].to_s.empty?`** (the Brewfile is evaluated as Ruby) so App Store apps are skipped in the headless VM, where there's no signed-in Apple ID.

## Testing in a throwaway VM

`packer/laptop.pkr.hcl` builds a clean macOS VM with [Tart](https://tart.run) and runs `install.sh` inside it to exercise the whole thing end to end. `tart` and `packer` are pinned in the **repo-local `mise.toml`** (separate from the machine's runtime config in the dotfiles repo; the `runtimes` step runs from `$HOME` so it never loads this file).

```bash
mise trust && mise install            # one-time: trust + install the pinned tart/packer
mise run test-vm                      # packer init + build with defaults
mise run test-vm -- -var vm_base_name=tahoe-vanilla   # reuse a local clone, no re-download
```

How it works: the repo is mounted **read-only** into the VM (Tart exposes it at `/Volumes/My Shared Files/laptop`) and `install.sh` provisions straight from the mount, so your **local working copy — including uncommitted changes — is tested, no push required**. `LAPTOP_VM=1` makes `install.sh` non-interactive: it takes the sudo/FileVault password from `LAPTOP_BECOME_PASS` (default `admin`) and bridges `LAPTOP_VM` → `HOMEBREW_LAPTOP_VM` so the Brewfile skips its App Store apps.

Gotchas: the default `*-vanilla` image ships the Command Line Tools but not Homebrew (which `install.sh` installs, hence `NONINTERACTIVE=1`). The `test-vm` task uses a variadic arg placed before the template, so `mise run test-vm -- <flags>` forwards `-var …`/`-force` correctly to `packer build`.

## Conventions & gotchas

- **Bootstrap ordering / chicken-and-egg:** the mise config is delivered by stow, and `stow`/`mise` binaries come from Homebrew — hence the strict `packages → dotfiles → runtimes` order. `install.sh` runs `eval "$(brew shellenv)"` after installing Homebrew so the rest of the script (and a fresh machine with no brew on PATH) can find `brew`/`stow`/`mise`.
- **dotfiles are a plain repo deployed via stow** (bootstrap clone at `~/Work/dotfiles`), not a bare git repo and not submodules. vim/zsh plugins that used to be git submodules are now fetched by mise's `http` backend (see the dotfiles `config.toml`).
- `install.sh` clones the dotfiles repo over **https** (a fresh machine has no SSH key yet); the dotfiles repo's own `origin` is SSH.
- **macOS `defaults`:** the `settings` step `killall`s Dock and SystemUIServer to apply the Dock and screenshot prefs live; the `NSGlobalDomain` keyboard prefs (KeyRepeat, InitialKeyRepeat, ApplePressAndHoldEnabled) have no live-reload path and take effect on next login.
