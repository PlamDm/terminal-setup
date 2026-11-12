# Shared pinned artifact/cache helpers. No release discovery happens at install time.
_PD_PACKAGES_DIR="$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

pd_require_managed_path() {
  local pd_path="$1"
  case "$pd_path" in "$PD_ROOT/"*) ;; *) die "Destination is outside the selected root: $pd_path." ;; esac
  case "$pd_path" in */../*|*/./*|*/..|*/.) die "Unsafe managed destination: $pd_path." ;; esac
  while [ "$pd_path" != "$PD_ROOT" ]; do
    [ ! -L "$pd_path" ] || die "Refusing to write through a symlink: $pd_path."
    pd_path="${pd_path%/*}"
  done
}

pd_verify_sha256() {
  local pd_file="$1" pd_expected="$2" pd_actual
  [[ "$pd_expected" =~ ^[a-fA-F0-9]{64}$ ]] || die "Invalid SHA-256 for $pd_file."
  if have sha256sum; then pd_actual="$(sha256sum < "$pd_file")"
  elif have shasum; then pd_actual="$(shasum -a 256 < "$pd_file")"
  else die "A host SHA-256 utility (sha256sum or shasum) is required."; fi
  [ "${pd_actual%% *}" = "$(printf '%s' "$pd_expected" | tr 'A-F' 'a-f')" ] ||
    die "SHA-256 verification failed for $pd_file."
}

pd_package_basename() {
  local pd_name="${1##*/}"
  pd_name="${pd_name%%\?*}"
  [[ "$pd_name" =~ ^[A-Za-z0-9_][A-Za-z0-9._+!-]*$ ]] ||
    die "Unsafe or missing package filename: $1."
  printf '%s\n' "$pd_name"
}

pd_fetch_locked() {
  local pd_hash="$1" pd_url="$2" pd_name pd_cache pd_file pd_mirror
  [[ "$pd_hash" =~ ^[a-f0-9]{64}$ ]] || die "Invalid locked SHA-256."
  case "$pd_url" in https://*) ;; *) die "Locked downloads require HTTPS: $pd_url." ;; esac
  pd_name="$pd_hash-$(pd_package_basename "$pd_url")"
  pd_cache="${PD_PACKAGE_CACHE:-$PD_ROOT/cache/packages}"
  if [ "${PD_DOWNLOAD_ONLY:-0}" = 1 ] && [ -n "${PD_PACKAGE_DIR:-}" ]; then
    pd_cache="$PD_PACKAGE_DIR"
  fi
  case "$pd_cache" in "$PD_ROOT/"*) pd_require_managed_path "$pd_cache" ;; esac
  mkdir -p "$pd_cache"
  pd_file="$pd_cache/$pd_name"
  if [ -f "$pd_file" ]; then
    pd_verify_sha256 "$pd_file" "$pd_hash"
    printf '%s\n' "$pd_file"
    return
  fi
  [ ! -L "$pd_file.partial" ] || die "Refusing a symlinked partial download."
  if [ -n "${PD_PACKAGE_DIR:-}" ]; then
    pd_mirror="$PD_PACKAGE_DIR/$pd_name"
    if [ -f "$pd_mirror" ]; then
      pd_verify_sha256 "$pd_mirror" "$pd_hash"
      cp "$pd_mirror" "$pd_file.partial"
      pd_verify_sha256 "$pd_file.partial" "$pd_hash"
      mv -f "$pd_file.partial" "$pd_file"
      printf '%s\n' "$pd_file"
      return
    fi
  fi
  [ "${PD_OFFLINE:-0}" != 1 ] || die "Offline package missing: $pd_name."
  if ! fetch "$pd_url" "$pd_file.partial" >&2; then
    rm -f "$pd_file.partial"
    die "Download failed: $pd_url."
  fi
  pd_verify_sha256 "$pd_file.partial" "$pd_hash"
  mv -f "$pd_file.partial" "$pd_file"
  printf '%s\n' "$pd_file"
}

pd_unix_platform() {
  local pd_arch
  case "$(uname -m)" in x86_64|amd64) pd_arch=x64 ;; arm64|aarch64) pd_arch=arm64 ;;
    *) die "Pinned portable tools support only x64 and arm64." ;; esac
  case "${PD_OS:-$(uname -s)}" in linux|Linux) printf 'linux-%s\n' "$pd_arch" ;;
    macos|Darwin) printf 'macos-%s\n' "$pd_arch" ;;
    *) die "Unsupported Unix platform." ;; esac
}

pd_locked_artifact() {
  local pd_id="$1" pd_platform="${2:-$(pd_unix_platform)}" pd_record pd_manifest
  pd_manifest="${PD_ARTIFACT_MANIFEST:-${PD_DIR:-$_PD_PACKAGES_DIR/..}/packages/artifacts.tsv}"
  [ -r "$pd_manifest" ] || die "Pinned artifact manifest missing: $pd_manifest."
  pd_record="$(awk -F '\t' -v id="$pd_id" -v platform="$pd_platform" '
    /^#/ || NF == 0 { next }
    $1 == id && ($2 == platform || $2 == "all") {
      if (NF != 8) exit 2
      if ($2 == platform) { exact = $0; ne++ } else { any = $0; na++ }
    }
    END {
      if (ne > 1 || na > 1) exit 2
      if (ne == 1) print exact; else if (na == 1) print any; else exit 3
    }' "$pd_manifest")" || die "No unique reviewed artifact for $pd_id on $pd_platform."
  IFS=$'\t' read -r PD_ARTIFACT_ID PD_ARTIFACT_PLATFORM PD_ARTIFACT_VERSION \
    PD_ARTIFACT_SHA256 PD_ARTIFACT_URL PD_ARTIFACT_ARCHIVE PD_ARTIFACT_EXECUTABLE \
    PD_ARTIFACT_REPOSITORY <<< "$pd_record"
  [[ "$PD_ARTIFACT_SHA256" =~ ^[a-f0-9]{64}$ ]] || die "Invalid artifact lock for $pd_id."
  [ -n "$PD_ARTIFACT_VERSION" ] || die "Missing locked version for $pd_id."
  case "$PD_ARTIFACT_URL" in https://*) ;; *) die "Artifact lock requires HTTPS." ;; esac
  case "$PD_ARTIFACT_EXECUTABLE" in /*|*../*|../*|*\\*) die "Unsafe executable in $pd_id lock." ;; esac
}

pd_extract_locked() {
  local pd_file="$1" pd_format="$2" pd_destination="$3"
  mkdir -p "$pd_destination"
  case "$pd_format" in
    tar.gz) tar -xzf "$pd_file" -C "$pd_destination" ;;
    tar.bz2) tar -xjf "$pd_file" -C "$pd_destination" ;;
    tar.xz) tar -xJf "$pd_file" -C "$pd_destination" ;;
    zip)
      if have ditto && [ "${PD_OS:-}" = macos ]; then ditto -xk "$pd_file" "$pd_destination"
      else have unzip || die "Host unzip is required for this locked archive."
        unzip -q "$pd_file" -d "$pd_destination"; fi ;;
    *) die "Unsupported portable archive format: $pd_format." ;;
  esac
}
