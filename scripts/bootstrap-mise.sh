#!/usr/bin/env bash
# Install the latest Mise release to ~/.local/bin (user-local, no host layer).
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

readonly MISE_PATH="$HOME/.local/bin/mise"

usage() {
  printf 'Usage: %s [--profile NAME] [--dry-run]\n' "${0##*/}"
}

while (($#)); do
  case $1 in
    --dry-run) DRY_RUN=true ;;
    --profile)
      (($# >= 2)) || usage_error "--profile requires a value"
      select_profile "$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift
done

reject_root

installed_version=
if [[ -x $MISE_PATH ]]; then
  installed_version=$("$MISE_PATH" --version 2>/dev/null || true)
fi

if [[ -n $installed_version ]]; then
  info "Updating Mise ${installed_version%% *} to the latest release at $MISE_PATH"
else
  info "Installing the latest Mise release to $MISE_PATH"
fi

if is_dry_run; then
  info "Would install/update the latest Mise release to $MISE_PATH via the official installer"
  exit 0
fi

require_command curl
mkdir -p -- "$HOME/.local/bin"
# Intentionally unpinned: desktop tools track rolling `latest` (see README).
# Repository GPG keys and fonts stay pinned; Mise itself is TLS-trusted.
curl -fsSL https://mise.run | MISE_INSTALL_PATH="$MISE_PATH" sh
installed_version=$("$MISE_PATH" --version 2>/dev/null || true)
[[ -n $installed_version ]] || die "Mise installation failed or produced no version"
info "Using Mise $installed_version"

"$MISE_PATH" trust "$REPO_ROOT/mise.toml"
(
  cd "$REPO_ROOT"
  "$MISE_PATH" install
)

# Make repo tools resolve in EVERY directory (not just the checkout) by
# pointing the global Mise config at the repo file. Dotfile sources stay
# relative to the repo root, so this is safe.
# Host and Toolbx share the same toolset (including Starship); the prompt
# itself shows a toolbox marker via the starship `container` module.
mkdir -p -- "$HOME/.config/mise"
# Remove the retired toolbox-only overlay link (Starship is now global).
legacy_overlay="$HOME/.config/mise/config.toolbox.toml"
if [[ -L $legacy_overlay ]]; then
  rm -- "$legacy_overlay"
  info "Removed retired Mise overlay link: $legacy_overlay"
fi
for pair in "${MISE_CONFIG_PAIRS[@]}"; do
  target="$HOME/.config/mise/${pair%%:*}"
  source="$REPO_ROOT/${pair##*:}"
  if [[ -L $target && $(readlink -f -- "$target" 2>/dev/null || true) == "$source" ]]; then
    info "global Mise ${pair%%:*} already points at repository"
  elif [[ -e $target || -L $target ]]; then
    die "global Mise ${pair%%:*} conflicts at $target; back it up or remove it manually"
  else
    ln -s -- "$source" "$target"
    info "linked global Mise ${pair%%:*} to repository"
  fi
done
