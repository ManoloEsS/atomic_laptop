#!/usr/bin/env bash
# Deploy dotfiles via Mise native [dotfiles] (replaces GNU Stow).
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

REPLACE=false
MISE_BIN="$HOME/.local/bin/mise"
command -v "$MISE_BIN" >/dev/null 2>&1 || MISE_BIN="mise"

# Managed targets mirrored from mise.toml [dotfiles] for conflict backups.
MANAGED_TARGETS=(
  "$HOME/.bash_aliases"
  "$HOME/.bash_functions"
  "$HOME/.bash_profile"
  "$HOME/.bashrc"
  "$HOME/.inputrc"
  "$HOME/.profile"
  "$HOME/.config/starship.toml"
)

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
elif [[ $DRY_RUN == true ]]; then
  info "Would compile dotfiles/terminfo/xterm-ghostty.ti into ~/.terminfo"
else
  require_command tic
  tic -x "$REPO_ROOT/dotfiles/terminfo/xterm-ghostty.ti"
  info "installed user terminfo entry: xterm-ghostty"
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
backup_root="$HOME/.local/state/fedora-laptop/backups/$timestamp"

if [[ $REPLACE == true ]]; then
  for target in "${MANAGED_TARGETS[@]}"; do
    if [[ -f $target && ! -L $target ]]; then
      rel=${target#"$HOME/"}
      if [[ $DRY_RUN == true ]]; then
        info "Would back up $target to $backup_root/$rel"
      else
        mkdir -p -- "$backup_root/$(dirname -- "$rel")"
        mv -- "$target" "$backup_root/$rel"
        info "Backed up $target"
      fi
    fi
  done
fi

if [[ $DRY_RUN == true ]]; then
  info "Would run: $MISE_BIN trust $REPO_ROOT/mise.toml"
  info "Would run: $MISE_BIN bootstrap dotfiles apply --dry-run (status/diff preview)"
  print_command "$MISE_BIN" bootstrap dotfiles apply --dry-run
else
  require_command "$MISE_BIN"
  "$MISE_BIN" trust "$REPO_ROOT/mise.toml"
  "$MISE_BIN" bootstrap dotfiles apply
fi

niri_local="$HOME/.config/niri/local.kdl"
niri_example="$REPO_ROOT/profiles/$PROFILE/local.kdl.example"
if [[ ! -e $niri_local && ! -L $niri_local ]]; then
  if [[ $DRY_RUN == true ]]; then
    info "Would install Niri machine-output stub to $niri_local"
  else
    mkdir -p -- "$HOME/.config/niri"
    cp -- "$niri_example" "$niri_local"
    info "Installed Niri machine-output stub; edit $niri_local with real output IDs"
  fi
fi

profile_source="$REPO_ROOT/profiles/$PROFILE/profile.env"
profile_target="$HOME/.config/fedora-laptop/profile.env"
if [[ -r $profile_source ]]; then
  if [[ -e $profile_target || -L $profile_target ]] && [[ $(readlink -f -- "$profile_source" 2>/dev/null || true) != $(readlink -f -- "$profile_target" 2>/dev/null || true) ]]; then
    if [[ -f $profile_target && ! -L $profile_target && $REPLACE == true ]]; then
      if [[ $DRY_RUN == true ]]; then
        info "Would back up $profile_target"
      else
        mkdir -p -- "$backup_root/.config/fedora-laptop"
        mv -- "$profile_target" "$backup_root/.config/fedora-laptop/profile.env"
      fi
    else
      die "profile environment conflicts at $profile_target; rerun with --replace-dotfiles for a regular file"
    fi
  fi
  if [[ ! -e $profile_target && ! -L $profile_target ]]; then
    if [[ $DRY_RUN == true ]]; then
      info "Would link $profile_source to $profile_target"
    else
      mkdir -p -- "$HOME/.config/fedora-laptop"
      ln -s -- "$profile_source" "$profile_target"
    fi
  fi
fi

# ya ships with yazi via Mise; resolve through Mise shims since a
# non-interactive shell has no activated PATH here.
if [[ $DRY_RUN == true ]]; then
  print_command "$MISE_BIN" exec -- ya pkg install
elif (cd "$REPO_ROOT" && "$MISE_BIN" which ya >/dev/null 2>&1); then
  # Run from the repo so Mise discovers mise.toml tool versions.
  (cd "$REPO_ROOT" && "$MISE_BIN" exec -- ya pkg install)
else
  warn "ya is unavailable via Mise; Yazi flavor install skipped"
fi

info "Dotfiles applied via Mise"
