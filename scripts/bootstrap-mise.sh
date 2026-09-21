#!/usr/bin/env bash
# Install a pinned Mise release to ~/.local/bin (user-local, no host layer).
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

readonly WANTED_MISE_VERSION=v2026.9.4
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

if [[ -x $MISE_PATH ]] && [[ $($MISE_PATH --version 2>/dev/null) == *"${WANTED_MISE_VERSION#v}"* ]]; then
  info "Mise ${WANTED_MISE_VERSION} already installed at $MISE_PATH"
fi

if [[ $DRY_RUN == true ]]; then
  info "Would install Mise ${WANTED_MISE_VERSION} to $MISE_PATH via official installer"
  exit 0
fi

require_command curl
run mkdir -p -- "$HOME/.local/bin"
if [[ ! -x $MISE_PATH ]]; then
  info "Installing Mise ${WANTED_MISE_VERSION} to $MISE_PATH"
  curl -fsSL https://mise.run | MISE_INSTALL_PATH="$MISE_PATH" MISE_VERSION="$WANTED_MISE_VERSION" sh
fi
"$MISE_PATH" --version

if [[ $DRY_RUN == true ]]; then
  info "Would run: $MISE_PATH trust + install --locked from $REPO_ROOT/mise.toml"
  exit 0
fi

"$MISE_PATH" trust "$REPO_ROOT/mise.toml"
(
  cd "$REPO_ROOT"
  "$MISE_PATH" install --locked
  MISE_ENV=toolbox "$MISE_PATH" install --locked
)

# Make repo tools resolve in EVERY directory (not just the checkout) by
# pointing the global Mise config AND lockfile at the repo files. Dotfile
# sources stay relative to the repo root, so this is safe. The lockfile link
# is required: Mise resolves locked versions relative to the config's own
# directory. Keep the checkout in place.
mkdir -p -- "$HOME/.config/mise"
# target:source pairs; config.toolbox.toml is the MISE_ENV=toolbox overlay
# and mise.toolbox.lock carries its locked versions.
for pair in "config.toml:mise.toml" "mise.lock:mise.lock" "config.toolbox.toml:mise.toolbox.toml" "mise.toolbox.lock:mise.toolbox.lock"; do
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
