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

## Architecture

Everything lives in a single role, `laptop`, orchestrated by `roles/laptop/tasks/main.yml`, which imports task files **in this order** (order matters):

1. `base.yml` — updates Homebrew.
2. `brew.yml` — taps + CLI tools via the `homebrew` module (includes `mise` and `stow`, the two managers the later steps drive).
3. `stow.yml` — runs `stow */` from `~/Desktop/dotfiles` (the bootstrap clone `start.sh` creates) to symlink every dotfiles package into `$HOME`. **Must precede `mise.yml`**, because it deploys `~/.config/mise/config.toml` + `config.mac.toml` and the `~/.default-*` package lists that mise reads.
4. `mise.yml` — `MISE_ENV=mac mise install`: installs everything declared in the stowed mise config. The global `config.toml` holds cross-platform CLI utilities; `config.mac.toml` (gated behind `MISE_ENV=mac`) adds language runtimes (python, ruby, node, go) and mac-only tools. The single `MISE_ENV=mac` invocation resolves both layers.
5. `casks.yml` — GUI apps via `homebrew_cask`.
6. `mas.yml` — Mac App Store apps via `mas` (referenced by numeric app ID, with a trailing comment naming each app).
7. `settings.yml` — SSH config dirs/keychain, macOS preferences via `osx_defaults` / `shell`, and `softwareupdate --schedule on`.

### What is and isn't configured here

- **Tool/runtime versions are NOT in this repo.** To change a CLI tool or language version, edit the mise config in the **dotfiles repo** (`config/.config/mise/config.toml` for cross-platform tools, `config.mac.toml` for runtimes/mac-only), not anything here. `mise.yml` just triggers the install.
- **GUI apps and CLI packages installed via Homebrew** are the editable lists here: `brew.yml` (CLI), `casks.yml` (GUI), `mas.yml` (App Store). Add/remove by editing the relevant list, not by adding tasks.
- **There are no `group_vars`** — every former variable became dead when asdf and the cron jobs were removed.

### Tags

Task slices you can run with `--tags`: `base`, `packages` (brew CLI install), `stow`, `mise`, `casks`, `mas`, `settings`.

## Conventions & gotchas

- **Bootstrap ordering / chicken-and-egg:** the mise config is delivered by stow, and stow + mise binaries come from Homebrew — hence the strict `brew → stow → mise` order in `main.yml`. Shell tasks that invoke `mise`/`stow` prepend `/opt/homebrew/bin` to `PATH` (the binaries aren't on Ansible's non-interactive PATH otherwise).
- **dotfiles are a plain repo deployed via stow** (bootstrap clone at `~/Desktop/dotfiles`), not a bare git repo and not submodules. vim/zsh plugins that used to be git submodules are now fetched by mise's `http` backend (see the dotfiles `config.toml`).
- **Scheduled jobs are launchd, not cron.** `settings.yml` no longer defines the compta/backup jobs; they are launchd agents/daemons installed by each job's own repo via its `mise install-launchd` task. Don't re-add them as cron here.
- `start.sh` clones over **https** (a fresh machine has no SSH key yet); the dotfiles repo's own `origin` is SSH.
