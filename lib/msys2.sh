# Shared package requirements for managed and read-only MSYS2 installations.
PD_MSYS2_PACKAGES=(
  bash tmux git file
  mingw-w64-ucrt-x86_64-rust mingw-w64-ucrt-x86_64-fzf
  mingw-w64-ucrt-x86_64-ffmpeg mingw-w64-ucrt-x86_64-7zip mingw-w64-ucrt-x86_64-jq
  mingw-w64-ucrt-x86_64-poppler mingw-w64-ucrt-x86_64-fd mingw-w64-ucrt-x86_64-ripgrep
  mingw-w64-ucrt-x86_64-zoxide mingw-w64-ucrt-x86_64-resvg mingw-w64-ucrt-x86_64-imagemagick
)

pd_check_msys2_packages() {
  local pd_installed pd_package pd_missing=()
  pd_installed="$("$PD_MSYS2_ROOT/usr/bin/pacman.exe" -Qq)" || {
    printf '[playground] ERROR: Could not read the existing MSYS2 package database; no packages were changed.\n' >&2
    return 1
  }
  for pd_package in "${PD_MSYS2_PACKAGES[@]}"; do
    if [[ $'\n'"$pd_installed"$'\n' != *$'\n'"$pd_package"$'\n'* ]]; then
      pd_missing+=("$pd_package")
    fi
  done
  if [ "${#pd_missing[@]}" -ne 0 ]; then
    printf '[playground] ERROR: Existing MSYS2 is read-only. Missing required packages: %s\n' "${pd_missing[*]}" >&2
    printf '[playground] Install these prerequisites yourself, or choose a separate managed MSYS2 installation.\n' >&2
    return 1
  fi
}

pd_install_msys2_packages() {
  if [ "${PD_MSYS2_READ_ONLY:-0}" = 1 ]; then
    pd_check_msys2_packages
  else
    "$PD_MSYS2_ROOT/usr/bin/pacman.exe" -S --needed --noconfirm "${PD_MSYS2_PACKAGES[@]}"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  PD_MSYS2_ROOT="${1:?MSYS2 root is required}"
  pd_check_msys2_packages
fi
