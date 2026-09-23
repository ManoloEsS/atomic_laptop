# Select a file with fzf and preview it with bat.
ff() {
  fzf --preview 'bat --style=numbers --color=always {}' "$@"
}

eff() {
  local file
  file="$(ff "$@")" || return
  [[ -n "${file}" ]] || return
  "${EDITOR}" "${file}"
}

open() (
  xdg-open "$@" >/dev/null 2>&1 &
)

n() {
  if (( $# == 0 )); then
    command nvim .
  else
    command nvim "$@"
  fi
}
