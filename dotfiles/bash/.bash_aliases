# Explicit convenience aliases. Core commands remain unmodified.
alias ls='command ls --color=auto'
alias vim='nvim'
alias ..='cd ..'
alias ...='cd ../..'

if command -v eza >/dev/null 2>&1; then
  alias ez='eza --icons --git'
  alias ll='eza -la --git'
  alias tree='eza --tree --icons'
fi
