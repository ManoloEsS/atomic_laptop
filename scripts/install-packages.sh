#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

PACKAGE_MANIFEST="$MANIFEST_DIR/host-packages.txt"
REPOSITORY_MANIFEST="$MANIFEST_DIR/external-repositories.conf"

usage() {
  printf 'Usage: %s [--profile NAME] [--dry-run]\n' "${0##*/}"
}

copr_repo_url() {
  local owner=$1 project=$2 arch=$3
  printf 'https://download.copr.fedorainfracloud.org/results/%s/%s/fedora-44-%s/' "$owner" "$project" "$arch"
}

check_key_fingerprint() {
  local key_file=$1 expected=$2 label=$3 actual
  actual=$(gpg --show-keys --with-colons "$key_file" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')
  if [[ -z ${actual:-} ]]; then
    die "$label: could not read a fingerprint from the downloaded key"
  fi
  if [[ ${actual^^} != "${expected^^}" ]]; then
    die "$label: fingerprint mismatch (got $actual, expected $expected); refusing to trust"
  fi
  info "$label: fingerprint verified ($actual)"
}

provision_copr_repo() {
  local package=$1 owner=$2 project=$3 arch=$4 expected_fpr=$5
  local repo_id base_url gpg_key destination temporary key_tmp
  repo_id="copr-${owner//[^[:alnum:]]/-}-${project//[^[:alnum:]]/-}"
  base_url=$(copr_repo_url "$owner" "$project" "$arch")
  gpg_key="https://download.copr.fedorainfracloud.org/results/$owner/$project/pubkey.gpg"
  destination="/etc/yum.repos.d/${repo_id}.repo"

  require_command curl
  require_command gpg

  if ! curl --fail --silent --show-error --location --output /dev/null "${base_url}repodata/repomd.xml"; then
    die "COPR $owner/$project has no Fedora 44/$arch metadata at ${base_url}; verify the COPR build or update $REPOSITORY_MANIFEST"
  fi
  info "COPR metadata reachable: ${base_url}"

  key_tmp=$(mktemp)
  trap 'rm -f -- "${key_tmp:-}"' RETURN
  curl --fail --silent --show-error --location "$gpg_key" --output "$key_tmp"
  check_key_fingerprint "$key_tmp" "$expected_fpr" "COPR $owner/$project"
  rm -f -- "$key_tmp"
  trap - RETURN

  if [[ $DRY_RUN == true ]]; then
    info "Would install repo file to $destination"
    return
  fi

  temporary=$(mktemp)
  trap 'rm -f -- "${temporary:-}"' RETURN
  printf '[%s]\nname=COPR %s/%s\nbaseurl=%s\nenabled=1\ngpgcheck=1\ngpgkey=%s\nincludepkgs=%s\nskip_if_unavailable=0\n' \
    "$repo_id" "$owner" "$project" "$base_url" "$gpg_key" "$package" > "$temporary"

  if run_root test -r "$destination" && run_root cmp --silent "$temporary" "$destination"; then
    info "COPR repository already configured: $owner/$project"
  elif run_root test -e "$destination"; then
    die "$destination differs from the expected $owner/$project definition; inspect it before continuing"
  else
    run_root install -o root -g root -m 0644 "$temporary" "$destination"
    info "Configured COPR repository: $owner/$project"
  fi
  rm -f -- "$temporary"
  trap - RETURN
}

provision_tailscale_repo() {
  local destination=/etc/yum.repos.d/tailscale.repo
  local upstream=https://pkgs.tailscale.com/stable/fedora/tailscale.repo
  # Tailscale Inc. package repository signing key (primary). Cross-check at
  # https://tailscale.com/kb/1485/install-clients before changing this value.
  local expected_fpr=2596A99EAAB33821893C0A79458CA832957F5868

  require_command curl
  require_command gpg

  if ! curl --fail --silent --show-error --location --output /dev/null "$upstream"; then
    die "official Tailscale repo unreachable at $upstream"
  fi
  info "Tailscale repo reachable: $upstream"

  local key_url key_tmp
  key_url=https://pkgs.tailscale.com/stable/fedora/repo.gpg
  key_tmp=$(mktemp)
  trap 'rm -f -- "${key_tmp:-}"' RETURN
  curl --fail --silent --show-error --location "$key_url" --output "$key_tmp"
  check_key_fingerprint "$key_tmp" "$expected_fpr" "Tailscale vendor key"
  rm -f -- "$key_tmp"
  trap - RETURN

  if [[ $DRY_RUN == true ]]; then
    info "Would install repo file to $destination"
    return
  fi

  local temporary
  temporary=$(mktemp)
  trap 'rm -f -- "${temporary:-}"' RETURN
  curl --fail --silent --show-error --location "$upstream" --output "$temporary"
  grep -q 'gpgkey' "$temporary" || die "downloaded Tailscale repo file lacks gpgkey; refusing to use it"

  if run_root test -r "$destination" && run_root cmp --silent "$temporary" "$destination"; then
    info "Tailscale repository already configured"
  elif run_root test -e "$destination"; then
    die "$destination differs from the official Tailscale repo; inspect it and rerun install-packages.sh after resolving"
  else
    run_root install -o root -g root -m 0644 "$temporary" "$destination"
    info "Configured official Tailscale repository"
  fi
  rm -f -- "$temporary"
  trap - RETURN
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
require_silverblue_44
if pending_deployment_exists; then
  info "An rpm-ostree deployment is already pending. Reboot before continuing."
  exit 10
fi
require_command rpm
require_command sudo

mapfile -t requested_packages < <(read_manifest "$PACKAGE_MANIFEST")
missing_packages=()
for package in "${requested_packages[@]}"; do
  rpm -q --quiet "$package" || missing_packages+=("$package")
done

if ((${#missing_packages[@]} == 0)); then
  info "All requested host packages are installed; no deployment change needed"
  exit 0
fi

for missing in "${missing_packages[@]}"; do
  if [[ $missing == tailscale ]]; then
    provision_tailscale_repo
    break
  fi
done

arch=$(rpm --eval '%{_arch}')
while IFS='|' read -r package owner project fingerprint; do
  [[ -n ${package:-} && ${package:0:1} != '#' ]] || continue
  [[ -n ${fingerprint:-} ]] || die "missing GPG fingerprint for $package in $REPOSITORY_MANIFEST"
  for missing in "${missing_packages[@]}"; do
    if [[ $missing == "$package" ]]; then
      provision_copr_repo "$package" "$owner" "$project" "$arch" "$fingerprint"
      break
    fi
  done
done < "$REPOSITORY_MANIFEST"

info "Layering missing packages: ${missing_packages[*]}"
run_root rpm-ostree install "${missing_packages[@]}"

if [[ $DRY_RUN == true ]]; then
  info "Dry run complete; a real package installation would require a reboot before continuing"
  exit 0
else
  info "A new deployment has been created. Reboot now, then run configure-system.sh."
fi
exit 10
