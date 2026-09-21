# Fedora Laptop

Reproducible workstation setup for **Fedora Silverblue 44**. GDM starts the
login session, Niri provides the Wayland compositor, and Noctalia supplies the
desktop shell.

## Layer model

```text
Base image (assumed, never layered)
  GNOME/GDM, git, openssh, toolbox, podman, flatpak,
  fontconfig, portals, PipeWire, NetworkManager, nautilus.

Host rpm-ostree (one transaction, one reboot)
  niri, noctalia, ghostty, keyd, wtype, tailscale.
  Declared in manifests/host-packages.txt.

User-local Mise (pinned, locked, survives rebases)
  herdr, yazi, neovim, tmux, fzf, bat, eza,
  zoxide, gh, jj, python.
  Declared in mise.toml + mise.lock. Dotfiles via mise dot apply.
  Linked as the global Mise config, so tools resolve in every directory.

Toolbx (project runtimes and container-only prompt)
  fedora-laptop-dev container, minimal DNF (git, openssh-clients,
  ncurses-term for Ghostty terminfo), project SDKs via Mise inside
  the container. Starship lives here only (mise.toolbox.toml,
  active with MISE_ENV=toolbox); host shells stay plain Bash.

Flatpak (system-wide)
  Firefox from Flathub, declared in manifests/flatpaks.txt.
```

Third-party host trust is limited to the Ghostty and keyd COPRs plus the
official Tailscale vendor repo. All COPR definitions are package-scoped
(`includepkgs`) with GPG checking; differing existing repo files refuse
instead of overwriting. Every key's fingerprint is pinned — in
`manifests/external-repositories.conf` for COPRs, in-script for Tailscale —
and verified against the downloaded key before any repo file is written.
Re-check fingerprints on the upstream project pages before changing them.

## Install

Review the scripts, manifests, and profile before running. Start with a dry run:

```sh
bash install.sh --dry-run
bash install.sh
```

Two passes. The first performs preflight and host package layering. If a new
deployment needs booting, `scripts/install-packages.sh` exits with status
`10`; `install.sh` stops without rebooting. Reboot manually, rerun the same
command. The second pass configures keyd/tailscale, installs the pinned Mise
release, applies tools and dotfiles, adds Flatpaks, creates the Toolbx, and
verifies.

Common options:

```text
--dry-run             Preview all mutating phases without applying changes
                      (verification is skipped: nothing was applied to verify)
--profile laptop      Select profiles/laptop
--replace-dotfiles    Back up conflicting dotfiles before replacement
--replace-system      Back up and replace a differing managed keyd config
--enable-keyd         Install and activate the system-wide keyd remap
```

Inspect deployments with `rpm-ostree status`; a successful layering
transaction is inactive until the matching deployment is booted.

## Profiles and dotfiles

Only the standard XDG layout (`XDG_CONFIG_HOME=$HOME/.config` or unset) is
supported; anything else fails fast. Machine-specific, non-secret settings
belong in `profiles/<name>/profile.env`.
Start from `profiles/laptop/profile.env.example`; the real file is ignored.
The installer links it into `~/.config/fedora-laptop/` when present.

Dotfiles are owned by Mise `[dotfiles]` in `mise.toml`, not Stow. Inspect
before applying:

```sh
mise bootstrap dotfiles status
mise bootstrap dotfiles diff
mise bootstrap dotfiles apply --dry-run
```

Mise refuses to overwrite conflicting real files. Use `--replace-dotfiles`
to back up known managed targets first. Niri output names are hardware data:
capture them with `niri msg outputs` and keep machine rules in the profile.

## Verification and recovery

Final phase runs `scripts/verify.sh`:

```sh
rpm-ostree status
systemctl status keyd tailscaled
mise bootstrap dotfiles status
niri msg outputs
```

If a deployment fails, select the previous entry at boot or run
`rpm-ostree rollback` and reboot. Rollback reverts `/usr` only; `/etc/keyd`,
repo files, and home symlinks must be reverted separately.

keyd is opt-in: pass `--enable-keyd` to install and activate the remap.
It applies to every keyboard, swaps Left Alt/Meta, and turns held Left
Control into a Shift+Meta layer (not Control). Keep a second input ready.

keyd recovery drill (an invalid map can break typing):

1. Switch to a TTY (`Ctrl+Alt+F3`) or boot the previous deployment.
2. `sudo systemctl stop keyd`
3. Repair or remove `/etc/keyd/default.conf`.
4. `sudo systemctl restart keyd` (or leave it stopped).
5. Note: `rpm-ostree rollback` does NOT revert `/etc/keyd` — fix it by hand.

Tailscale needs one manual step: `sudo tailscale up`.

Base services (NetworkManager, firewalld, fstrim, power-profile backend)
are observed and reported, never enabled or changed by the installer. Only
`keyd` (opt-in) and `tailscaled` are managed.

## Security boundaries

The installer crosses privilege boundaries only in package and system phases.
Read every `sudo` command, systemd unit, and `/etc` file before execution.
Profiles are trusted local config; the repo contains no secrets and never
reboots automatically.
