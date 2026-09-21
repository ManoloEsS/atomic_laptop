#!/usr/bin/env bash
# Fedora Silverblue 44 laptop setup orchestrator (rerunnable, two-pass).
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROFILE=laptop
DRY_RUN=false
REPLACE_DOTFILES=false
REPLACE_SYSTEM=false
ENABLE_KEYD=false

usage() {
  cat <<'EOF'
Usage: bash install.sh [options]

Options:
  --profile NAME       Select a profile (default: laptop)
  --dry-run            Show intended changes without applying them
  --replace-dotfiles   Back up conflicting dotfiles before replacement
  --replace-system     Back up and replace a differing managed keyd config
  --enable-keyd        Install and activate the system-wide keyd remap
  -h, --help           Show this help
EOF
}

while (($#)); do
  case "$1" in
    --profile)
      if (($# < 2)); then
        printf 'install: --profile requires a value\n' >&2
        exit 2
      fi
      PROFILE=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --replace-dotfiles)
      REPLACE_DOTFILES=true
      shift
      ;;
    --replace-system)
      REPLACE_SYSTEM=true
      shift
      ;;
    --enable-keyd)
      ENABLE_KEYD=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'install: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! $PROFILE =~ ^[[:alnum:]_-]+$ ]]; then
  printf 'install: invalid profile name: %s\n' "$PROFILE" >&2
  exit 2
fi

common_args=(--profile "$PROFILE")
if [[ $DRY_RUN == true ]]; then
  common_args+=(--dry-run)
fi

run_phase() {
  local name=$1
  local script=$2
  shift 2

  if [[ ! -f $script ]]; then
    printf 'install: missing %s script: %s\n' "$name" "$script" >&2
    return 1
  fi

  printf '\n==> %s\n' "$name"
  bash "$script" "$@"
}

run_phase preflight "$ROOT_DIR/scripts/preflight.sh" "${common_args[@]}"

package_status=0
run_phase packages "$ROOT_DIR/scripts/install-packages.sh" "${common_args[@]}" || package_status=$?
case $package_status in
  0)
    ;;
  10)
    printf '\nA reboot is required before configuration can continue.\n'
    printf 'Reboot manually, then run this command again with the same options.\n'
    exit 10
    ;;
  *)
    printf 'install: package installation failed with status %d\n' "$package_status" >&2
    exit "$package_status"
    ;;
esac

system_args=("${common_args[@]}")
if [[ $REPLACE_SYSTEM == true ]]; then
  system_args+=(--replace)
fi
if [[ $ENABLE_KEYD == true ]]; then
  system_args+=(--enable-keyd)
fi
run_phase system-configuration "$ROOT_DIR/scripts/configure-system.sh" "${system_args[@]}"

run_phase fonts "$ROOT_DIR/scripts/install-font.sh" "${common_args[@]}"
run_phase mise "$ROOT_DIR/scripts/bootstrap-mise.sh" "${common_args[@]}"

dotfile_args=("${common_args[@]}")
if [[ $REPLACE_DOTFILES == true ]]; then
  dotfile_args+=(--replace-dotfiles)
fi
run_phase dotfiles "$ROOT_DIR/scripts/install-dotfiles.sh" "${dotfile_args[@]}"

run_phase flatpaks "$ROOT_DIR/scripts/install-flatpak.sh" "${common_args[@]}"
run_phase toolbox "$ROOT_DIR/scripts/install-toolbox.sh" "${common_args[@]}"

if [[ $DRY_RUN == true ]]; then
  printf '\nDry run complete; verification was skipped because no changes were applied.\n'
  exit 0
fi

run_phase verification "$ROOT_DIR/scripts/verify.sh" "${common_args[@]}"

printf '\nInstallation and verification completed for profile %s.\n' "$PROFILE"
