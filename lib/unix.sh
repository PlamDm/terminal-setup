# Pinned binary-only Unix backend. Each feature has its own dependency prefix.
_PD_UNIX_DIR="$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$_PD_UNIX_DIR/portable.sh"

pd_conda_subdir() {
  case "$1" in linux-x64) printf 'linux-64\n' ;; linux-arm64) printf 'linux-aarch64\n' ;;
    macos-x64) printf 'osx-64\n' ;; macos-arm64) printf 'osx-arm64\n' ;;
    *) die "Unsupported pinned conda platform: $1." ;; esac
}

pd_unix_check_host() {
  local pd_version pd_major pd_minor
  case "$PD_OS" in
    linux)
      have getconf || die "Linux requires glibc >=2.28 (musl is unsupported)."
      pd_version="$(getconf GNU_LIBC_VERSION 2>/dev/null)" ||
        die "Linux requires glibc >=2.28 (musl is unsupported)."
      pd_version="${pd_version##* }"
      pd_major="${pd_version%%.*}"; pd_minor="${pd_version#*.}"; pd_minor="${pd_minor%%.*}"
      [[ "$pd_major.$pd_minor" =~ ^[0-9]+\.[0-9]+$ ]] || die "Cannot determine glibc version."
      [ "$pd_major" -gt 2 ] || { [ "$pd_major" -eq 2 ] && [ "$pd_minor" -ge 28 ]; } ||
        die "Pinned Linux packages require glibc >=2.28."
      pd_version="$(uname -r)"; pd_major="${pd_version%%.*}"; pd_minor="${pd_version#*.}"; pd_minor="${pd_minor%%.*}"
      [ "$pd_major" -gt 4 ] || { [ "$pd_major" -eq 4 ] && [ "$pd_minor" -ge 18 ]; } ||
        die "Pinned Linux packages require kernel >=4.18."
      ;;
    macos)
      pd_version="$(sw_vers -productVersion)"
      pd_major="${pd_version%%.*}"; pd_minor="${pd_version#*.}"; pd_minor="${pd_minor%%.*}"
      [[ "$pd_major.$pd_minor" =~ ^[0-9]+\.[0-9]+$ ]] || die "Cannot determine macOS version."
      if [ "$PD_UNIX_PLATFORM" = macos-arm64 ]; then
        [ "$pd_major" -gt 14 ] || { [ "$pd_major" -eq 14 ] && [ "$pd_minor" -ge 5 ]; } ||
          die "Pinned macOS arm64 packages require macOS >=14.5 (current Ghostscript)."
      else [ "$pd_major" -ge 13 ] || die "Pinned macOS x64 packages require macOS >=13."; fi
      ;;
    *) die "This backend only supports Linux and macOS." ;;
  esac
}

pd_unix_check_artifact_host() {
  [ "$PD_OS:$PD_UNIX_PLATFORM" = linux:linux-x64 ] || return 0
  local pd_id="$1" pd_minimum pd_version pd_major pd_minor
  # GNU ELF version requirements in the exact reviewed standalone archives.
  case "$pd_id" in rustifiedgit) pd_minimum=34 ;; wezterm) pd_minimum=29 ;; *) return 0 ;; esac
  pd_version="$(getconf GNU_LIBC_VERSION)"
  pd_version="${pd_version##* }"
  pd_major="${pd_version%%.*}"; pd_minor="${pd_version#*.}"; pd_minor="${pd_minor%%.*}"
  [ "$pd_major" -gt 2 ] || { [ "$pd_major" -eq 2 ] && [ "$pd_minor" -ge "$pd_minimum" ]; } ||
    die "$pd_id $PD_ARTIFACT_VERSION requires Linux x64 glibc >=2.$pd_minimum (verified ELF ABI)."
}

pd_conda_lock_file() {
  printf '%s/packages/unix-%s.tsv\n' "${PD_DIR:-$_PD_UNIX_DIR/..}" "$PD_UNIX_PLATFORM"
}

pd_conda_validate_lock() {
  local pd_lock="$1" pd_feature pd_name pd_version pd_hash pd_url pd_extra
  [ -s "$pd_lock" ] || die "Missing reviewed Unix package lock: $pd_lock."
  while IFS=$'\t' read -r pd_feature pd_name pd_version pd_hash pd_url pd_extra; do
    pd_url="${pd_url%$'\r'}"
    case "$pd_feature" in ''|'#'*) continue ;; esac
    [[ "$pd_feature" =~ ^(bash|git|tmux|fzf|btop|yazi)(-[a-z0-9]+)?$ ]] ||
      die "Invalid locked feature: $pd_feature."
    [[ "$pd_name" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] && [ -n "$pd_version" ] &&
      [[ "$pd_hash" =~ ^[a-f0-9]{64}$ ]] && [ -z "$pd_extra" ] ||
      die "Invalid package record for $pd_feature/$pd_name."
    case "$pd_url" in
      "https://conda.anaconda.org/conda-forge/$PD_CONDA_SUBDIR/"*|https://conda.anaconda.org/conda-forge/noarch/*) ;;
      *) die "Unreviewed channel or wrong package platform: $pd_url." ;;
    esac
    pd_package_basename "$pd_url" >/dev/null
  done < "$pd_lock"
}

pd_conda_selected_features() {
  local pd_feature
  while IFS= read -r pd_feature; do
    if pd_selected "${pd_feature%%-*}"; then printf '%s\n' "$pd_feature"; fi
  done < <(awk -F '\t' '!/^#/ && NF == 5 && !seen[$1]++ { print $1 }' "$1")
}

pd_unix_preflight() {
  local pd_feature pd_id pd_found
  PD_UNIX_PLATFORM="$(pd_unix_platform)"
  PD_CONDA_SUBDIR="$(pd_conda_subdir "$PD_UNIX_PLATFORM")"
  pd_unix_check_host
  pd_conda_validate_lock "$(pd_conda_lock_file)"
  for pd_feature in bash git tmux fzf btop yazi; do
    if pd_selected "$pd_feature"; then
      pd_found="$(awk -F '\t' -v id="$pd_feature" '$1 == id { n++ } END { print n+0 }' "$(pd_conda_lock_file)")"
      [ "$pd_found" -gt 0 ] || die "No reviewed binary package closure for $pd_feature on $PD_UNIX_PLATFORM."
    fi
  done
  if [ -n "$(pd_conda_selected_features "$(pd_conda_lock_file)")" ]; then pd_locked_artifact micromamba; fi
  for pd_id in copilot codex vscode wezterm rustifiedgit; do
    if pd_selected "$pd_id"; then
      if [ "$pd_id:$PD_UNIX_PLATFORM" = rustifiedgit:linux-arm64 ]; then
        die "RustifiedGit v0.1.0 has no Linux arm64 release; no approved locked build recipe exists."
      fi
      pd_locked_artifact "$pd_id"
      pd_unix_check_artifact_host "$pd_id"
      case "$PD_ARTIFACT_ARCHIVE" in source|sfx)
        die "No approved compiler-free Unix artifact for $pd_id on $PD_UNIX_PLATFORM." ;; esac
    fi
  done
  if pd_selected wezterm; then pd_locked_artifact font; fi
  if pd_selected yazi && [ "$PD_OS" = linux ]; then
    PD_UNAVAILABLE_UNIX_COMMANDS="wl-copy wl-paste"
    log "Optional unsupported Yazi capability: Wayland clipboard (wl-copy/wl-paste); no reviewed binary recipe is available. Core Yazi and X11 xclip are supported; this bundle does not provide full Wayland feature parity." >&2
  fi
}

pd_conda_mamba() {
  local pd_directory
  for pd_directory in state/mamba-home state/mamba-root cache/conda tmp/mamba; do
    pd_require_managed_path "$PD_ROOT/$pd_directory"
  done
  mkdir -p "$PD_ROOT/state/mamba-home" "$PD_ROOT/state/mamba-root" "$PD_ROOT/cache/conda" "$PD_ROOT/tmp/mamba"
  env -u CONDA_PREFIX -u CONDA_DEFAULT_ENV -u CONDA_ENVS_PATH -u CONDA_PINNED_PACKAGES \
    -u CONDA_OVERRIDE_GLIBC -u CONDA_OVERRIDE_LINUX -u CONDA_OVERRIDE_OSX \
    -u CONDA_OVERRIDE_ARCHSPEC -u CONDA_OVERRIDE_CUDA \
    HOME="$PD_ROOT/state/mamba-home" USERPROFILE="$PD_ROOT/state/mamba-home" \
    XDG_CONFIG_HOME="$PD_ROOT/state/mamba-home/config" XDG_CACHE_HOME="$PD_ROOT/cache/conda" \
    XDG_DATA_HOME="$PD_ROOT/state/mamba-home/data" XDG_STATE_HOME="$PD_ROOT/state/mamba-home/state" \
    MAMBA_ROOT_PREFIX="$PD_ROOT/state/mamba-root" CONDA_PKGS_DIRS="$PD_ROOT/cache/conda" \
    TMPDIR="$PD_ROOT/tmp/mamba" TMP="$PD_ROOT/tmp/mamba" TEMP="$PD_ROOT/tmp/mamba" \
    BASH_ENV= ENV= "$PD_INSTALL/micromamba/$PD_MICROMAMBA_RELATIVE" "$@"
}

pd_conda_file_url() {
  local pd_path="$1" pd_encoded="" pd_char pd_hex pd_index LC_ALL=C
  # Explicit URLs must retain the original conda archive basename.
  for ((pd_index = 0; pd_index < ${#pd_path}; pd_index++)); do
    pd_char="${pd_path:pd_index:1}"
    case "$pd_char" in
      [a-zA-Z0-9._~!+/-]) pd_encoded="$pd_encoded$pd_char" ;;
      *) printf -v pd_hex '%02X' "'$pd_char"; pd_encoded="$pd_encoded%$pd_hex" ;;
    esac
  done
  printf 'file://%s\n' "$pd_encoded"
}

pd_conda_prepare_explicit() {
  local pd_lock="$1" pd_feature="$2" pd_explicit="$3" pd_name pd_version pd_hash pd_url pd_file pd_alias
  printf '@EXPLICIT\n' > "$pd_explicit"
  while IFS=$'\t' read -r pd_name pd_version pd_hash pd_url; do
    pd_url="${pd_url%$'\r'}"
    pd_file="$(pd_fetch_locked "$pd_hash" "$pd_url")"
    pd_alias="$PD_ROOT/cache/conda-archives/$pd_hash/$(pd_package_basename "$pd_url")"
    pd_require_managed_path "$pd_alias"
    mkdir -p "$(dirname -- "$pd_alias")"
    if [ ! -f "$pd_alias" ]; then
      ln "$pd_file" "$pd_alias" 2>/dev/null || cp "$pd_file" "$pd_alias"
    fi
    pd_verify_sha256 "$pd_alias" "$pd_hash"
    printf '%s#%s\n' "$(pd_conda_file_url "$pd_alias")" "$pd_hash" >> "$pd_explicit"
  done < <(awk -F '\t' -v feature="$pd_feature" '$1 == feature && !seen[$5]++ { print $2 "\t" $3 "\t" $4 "\t" $5 }' "$pd_lock")
  [ "$(wc -l < "$pd_explicit")" -gt 1 ] || die "Empty explicit lock for $pd_feature."
}

pd_conda_check_commands() {
  local pd_feature="$1" pd_prefix="$2" pd_command pd_commands
  case "$pd_feature" in
    bash|git|tmux|fzf|btop|yazi) pd_commands="$pd_feature" ;;
    yazi-file) pd_commands=file ;; yazi-ffmpeg) pd_commands="ffmpeg ffprobe" ;;
    yazi-7zip) pd_commands=7z
      if [ ! -x "$pd_prefix/bin/7z" ] && [ -x "$pd_prefix/bin/7zz" ]; then ln -s 7zz "$pd_prefix/bin/7z"; fi ;;
    yazi-jq) pd_commands=jq ;; yazi-poppler) pd_commands="pdftoppm pdftotext pdfinfo" ;;
    yazi-fd) pd_commands=fd ;; yazi-ripgrep) pd_commands=rg ;; yazi-zoxide) pd_commands=zoxide ;;
    yazi-resvg) pd_commands=resvg ;; yazi-imagemagick) pd_commands=magick ;;
    yazi-xclip) pd_commands=xclip ;; yazi-glib) pd_commands=gio ;;
    *) die "Unknown managed conda feature: $pd_feature." ;;
  esac
  for pd_command in $pd_commands; do
    [ -x "$pd_prefix/bin/$pd_command" ] ||
      die "The reviewed $pd_feature closure did not install the expected command: $pd_command."
  done
}

pd_conda_link_feature() {
  local pd_feature="$1" pd_lock="$2" pd_prefix="$PD_INSTALL/conda/$1" pd_state pd_explicit pd_binary
  [[ "$pd_feature" =~ ^(bash|git|tmux|fzf|btop|yazi)(-[a-z0-9]+)?$ ]] || die "Unsafe conda feature."
  pd_state="$PD_ROOT/state/conda/$pd_feature"
  pd_require_managed_path "$pd_prefix"
  pd_require_managed_path "$PD_ROOT/state/conda"
  pd_require_managed_path "$PD_ROOT/tmp/mamba"
  pd_require_managed_path "$pd_state.prefix"
  pd_require_managed_path "$pd_state.installing"
  pd_require_managed_path "$pd_state.lock.tsv"
  pd_require_managed_path "$pd_prefix/.playground-managed"
  mkdir -p "$PD_ROOT/state/conda" "$PD_INSTALL/conda/bin" "$PD_ROOT/tmp/mamba"
  if [ -f "$pd_state.prefix" ] && [ "$(cat "$pd_state.prefix")" = "$pd_prefix" ] &&
      [ -f "$pd_prefix/.playground-managed" ] && [ -f "$pd_state.lock.tsv" ] &&
      cmp -s "$pd_lock" "$pd_state.lock.tsv"; then
    pd_conda_check_commands "$pd_feature" "$pd_prefix"
  else
    pd_explicit="$PD_ROOT/tmp/mamba/$pd_feature.explicit"
    pd_conda_prepare_explicit "$pd_lock" "$pd_feature" "$pd_explicit"
    # Moving a conda environment requires actual prefix rewriting. Retained,
    # verified archives are re-linked offline into only this managed payload.
    [ ! -L "$PD_INSTALL" ] && [ ! -L "$PD_INSTALL/conda" ] && [ ! -L "$pd_prefix" ] ||
      die "Refusing to recreate a symlinked conda installation."
    if [ -e "$pd_prefix" ]; then
      [ -f "$pd_prefix/.playground-managed" ] ||
        { [ -f "$pd_state.installing" ] && [ "$(cat "$pd_state.installing")" = "$pd_feature" ]; } ||
        die "Refusing to replace an unmanaged conda prefix: $pd_prefix."
      rm -rf -- "$pd_prefix"
    fi
    log "Linking pinned $pd_feature binaries offline into $pd_prefix." >&2
    printf '%s\n' "$pd_feature" > "$pd_state.installing"
    pd_conda_mamba create --no-rc --offline --yes --quiet --no-shortcuts --no-py-pin \
      --platform "$PD_CONDA_SUBDIR" --prefix "$pd_prefix" --file "$pd_explicit" >&2
    pd_conda_check_commands "$pd_feature" "$pd_prefix"
    printf '%s\n' "$pd_feature" > "$pd_prefix/.playground-managed"
    rm -f "$pd_state.installing"
    if [ "$pd_lock" != "$pd_state.lock.tsv" ]; then cp "$pd_lock" "$pd_state.lock.tsv"; fi
    printf '%s\n' "$pd_prefix" > "$pd_state.prefix"
  fi
  for pd_binary in "$pd_prefix/bin/"*; do
    [ -x "$pd_binary" ] && [ ! -d "$pd_binary" ] || continue
    if [ ! -e "$PD_TOOL_BIN/${pd_binary##*/}" ] && [ ! -L "$PD_TOOL_BIN/${pd_binary##*/}" ]; then
      ln -s "../$pd_feature/bin/${pd_binary##*/}" "$PD_TOOL_BIN/${pd_binary##*/}"
    fi
  done
}

pd_install_unix_runtime() {
  local pd_library pd_manifest="${PD_ARTIFACT_MANIFEST:-${PD_DIR:-$_PD_UNIX_DIR/..}/packages/artifacts.tsv}"
  for pd_library in lib/packages.sh lib/portable.sh lib/unix.sh lib/relocate.sh packages/artifacts.tsv state/conda-platform state/conda-micromamba; do
    pd_require_managed_path "$PD_ROOT/$pd_library"
  done
  mkdir -p "$PD_ROOT/lib" "$PD_ROOT/packages" "$PD_ROOT/state"
  for pd_library in packages.sh portable.sh unix.sh; do
    if [ "$_PD_UNIX_DIR/$pd_library" != "$PD_ROOT/lib/$pd_library" ]; then
      cp "$_PD_UNIX_DIR/$pd_library" "$PD_ROOT/lib/$pd_library"
    fi
  done
  if [ "$pd_manifest" != "$PD_ROOT/packages/artifacts.tsv" ]; then cp "$pd_manifest" "$PD_ROOT/packages/artifacts.tsv"; fi
  printf '%s\n' "$PD_UNIX_PLATFORM" > "$PD_ROOT/state/conda-platform"
  printf '%s\n' "$PD_MICROMAMBA_RELATIVE" > "$PD_ROOT/state/conda-micromamba"
  cat > "$PD_ROOT/lib/relocate.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
PD_ROOT="$(CDPATH= cd -P -- "$1" && pwd)"
case "$PD_ROOT" in /|*$'\n'*|*$'\r'*) printf 'Unsafe relocation root.\n' >&2; exit 1 ;; esac
PD_INSTALL="$PD_ROOT/install"
PD_DIR="$PD_ROOT"
PD_TOOL_BIN="$PD_INSTALL/conda/bin"
PD_OFFLINE=1
PD_DOWNLOAD_ONLY=0
PD_PACKAGE_DIR=
PD_PACKAGE_CACHE="$PD_ROOT/cache/packages"
PD_ARTIFACT_MANIFEST="$PD_ROOT/packages/artifacts.tsv"
PD_UNIX_PLATFORM="$(cat "$PD_ROOT/state/conda-platform")"
PD_MICROMAMBA_RELATIVE="$(cat "$PD_ROOT/state/conda-micromamba")"
case "$PD_UNIX_PLATFORM" in linux-*) PD_OS=linux ;; macos-*) PD_OS=macos ;; *) exit 1 ;; esac
log() { printf '[playground] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
fetch() { die "Relocation never uses the network."; }
. "$PD_ROOT/lib/unix.sh"
PD_CONDA_SUBDIR="$(pd_conda_subdir "$PD_UNIX_PLATFORM")"
pd_locked_artifact micromamba "$PD_UNIX_PLATFORM"
[ "$PD_MICROMAMBA_RELATIVE" = "$PD_ARTIFACT_EXECUTABLE" ] || die "Changed micromamba executable lock."
pd_needs_relocation=0
for pd_saved in "$PD_ROOT/state/conda/"*.prefix; do
  [ -f "$pd_saved" ] || continue
  pd_feature="${pd_saved##*/}"; pd_feature="${pd_feature%.prefix}"
  [ -z "${2:-}" ] || [ "$2" = "$pd_feature" ] || continue
  if [ "$(cat "$pd_saved")" != "$PD_INSTALL/conda/$pd_feature" ]; then pd_needs_relocation=1; break; fi
done
[ "$pd_needs_relocation" = 1 ] || exit 0
case "$(uname -s)" in
  Linux) PD_OS=linux ;; Darwin) PD_OS=macos ;;
  *) die "Unsupported relocation host." ;;
esac
[ "$(pd_unix_platform)" = "$PD_UNIX_PLATFORM" ] || die "Relocation across operating systems or architectures is unsupported."
pd_unix_check_host
pd_verify_sha256 "$(pd_fetch_locked "$PD_ARTIFACT_SHA256" "$PD_ARTIFACT_URL")" "$PD_ARTIFACT_SHA256"
pd_require_managed_path "$PD_ROOT/state/conda-relocating"
if ! mkdir "$PD_ROOT/state/conda-relocating" 2>/dev/null; then
  die "Another relocation is running; after interruption remove only state/conda-relocating and retry."
fi
trap 'rmdir "$PD_ROOT/state/conda-relocating"' EXIT
for pd_saved in "$PD_ROOT/state/conda/"*.prefix; do
  [ -f "$pd_saved" ] || continue
  pd_feature="${pd_saved##*/}"; pd_feature="${pd_feature%.prefix}"
  [ -z "${2:-}" ] || [ "$2" = "$pd_feature" ] || continue
  if [ "$(cat "$pd_saved")" != "$PD_INSTALL/conda/$pd_feature" ]; then
    pd_conda_validate_lock "$PD_ROOT/state/conda/$pd_feature.lock.tsv"
    pd_conda_link_feature "$pd_feature" "$PD_ROOT/state/conda/$pd_feature.lock.tsv"
  fi
done
EOF
  chmod 755 "$PD_ROOT/lib/relocate.sh"
}

install_unix_tools() {
  local pd_lock pd_feature pd_file pd_name pd_version pd_hash pd_url
  PD_TOOL_BIN="$PD_INSTALL/conda/bin"
  PD_WEZTERM=""
  pd_unix_preflight
  pd_lock="$(pd_conda_lock_file)"
  if [ -n "$(pd_conda_selected_features "$pd_lock")" ]; then
    pd_locked_artifact micromamba
    PD_MICROMAMBA_RELATIVE="$PD_ARTIFACT_EXECUTABLE"
    pd_file="$(pd_fetch_locked "$PD_ARTIFACT_SHA256" "$PD_ARTIFACT_URL")"
    while IFS= read -r pd_feature; do
      while IFS=$'\t' read -r pd_name pd_version pd_hash pd_url; do
        pd_url="${pd_url%$'\r'}"
        pd_fetch_locked "$pd_hash" "$pd_url" >/dev/null
      done < <(awk -F '\t' -v feature="$pd_feature" '$1 == feature { print $2 "\t" $3 "\t" $4 "\t" $5 }' "$pd_lock")
    done < <(pd_conda_selected_features "$pd_lock")
    if [ "${PD_DOWNLOAD_ONLY:-0}" != 1 ]; then
      pd_install_locked_tool micromamba "$PD_INSTALL/micromamba"
      pd_install_unix_runtime
      while IFS= read -r pd_feature; do
        pd_conda_link_feature "$pd_feature" "$pd_lock"
      done < <(pd_conda_selected_features "$pd_lock")
    fi
  fi
  if pd_selected wezterm; then
    pd_install_locked_tool wezterm "$PD_INSTALL/wezterm"
    PD_WEZTERM="${PD_LOCKED_EXECUTABLE:-}"
    if [ "${PD_DOWNLOAD_ONLY:-0}" != 1 ] && [ "$PD_ARTIFACT_ARCHIVE" = appimage ] &&
        [ -x "$PD_INSTALL/wezterm/AppRun" ]; then PD_WEZTERM="$PD_INSTALL/wezterm/AppRun"; fi
  fi
  [ "${PD_DOWNLOAD_ONLY:-0}" != 1 ] || return 0
  mkdir -p "$PD_TOOL_BIN"
}
