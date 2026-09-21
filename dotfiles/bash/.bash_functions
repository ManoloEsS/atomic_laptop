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

sff() {
  if (( $# == 0 )); then
    echo "Usage: sff <destination> (e.g. sff host:/tmp/)"
    return 1
  fi
  command -v scp >/dev/null 2>&1 || { echo "sff requires the Fedora OpenSSH client"; return 127; }

  local file
  file="$(find . -type f -printf '%T@\t%p\n' | sort -rn | cut -f2- | ff)" || return
  [[ -n "${file}" ]] && scp "${file}" "$1"
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
