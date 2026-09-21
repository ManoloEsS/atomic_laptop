#!/usr/bin/env bash
# Read-only verification for the Atomic-first laptop setup.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

failures=0
warnings=0

usage() {
  printf 'Usage: %s [--profile NAME] [--dry-run]\n' "${0##*/}"
}

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; ((failures += 1)); }
verify_warn() { printf 'WARN: %s\n' "$*" >&2; ((warnings += 1)); }

check_service() {
  local unit=$1
  if ! unit_exists "$unit"; then
    fail "$unit is not installed"
  elif ! systemctl is-enabled --quiet "$unit"; then
    fail "$unit is not enabled"
  elif ! systemctl is-active --quiet "$unit"; then
    fail "$unit is not active"
  else
    pass "$unit is enabled and active"
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
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift
done

reject_root
if ! require_silverblue_44; then
  fail "host is not Fedora Silverblue 44"
fi

if pending_deployment_exists; then
  fail "an rpm-ostree deployment is pending; reboot is required"
else
  pass "booted deployment is current"
fi

while IFS= read -r package; do
  if rpm -q --quiet "$package"; then
    pass "host package installed: $package"
  else
    fail "host package missing: $package"
  fi
done < <(read_manifest "$MANIFEST_DIR/host-packages.txt")

# Host-integrated commands (RPM layers). keyd is opt-in: warn, don't fail.
for command in niri noctalia ghostty wtype tailscale; do
  command -v "$command" >/dev/null 2>&1 && pass "host command available: $command" || fail "host command unavailable: $command"
done
if command -v keyd >/dev/null 2>&1; then
  pass "host command available: keyd"
else
  verify_warn "host command unavailable: keyd (opt-in via --enable-keyd)"
fi

# User-local Mise tools.
MISE_BIN="$HOME/.local/bin/mise"
command -v "$MISE_BIN" >/dev/null 2>&1 || MISE_BIN="mise"
if command -v "$MISE_BIN" >/dev/null 2>&1; then
  pass "mise available: $MISE_BIN"
  # starship is toolbox-scoped (checked below), never on the host.
  for tool in herdr yazi nvim tmux fzf bat eza zoxide gh jj python; do
    if "$MISE_BIN" which "$tool" >/dev/null 2>&1; then
      pass "mise tool installed: $tool"
    else
      fail "mise tool missing: $tool (run mise install --locked)"
    fi
  done
  if "$MISE_BIN" exec -- herdr --version >/dev/null 2>&1; then
    pass "herdr launches: $("$MISE_BIN" exec -- herdr --version 2>/dev/null | head -1)"
  else
    fail "herdr is installed but does not run"
  fi
  # Tools must resolve outside the checkout (global links point at repo).
  links_ok=true
  for pair in "config.toml:mise.toml" "mise.lock:mise.lock" "config.toolbox.toml:mise.toolbox.toml" "mise.toolbox.lock:mise.toolbox.lock"; do
    [[ $(readlink -f -- "$HOME/.config/mise/${pair%%:*}" 2>/dev/null || true) == "$REPO_ROOT/${pair##*:}" ]] || links_ok=false
  done
  if [[ $links_ok == true ]]; then
    pass "global Mise config and lockfiles point at repository"
  else
    fail "global Mise links missing; tools only resolve inside the checkout"
  fi
  if (cd "$HOME" && "$MISE_BIN" which zoxide >/dev/null 2>&1); then
    pass "mise tools resolve from home directory"
  else
    fail "mise tools do not resolve from home directory"
  fi
else
  fail "mise is unavailable at ~/.local/bin/mise"
fi

# Dotfiles via Mise state.
if command -v "$MISE_BIN" >/dev/null 2>&1; then
  if "$MISE_BIN" bootstrap dotfiles status --missing >/dev/null 2>&1; then
    pass "mise dotfiles converge"
  else
    fail "mise dotfiles have missing/conflicting entries (run mise bootstrap dotfiles status)"
  fi
fi

if [[ -r /etc/keyd/default.conf && ! -L /etc/keyd/default.conf ]]; then
  if cmp --silent "$REPO_ROOT/system/keyd/default.conf" /etc/keyd/default.conf; then
    pass "keyd configuration matches repository"
  else
    fail "keyd configuration differs from repository (rerun with --enable-keyd --replace-system after review)"
  fi
  check_service keyd.service
else
  verify_warn "keyd not installed (opt-in); rerun system configuration with --enable-keyd"
fi

check_service tailscaled.service

# Managed WiFi powersave config (mirrors keyd handling, always expected).
wifi_source="$REPO_ROOT/system/NetworkManager/wifi-powersave.conf"
wifi_dest=/etc/NetworkManager/conf.d/wifi-powersave.conf
if [[ -r $wifi_dest && ! -L $wifi_dest ]] && cmp --silent "$wifi_source" "$wifi_dest"; then
  pass "WiFi powersave configuration matches repository"
else
  fail "WiFi powersave configuration is missing or differs from repository"
fi

# Effective radio state (needs a NetworkManager restart/reboot after install).
if command -v iw >/dev/null 2>&1; then
  wifi_ifaces=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}')
  if [[ -z $wifi_ifaces ]]; then
    verify_warn "no wireless interfaces found; skipping radio check"
  else
    for iface in $wifi_ifaces; do
      if iw dev "$iface" get power_save 2>/dev/null | grep -qi off; then
        pass "WiFi power save off: $iface"
      else
        fail "WiFi power save on: $iface (restart NetworkManager or reboot)"
      fi
    done
  fi
else
  verify_warn "iw unavailable; skipping radio check"
fi

# Base-image services are informational only; never fail on them.
for unit in NetworkManager.service firewalld.service fstrim.timer; do
  if unit_exists "$unit" && systemctl is-active --quiet "$unit"; then
    pass "base service active: $unit"
  else
    verify_warn "base service inactive or absent (left alone by installer): $unit"
  fi
done
if systemctl is-active --quiet tuned-ppd.service || systemctl is-active --quiet power-profiles-daemon.service; then
  pass "power-profile backend active"
else
  verify_warn "no power-profile backend active (Noctalia power controls unavailable)"
fi

# Flatpaks.
if command -v flatpak >/dev/null 2>&1; then
  while IFS= read -r app; do
    if flatpak info --system "$app" >/dev/null 2>&1; then
      pass "flatpak installed: $app"
    else
      fail "flatpak missing: $app"
    fi
  done < <(read_manifest "$MANIFEST_DIR/flatpaks.txt")
else
  fail "flatpak command unavailable"
fi

# Toolbx container.
if command -v toolbox >/dev/null 2>&1; then
  if toolbox list --containers 2>/dev/null | grep -q fedora-laptop-dev; then
    pass "toolbox container present: fedora-laptop-dev"
    if toolbox run --container fedora-laptop-dev env MISE_ENV=toolbox "$MISE_BIN" which starship >/dev/null 2>&1; then
      pass "starship resolves inside toolbox"
    else
      fail "starship missing inside toolbox"
    fi
  else
    fail "toolbox container missing: fedora-laptop-dev"
  fi
else
  verify_warn "toolbox command unavailable"
fi

if command -v fc-match >/dev/null 2>&1; then
  matched_font=$(fc-match --format '%{family}\n' 'JetBrainsMono Nerd Font' 2>/dev/null)
  [[ $matched_font == *'JetBrainsMono Nerd Font'* ]] && pass "JetBrainsMono Nerd Font is available" || fail "JetBrainsMono Nerd Font is unavailable"
fi

if infocmp xterm-ghostty >/dev/null 2>&1; then
  pass "terminfo entry resolves: xterm-ghostty"
else
  fail "terminfo entry missing: xterm-ghostty (TUI apps break in Ghostty TERM)"
fi

yazi_flavor=${XDG_CONFIG_HOME:-$HOME/.config}/yazi/flavors/tokyo-night.yazi/flavor.toml
[[ -r $yazi_flavor ]] && pass "Yazi Tokyo Night flavor is installed" || fail "Yazi Tokyo Night flavor is missing; run ya pkg install"

niri_config=${XDG_CONFIG_HOME:-$HOME/.config}/niri/config.kdl
if command -v niri >/dev/null 2>&1 && [[ -r $niri_config ]]; then
  if niri validate --config "$niri_config" >/dev/null 2>&1; then
    pass "niri configuration validates"
  else
    fail "niri configuration validation failed"
  fi
else
  verify_warn "niri validation skipped because command or config is unavailable"
fi

niri_local=${XDG_CONFIG_HOME:-$HOME/.config}/niri/local.kdl
if [[ ! -r $niri_local ]]; then
  verify_warn "Niri machine-output file missing: $niri_local (shared config includes it)"
elif cmp --silent "$REPO_ROOT/profiles/$PROFILE/local.kdl.example" "$niri_local"; then
  verify_warn "Niri machine-output file is still the unedited stub; fill real IDs from niri msg outputs"
else
  pass "Niri machine-output file present"
fi

# A missing touchpad fragment breaks Niri config load, so this fails.
niri_touchpad=${XDG_CONFIG_HOME:-$HOME/.config}/niri/touchpad.kdl
if [[ -r $niri_touchpad ]]; then
  pass "Niri touchpad fragment present"
else
  fail "Niri touchpad fragment missing: $niri_touchpad (shared config includes it)"
fi

if command -v noctalia >/dev/null 2>&1; then
  if noctalia config validate >/dev/null 2>&1; then
    pass "noctalia configuration validates"
  else
    verify_warn "noctalia configuration validation failed (v5 migration may be pending)"
  fi
fi

printf '\nVerification complete: %d failure(s), %d warning(s).\n' "$failures" "$warnings"
((failures == 0))
