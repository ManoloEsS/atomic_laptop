#!/usr/bin/env bash
# Deploy laptop dotfiles via Mise native [dotfiles] (replaces GNU Stow).
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

REPLACE=false
MISE_BIN="$HOME/.local/bin/mise"
[[ -x $MISE_BIN ]] || MISE_BIN="mise"

# Managed targets are derived from mise.toml [dotfiles] so backups never drift
# from what `mise bootstrap dotfiles apply` will touch.
managed_targets() {
  grep -oE '"~/[^"]+"' "$REPO_ROOT/mise.toml" | tr -d '"' | while IFS= read -r target; do
    printf '%s\n' "${target/#\~/$HOME}"
  done
}

usage() {
  printf 'Usage: %s [--profile NAME] [--dry-run] [--replace-dotfiles]\n' "${0##*/}"
}

while (($#)); do
  case $1 in
    --dry-run) DRY_RUN=true ;;
    --profile)
      (($# >= 2)) || usage_error "--profile requires a value"
      select_profile "$2"
      shift
      ;;
    --replace|--replace-dotfiles) REPLACE=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift
done

reject_root
[[ -f $REPO_ROOT/mise.toml ]] || die "mise.toml is missing: $REPO_ROOT/mise.toml"

# Ghostty TERM (xterm-ghostty) entry for contexts without system terminfo
# (notably Toolbx). Source vendored from ghostty-1.3.1; compiled user-local
# so it follows $HOME into every container. Always ensured: a system entry
# on the host does not help the container's separate /usr.
if [[ -f $HOME/.terminfo/x/xterm-ghostty ]]; then
  info "user terminfo entry present: xterm-ghostty"
elif is_dry_run; then
  info "Would compile dotfiles/terminfo/xterm-ghostty.ti into ~/.terminfo"
else
  require_command tic
  tic -x "$REPO_ROOT/dotfiles/terminfo/xterm-ghostty.ti"
  info "installed user terminfo entry: xterm-ghostty"
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
backup_root="$HOME/.local/state/fedora-laptop/backups/$timestamp"

if [[ $REPLACE == true ]]; then
  while IFS= read -r target; do
    if [[ -f $target && ! -L $target ]]; then
      dest=$(backup_path "$target" "$backup_root")
      if is_dry_run; then
        info "Would back up $target to $dest"
      else
        mkdir -p -- "$(dirname -- "$dest")"
        mv -- "$target" "$dest"
        info "Backed up $target"
      fi
    fi
  done < <(managed_targets)
fi

# Remove the repository-managed .profile symlink from older revisions, but
# leave regular files and unrelated symlinks untouched.
legacy_profile="$HOME/.profile"
legacy_source="$REPO_ROOT/dotfiles/bash/.profile"
if [[ -L $legacy_profile && $(readlink -f -- "$legacy_profile" 2>/dev/null || true) == "$legacy_source" ]]; then
  if is_dry_run; then
    info "Would remove legacy managed symlink $legacy_profile"
  else
    rm -- "$legacy_profile"
    info "Removed legacy managed symlink $legacy_profile"
  fi
fi

if is_dry_run; then
  info "Would run: $MISE_BIN trust $REPO_ROOT/mise.toml"
  info "Would run: $MISE_BIN bootstrap dotfiles apply --dry-run (status/diff preview)"
  print_command "$MISE_BIN" bootstrap dotfiles apply --dry-run
else
  command -v "$MISE_BIN" >/dev/null 2>&1 || die "required command not found: $MISE_BIN"
  "$MISE_BIN" trust "$REPO_ROOT/mise.toml"
  "$MISE_BIN" bootstrap dotfiles apply
fi

niri_local="$HOME/.config/niri/local.kdl"
niri_example="$REPO_ROOT/profiles/$PROFILE/local.kdl.example"
if [[ ! -e $niri_local && ! -L $niri_local ]]; then
  if is_dry_run; then
    info "Would install Niri machine-output stub to $niri_local"
  else
    [[ -r $niri_example ]] || die "Niri output example is missing: $niri_example"
    mkdir -p -- "$HOME/.config/niri"
    cp -- "$niri_example" "$niri_local"
    info "Installed Niri machine-output stub; edit $niri_local with real output IDs"
  fi
fi

# Touchpad fragment defaulted ON; toggle-touchpad owns it afterwards.
# Never overwritten: a missing include breaks Niri config load entirely.
niri_touchpad="$HOME/.config/niri/touchpad.kdl"
if [[ ! -e $niri_touchpad && ! -L $niri_touchpad ]]; then
  if is_dry_run; then
    info "Would install Niri touchpad stub (enabled) to $niri_touchpad"
  else
    mkdir -p -- "$HOME/.config/niri"
    printf '%s\n' '// Touchpad enabled (managed by toggle-touchpad).' >"$niri_touchpad"
    info "Installed Niri touchpad stub (enabled)"
  fi
fi

profile_source="$REPO_ROOT/profiles/$PROFILE/profile.env"
profile_target="$HOME/.config/fedora-laptop/profile.env"
if [[ -r $profile_source ]]; then
  if [[ -e $profile_target || -L $profile_target ]] && [[ $(readlink -f -- "$profile_source" 2>/dev/null || true) != $(readlink -f -- "$profile_target" 2>/dev/null || true) ]]; then
    if [[ $REPLACE == true ]]; then
      dest=$(backup_path "$profile_target" "$backup_root")
      if is_dry_run; then
        info "Would back up $profile_target to $dest"
      else
        if [[ -f $profile_target && ! -L $profile_target ]]; then
          mkdir -p -- "$(dirname -- "$dest")"
          mv -- "$profile_target" "$dest"
        else
          rm -- "$profile_target"
        fi
      fi
    else
      die "profile environment conflicts at $profile_target; rerun with --replace-dotfiles for a regular file"
    fi
  fi
  if [[ ! -e $profile_target && ! -L $profile_target ]]; then
    if is_dry_run; then
      info "Would link $profile_source to $profile_target"
    else
      mkdir -p -- "$HOME/.config/fedora-laptop"
      ln -s -- "$profile_source" "$profile_target"
    fi
  fi
fi

# Notify-only update checker: user timer, enabled once its unit is linked
# into ~/.config/systemd/user by the Mise dotfiles above.
update_timer="$HOME/.config/systemd/user/fedora-update-check.timer"
if [[ ! -e $update_timer && ! -L $update_timer ]]; then
  warn "update-check timer unit is not linked; skipping timer enablement"
elif is_dry_run; then
  print_command systemctl --user daemon-reload
  print_command systemctl --user enable --now fedora-update-check.timer
else
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl is unavailable; update-check timer was not enabled"
  elif run systemctl --user daemon-reload && run systemctl --user enable --now fedora-update-check.timer; then
    info "Enabled user update-check timer: fedora-update-check.timer"
  else
    warn "update-check timer could not be enabled (user manager unavailable?)"
  fi
fi

# ya ships with yazi via Mise; resolve through Mise shims since a
# non-interactive shell has no activated PATH here.
if is_dry_run; then
  print_command "$MISE_BIN" exec -- ya pkg install
elif (cd "$REPO_ROOT" && "$MISE_BIN" which ya >/dev/null 2>&1); then
  # Run from the repo so Mise discovers mise.toml tool versions.
  (cd "$REPO_ROOT" && "$MISE_BIN" exec -- ya pkg install)
else
  warn "ya is unavailable via Mise; Yazi flavor install skipped"
fi

info "Dotfiles applied via Mise"
