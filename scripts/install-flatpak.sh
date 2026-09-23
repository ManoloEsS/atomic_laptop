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

info "Flatpak phase complete"
