#!/usr/bin/env bash
# Create the fedora-laptop-dev Toolbx and install its minimal DNF set.
# Personal CLI tools inside the container are managed by Mise.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

readonly TOOLBOX_NAME=fedora-laptop-dev

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
require_command toolbox

if ! toolbox list --containers 2>/dev/null | grep -q "$TOOLBOX_NAME"; then
  # -y auto-downloads the matching fedora-toolbox image on first run.
  run toolbox create --assumeyes "$TOOLBOX_NAME"
else
  info "Toolbx container already exists: $TOOLBOX_NAME"
fi

mapfile -t pkgs < <(read_manifest "$MANIFEST_DIR/toolbox-packages.txt")
if ((${#pkgs[@]})); then
  if [[ $DRY_RUN == true ]]; then
    print_command toolbox run --container "$TOOLBOX_NAME" sudo dnf install -y "${pkgs[@]}"
  else
    toolbox run --container "$TOOLBOX_NAME" sudo dnf install -y "${pkgs[@]}"
  fi
fi

info "Toolbx phase complete; project runtimes inside $TOOLBOX_NAME are managed by Mise"
