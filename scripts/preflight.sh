#!/usr/bin/env bash
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
require_silverblue_44

for command in rpm sudo systemctl; do
  require_command "$command"
done

[[ -r $MANIFEST_DIR/host-packages.txt ]] || die "missing host package manifest"
[[ -r $MANIFEST_DIR/external-repositories.conf ]] || die "missing external repository manifest"
[[ -r $MANIFEST_DIR/toolbox-packages.txt ]] || die "missing toolbox package manifest"
[[ -r $MANIFEST_DIR/flatpaks.txt ]] || die "missing flatpak manifest"
[[ -r $REPO_ROOT/mise.toml ]] || die "missing mise.toml"
[[ -r $REPO_ROOT/mise.lock ]] || die "missing mise.lock"

if [[ $DRY_RUN == true ]]; then
  info "dry-run: skipping sudo credential check (zero side effects)"
elif ! sudo -n true 2>/dev/null; then
  warn "sudo requires authentication; later mutating steps may prompt"
fi

if pending_deployment_exists; then
  warn "an rpm-ostree deployment is pending; reboot before package or system configuration steps"
else
  info "No pending rpm-ostree deployment"
fi

for path in dotfiles system/keyd/default.conf; do
  [[ -e $REPO_ROOT/$path ]] || warn "repository input is currently absent: $path"
done

info "Fedora Silverblue 44 Atomic preflight passed for profile $PROFILE"
if [[ $DRY_RUN == true ]]; then
  info "Dry-run mode selected; no later script should mutate the host"
fi
exit 0
