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
require_silverblue

require_command sudo
require_command systemctl

# Manifests must exist and parse to at least one entry.
for manifest in host-packages.txt external-repositories.conf vendor-repositories.conf toolbox-packages.txt flatpaks.txt; do
  [[ -s $MANIFEST_DIR/$manifest ]] || die "missing manifest: $manifest"
  [[ -n $(read_manifest "$MANIFEST_DIR/$manifest") ]] || die "manifest has no entries: $manifest"
done
[[ -r $REPO_ROOT/mise.toml ]] || die "missing mise.toml"

if is_dry_run; then
  info "dry-run: skipping sudo credential check (zero side effects)"
elif ! sudo -n true 2>/dev/null; then
  warn "sudo requires authentication; later mutating steps may prompt"
fi

if pending_deployment_exists; then
  warn "an rpm-ostree deployment is pending; reboot before package or system configuration steps"
else
  info "No pending rpm-ostree deployment"
fi

for path in dotfiles system/keyd/default.conf profiles/$PROFILE/local.kdl.example profiles/$PROFILE/profile.env.example; do
  [[ -e $REPO_ROOT/$path ]] || warn "repository input is currently absent: $path"
done

info "Fedora Silverblue Atomic laptop preflight passed for profile $PROFILE"
if is_dry_run; then
  info "Dry-run mode selected; no later script should mutate the host"
fi
exit 0
