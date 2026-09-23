#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

PACKAGE_MANIFEST="$MANIFEST_DIR/host-packages.txt"
REPOSITORY_MANIFEST="$MANIFEST_DIR/external-repositories.conf"
VENDOR_REPOSITORY_MANIFEST="$MANIFEST_DIR/vendor-repositories.conf"

usage() {
  printf 'Usage: %s [--profile NAME] [--dry-run]\n' "${0##*/}"
}

copr_repo_url() {
  local owner=$1 project=$2 arch=$3 version=$4
  printf 'https://download.copr.fedorainfracloud.org/results/%s/%s/fedora-%s-%s/' "$owner" "$project" "$version" "$arch"
}

CURL_FLAGS=(--fail --silent --show-error --location)

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
  local package=$1 owner=$2 project=$3 arch=$4 expected_fpr=$5 version=$6
  local repo_id base_url gpg_key destination temporary key_tmp
  repo_id="copr-${owner//[^[:alnum:]]/-}-${project//[^[:alnum:]]/-}"
  base_url=$(copr_repo_url "$owner" "$project" "$arch" "$version")
  gpg_key="https://download.copr.fedorainfracloud.org/results/$owner/$project/pubkey.gpg"
  destination="/etc/yum.repos.d/${repo_id}.repo"

  if ! curl "${CURL_FLAGS[@]}" --output /dev/null "${base_url}repodata/repomd.xml"; then
    die "COPR $owner/$project has no Fedora $version/$arch metadata at ${base_url}; verify the COPR build or update $REPOSITORY_MANIFEST"
  fi
  info "COPR metadata reachable: ${base_url}"

  key_tmp=$(mktemp)
  trap 'rm -f -- "${key_tmp:-}"' RETURN
  curl "${CURL_FLAGS[@]}" "$gpg_key" --output "$key_tmp"
  check_key_fingerprint "$key_tmp" "$expected_fpr" "COPR $owner/$project"
  rm -f -- "$key_tmp"
  trap - RETURN

  if is_dry_run; then
    info "Would install repo file to $destination"
    return
  fi

  temporary=$(mktemp)
  trap 'rm -f -- "${temporary:-}"' RETURN
  printf '[%s]\nname=COPR %s/%s\nbaseurl=%s\nenabled=1\ngpgcheck=1\ngpgkey=%s\nincludepkgs=%s\nskip_if_unavailable=0\n' \
    "$repo_id" "$owner" "$project" "$base_url" "$gpg_key" "$package" > "$temporary"

  install_repo_file "$temporary" "$destination" "$owner/$project"
  rm -f -- "$temporary"
  trap - RETURN
}

install_repo_file() {
  local temporary=$1 destination=$2 label=$3
  if run_root test -r "$destination" && run_root cmp --silent "$temporary" "$destination"; then
    info "Repository already configured: $label"
  elif run_root test -e "$destination"; then
    die "$destination differs from the expected $label definition; inspect it before continuing"
  else
    run_root install -o root -g root -m 0644 "$temporary" "$destination"
    info "Configured repository: $label"
  fi
}

download_repo_file() {
  local repo_url=$1 package=$2 temporary=$3
  curl "${CURL_FLAGS[@]}" "$repo_url" --output "$temporary"
  grep -q 'gpgkey' "$temporary" || die "downloaded repository for $package lacks gpgkey; refusing to use it"
}

download_and_verify_key() {
  local key_url=$1 expected_fpr=$2 label=$3 key_tmp
  key_tmp=$(mktemp)
  trap 'rm -f -- "${key_tmp:-}"' RETURN
  curl "${CURL_FLAGS[@]}" "$key_url" --output "$key_tmp"
  check_key_fingerprint "$key_tmp" "$expected_fpr" "$label"
  rm -f -- "$key_tmp"
  trap - RETURN
}

provision_vendor_repo() {
  local package=$1 repo_url=$2 key_url=$3 expected_fpr=$4 destination=$5
  local temporary

  download_and_verify_key "$key_url" "$expected_fpr" "Vendor $package"

  if is_dry_run; then
    info "Would install vendor repository file for $package to $destination"
    return
  fi

  temporary=$(mktemp)
  trap 'rm -f -- "${temporary:-}"' RETURN
  download_repo_file "$repo_url" "$package" "$temporary"
  install_repo_file "$temporary" "$destination" "vendor $package"
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
require_silverblue
if pending_deployment_exists; then
  info "An rpm-ostree deployment is already pending. Reboot before continuing."
  exit 10
fi
require_command rpm
require_command sudo
require_command curl
require_command gpg

mapfile -t requested_packages < <(read_manifest "$PACKAGE_MANIFEST")
missing_packages=()
for package in "${requested_packages[@]}"; do
  rpm -q --quiet "$package" || missing_packages+=("$package")
done

if ((${#missing_packages[@]} == 0)); then
  info "All requested host packages are installed; no deployment change needed"
  exit 0
fi

# Only provision repositories needed by the missing packages.
needs_package() {
  local wanted=$1 candidate
  for candidate in "${missing_packages[@]}"; do
    [[ $candidate == "$wanted" ]] && return 0
  done
  return 1
}

while IFS='|' read -r package repo_url key_url fingerprint destination; do
  [[ -n ${package:-} ]] || continue
  [[ -n ${fingerprint:-} ]] || die "missing GPG fingerprint for $package in $VENDOR_REPOSITORY_MANIFEST"
  if needs_package "$package"; then
    provision_vendor_repo "$package" "$repo_url" "$key_url" "$fingerprint" "$destination"
  fi
done < <(read_manifest "$VENDOR_REPOSITORY_MANIFEST")

arch=$(rpm --eval '%{_arch}')
fedora_ver=$(fedora_version)
while IFS='|' read -r package owner project fingerprint; do
  [[ -n ${package:-} ]] || continue
  [[ -n ${fingerprint:-} ]] || die "missing GPG fingerprint for $package in $REPOSITORY_MANIFEST"
  if needs_package "$package"; then
    provision_copr_repo "$package" "$owner" "$project" "$arch" "$fingerprint" "$fedora_ver"
  fi
done < <(read_manifest "$REPOSITORY_MANIFEST")

info "Layering missing packages: ${missing_packages[*]}"
run_root rpm-ostree install "${missing_packages[@]}"

if is_dry_run; then
  info "Dry run complete; a real package installation would require a reboot before continuing"
  exit 0
else
  info "A new deployment has been created. Reboot now, then run configure-system.sh."
fi
exit 10
