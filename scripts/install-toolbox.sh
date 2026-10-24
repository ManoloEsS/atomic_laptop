#!/usr/bin/env bash
# Create the Toolbx dev container and install its minimal DNF set.
# Personal CLI tools inside the container are managed by Mise.
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
require_command toolbox

if ! toolbox list --containers 2>/dev/null \
  | awk -v name="$TOOLBOX_NAME" '$2 == name { found = 1 } END { exit !found }'; then
  # -y auto-downloads the matching fedora-toolbox image on first run.
  run toolbox create --assumeyes "$TOOLBOX_NAME"
else
  info "Toolbx container already exists: $TOOLBOX_NAME"
fi

mapfile -t pkgs < <(read_manifest "$MANIFEST_DIR/toolbox-packages.txt")
if ((${#pkgs[@]})); then
  # Intentionally unconditional: `dnf install -y` is idempotent and keeps the
  # container converged on reruns without extra probing logic.
  run toolbox run --container "$TOOLBOX_NAME" sudo dnf install -y "${pkgs[@]}"
fi

info "Toolbx phase complete; project runtimes inside $TOOLBOX_NAME are managed by Mise"
