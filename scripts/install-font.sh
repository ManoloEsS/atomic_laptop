#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

readonly FONT_VERSION=v3.5.1
readonly FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/${FONT_VERSION}/JetBrainsMono.tar.xz"
readonly FONT_SHA256=04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf
readonly FONT_DIR="$HOME/.local/share/fonts/JetBrainsMono Nerd Font"

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
if command -v fc-match >/dev/null 2>&1 && [[ $(fc-match -f '%{family}' 'JetBrainsMono Nerd Font' 2>/dev/null) == *'JetBrainsMono Nerd Font'* ]]; then
  info "JetBrainsMono Nerd Font is already installed"
  exit 0
fi

if is_dry_run; then
  info "Would download and verify JetBrainsMono Nerd Font $FONT_VERSION into $FONT_DIR"
  exit 0
fi

for command in curl sha256sum tar fc-cache mktemp; do
  require_command "$command"
done

temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
archive="$temporary/JetBrainsMono.tar.xz"
curl --fail --location --retry 3 --silent --show-error "$FONT_URL" --output "$archive"
printf '%s  %s\n' "$FONT_SHA256" "$archive" | sha256sum --check --status
mkdir -p -- "$FONT_DIR"
tar --extract --xz --file "$archive" --directory "$FONT_DIR"
fc-cache -f "$FONT_DIR"
info "Installed JetBrainsMono Nerd Font $FONT_VERSION"
