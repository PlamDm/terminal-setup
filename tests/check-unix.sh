#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
PD_DIR="$(pwd -P)"
pd_repository="$PD_DIR"
pd_test="$PD_DIR/.ci-playground/check-unix-$$"
[ ! -e "$pd_test" ] || exit 1
mkdir -p "$pd_test"
trap 'rm -rf -- "$pd_test"' EXIT
PD_ROOT="$pd_test/root"
PD_INSTALL="$PD_ROOT/install"
PD_OS=linux
PD_OFFLINE=1
PD_DOWNLOAD_ONLY=0
PD_SELECTION_MODE=explicit
PD_SELECTED_TOOLS=bash
pd_original_home="$HOME"
log() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
pd_selected() { case ",$PD_SELECTED_TOOLS," in *,"$1",*) return 0 ;; esac; return 1; }
fetch() { printf 'Unexpected network fetch\n' >&2; exit 90; }
. "$PD_DIR/lib/unix.sh"
for PD_UNIX_PLATFORM in linux-x64 linux-arm64 macos-x64 macos-arm64; do
  PD_CONDA_SUBDIR="$(pd_conda_subdir "$PD_UNIX_PLATFORM")"
  pd_conda_validate_lock "$PD_DIR/packages/unix-$PD_UNIX_PLATFORM.tsv"
done
pd_hash() {
  local pd_result
  if have sha256sum; then pd_result="$(sha256sum "$1")"; else pd_result="$(shasum -a 256 "$1")"; fi
  printf '%s\n' "${pd_result%% *}"
}
pd_expect_failure() {
  if ("$@") >"$pd_test/failure.log" 2>&1; then die "Expected failure: $*"; fi
}
pd_test_macos_preflight() {
  local PD_OS=macos pd_macos_version="$1" pd_macos_arch="${2:-arm64}"
  uname() { case "${1:-}" in -m) printf '%s\n' "$pd_macos_arch" ;; *) printf 'Darwin\n' ;; esac; }
  sw_vers() { printf '%s\n' "$pd_macos_version"; }
  pd_unix_preflight
}
pd_expect_failure pd_test_macos_preflight 13.6
grep -q 'macOS >=14.5' "$pd_test/failure.log"
pd_expect_failure pd_test_macos_preflight 14.4.1
grep -q 'macOS >=14.5' "$pd_test/failure.log"
(pd_test_macos_preflight 14.5)
(pd_test_macos_preflight 15.0)
(pd_test_macos_preflight 13.0 x86_64)
pd_test_linux_artifact_preflight() {
  local PD_OS=linux PD_SELECTED_TOOLS="$1" pd_glibc="$2"
  uname() { case "${1:-}" in -m) printf 'x86_64\n' ;; -r) printf '4.18.0\n' ;; *) printf 'Linux\n' ;; esac; }
  getconf() { printf 'glibc %s\n' "$pd_glibc"; }
  pd_unix_preflight
}
pd_expect_failure pd_test_linux_artifact_preflight rustifiedgit 2.28
grep -q 'rustifiedgit .*glibc >=2.34' "$pd_test/failure.log"
pd_expect_failure pd_test_linux_artifact_preflight rustifiedgit 2.33
(pd_test_linux_artifact_preflight rustifiedgit 2.34)
pd_expect_failure pd_test_linux_artifact_preflight wezterm 2.28
grep -q 'wezterm .*glibc >=2.29' "$pd_test/failure.log"
(pd_test_linux_artifact_preflight wezterm 2.29)
(pd_test_linux_artifact_preflight copilot 2.28)
(pd_test_linux_artifact_preflight bash 2.28)
pd_test_wayland_preflight() {
  local PD_OS=linux PD_SELECTED_TOOLS=yazi
  uname() { case "${1:-}" in -m) printf 'x86_64\n' ;; -r) printf '4.18.0\n' ;; *) printf 'Linux\n' ;; esac; }
  getconf() { printf 'glibc 2.28\n'; }
  pd_unix_preflight
  [ "$PD_UNAVAILABLE_UNIX_COMMANDS" = 'wl-copy wl-paste' ]
}
(pd_test_wayland_preflight) 2> "$pd_test/wayland.log"
grep -q 'Optional unsupported Yazi capability: Wayland clipboard' "$pd_test/wayland.log"
grep -q 'does not provide full Wayland feature parity' "$pd_test/wayland.log"
[ ! -e "$PD_ROOT" ]
mkdir -p "$pd_test/bundle"
PD_PACKAGE_DIR="$pd_test/bundle"
printf 'locked payload\n' > "$pd_test/package"
pd_sha="$(pd_hash "$pd_test/package")"
cp "$pd_test/package" "$PD_PACKAGE_DIR/$pd_sha-example-1.0-0.conda"
pd_cached="$(pd_fetch_locked "$pd_sha" https://example.invalid/example-1.0-0.conda)"
cmp "$pd_cached" "$pd_test/package"
printf 'tampered\n' > "$pd_cached"
pd_expect_failure pd_fetch_locked "$pd_sha" https://example.invalid/example-1.0-0.conda
rm "$pd_cached"
pd_expect_failure pd_fetch_locked "$pd_sha" https://example.invalid/missing-1.0-0.conda
pd_expect_failure pd_fetch_locked "$pd_sha" http://example.invalid/example-1.0-0.conda
PD_DOWNLOAD_ONLY=1
[ "$(pd_fetch_locked "$pd_sha" https://example.invalid/example-1.0-0.conda)" = "$PD_PACKAGE_DIR/$pd_sha-example-1.0-0.conda" ]
[ ! -e "$PD_INSTALL" ]
PD_DOWNLOAD_ONLY=0
PD_OFFLINE=0
fetch() { printf 'bad download\n' > "$2"; }
pd_expect_failure pd_fetch_locked "$pd_sha" https://example.invalid/fresh-1.0-0.conda
[ ! -e "$PD_ROOT/cache/packages/$pd_sha-fresh-1.0-0.conda" ]
fetch() { cp "$pd_test/package" "$2"; }
pd_fetch_locked "$pd_sha" https://example.invalid/fresh-1.0-0.conda >/dev/null
PD_OFFLINE=1
fetch() { die "Unexpected network access"; }

# The fixture linker makes the prefix observable, proving relocation re-links
# rather than merely renaming a path or updating a state marker.
mkdir -p "$pd_test/mamba/bin"
cat > "$pd_test/mamba/bin/micromamba" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "$*" == *--no-rc* && "$*" == *--offline* ]] || exit 91
case "$HOME" in */state/mamba-home) ;; *) exit 92 ;; esac
case "$MAMBA_ROOT_PREFIX" in */state/mamba-root) ;; *) exit 93 ;; esac
case "$CONDA_PKGS_DIRS" in */cache/conda) ;; *) exit 95 ;; esac
case "$TMPDIR" in */tmp/mamba) ;; *) exit 96 ;; esac
prefix= explicit=
while [ "$#" -gt 0 ]; do
  case "$1" in --prefix) prefix="$2"; shift ;; --file) explicit="$2"; shift ;; esac
  shift
done
grep -q '^@EXPLICIT$' "$explicit"
grep -Eq '^file://.*example-1\.0-0\.conda#[a-f0-9]{64}$' "$explicit"
[ ! -e "$prefix" ] || exit 94
if [ -n "${PD_EP_MAMBA_LOG:-}" ]; then printf '%s\n' "$prefix" >> "$PD_EP_MAMBA_LOG"; fi
mkdir -p "$prefix/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "%s"\n' "$prefix" > "$prefix/bin/bash"
chmod 755 "$prefix/bin/bash"
EOF
chmod 755 "$pd_test/mamba/bin/micromamba"
tar -cjf "$pd_test/micromamba-2.10.0.tar.bz2" -C "$pd_test/mamba" bin
pd_mamba_sha="$(pd_hash "$pd_test/micromamba-2.10.0.tar.bz2")"
cp "$pd_test/micromamba-2.10.0.tar.bz2" "$PD_PACKAGE_DIR/$pd_mamba_sha-micromamba-2.10.0.tar.bz2"
mkdir -p "$pd_test/metadata/packages"
PD_ARTIFACT_MANIFEST="$pd_test/metadata/packages/artifacts.tsv"
printf '# id\tplatform\tversion\tsha256\turl\tarchive\texecutable\trepository\n' > "$PD_ARTIFACT_MANIFEST"
printf 'micromamba\tall\t2.10.0\t%s\thttps://example.invalid/micromamba-2.10.0.tar.bz2\ttar.bz2\tbin/micromamba\ttest\n' "$pd_mamba_sha" >> "$PD_ARTIFACT_MANIFEST"
pd_locked_artifact micromamba linux-x64
[ "$PD_ARTIFACT_SHA256" = "$pd_mamba_sha" ]
pd_expect_failure pd_locked_artifact copilot linux-x64
printf 'micromamba\tall\t2.10.0\t%s\thttps://example.invalid/micromamba-2.10.0.tar.bz2\ttar.bz2\tbin/micromamba\ttest\n' "$pd_mamba_sha" >> "$PD_ARTIFACT_MANIFEST"
pd_expect_failure pd_locked_artifact micromamba linux-x64
sed '$d' "$PD_ARTIFACT_MANIFEST" > "$pd_test/manifest"
mv "$pd_test/manifest" "$PD_ARTIFACT_MANIFEST"
printf 'vscode\tall\t1.0\t%s\thttps://example.invalid/vscode.tar.gz\ttar.gz\tbin/code\ttest\nfont\tall\t1.0\t%s\thttps://example.invalid/font.tar.xz\ttar.xz\t-\ttest\n' "$pd_sha" "$pd_sha" >> "$PD_ARTIFACT_MANIFEST"
PD_PACKAGE_DIR="$pd_test/download-only"
PD_SELECTED_TOOLS=vscode,wezterm
PD_DOWNLOAD_ONLY=1
PD_OFFLINE=0
fetch() { printf '%s\n' "$1" >> "$pd_test/download-urls"; cp "$pd_test/package" "$2"; }
install_portable_unix_tools
grep -q '/font.tar.xz$' "$pd_test/download-urls"
[ -f "$PD_PACKAGE_DIR/$pd_sha-font.tar.xz" ]
[ ! -e "$PD_INSTALL" ]
PD_PACKAGE_DIR="$pd_test/bundle"
PD_SELECTED_TOOLS=bash
PD_DOWNLOAD_ONLY=0
PD_OFFLINE=1
fetch() { die "Unexpected network access"; }
printf 'micromamba\tlinux-x64\t2.10.0\t%s\thttps://example.invalid/exact-micromamba.tar.bz2\ttar.bz2\tbin/micromamba\ttest\n' "$pd_mamba_sha" >> "$PD_ARTIFACT_MANIFEST"
pd_locked_artifact micromamba linux-x64
[ "$PD_ARTIFACT_PLATFORM" = linux-x64 ]
sed '$d' "$PD_ARTIFACT_MANIFEST" > "$pd_test/manifest"
mv "$pd_test/manifest" "$PD_ARTIFACT_MANIFEST"
mkdir -p "$pd_test/vscode-archive/VSCode-linux-x64/bin"
printf '#!/bin/bash\nexit 0\n' > "$pd_test/vscode-archive/VSCode-linux-x64/bin/code"
chmod 755 "$pd_test/vscode-archive/VSCode-linux-x64/bin/code"
tar -czf "$pd_test/vscode-fixture.tar.gz" -C "$pd_test/vscode-archive" VSCode-linux-x64
pd_vscode_sha="$(pd_hash "$pd_test/vscode-fixture.tar.gz")"
cp "$pd_test/vscode-fixture.tar.gz" "$PD_PACKAGE_DIR/$pd_vscode_sha-vscode-fixture.tar.gz"
printf 'vscode\tlinux-x64\t2.0\t%s\thttps://example.invalid/vscode-fixture.tar.gz\ttar.gz\tbin/code\ttest\n' "$pd_vscode_sha" >> "$PD_ARTIFACT_MANIFEST"
PD_SELECTED_TOOLS=vscode
PD_OS=linux
install_portable_unix_tools
[ "$PD_CODE" = "$PD_INSTALL/vscode/bin/code" ]
[ -x "$PD_CODE" ] && [ -d "$PD_INSTALL/vscode/data" ]
if [ -L "$PD_INSTALL/vscode/data" ]; then
  [ "$(cd -P "$PD_INSTALL/vscode/data" && pwd)" = "$PD_ROOT/config/vscode" ]
fi
printf 'codex\tall\t2.0\t%s\thttps://example.invalid/vscode-fixture.tar.gz\ttar.gz\tbin/code\ttest\n' "$pd_vscode_sha" >> "$PD_ARTIFACT_MANIFEST"
mkdir -p "$PD_INSTALL/codex/packages"
printf 'retained package state\n' > "$PD_INSTALL/codex/packages/keep"
install_portable_codex_unix
[ "$(cat "$PD_INSTALL/codex/packages/keep")" = 'retained package state' ]
[ -x "$PD_INSTALL/codex/bin/codex" ]
PD_SELECTED_TOOLS=bash
printf '# feature\tname\tversion\tsha256\turl\nbash\texample\t1.0\t%s\thttps://conda.anaconda.org/conda-forge/linux-64/example-1.0-0.conda\n' "$pd_sha" > "$pd_test/metadata/packages/unix-linux-x64.tsv"
PD_DIR="$pd_test/metadata"
uname() { case "${1:-}" in -m) printf 'x86_64\n' ;; -r) printf '4.18.0\n' ;; *) printf 'Linux\n' ;; esac; }
getconf() { printf 'glibc 2.28\n'; }
export -f uname getconf
pd_try_unsupported_rustifiedgit() {
  uname() { printf 'aarch64\n'; }
  install_portable_rustifiedgit_unix
}
pd_expect_failure pd_try_unsupported_rustifiedgit
grep -q 'has no Linux arm64 release' "$pd_test/failure.log"
install_unix_tools
[ "$HOME" = "$pd_original_home" ]
[ "$("$PD_TOOL_BIN/bash")" = "$PD_INSTALL/conda/bash" ]
pd_try_unmanaged() {
  local PD_ROOT="$pd_test/unmanaged" PD_INSTALL="$pd_test/unmanaged/install" PD_TOOL_BIN="$pd_test/unmanaged/install/conda/bin"
  mkdir -p "$PD_INSTALL/conda/bash"
  printf 'user payload\n' > "$PD_INSTALL/conda/bash/keep"
  pd_conda_link_feature bash "$pd_test/metadata/packages/unix-linux-x64.tsv"
}
pd_expect_failure pd_try_unmanaged
[ "$(cat "$pd_test/unmanaged/install/conda/bash/keep")" = 'user payload' ]
pd_conda_prepare_explicit "$pd_test/metadata/packages/unix-linux-x64.tsv" bash "$pd_test/explicit"
grep -q '%20' <(pd_conda_file_url "$PD_ROOT/a space/file.conda")
printf 'keep configuration\n' > "$PD_ROOT/config-marker"
mv "$PD_ROOT" "$pd_test/moved root"
PD_ROOT="$pd_test/moved root"
PD_INSTALL="$PD_ROOT/install"
PD_TOOL_BIN="$PD_INSTALL/conda/bin"
/bin/bash --noprofile --norc "$PD_ROOT/lib/relocate.sh" "$PD_ROOT"
[ "$("$PD_INSTALL/conda/bash/bin/bash")" = "$PD_INSTALL/conda/bash" ]
if [ -L "$PD_TOOL_BIN/bash" ]; then
  [ "$("$PD_TOOL_BIN/bash")" = "$PD_INSTALL/conda/bash" ]
fi
[ "$(cat "$PD_ROOT/config-marker")" = 'keep configuration' ]
[ "$(cat "$PD_ROOT/state/conda/bash.prefix")" = "$PD_INSTALL/conda/bash" ]
/bin/bash --noprofile --norc "$PD_ROOT/lib/relocate.sh" "$PD_ROOT"
pd_other="$PD_ROOT/cache/packages/$pd_sha-example-1.0-0.conda"
printf 'bad\n' > "$pd_other"
mv "$PD_ROOT" "$pd_test/moved-again"
PD_ROOT="$pd_test/moved-again"
pd_expect_failure /bin/bash --noprofile --norc "$PD_ROOT/lib/relocate.sh" "$PD_ROOT"
[ -f "$PD_ROOT/config-marker" ]

pd_test_install_entrypoint() (
  local pd_source="$pd_test/entrypoint-source" pd_root="$pd_test/entrypoint root"
  local pd_moved="$pd_test/entrypoint moved" pd_download="$pd_test/entrypoint-download"
  local pd_home="$pd_test/entrypoint-home" pd_bundle="$pd_test/entrypoint-bundle"
  local pd_output_bundle="$pd_test/entrypoint-output-bundle" pd_file pd_directory pd_logs
  local pd_host_bash="$BASH"
  mkdir -p "$pd_source/packages" "$pd_root" "$pd_home" "$pd_bundle"
  for pd_file in install.sh install.ps1 wezterm.lua; do cp "$pd_repository/$pd_file" "$pd_source/$pd_file"; done
  for pd_directory in lib templates patches yazi; do cp -R "$pd_repository/$pd_directory" "$pd_source/$pd_directory"; done
  printf '# id\tplatform\tversion\tsha256\turl\tarchive\texecutable\trepository\nmicromamba\tall\t2.10.0\t%s\thttps://example.invalid/micromamba-2.10.0.tar.bz2\ttar.bz2\tbin/micromamba\ttest\n' \
    "$pd_mamba_sha" > "$pd_source/packages/artifacts.tsv"
  printf '# feature\tname\tversion\tsha256\turl\nbash\texample\t1.0\t%s\thttps://conda.anaconda.org/conda-forge/linux-64/example-1.0-0.conda\ngit\tgit\t2.0\t%s\thttps://conda.anaconda.org/conda-forge/linux-64/unselected-git-2.0-0.conda\n' \
    "$pd_sha" "$(printf '%064d' 0)" > "$pd_source/packages/unix-linux-x64.tsv"
  cp "$pd_test/package" "$pd_bundle/$pd_sha-example-1.0-0.conda"
  cp "$pd_test/micromamba-2.10.0.tar.bz2" "$pd_bundle/$pd_mamba_sha-micromamba-2.10.0.tar.bz2"
  printf 'existing user profile\n' > "$pd_home/.bashrc"
  cp "$pd_home/.bashrc" "$pd_test/entrypoint-profile"
  export PD_EP_MAMBA_LOG="$pd_test/entrypoint-mamba.log"
  export PD_EP_FETCH_LOG="$pd_test/entrypoint-fetch.log"
  export PD_EP_BUNDLE="$pd_bundle" PD_EP_MICROSHA="$pd_mamba_sha" PD_EP_PKGSHA="$pd_sha"
  export PD_EP_ALLOW_FETCH=0
  unset PD_ARTIFACT_MANIFEST PD_PACKAGE_CACHE
  uname() { case "${1:-}" in -m) printf 'x86_64\n' ;; -r) printf '4.18.0\n' ;; *) printf 'Linux\n' ;; esac; }
  getconf() { printf 'glibc 2.28\n'; }
  # Exercise the real entrypoint without using a host/global temporary directory.
  mktemp() {
    [ "$#" -eq 2 ] && [ "$1" = -d ] || return 97
    case "$2" in "$pd_test/"*/tmp/install.XXXXXX) ;; *) return 97 ;; esac
    local pd_directory="${2%XXXXXX}fixture-$$"
    mkdir "$pd_directory" && printf '%s\n' "$pd_directory"
  }
  curl() {
    [ "$PD_EP_ALLOW_FETCH" = 1 ] || { printf 'Unexpected entrypoint network request\n' >&2; return 98; }
    local pd_url="" pd_destination="" pd_archive
    while [ "$#" -gt 0 ]; do
      case "$1" in https://*) pd_url="$1" ;; --output) pd_destination="$2"; shift ;; esac
      shift
    done
    case "$pd_url" in
      https://example.invalid/micromamba-2.10.0.tar.bz2) pd_archive="$PD_EP_MICROSHA-micromamba-2.10.0.tar.bz2" ;;
      https://conda.anaconda.org/conda-forge/linux-64/example-1.0-0.conda) pd_archive="$PD_EP_PKGSHA-example-1.0-0.conda" ;;
      *) printf 'Unexpected entrypoint artifact: %s\n' "$pd_url" >&2; return 98 ;;
    esac
    printf '%s\n' "$pd_url" >> "$PD_EP_FETCH_LOG"
    cp "$PD_EP_BUNDLE/$pd_archive" "$pd_destination"
  }
  export -f uname getconf mktemp curl
  export pd_test
  pd_ep_run() {
    local pd_cwd="$1" pd_installer="$2" pd_log="$3"
    shift 3
    if ! (cd "$pd_cwd"; HOME="$pd_home" PD_USER_HOME="$pd_home" XDG_CONFIG_HOME="$pd_home/config" \
        XDG_CACHE_HOME="$pd_home/cache" XDG_DATA_HOME="$pd_home/data" PD_SKIP_DESKTOP_PATH=1 \
        BASH_ENV= ENV= "$pd_host_bash" --noprofile --norc "$pd_installer" "$@") > "$pd_log" 2>&1; then
      cat "$pd_log" >&2
      die "Actual install.sh fixture failed: $pd_installer $*"
    fi
  }
  pd_ep_run "$pd_root" "$pd_source/install.sh" "$pd_test/entrypoint-first.log" \
    --tools bash --offline --package-dir "$pd_bundle" --no-activate
  [ "$(cat "$pd_root/state/conda/bash.prefix")" = "$pd_root/install/conda/bash" ]
  [ "$("$pd_root/bin/bash" --version)" = "$pd_root/install/conda/bash" ]
  [ -f "$pd_root/templates/bash/bashrc" ] && [ -f "$pd_root/config/bash/bashrc" ]
  for pd_file in install.sh lib/unix.sh lib/environment.sh packages/artifacts.tsv patches/yazi-portable-dirs.patch yazi/yazi.toml; do
    [ -f "$pd_root/$pd_file" ] || die "Copied root lacks $pd_file."
  done
  [ "$(wc -l < "$PD_EP_MAMBA_LOG")" -eq 1 ] && [ ! -e "$PD_EP_FETCH_LOG" ]
  [ "$(find "$pd_root/state/conda" -name '*.prefix' | wc -l)" -eq 1 ]
  for pd_directory in git tmux fzf btop yazi codex copilot vscode wezterm; do
    [ ! -e "$pd_root/install/conda/$pd_directory" ] && [ ! -e "$pd_root/install/$pd_directory" ]
  done
  printf 'user-maintained Bash template\n' > "$pd_root/templates/bash/bashrc"
  printf 'user-maintained Bash configuration\n' > "$pd_root/config/bash/bashrc"
  printf 'new missing-only seed\n' > "$pd_root/templates/bash/new-default"
  pd_ep_run "$pd_root" "$pd_source/install.sh" "$pd_test/entrypoint-rerun.log" \
    --tools bash --offline --package-dir "$pd_bundle" --no-activate
  [ "$(cat "$pd_root/templates/bash/bashrc")" = 'user-maintained Bash template' ]
  [ "$(cat "$pd_root/config/bash/bashrc")" = 'user-maintained Bash configuration' ]
  [ "$(cat "$pd_root/config/bash/new-default")" = 'new missing-only seed' ]
  [ "$(wc -l < "$PD_EP_MAMBA_LOG")" -eq 1 ]
  cmp "$pd_home/.bashrc" "$pd_test/entrypoint-profile"

  mv "$pd_root" "$pd_moved"
  mv "$pd_source" "$pd_test/entrypoint-source-hidden"
  pd_ep_run "$pd_moved" "$pd_moved/install.sh" "$pd_test/entrypoint-moved.log" \
    --tools bash --offline --no-activate
  [ "$(cat "$pd_moved/state/conda/bash.prefix")" = "$pd_moved/install/conda/bash" ]
  [ "$("$pd_moved/install/conda/bash/bin/bash")" = "$pd_moved/install/conda/bash" ]
  [ "$(cat "$pd_moved/templates/bash/bashrc")" = 'user-maintained Bash template' ]
  [ "$(cat "$pd_moved/config/bash/bashrc")" = 'user-maintained Bash configuration' ]
  [ "$(wc -l < "$PD_EP_MAMBA_LOG")" -eq 2 ] && [ ! -e "$PD_EP_FETCH_LOG" ]
  ! grep -Fq "$pd_root" "$pd_moved/bin/bash"
  if [ -L "$pd_moved/install/conda/bin/bash" ]; then
    [ "$("$pd_moved/bin/bash" --version)" = "$pd_moved/install/conda/bash" ]
  fi
  pd_logs="$(wc -l < "$PD_EP_MAMBA_LOG")"
  mkdir "$pd_download"
  export PD_EP_ALLOW_FETCH=1
  pd_ep_run "$pd_download" "$pd_moved/install.sh" "$pd_test/entrypoint-download.log" \
    --tools bash --download-only --package-dir "$pd_output_bundle" --activate
  [ -f "$pd_output_bundle/$pd_sha-example-1.0-0.conda" ]
  [ -f "$pd_output_bundle/$pd_mamba_sha-micromamba-2.10.0.tar.bz2" ]
  [ "$(wc -l < "$PD_EP_FETCH_LOG")" -eq 2 ]
  [ "$(wc -l < "$PD_EP_MAMBA_LOG")" -eq "$pd_logs" ]
  [ -z "$(find "$pd_download/install" "$pd_download/bin" "$pd_download/config" -mindepth 1 ! -type d -print)" ]
  for pd_file in activate.sh activate.ps1 templates lib packages; do [ ! -e "$pd_download/$pd_file" ]; done
  cmp "$pd_home/.bashrc" "$pd_test/entrypoint-profile"
  [ ! -e "$pd_home/.profile" ] && [ ! -e "$pd_home/.bash_profile" ] && [ ! -e "$pd_home/install" ]
  printf 'Actual install.sh selected-only/offline/rerun/copied-root/download-only integration passed.\n'
)
pd_test_install_entrypoint
printf 'Unix cache, lock resolution, offline linking and prefix relocation checks passed.\n'
