# Shared package requirements for new and existing MSYS2 installations.
PD_MSYS2_PACKAGES=(
  bash tmux git file
  mingw-w64-ucrt-x86_64-rust mingw-w64-ucrt-x86_64-fzf
  mingw-w64-ucrt-x86_64-ffmpeg mingw-w64-ucrt-x86_64-7zip mingw-w64-ucrt-x86_64-jq
  mingw-w64-ucrt-x86_64-poppler mingw-w64-ucrt-x86_64-fd mingw-w64-ucrt-x86_64-ripgrep
  mingw-w64-ucrt-x86_64-zoxide mingw-w64-ucrt-x86_64-resvg mingw-w64-ucrt-x86_64-imagemagick
)

pd_msys2_feature_selected() {
  case ",${PD_SELECTED_TOOLS:-}," in *,"$1",*) return 0 ;; esac
  return 1
}

pd_install_msys2_packages() (
  [ "${PD_MSYS2_PACKAGES_READY:-0}" != 1 ] || return 0
  if [ "${PD_MSYS2_READ_ONLY:-0}" = 1 ]; then
    return 0
  fi
  local pd_packages=("${PD_MSYS2_PACKAGES[@]}")
  if [ "${PD_SELECTION_MODE:-all}" = explicit ]; then
    pd_packages=(bash)
    if pd_msys2_feature_selected tmux; then pd_packages+=(tmux); fi
    if pd_msys2_feature_selected git || pd_msys2_feature_selected yazi ||
        pd_msys2_feature_selected rustifiedgit; then
      pd_packages+=(git)
    fi
    if pd_msys2_feature_selected yazi; then
      pd_packages+=(
        file mingw-w64-ucrt-x86_64-rust
        mingw-w64-ucrt-x86_64-ffmpeg mingw-w64-ucrt-x86_64-7zip
        mingw-w64-ucrt-x86_64-jq mingw-w64-ucrt-x86_64-poppler
        mingw-w64-ucrt-x86_64-fd mingw-w64-ucrt-x86_64-ripgrep
        mingw-w64-ucrt-x86_64-zoxide mingw-w64-ucrt-x86_64-resvg
        mingw-w64-ucrt-x86_64-imagemagick
      )
    fi
    if pd_msys2_feature_selected fzf; then pd_packages+=(mingw-w64-ucrt-x86_64-fzf); fi
    if pd_msys2_feature_selected rustifiedgit; then
      pd_packages+=(mingw-w64-ucrt-x86_64-rust)
    fi
    local pd_unique_packages=() pd_seen pd_existing
    for pd_package in "${pd_packages[@]}"; do
      pd_seen=0
      for pd_existing in "${pd_unique_packages[@]}"; do
        if [ "$pd_package" = "$pd_existing" ]; then pd_seen=1; break; fi
      done
      [ "$pd_seen" -eq 1 ] || pd_unique_packages+=("$pd_package")
    done
    pd_packages=("${pd_unique_packages[@]}")
  fi
  local pd_pacman="${PD_MSYS2_ROOT%/}/usr/bin/pacman.exe"
  if [ "${PD_MSYS2_PRESERVE_INSTALLED:-0}" != 1 ]; then
    "$pd_pacman" -S --needed --noconfirm "${pd_packages[@]}"
    return $?
  fi
  local pd_installed pd_package pd_missing=() pd_hookdir
  pd_installed="$("$pd_pacman" -Qq)" || {
    printf '[playground] ERROR: Could not read the existing MSYS2 package database; no packages were changed.\n' >&2
    return 1
  }
  for pd_package in "${pd_packages[@]}"; do
    if [[ $'\n'"$pd_installed"$'\n' != *$'\n'"$pd_package"$'\n'* ]]; then
      pd_missing+=("$pd_package")
    fi
  done
  [ "${#pd_missing[@]}" -ne 0 ] || return 0
  printf '[playground] Installing missing MSYS2 packages: %s\n' "${pd_missing[*]}"
  pd_hookdir="$(mktemp -d "${TMPDIR:?Playground temporary directory is required}/msys2-hooks.XXXXXX")" || return 1
  trap 'rm -rf -- "$pd_hookdir"' EXIT
  cat > "$pd_hookdir/00-terminal-setup-preserve-installed.hook" <<'EOF'
[Trigger]
Operation = Upgrade
Operation = Remove
Type = Package
Target = *

[Action]
Description = Refusing changes to already installed packages
When = PreTransaction
Exec = /usr/bin/false
AbortOnFail
EOF
  if ! "$pd_pacman" -S --needed --noconfirm \
      --hookdir "${PD_MSYS2_ROOT%/}/etc/pacman.d/hooks" --hookdir "$pd_hookdir" "${pd_missing[@]}"; then
    printf '[playground] ERROR: Missing packages could not be installed without changing existing packages. No upgrades, reinstalls, downgrades or removals are permitted; use a separate MSYS2 installation if necessary.\n' >&2
    return 1
  fi
)

pd_install_msys2_archives() (
  local pd_hookdir pd_pacman="${PD_MSYS2_ROOT%/}/usr/bin/pacman.exe"
  [ "$#" -gt 0 ] || return 0
  pd_hookdir="$(mktemp -d "${TMPDIR:?}/msys2-hooks.XXXXXX")" || return 1
  trap 'rm -rf -- "$pd_hookdir"' EXIT
  cp "$PD_DIR/lib/preserve-installed.hook" "$pd_hookdir/00-terminal-setup-preserve-installed.hook" || return 1
  "$pd_pacman" -U --needed --noconfirm \
    --hookdir "${PD_MSYS2_ROOT%/}/etc/pacman.d/hooks" --hookdir "$pd_hookdir" "$@"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  PD_MSYS2_ROOT="${1:?MSYS2 root is required}"
  if [ "${2:-}" = --locked ]; then
    PD_DIR="${3:?Manager root is required}"
    cd -- "${4:?Package transaction directory is required}"
    mapfile -t pd_archives < files.txt
    pd_install_msys2_archives "${pd_archives[@]}"
  else
    pd_install_msys2_packages
  fi
fi
