# Fedora Laptop

Reproducible workstation setup for **Fedora Silverblue 44 or newer**. GDM
starts the login session, Niri provides the Wayland compositor, and Noctalia
supplies the desktop shell.

## Layer model

```text
Base image (assumed, never layered)
  GNOME/GDM, git, openssh, toolbox, podman, flatpak,
  fontconfig, portals, PipeWire, NetworkManager, nautilus.

Host rpm-ostree (one transaction, one reboot)
  niri, noctalia, ghostty, keyd, wtype, gcc, make, wl-clipboard,
  tailscale, openssh-server, Docker CE + Compose/buildx.
  Declared in manifests/host-packages.txt.

User-local Mise (rolling latest, survives rebases)
  herdr, yazi, neovim, tmux, fzf, bat, eza,
  zoxide, gh, jj, opencode, ripgrep, tree-sitter,
  starship, node, lazygit, prettierd, fd, go.
  Declared in mise.toml (no lockfile by design). Dotfiles via mise dot apply.
  Linked as the global Mise config, so tools resolve in every directory.
  Go stays global; other project language runtimes stay per-project.

Toolbx (project runtimes)
  fedora-laptop-dev container, minimal DNF (gcc, make,
  wl-clipboard for Neovim builds/clipboard). The same rolling
  Mise CLI tools are available inside the container. Starship is
  global (host and Toolbx) and shows a `⬢ [dev]` marker inside containers
  via its `container` module.

Flatpak (system-wide)
  Firefox from Flathub, declared in manifests/flatpaks.txt.
```

Neovim's configuration is kept in the independent kickstart.nvim
repository and follows its `master` branch. It is managed natively by
Mise: `[bootstrap.repos]` in `mise.toml` clones it to
`~/.local/share/fedora-laptop/sources/nvim`, and the `[dotfiles]`
`~/.config/nvim` entry links at it. The dotfiles phase runs
`mise bootstrap repos apply/update` (dirty checkouts are skipped, never
discarded) before applying links, so reruns follow the branch tip
without touching local edits.

Third-party host trust is limited to the Ghostty and keyd COPRs plus the
official Docker and Tailscale vendor repos. All COPR definitions are
package-scoped (`includepkgs`) with GPG checking; differing existing repo
files refuse instead of overwriting. Every key's fingerprint is pinned — in
`manifests/external-repositories.conf` for COPRs,
`manifests/vendor-repositories.conf` for vendor repos — and verified
against the downloaded key before any repo file is written.
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
command. The second pass configures keyd (opt-in), WiFi powersave, and the
Docker/SSH/Tailscale services, installs the latest Mise tools, applies
dotfiles (including the Neovim checkout and its link), adds Flatpaks,
creates the Toolbx, and verifies.

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

`XDG_CONFIG_HOME` is honored when set, otherwise `~/.config`.
Machine-specific, non-secret settings belong in `profiles/<name>/profile.env`.
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

Global Mise tools are intentionally rolling. Go is installed globally;
other project language runtimes are not installed by this laptop
profile; declare them in each project instead:

```sh
cd /path/to/project
mise use python@3.13
```

## Updates

There is no GNOME Software here, so updates are explicit and notify-only.
Two streams are covered; everything else stays manual:

- OS deployment (`rpm-ostree`, base plus host layers).
- System Flatpaks.

A daily user timer (`fedora-update-check.timer`) runs
`fedora-update-check`, which performs read-only checks and sends one
Noctalia notification when the pending set changes (a state file prevents
repeat nags). Nothing is staged or applied automatically.

Act on a notification with `Super+Alt+U` or by running `fedora-update` in
a terminal: it stages the OS deployment (takes effect on reboot) and
updates system Flatpaks immediately. Deliberately out of scope: Mise tools
(`mise upgrade` when you choose), the toolbox userland (`dnf upgrade`
inside `fedora-laptop-dev`), firmware (`fwupdmgr`), and Neovim/Mason packages.

## Remote development over Tailscale SSH

SSH sessions land on the host and authenticate through Tailscale identity,
so no SSH keys are needed on clients. Tailscale SSH sessions skip
`pam_systemd`, leaving `XDG_RUNTIME_DIR` unset; without it rootless
Podman/Toolbox fails. The managed `.bashrc` repairs this automatically
(before the non-interactive early return), so
`toolbox enter fedora-laptop-dev` works from any Tailscale SSH shell.

## Verification and recovery

Final phase runs `scripts/verify.sh`:

```sh
rpm-ostree status
systemctl status keyd tailscaled docker sshd
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

The installer enables Docker, `sshd`, and `tailscaled`, but does not
authenticate or populate them. Docker starts with no migrated containers,
images, or volumes.

Base services (NetworkManager, firewalld, fstrim, power-profile backend)
are observed and reported, never enabled or changed by the installer, except
that SSH is allowed in the default firewalld zone. Only `keyd` (opt-in),
the Docker/SSH/Tailscale services, and the WiFi powersave config are managed.

WiFi power save is unconditionally disabled via
`system/NetworkManager/wifi-powersave.conf` (`wifi.powersave = 2`): the
Fedora default parks the radio and adds wake-up latency spikes that power
profiles (Noctalia/tuned) do not govern. Battery cost is negligible. The
setting takes effect on NetworkManager restart or reboot.

## Security boundaries

The installer crosses privilege boundaries only in package and system phases.
Read every `sudo` command, systemd unit, and `/etc` file before execution.
Profiles are trusted local config; the repo contains no secrets and never
reboots automatically.
