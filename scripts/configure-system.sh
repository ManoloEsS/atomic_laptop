#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

REPLACE=false
ENABLE_DOCKER=false
ENABLE_TAILSCALE=false
ENABLE_KEYD=false
KEYD_SOURCE="$REPO_ROOT/system/keyd/default.conf"
KEYD_DESTINATION=/etc/keyd/default.conf
WIFI_SOURCE="$REPO_ROOT/system/NetworkManager/wifi-powersave.conf"
WIFI_DESTINATION=/etc/NetworkManager/conf.d/wifi-powersave.conf

# Install one managed system file with backup/refusal semantics (keyd-style).
install_managed_file() {
  local source=$1 destination=$2 label=$3 backup
  [[ -r $source ]] || die "$label source is missing: $source"

  if [[ -L $destination ]] || [[ -e $destination && ! -f $destination ]]; then
    die "$destination is not a regular file; refusing to replace it"
  fi

  if [[ -e $destination ]] && ! cmp --silent "$source" "$destination"; then
    if [[ $REPLACE != true ]]; then
      die "$destination differs; inspect it and rerun with --replace to make a timestamped backup"
    fi
    backup="${destination}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    [[ ! -e $backup && ! -L $backup ]] || die "backup destination already exists: $backup"
    run_root cp --archive "$destination" "$backup"
    info "Backed up $destination to $backup"
  fi

  if [[ ! -e $destination ]] || ! cmp --silent "$source" "$destination"; then
    run_root install -D -o root -g root -m 0644 "$source" "$destination"
    info "Installed managed $label configuration"
  else
    info "Managed $label configuration already in place"
  fi
}

usage() {
  printf 'Usage: %s [--profile NAME] [--dry-run] [--replace] [--enable-keyd] [--enable-docker] [--enable-tailscale]\n' "${0##*/}"
}

enable_service() {
  local unit=$1
  if ! unit_exists "$unit"; then
    warn "service unit is not installed; skipping: $unit"
    return
  fi
  if systemctl is-enabled --quiet "$unit" && systemctl is-active --quiet "$unit"; then
    info "Service already enabled and active: $unit"
  else
    run_root systemctl enable --now "$unit"
  fi
}

while (($#)); do
  case $1 in
    --dry-run) DRY_RUN=true ;;
    --profile)
      (($# >= 2)) || usage_error "--profile requires a value"
      select_profile "$2"
      shift
      ;;
    --replace) REPLACE=true ;;
    --enable-keyd) ENABLE_KEYD=true ;;
    --enable-docker) ENABLE_DOCKER=true ;;
    --enable-tailscale) ENABLE_TAILSCALE=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift
done

reject_root
require_silverblue_44
require_booted_deployment_current
require_command sudo
require_command systemctl
[[ -r $KEYD_SOURCE ]] || die "keyd configuration is missing: $KEYD_SOURCE"

if [[ $ENABLE_KEYD == true ]]; then
  cat <<'EOF'
keyd remap about to be activated system-wide ([ids] * covers external keyboards):
  - Caps Lock: Escape on tap, Control on hold
  - Escape: Caps Lock
  - Left Alt <-> Left Meta swap
  - Left Control (hold): Shift+Meta layer, NOT Control
Keep a second input method or TTY available while testing.
EOF
  if command -v keyd >/dev/null 2>&1; then
    # NB: keyd check exits nonzero (255) for WARNINGs as well as errors,
    # so only ERROR output is fatal; warnings are reported and accepted.
    keyd_check_output=$(keyd check "$KEYD_SOURCE" 2>&1) && keyd_check_status=0 || keyd_check_status=$?
    if ((keyd_check_status != 0)); then
      printf '%s\n' "$keyd_check_output" >&2
      if grep -qi 'error' <<<"$keyd_check_output"; then
        die "keyd configuration has errors; refusing to install"
      else
        warn "keyd check reports warnings only; proceeding with reviewed config"
      fi
    fi
  elif [[ $DRY_RUN == true ]]; then
    warn "keyd is not installed in the booted deployment; validation is skipped during dry-run"
  else
    die "keyd is not installed; run install-packages.sh and reboot first"
  fi

  if [[ -L $KEYD_DESTINATION ]] || [[ -e $KEYD_DESTINATION && ! -f $KEYD_DESTINATION ]]; then
    die "$KEYD_DESTINATION is not a regular file; refusing to replace it"
  fi

  if [[ -e $KEYD_DESTINATION ]] && ! cmp --silent "$KEYD_SOURCE" "$KEYD_DESTINATION"; then
    if [[ $REPLACE != true ]]; then
      die "$KEYD_DESTINATION differs; inspect it and rerun with --replace to make a timestamped backup"
    fi
    backup="${KEYD_DESTINATION}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    [[ ! -e $backup && ! -L $backup ]] || die "backup destination already exists: $backup"
    run_root cp --archive "$KEYD_DESTINATION" "$backup"
    info "Backed up existing keyd configuration to $backup"
  fi

  keyd_changed=false
  if [[ ! -e $KEYD_DESTINATION ]] || ! cmp --silent "$KEYD_SOURCE" "$KEYD_DESTINATION"; then
    run_root install -D -o root -g root -m 0644 "$KEYD_SOURCE" "$KEYD_DESTINATION"
    keyd_changed=true
  fi

  if [[ $keyd_changed == true ]] && unit_exists keyd.service && systemctl is-active --quiet keyd.service; then
    run_root systemctl restart keyd.service
  else
    enable_service keyd.service
  fi
else
  info "keyd skipped (opt-in); rerun with --enable-keyd to install and activate the remap"
fi

# WiFi power save is always managed (low-risk latency fix, not opt-in).
# Takes effect on NetworkManager restart/reboot; the installer never reboots.
install_managed_file "$WIFI_SOURCE" "$WIFI_DESTINATION" "WiFi powersave"
if [[ $DRY_RUN != true ]] && command -v iw >/dev/null 2>&1; then
  while IFS= read -r iface; do
    if iw dev "$iface" get power_save 2>/dev/null | grep -qi off; then
      info "WiFi power save already off: $iface"
    else
      warn "WiFi power save still on ($iface); restart NetworkManager or reboot to apply"
    fi
  done < <(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}')
fi

report_service() {
  local unit=$1
  if ! unit_exists "$unit"; then
    warn "base service not installed (left alone): $unit"
  elif systemctl is-active --quiet "$unit"; then
    info "base service active (left alone): $unit"
  else
    warn "base service inactive (left alone, enable manually if wanted): $unit"
  fi
}

# Base-image services are observed, never managed by this installer.
report_service NetworkManager.service
report_service firewalld.service
report_service fstrim.timer
if systemctl is-active --quiet tuned-ppd.service || systemctl is-active --quiet power-profiles-daemon.service; then
  info "power-profile backend active (left alone)"
elif unit_exists tuned-ppd.service || unit_exists power-profiles-daemon.service; then
  warn "power-profile backend installed but inactive (left alone; Noctalia power controls unavailable)"
else
  warn "no power-profile backend installed (left alone)"
fi

if [[ $ENABLE_DOCKER == true ]]; then
  command -v docker >/dev/null 2>&1 || die "--enable-docker requested, but docker is not installed"
  unit_exists docker.service || die "--enable-docker requested, but docker.service is unavailable"
  enable_service docker.service
fi

if unit_exists tailscaled.service; then
  enable_service tailscaled.service
  info 'Tailscale service enabled; run "sudo tailscale up" to authenticate'
else
  warn "tailscaled.service is not installed; rerun install-packages.sh and reboot first"
fi

info "System configuration complete; firewall zone and zram settings were left unchanged"
