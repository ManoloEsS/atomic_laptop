#!/usr/bin/env bash
# Install Flathub remote and declarative Flatpak apps (system-wide).
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

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
require_command flatpak

# --if-not-exists is already idempotent; no need to probe the remote first.
# Flathub ships its own GPG key inside the .flatpakrepo file (TLS + embedded
# signature), unlike COPR/vendor repos which we fingerprint-pin above.
run_root flatpak remote-add --if-not-exists --system flathub https://flathub.org/repo/flathub.flatpakrepo

mapfile -t apps < <(read_manifest "$MANIFEST_DIR/flatpaks.txt")
for app in "${apps[@]}"; do
  if flatpak info --system "$app" >/dev/null 2>&1; then
    info "Flatpak already installed: $app"
  else
    run_root flatpak install --system -y flathub "$app"
  fi
done

# Firefox is the declared default browser (checked by verify.sh). Its desktop
# file is exported once the Flatpak above is installed.
if ! command -v xdg-settings >/dev/null 2>&1; then
  warn "xdg-settings is unavailable; default browser was not set"
elif [[ $(xdg-settings get default-web-browser 2>/dev/null || true) == "$FIREFOX_DESKTOP_FILE" ]]; then
  info "Default browser is already Firefox"
elif is_dry_run; then
  info "Would set default browser to $FIREFOX_DESKTOP_FILE"
else
  xdg-settings set default-web-browser "$FIREFOX_DESKTOP_FILE"
  info "Set default browser to Firefox"
fi

info "Flatpak phase complete"
