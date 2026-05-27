# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is an Ansible playbook that provisions a personal macOS laptop (developer machine of `adrienkohlbecker`). There is no application code, build step, or test suite — running the playbook *is* the deliverable, and it is idempotent (re-runnable to converge the machine to the declared state).

This repo is one of several that together set up the machine; it owns Homebrew packages, GUI/App Store apps, macOS defaults, and bootstrapping the runtime/dotfiles managers. It deliberately does **not** own:
- **dotfiles** — a separate repo, deployed with GNU stow. `start.sh` bootstrap-clones it to `~/Desktop/dotfiles`, and that is the directory `stow.yml` deploys from. The user's canonical working copies (`~/Work/dotfiles`, etc.) come from a backup restore, separate from this bootstrap.
- **runtime/CLI tool versions** — declared in mise config that lives *in the dotfiles repo*, not here.
- **the compta / backup jobs** — now launchd agents installed by their own repos (`~/Work/compta`, `~/Work/backup`), no longer cron entries here.

## Running the playbook

The playbook targets `localhost` only (`hosts.ini` maps `localhost` to a local connection, and `site.yml` runs against `all`).

```bash
# Full bootstrap on a fresh machine (enables FileVault, installs Xcode CLT,
# clones laptop + dotfiles into ~/Desktop, installs Homebrew + Ansible, runs the playbook)
./start.sh

# Re-run the playbook directly (sudo password is needed for some tasks)
ansible-playbook -i hosts.ini site.yml --ask-become-pass

# Run only a subset of tasks via tags (see Tags below)
ansible-playbook -i hosts.ini site.yml --ask-become-pass --tags mise
```

`ansible.cfg` sets verbose, YAML-formatted output (`result_format = yaml`, `verbosity = 1`, `bin_ansible_callbacks = True`) and `diff.always = True`, so runs are verbose and show diffs by default.

## Testing in a throwaway VM

`packer/laptop.pkr.hcl` builds a clean macOS VM with [Tart](https://tart.run) and runs `start.sh` inside it (with `LAPTOP_VM=1`) to exercise the whole bootstrap end to end. `tart` and `packer` are pinned in the **repo-local `mise.toml`** (separate from the machine's runtime config in the dotfiles repo; the playbook's `mise.yml` deliberately runs from `$HOME` so it never loads this file).

```bash
mise trust && mise install            # one-time: trust + install the pinned tart/packer
mise run test-vm                      # packer init + build with defaults
mise run test-vm -- -var vm_base_name=ghcr.io/cirruslabs/macos-tahoe-vanilla:latest
```

How it works: the repo is mounted **read-only** into the VM (Tart exposes it at `/Volumes/My Shared Files/laptop`); `start.sh` copies it to `~/Desktop/laptop` and provisions from there, so your **local working copy — including uncommitted changes — is what gets tested, no push required** (the copy step also avoids the space-containing mount path, which would break ansible's `command` module). `LAPTOP_VM=1` makes `start.sh` skip the FileVault gate and take the sudo password from `LAPTOP_BECOME_PASS` (default `admin`) instead of prompting.

Gotchas: the default `*-vanilla` image ships the Command Line Tools but not Homebrew (which `start.sh` installs, hence `NONINTERACTIVE=1`). App Store (`mas`) apps in the Brewfile **cannot install headlessly** (no signed-in Apple ID), so a full run currently fails at that step — strip `mas` entries or sign in if you need a green build.

## Architecture

Everything lives in a single role, `laptop`, orchestrated by `roles/laptop/tasks/main.yml`, which imports task files **in this order** (order matters). Each `import_tasks` carries the tag for that slice, so the tag applies to every task in the imported file:

1. `packages.yml` — runs `brew bundle install --no-upgrade` against the repo-root `Brewfile`, which declares the taps, CLI formulae (incl. `mise` and `stow`, the two managers the later steps drive), GUI casks, and Mac App Store apps. `brew bundle` is idempotent and resolves its own ordering (taps → brews → casks → mas).
2. `stow.yml` — asserts the bootstrap clone exists, then runs `stow */` from `~/Desktop/dotfiles` (the clone `start.sh` creates) to symlink every dotfiles package into `$HOME`. **Must precede `mise.yml`**, because it deploys `~/.config/mise/config.toml` + `config.mac.toml` and the `~/.default-*` package lists that mise reads.
3. `mise.yml` — `MISE_ENV=mac mise install`: installs everything declared in the stowed mise config. The global `config.toml` holds cross-platform CLI utilities; `config.mac.toml` (gated behind `MISE_ENV=mac`) adds language runtimes (python, ruby, node, go) and mac-only tools. The single `MISE_ENV=mac` invocation resolves both layers.
4. `settings.yml` — SSH config dirs/keychain, macOS preferences via `osx_defaults` / `shell`, and `softwareupdate --schedule on`.

### What is and isn't configured here

- **Tool/runtime versions are NOT in this repo.** To change a CLI tool or language version, edit the mise config in the **dotfiles repo** (`config/.config/mise/config.toml` for cross-platform tools, `config.mac.toml` for runtimes/mac-only), not anything here. `mise.yml` just triggers the install.
- **GUI apps and CLI packages installed via Homebrew** are the editable list in the repo-root `Brewfile`: `brew` (CLI formulae), `cask` (GUI), `mas` (App Store, by numeric ID). Add/remove by editing the `Brewfile`, not by adding tasks.
- **There are no `group_vars`** — every former variable became dead when asdf and the cron jobs were removed.

### Tags

Task slices you can run with `--tags`: `packages` (the `brew bundle` run), `stow`, `mise`, `settings`. Tags are declared on the `import_tasks` lines in `main.yml`, so every task in a file inherits its slice's tag.

## Conventions & gotchas

- **Bootstrap ordering / chicken-and-egg:** the mise config is delivered by stow, and stow + mise binaries come from Homebrew (installed by `brew bundle`) — hence the strict `packages → stow → mise` order in `main.yml`. Shell/command tasks that invoke `brew`/`mise`/`stow` prepend `/opt/homebrew/bin` to `PATH` (the binaries aren't on Ansible's non-interactive PATH otherwise).
- **dotfiles are a plain repo deployed via stow** (bootstrap clone at `~/Desktop/dotfiles`), not a bare git repo and not submodules. vim/zsh plugins that used to be git submodules are now fetched by mise's `http` backend (see the dotfiles `config.toml`).
- **Scheduled jobs are launchd, not cron.** `settings.yml` no longer defines the compta/backup jobs; they are launchd agents/daemons installed by each job's own repo via its `mise install-launchd` task. Don't re-add them as cron here.
- `start.sh` clones over **https** (a fresh machine has no SSH key yet); the dotfiles repo's own `origin` is SSH.
