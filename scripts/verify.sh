#!/usr/bin/env bash
# Read-only verification for the Atomic laptop setup.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

failures=0
warnings=0

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; ((failures += 1)); }
verify_warn() { printf 'WARN: %s\n' "$*" >&2; ((warnings += 1)); }

check_command() {
  local command_name=$1
  if command -v "$command_name" >/dev/null 2>&1; then
    pass "command available: $command_name"
  else
    fail "command unavailable: $command_name"
  fi
}

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

check_link() {
  local target=$1 expected=$2 actual
  actual=$(readlink -f -- "$target" 2>/dev/null || true)
  if [[ -L "$target" && $actual == "$expected" ]]; then
    pass "managed link: $target"
  else
    fail "managed link missing or incorrect: $target"
  fi
}

# Rolling Mise tools parsed from mise.toml [tools] (keys may be `name` or
# `backend:name/path`; the binary is the text after the last `/` or `:`).
mise_tools() {
  awk '/^\[tools\]/{flag=1; next} /^\[/{flag=0} flag' "$REPO_ROOT/mise.toml" \
    | sed -n 's/^[[:space:]]*"*\([^"=[:space:]]*\)"*[[:space:]]*=.*/\1/p' \
    | while IFS= read -r key; do
      key=${key##*/}; key=${key##*:}; [[ -n $key ]] && printf '%s\n' "$key"
    done | sort -u
}

mise_tool_available() {
  case $1 in
    neovim) "$MISE_BIN" exec -- nvim --version >/dev/null 2>&1 ;;
    ripgrep) "$MISE_BIN" exec -- rg --version >/dev/null 2>&1 ;;
    tree-sitter) "$MISE_BIN" exec -- tree-sitter --version >/dev/null 2>&1 ;;
    *) "$MISE_BIN" which "$1" >/dev/null 2>&1 ;;
  esac
}

while (($#)); do
  case $1 in
    --dry-run) DRY_RUN=true ;;
    --profile)
      (($# >= 2)) || usage_error "--profile requires a value"
      select_profile "$2"
      shift
      ;;
    -h|--help)
      printf 'Usage: %s [--profile NAME] [--dry-run]\n' "${0##*/}"
      exit 0
      ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift
done

reject_root
require_silverblue

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

if rpm -q --quiet neovim; then
  fail "host Neovim RPM is still installed; migrate to Mise"
else
  pass "host Neovim is Mise-managed, not RPM-installed"
fi

# Host commands include laptop tools, host-integrated services, and shared
# Mise shims. keyd is opt-in: warn, don't fail.
for command_name in niri noctalia ghostty wtype gcc make wl-copy nvim rg tree-sitter tailscale ssh docker; do
  check_command "$command_name"
done
if command -v keyd >/dev/null 2>&1; then
  pass "command available: keyd"
else
  verify_warn "command unavailable: keyd (opt-in via --enable-keyd)"
fi

MISE_BIN="$HOME/.local/bin/mise"
[[ -x $MISE_BIN ]] || MISE_BIN=mise
if command -v "$MISE_BIN" >/dev/null 2>&1; then
  pass "mise available: $MISE_BIN"
  while IFS= read -r tool; do
    if mise_tool_available "$tool"; then
      pass "mise tool installed and runnable: $tool"
    else
      fail "mise tool missing: $tool"
    fi
  done < <(mise_tools)
  links_ok=true
  for pair in "${MISE_CONFIG_PAIRS[@]}"; do
    [[ $(readlink -f -- "$HOME/.config/mise/${pair%%:*}" 2>/dev/null || true) == "$REPO_ROOT/${pair##*:}" ]] || links_ok=false
  done
  if [[ $links_ok == true ]]; then
    pass "global Mise configs point at repository"
  else
    fail "global Mise links are missing or incorrect"
  fi
  if (cd "$HOME" && "$MISE_BIN" which zoxide >/dev/null 2>&1); then
    pass "Mise tools resolve from home directory"
  else
    fail "Mise tools do not resolve from home directory"
  fi
else
  fail "Mise is unavailable at ~/.local/bin/mise"
fi

if command -v "$MISE_BIN" >/dev/null 2>&1 && "$MISE_BIN" bootstrap dotfiles status --missing >/dev/null 2>&1; then
  pass "Mise dotfiles converge"
else
  fail "Mise dotfiles have missing or conflicting entries"
fi

if [[ -r /etc/keyd/default.conf && ! -L /etc/keyd/default.conf ]]; then
  if cmp --silent "$REPO_ROOT/system/keyd/default.conf" /etc/keyd/default.conf; then
    pass "keyd configuration matches repository"
  else
    fail "keyd configuration differs from repository (rerun with --enable-keyd --replace after review)"
  fi
  check_service keyd.service
else
  verify_warn "keyd not installed (opt-in); rerun system configuration with --enable-keyd"
fi

# Managed WiFi powersave config (always expected on the laptop).
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

for helper in fedora-update-check fedora-update; do
  if command -v "$helper" >/dev/null 2>&1; then
    pass "update helper resolves: $helper"
  else
    fail "update helper missing: $helper"
  fi
done

if systemctl --user is-enabled --quiet fedora-update-check.timer 2>/dev/null; then
  pass "update-check timer is enabled"
else
  fail "update-check timer is not enabled"
fi

for pair in \
  "$HOME/.bashrc:dotfiles/bash/.bashrc" \
  "$HOME/.config/niri/config.kdl:dotfiles/niri/.config/niri/config.kdl" \
  "$HOME/.config/niri/local.kdl:profiles/$PROFILE/local.kdl.example" \
  "$HOME/.config/noctalia/config.toml:dotfiles/noctalia/.config/noctalia/config.toml" \
  "$HOME/.config/ghostty/config:dotfiles/ghostty/.config/ghostty/config" \
  "$HOME/.config/tmux/tmux.conf:dotfiles/tmux/.config/tmux/tmux.conf"; do
  target=${pair%%:*}
  source=${pair#*:}
  if [[ $source == profiles/* ]]; then
    [[ -r $target ]] && pass "laptop profile file present: $target" || fail "laptop profile file missing: $target"
  else
    check_link "$target" "$REPO_ROOT/$source"
  fi
done

nvim_source_profile="$REPO_ROOT/profiles/$PROFILE/nvim-source.conf"
# shellcheck disable=SC1090
source "$nvim_source_profile"
nvim_source_root="$HOME/.local/share/fedora-laptop/sources/nvim"
nvim_config_dir=$(readlink -m -- "$nvim_source_root/$NVIM_CONFIG_SUBDIR")
if [[ -L $HOME/.config/nvim && $(readlink -f -- "$HOME/.config/nvim") == "$nvim_config_dir" ]]; then
  pass "Neovim config link points at the external checkout"
else
  fail "Neovim config link is missing or points at the wrong checkout"
fi
expected_nvim_ref=$(git -C "$nvim_source_root" rev-parse "origin/$NVIM_CONFIG_REF^{commit}" 2>/dev/null || git -C "$nvim_source_root" rev-parse FETCH_HEAD 2>/dev/null || true)
if [[ -d "$nvim_source_root/.git" && -n $expected_nvim_ref && $(git -C "$nvim_source_root" rev-parse HEAD 2>/dev/null) == "$expected_nvim_ref" ]]; then
  pass "Neovim config checkout matches $NVIM_CONFIG_REF"
else
  fail "Neovim config checkout does not match $NVIM_CONFIG_REF"
fi

for unit in "${DESKTOP_SERVICES[@]}"; do
  check_service "$unit"
done

for unit in NetworkManager.service firewalld.service fstrim.timer; do
  if unit_exists "$unit" && systemctl is-active --quiet "$unit"; then
    pass "base service active: $unit"
  else
    verify_warn "base service inactive or absent: $unit"
  fi
done
if systemctl is-active --quiet tuned-ppd.service || systemctl is-active --quiet power-profiles-daemon.service; then
  pass "power-profile backend active"
else
  verify_warn "no power-profile backend active"
fi

if ! command -v firewall-cmd >/dev/null 2>&1 || ! firewall-cmd --state >/dev/null 2>&1; then
  verify_warn "firewalld is unavailable; SSH firewall access was not checked"
elif firewall-cmd --zone "$(firewall-cmd --get-default-zone)" --query-service ssh >/dev/null 2>&1; then
  pass "SSH allowed in the default firewalld zone"
else
  verify_warn "SSH is not allowed in the default firewalld zone"
fi

if command -v flatpak >/dev/null 2>&1; then
  while IFS= read -r app; do
    if flatpak info --system "$app" >/dev/null 2>&1; then
      pass "Flatpak installed: $app"
    else
      fail "Flatpak missing: $app"
    fi
  done < <(read_manifest "$MANIFEST_DIR/flatpaks.txt")
else
  fail "Flatpak command unavailable"
fi

if command -v toolbox >/dev/null 2>&1; then
if toolbox list --containers 2>/dev/null \
  | awk -v name="$TOOLBOX_NAME" '$2 == name { found = 1 } END { exit !found }'; then
    pass "Toolbx container present: $TOOLBOX_NAME"
    if toolbox run --container "$TOOLBOX_NAME" rpm -q --quiet gcc make wl-clipboard; then
      pass "Toolbx native Neovim build/clipboard packages are installed"
    else
      fail "Toolbx native Neovim build/clipboard packages are missing"
    fi
    if toolbox run --container "$TOOLBOX_NAME" rpm -q --quiet neovim; then
      fail "Toolbx Neovim RPM is still installed; use Mise"
    else
      pass "Toolbx Neovim is Mise-managed, not RPM-installed"
    fi
    if toolbox run --container "$TOOLBOX_NAME" "$MISE_BIN" which starship >/dev/null 2>&1; then
      pass "Starship resolves inside Toolbx"
    else
      fail "Starship missing inside Toolbx"
    fi
    if toolbox run --container "$TOOLBOX_NAME" "$MISE_BIN" exec -- starship print-config >/dev/null 2>&1; then
      if toolbox run --container "$TOOLBOX_NAME" "$MISE_BIN" exec -- starship print-config 2>/dev/null | grep -q '^\[container\]'; then
        pass "Starship toolbox marker is configured"
      else
        fail "Starship toolbox marker is missing"
      fi
    else
      verify_warn "Starship config was not checked inside Toolbx"
    fi
  else
    fail "Toolbx container missing: $TOOLBOX_NAME"
  fi
else
  fail "Toolbox command unavailable"
fi

if command -v fc-match >/dev/null 2>&1 && [[ $(fc-match --format '%{family}' 'JetBrainsMono Nerd Font' 2>/dev/null) == *'JetBrainsMono Nerd Font'* ]]; then
  pass "JetBrainsMono Nerd Font is available"
else
  fail "JetBrainsMono Nerd Font is unavailable"
fi

if command -v infocmp >/dev/null 2>&1 && infocmp xterm-ghostty >/dev/null 2>&1; then
  pass "terminfo entry resolves: xterm-ghostty"
elif ! command -v infocmp >/dev/null 2>&1; then
  verify_warn "infocmp unavailable; terminfo entry was not checked"
else
  fail "terminfo entry missing: xterm-ghostty"
fi

yazi_flavor=$CONFIG_HOME/yazi/flavors/tokyo-night.yazi/flavor.toml
[[ -r $yazi_flavor ]] && pass "Yazi Tokyo Night flavor is installed" || fail "Yazi Tokyo Night flavor is missing"

niri_config=$CONFIG_HOME/niri/config.kdl
if ! command -v niri >/dev/null 2>&1; then
  verify_warn "niri unavailable; configuration was not validated"
elif niri validate --config "$niri_config" >/dev/null 2>&1; then
  pass "Niri configuration validates"
else
  verify_warn "Niri configuration validation failed (or no graphical session)"
fi

niri_local=$CONFIG_HOME/niri/local.kdl
if [[ ! -r $niri_local ]]; then
  verify_warn "Niri machine-output file missing: $niri_local (shared config includes it)"
elif cmp --silent "$REPO_ROOT/profiles/$PROFILE/local.kdl.example" "$niri_local"; then
  verify_warn "Niri machine-output file is still the unedited stub; fill real IDs from niri msg outputs"
else
  pass "Niri machine-output file present"
fi

# A missing touchpad fragment breaks Niri config load, so this fails.
niri_touchpad=$CONFIG_HOME/niri/touchpad.kdl
if [[ -r $niri_touchpad ]]; then
  pass "Niri touchpad fragment present"
else
  fail "Niri touchpad fragment missing: $niri_touchpad (shared config includes it)"
fi

if ! command -v noctalia >/dev/null 2>&1; then
  verify_warn "noctalia unavailable; configuration was not validated"
elif noctalia config validate >/dev/null 2>&1; then
  pass "Noctalia configuration validates"
else
  verify_warn "Noctalia configuration validation failed"
fi

printf '\nVerification complete: %d failure(s), %d warning(s).\n' "$failures" "$warnings"
((failures == 0))
