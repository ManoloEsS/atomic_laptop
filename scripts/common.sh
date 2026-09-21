#!/usr/bin/env bash

# Shared helpers for Fedora Silverblue setup scripts.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
MANIFEST_DIR="$REPO_ROOT/manifests"
DRY_RUN=${DRY_RUN:-false}
PROFILE=${PROFILE:-laptop}

# Dotfiles deploy to literal $HOME/.config; only the standard XDG layout is supported.
if [[ -n ${XDG_CONFIG_HOME:-} && ${XDG_CONFIG_HOME} != "$HOME/.config" ]]; then
  printf 'error: non-standard XDG_CONFIG_HOME=%s is not supported (expected %s/.config)\n' "$XDG_CONFIG_HOME" "$HOME" >&2
  exit 2
fi

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

print_command() {
  printf 'DRY-RUN:'
  printf ' %q' "$@"
  printf '\n'
}

run() {
  if [[ $DRY_RUN == true ]]; then
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

require_silverblue_44() {
  [[ -e /run/ostree-booted ]] || die "this host is not booted through ostree (/run/ostree-booted is absent)"
  load_os_release
  [[ ${ID:-} == fedora ]] || die "unsupported operating system ID: ${ID:-unknown} (expected fedora)"
  [[ ${VARIANT_ID:-} == silverblue ]] || die "unsupported Fedora variant: ${VARIANT_ID:-unknown} (expected silverblue)"
  [[ ${VERSION_ID:-} == 44 ]] || die "unsupported Fedora version: ${VERSION_ID:-unknown} (expected 44)"
  require_command rpm-ostree
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
