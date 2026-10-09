profile_env="${XDG_CONFIG_HOME:-$HOME/.config}/fedora-laptop/profile.env"
if [[ -r "$profile_env" ]]; then
  # shellcheck disable=SC1090
  source "$profile_env"
fi

if [[ -n "${FEDORA_LAPTOP_RDP_HOST:-}" && -n "${FEDORA_LAPTOP_RDP_USER:-}" ]]; then
  if command -v flatpak >/dev/null 2>&1; then
    _fedora_laptop_rdp_launcher="flatpak"
  elif command -v flatpak-spawn >/dev/null 2>&1; then
    _fedora_laptop_rdp_launcher="flatpak-spawn --host flatpak"
  else
    _fedora_laptop_rdp_launcher=""
  fi

  if [[ -n "$_fedora_laptop_rdp_launcher" ]]; then
    alias win-rdp="${_fedora_laptop_rdp_launcher} run --command=sdl-freerdp com.freerdp.FreeRDP /v:${FEDORA_LAPTOP_RDP_HOST} /u:${FEDORA_LAPTOP_RDP_USER} /dynamic-resolution +clipboard"
  fi
  unset _fedora_laptop_rdp_launcher
fi
