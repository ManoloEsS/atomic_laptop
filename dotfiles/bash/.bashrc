# Portable Bash setup for the Fedora workstation.

export EDITOR="nvim"
export VISUAL="nvim"
export GIT_EDITOR="nvim"
export SUDO_EDITOR="nvim"
export BAT_THEME="ansi"
export MANROFFOPT="-c"
export MANPAGER="sh -c 'col -bx | bat -l man -p'"

case ":${PATH}:" in
  *":${HOME}/.local/bin:"*) ;;
  *) PATH="${PATH:+${PATH}:}${HOME}/.local/bin" ;;
esac

case ":${PATH}:" in
  *":${HOME}/.local/share/mise/shims:"*) ;;
  *) PATH="${PATH:+${PATH}:}${HOME}/.local/share/mise/shims" ;;
esac
export PATH

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

set +h

# Inside Toolbx only, enable the toolbox tool overlay (starship prompt).
if [[ -f /run/.toolboxenv ]]; then
  export MISE_ENV=toolbox
fi

if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi

# Starship prompt lives in the dev container only, never on the host.
# Version check (not command -v) so a broken shim never corrupts the shell.
if [[ -f /run/.toolboxenv && ${TERM:-} != "dumb" ]] && starship --version >/dev/null 2>&1; then
  eval "$(starship init bash)"
fi

if zoxide --version >/dev/null 2>&1; then
  eval "$(zoxide init bash)"
fi

# fzf ships via Mise (no /usr/share/fzf RPM files); use its built-in integration.
# Version check (not command -v) so a broken shim never corrupts the shell.
if fzf --bash >/dev/null 2>&1; then
  eval "$(fzf --bash)"
fi

[[ -r "${HOME}/.bash_aliases" ]] && source "${HOME}/.bash_aliases"
[[ -r "${HOME}/.bash_functions" ]] && source "${HOME}/.bash_functions"
[[ -r "${HOME}/.config/fedora-laptop/profile.sh" ]] && source "${HOME}/.config/fedora-laptop/profile.sh"

# opencode
export PATH="$HOME/.opencode/bin:$PATH"
