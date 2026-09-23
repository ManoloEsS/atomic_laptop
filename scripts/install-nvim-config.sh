#!/usr/bin/env bash
# Install the tracked external Neovim configuration for the laptop profile.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

REPLACE=false
NVIM_SOURCE_ROOT="$HOME/.local/share/fedora-laptop/sources/nvim"
NVIM_TARGET="$HOME/.config/nvim"

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
source_profile="$REPO_ROOT/profiles/$PROFILE/nvim-source.conf"
[[ -r $source_profile ]] || die "Neovim source manifest is missing: $source_profile"
# shellcheck disable=SC1090
source "$source_profile"

: "${NVIM_CONFIG_URL:?NVIM_CONFIG_URL is missing from $source_profile}"
: "${NVIM_CONFIG_REF:?NVIM_CONFIG_REF is missing from $source_profile}"
: "${NVIM_CONFIG_SUBDIR:?NVIM_CONFIG_SUBDIR is missing from $source_profile}"

config_dir="$NVIM_SOURCE_ROOT/$NVIM_CONFIG_SUBDIR"
backup_root="$HOME/.local/state/fedora-laptop/backups/$(date -u +%Y%m%dT%H%M%SZ)"

backup_target() {
  local target=$1 dest
  dest=$(backup_path "$target" "$backup_root")
  mkdir -p -- "$(dirname -- "$dest")"
  mv -- "$target" "$dest"
  info "Backed up existing Neovim config to $dest"
}

if is_dry_run; then
  info "Would clone/update $NVIM_CONFIG_URL at $NVIM_SOURCE_ROOT"
  info "Would check out the latest Neovim config from $NVIM_CONFIG_REF"
  info "Would link $NVIM_TARGET to $config_dir"
  exit 0
fi

require_command git
mkdir -p -- "$(dirname -- "$NVIM_SOURCE_ROOT")"

if [[ -e $NVIM_SOURCE_ROOT && ! -d $NVIM_SOURCE_ROOT ]]; then
  die "Neovim source path is not a directory: $NVIM_SOURCE_ROOT"
fi

if [[ ! -d "$NVIM_SOURCE_ROOT/.git" ]]; then
  [[ ! -e $NVIM_SOURCE_ROOT ]] || die "Neovim source directory exists without Git metadata: $NVIM_SOURCE_ROOT"
  git clone --filter=blob:none --no-checkout "$NVIM_CONFIG_URL" "$NVIM_SOURCE_ROOT"
else
  configured_url=$(git -C "$NVIM_SOURCE_ROOT" remote get-url origin 2>/dev/null || true)
  [[ $configured_url == "$NVIM_CONFIG_URL" ]] || die "Neovim source origin differs: $configured_url"
  checkout_status=$(git -C "$NVIM_SOURCE_ROOT" status --porcelain=v1 --untracked-files=all)
  [[ -z $checkout_status ]] || die "Neovim source checkout has local changes or extra files; review $NVIM_SOURCE_ROOT before continuing"
fi

git -C "$NVIM_SOURCE_ROOT" fetch --depth=1 origin "$NVIM_CONFIG_REF"
git -C "$NVIM_SOURCE_ROOT" checkout --detach --force FETCH_HEAD
resolved_ref=$(git -C "$NVIM_SOURCE_ROOT" rev-parse HEAD)
[[ -d $config_dir ]] || die "Neovim config subdirectory is missing: $config_dir"
config_dir=$(cd -- "$config_dir" && pwd -P)

if [[ -L $NVIM_TARGET ]]; then
  if [[ $(readlink -f -- "$NVIM_TARGET") == "$config_dir" ]]; then
    info "Neovim config link already points at the tracked checkout"
    exit 0
  fi
  if [[ $REPLACE != true ]]; then
    die "$NVIM_TARGET is an existing symlink to the wrong target; rerun with --replace-dotfiles after review"
  fi
  backup_target "$NVIM_TARGET"
elif [[ -e $NVIM_TARGET ]]; then
  if [[ $REPLACE != true ]]; then
    die "$NVIM_TARGET is a real file or directory; rerun with --replace-dotfiles after review"
  fi
  backup_target "$NVIM_TARGET"
fi

mkdir -p -- "$(dirname -- "$NVIM_TARGET")"
ln -s -- "$config_dir" "$NVIM_TARGET"
info "Linked Neovim config to $NVIM_CONFIG_REF at $resolved_ref"
