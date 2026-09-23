# Portable Bash setup for the Fedora workstation.

export EDITOR="nvim"
export VISUAL="nvim"
export GIT_EDITOR="nvim"
export SUDO_EDITOR="nvim"
export BAT_THEME="ansi"
export MANROFFOPT="-c"
export MANPAGER="sh -c 'col -bx | bat -l man -p'"

# Mise shims and ~/.local/bin come first so rolling user tools shadow the
# system defaults (mise activate also prepends when it runs below).
case ":${PATH}:" in
  *":${HOME}/.local/bin:"*) ;;
  *) PATH="${HOME}/.local/bin${PATH:+:${PATH}}" ;;
esac

case ":${PATH}:" in
  *":${HOME}/.local/share/mise/shims:"*) ;;
  *) PATH="${HOME}/.local/share/mise/shims${PATH:+:${PATH}}" ;;
esac
export PATH

# Tailscale SSH sessions skip pam_systemd, so XDG_RUNTIME_DIR is unset and
# rootless Podman/Toolbox fails with "failed to initialize container".
# Repair it whenever the per-user runtime dir exists (no-op otherwise).
# Placed before the non-interactive early return so toolbox works in
# every shell, including `tailscale ssh` sessions.
if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
  _runtime_dir="/run/user/$(id -u)"
  if [[ -d "$_runtime_dir" ]]; then
    XDG_RUNTIME_DIR="$_runtime_dir"
    export XDG_RUNTIME_DIR
  fi
  unset _runtime_dir
fi

[[ -r "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env"

if [[ -z "${LANG:-}" ]]; then
  [[ -r /etc/locale.conf ]] && source /etc/locale.conf
  : "${LANG:=C.UTF-8}"
  export LANG LANGUAGE LC_CTYPE LC_NUMERIC LC_TIME LC_COLLATE LC_MONETARY \
    LC_MESSAGES LC_PAPER LC_NAME LC_ADDRESS LC_TELEPHONE LC_MEASUREMENT \
    LC_IDENTIFICATION
fi

[[ $- != *i* ]] && return

shopt -s histappend
HISTCONTROL="ignoredups"
HISTSIZE=32768
HISTFILESIZE="${HISTSIZE}"

if [[ ! -v BASH_COMPLETION_VERSINFO && -f /usr/share/bash-completion/bash_completion ]]; then
  source /usr/share/bash-completion/bash_completion
fi

if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi

# Starship is global (host and Toolbx share the same Mise toolset).
# The prompt shows a `⬢ [dev]` marker inside containers via the
# starship `container` module and nothing extra on the host.
if [[ ${TERM:-} != "dumb" ]] && starship --version >/dev/null 2>&1; then
  eval "$(starship init bash)"
fi

if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init bash)"
fi

if command -v fzf >/dev/null 2>&1 && fzf --bash >/dev/null 2>&1; then
  eval "$(fzf --bash)"
fi

[[ -r "${HOME}/.bash_aliases" ]] && source "${HOME}/.bash_aliases"
[[ -r "${HOME}/.bash_functions" ]] && source "${HOME}/.bash_functions"
[[ -r "${HOME}/.config/fedora-laptop/profile.sh" ]] && source "${HOME}/.config/fedora-laptop/profile.sh"

# OpenCode tools, when installed.
if [[ -d "${HOME}/.opencode/bin" ]]; then
  PATH="${HOME}/.opencode/bin:${PATH}"
  export PATH
fi
