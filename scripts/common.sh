#!/usr/bin/env bash

# Shared helpers for the Fedora Silverblue laptop setup.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
MANIFEST_DIR="$REPO_ROOT/manifests"
DRY_RUN=${DRY_RUN:-false}
PROFILE=${PROFILE:-laptop}

# Shared assumptions (documented in README.md): Fedora Silverblue >= 44,
# GNU bash/tar, sudo available. $HOME is the single source of truth.
# XDG_CONFIG_HOME is honored when set, otherwise ~/.config.
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

# Minimum supported Fedora version. COPR/vendor URLs derive from the booted
# VERSION_ID at runtime instead of a hardcoded release number.
MIN_FEDORA_VERSION=44

# Single source of truth for names shared by install + verify scripts.
TOOLBOX_NAME=fedora-laptop-dev
DESKTOP_SERVICES=(docker.service sshd.service tailscaled.service)
MISE_CONFIG_PAIRS=("config.toml:mise.toml")

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

is_dry_run() {
  [[ ${DRY_RUN:-false} == true || ${DRY_RUN:-} == 1 || ${DRY_RUN:-} == yes ]]
}

print_command() {
  printf 'DRY-RUN:'
  printf ' %q' "$@"
  printf '\n'
}

run() {
  if is_dry_run; then
    print_command "$@"
  else
    "$@"
  fi
}

run_root() {
  if (( EUID == 0 )); then
    run "$@"
  else
    run sudo -- "$@"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

reject_root() {
  (( EUID != 0 )) || die "run this script as your regular user; it will use sudo when needed"
}

select_profile() {
  [[ $1 =~ ^[[:alnum:]_-]+$ ]] || usage_error "invalid profile name: $1"
  [[ -d $REPO_ROOT/profiles/$1 ]] || die "profile does not exist: $1"
  PROFILE=$1
}

load_os_release() {
  [[ -r /etc/os-release ]] || die "/etc/os-release is not readable"
  # This is the system-provided shell-compatible operating-system metadata.
  # shellcheck disable=SC1091
  source /etc/os-release
}

require_silverblue() {
  [[ -e /run/ostree-booted ]] || die "this host is not booted through ostree (/run/ostree-booted is absent)"
  load_os_release
  [[ ${ID:-} == fedora ]] || die "unsupported operating system ID: ${ID:-unknown} (expected fedora)"
  [[ ${VARIANT_ID:-} == silverblue ]] || die "unsupported Fedora variant: ${VARIANT_ID:-unknown} (expected silverblue)"
  if [[ ! ${VERSION_ID:-} =~ ^[0-9]+$ ]] || (( VERSION_ID < MIN_FEDORA_VERSION )); then
    die "unsupported Fedora version: ${VERSION_ID:-unknown} (expected Silverblue >= $MIN_FEDORA_VERSION)"
  fi
  require_command rpm-ostree
}

# Deprecated alias kept for out-of-tree callers.
require_silverblue_44() {
  require_silverblue
}

pending_deployment_exists() {
  local status
  set +e
  rpm-ostree status --pending-exit-77 >/dev/null 2>&1
  status=$?
  set -e
  case $status in
    0) return 1 ;;
    77) return 0 ;;
    *) die "could not determine whether an rpm-ostree deployment is pending" ;;
  esac
}

require_booted_deployment_current() {
  if pending_deployment_exists; then
    die "an rpm-ostree deployment is pending; reboot into it before continuing"
  fi
}

read_manifest() {
  local manifest=$1 line
  [[ -r $manifest ]] || die "manifest is not readable: $manifest"
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -n $line ]] && printf '%s\n' "$line"
  done < "$manifest"
}

unit_exists() {
  systemctl cat "$1" >/dev/null 2>&1
}

# Booted Fedora version for COPR/vendor URLs (defaults to minimum when
# /etc/os-release is unreadable, e.g. during dry-runs on other systems).
fedora_version() {
  local version_id=""
  if [[ -r /etc/os-release ]]; then
    version_id=$(source /etc/os-release >/dev/null 2>&1; printf '%s' "${VERSION_ID:-}")
  fi
  [[ $version_id =~ ^[0-9]+$ ]] || version_id=$MIN_FEDORA_VERSION
  printf '%s' "$version_id"
}

# Move $1 aside under a timestamped backup root. Usage:
# backup_path "$target" "$backup_root" ; then mv -- "$target" "$(backup_path ...)"
backup_path() {
  local target=$1 backup_root=$2 rel=${1#"$HOME/"}
  printf '%s/%s' "$backup_root" "$rel"
}
