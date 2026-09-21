profile_env="${XDG_CONFIG_HOME:-$HOME/.config}/fedora-laptop/profile.env"
if [[ -r "$profile_env" ]]; then
  # shellcheck disable=SC1090
  source "$profile_env"
fi

if [[ -n "${FEDORA_LAPTOP_RDP_HOST:-}" && -n "${FEDORA_LAPTOP_RDP_USER:-}" ]]; then
  alias win-rdp="sdl-freerdp /v:${FEDORA_LAPTOP_RDP_HOST} /u:${FEDORA_LAPTOP_RDP_USER} /dynamic-resolution +clipboard"
fi
