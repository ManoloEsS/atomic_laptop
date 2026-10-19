#!/usr/bin/env bash
# Configure laptop services: laptop-specific keyd/wifi plus shared
# SSH/Tailscale functionality contract.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

REPLACE=false
ENABLE_KEYD=false
KEYD_SOURCE="$REPO_ROOT/system/keyd/default.conf"
KEYD_DESTINATION=/etc/keyd/default.conf
WIFI_SOURCE="$REPO_ROOT/system/NetworkManager/wifi-powersave.conf"
WIFI_DESTINATION=/etc/NetworkManager/conf.d/wifi-powersave.conf
BATTERY_HWDB_SOURCE="$REPO_ROOT/system/udev/61-battery-local.hwdb"
BATTERY_HWDB_DESTINATION=/etc/udev/hwdb.d/61-battery-local.hwdb
BATTERY_APPLY_SOURCE="$REPO_ROOT/system/battery/battery-thresholds-apply"
BATTERY_APPLY_DESTINATION=/usr/local/bin/battery-thresholds-apply
BATTERY_SERVICE_SOURCE="$REPO_ROOT/system/systemd/battery-thresholds.service"
BATTERY_SERVICE_DESTINATION=/etc/systemd/system/battery-thresholds.service

# Install one managed system file with backup/refusal semantics (keyd-style).
install_managed_file() {
  local source=$1 destination=$2 label=$3 mode=${4:-0644}
  local backup
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
    run_root install -D -o root -g root -m "$mode" "$source" "$destination"
    info "Installed managed $label configuration"
  else
    info "Managed $label configuration already in place"
  fi

  if [[ -e $destination && ! -L $destination ]]; then
    current_mode=$(stat -c %a "$destination" 2>/dev/null || true)
    if [[ -n $current_mode && $current_mode != "${mode#0}" && $current_mode != "$mode" ]]; then
      run_root chmod "$mode" "$destination"
      info "Fixed mode on managed $label configuration ($mode)"
    fi
  fi
}

usage() {
  printf 'Usage: %s [--profile NAME] [--dry-run] [--replace] [--enable-keyd]\n' "${0##*/}"
}

enable_service() {
  local unit=$1
  if ! unit_exists "$unit"; then
    warn "required laptop service is not installed: $unit"
    return
  fi
  # `enable --now` is idempotent; no need to probe state first.
  run_root systemctl enable --now "$unit"
  info "Enabled laptop service: $unit"
}

remove_public_rule_if_present() {
  local query=$1 remove=$2
  local -a scope=(--zone=public)

  if firewall-cmd "${scope[@]}" "$query" >/dev/null 2>&1; then
    run_root firewall-cmd "${scope[@]}" "$remove"
  fi
  scope=(--permanent --zone=public)
  if firewall-cmd "${scope[@]}" "$query" >/dev/null 2>&1; then
    run_root firewall-cmd "${scope[@]}" "$remove"
  fi
}

configure_network_zones() {
  local profile_env="$REPO_ROOT/profiles/$PROFILE/profile.env"
  local uuid name type zone trusted_uuid
  local -a trusted_uuids=()

  if [[ -r $profile_env ]]; then
    # shellcheck disable=SC1090
    source "$profile_env"
  fi
  read -r -a trusted_uuids <<< "${FEDORA_LAPTOP_TRUSTED_CONNECTION_UUIDS:-}"

  require_command nmcli
  require_command firewall-cmd
  if ! unit_exists firewalld.service || ! systemctl is-active --quiet firewalld.service; then
    die "firewalld must be installed and active to configure network zones safely"
  fi

  if ((${#trusted_uuids[@]} == 0)); then
    info "No trusted NetworkManager profiles configured; using public except for Tailscale"
  fi

  # Assign saved network profiles explicitly so stale FedoraWorkstation
  # assignments cannot make an untrusted Wi-Fi profile permissive.
  while IFS=: read -r uuid name type; do
    case $type in
      802-11-wireless|802-3-ethernet)
        zone=public
        for trusted_uuid in "${trusted_uuids[@]}"; do
          if [[ $uuid == "$trusted_uuid" ]]; then
            zone=FedoraWorkstation
            break
          fi
        done
        ;;
      tun)
        zone=public
        [[ $name == tailscale0 ]] && zone=trusted
        ;;
      *)
        continue
        ;;
    esac
    run_root nmcli connection modify "$uuid" connection.zone "$zone"
    info "Assigned NetworkManager profile $uuid to firewalld zone $zone"
  done < <(nmcli -t -f UUID,NAME,TYPE connection show)

  run_root firewall-cmd --set-default-zone=public
  run_root firewall-cmd --permanent --zone=trusted --change-interface=tailscale0
  if ip link show tailscale0 >/dev/null 2>&1; then
    run_root firewall-cmd --zone=trusted --change-interface=tailscale0
  fi
  remove_public_rule_if_present --query-service=ssh --remove-service=ssh
  remove_public_rule_if_present --query-port=1025-65535/tcp --remove-port=1025-65535/tcp
  remove_public_rule_if_present --query-port=1025-65535/udp --remove-port=1025-65535/udp
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
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift
done

reject_root
require_silverblue
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
  elif is_dry_run; then
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
if ! is_dry_run && command -v iw >/dev/null 2>&1; then
  while IFS= read -r iface; do
    if iw dev "$iface" get power_save 2>/dev/null | grep -qi off; then
      info "WiFi power save already off: $iface"
    else
      warn "WiFi power save still on ($iface); restart NetworkManager or reboot to apply"
    fi
  done < <(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}')
fi

# UPower battery charge thresholds are always managed (pins Lenovo
# conservation 75/80 via hwdb; Noctalia's Power toggle applies them).
# Takes effect after hwdb update + trigger + upower restart; the installer
# never reboots.
battery_hwdb_needs_refresh=false
if [[ ! -e $BATTERY_HWDB_DESTINATION ]] || ! cmp --silent "$BATTERY_HWDB_SOURCE" "$BATTERY_HWDB_DESTINATION"; then
  battery_hwdb_needs_refresh=true
fi
install_managed_file "$BATTERY_HWDB_SOURCE" "$BATTERY_HWDB_DESTINATION" "UPower battery thresholds"
if [[ $battery_hwdb_needs_refresh == true ]]; then
  run_root systemd-hwdb update
  run_root udevadm trigger --subsystem-match=power_supply --action=change
  if ! unit_exists upower.service; then
    warn "upower.service is not installed; thresholds apply once upower is present"
  elif is_dry_run; then
    run_root systemctl restart upower.service
  elif systemctl is-active --quiet upower.service; then
    run_root systemctl restart upower.service
    info "Restarted upower; enable Noctalia Control Center > Power > Use charge thresholds"
  else
    warn "upower.service is not active; thresholds apply on next boot/service start"
  fi
else
  info "UPower battery thresholds already in place"
fi

# Boot-time re-application: the EC resets sysfs to 95/100 on every boot and
# UPower does not rewrite the start threshold on its own. The helper only
# writes when the UPower toggle is on, so travel mode is respected.
battery_service_needs_reload=false
if [[ ! -e $BATTERY_SERVICE_DESTINATION ]] || ! cmp --silent "$BATTERY_SERVICE_SOURCE" "$BATTERY_SERVICE_DESTINATION"; then
  battery_service_needs_reload=true
fi
install_managed_file "$BATTERY_APPLY_SOURCE" "$BATTERY_APPLY_DESTINATION" "battery threshold helper" 0755
install_managed_file "$BATTERY_SERVICE_SOURCE" "$BATTERY_SERVICE_DESTINATION" "battery threshold service"
if [[ $battery_service_needs_reload == true ]]; then
  run_root systemctl daemon-reload
  info "Reloaded systemd for battery threshold service"
fi
enable_service battery-thresholds.service

report_base_service() {
  local unit=$1
  if ! unit_exists "$unit"; then
    warn "base service absent (left alone): $unit"
  elif systemctl is-active --quiet "$unit"; then
    info "base service active (left alone): $unit"
  else
    warn "base service inactive (left alone): $unit"
  fi
}

for unit in "${DESKTOP_SERVICES[@]}"; do
  enable_service "$unit"
done
configure_network_zones

# Base-image services are observed, never managed by this installer.
report_base_service NetworkManager.service
report_base_service firewalld.service
report_base_service fstrim.timer
if systemctl is-active --quiet tuned-ppd.service || systemctl is-active --quiet power-profiles-daemon.service; then
  info "power-profile backend active (left alone)"
else
  warn "no active power-profile backend (Noctalia power controls may be unavailable)"
fi

info 'Tailscale service is ready; authenticate this fresh machine with "sudo tailscale up"'
info 'Rootless Podman is provided by the Silverblue base; Compose uses podman-compose'
info "System configuration complete for profile: $PROFILE"
