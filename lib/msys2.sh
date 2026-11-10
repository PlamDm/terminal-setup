# Shared package requirements for new and existing MSYS2 installations.
PD_MSYS2_PACKAGES=(
  bash tmux git file
  mingw-w64-ucrt-x86_64-rust mingw-w64-ucrt-x86_64-fzf
  mingw-w64-ucrt-x86_64-ffmpeg mingw-w64-ucrt-x86_64-7zip mingw-w64-ucrt-x86_64-jq
  mingw-w64-ucrt-x86_64-poppler mingw-w64-ucrt-x86_64-fd mingw-w64-ucrt-x86_64-ripgrep
  mingw-w64-ucrt-x86_64-zoxide mingw-w64-ucrt-x86_64-resvg mingw-w64-ucrt-x86_64-imagemagick
)

pd_install_msys2_packages() (
  if [ "${PD_MSYS2_READ_ONLY:-0}" = 1 ]; then
    return 0
  fi
  local pd_pacman="${PD_MSYS2_ROOT%/}/usr/bin/pacman.exe"
  if [ "${PD_MSYS2_PRESERVE_INSTALLED:-0}" != 1 ]; then
    "$pd_pacman" -S --needed --noconfirm "${PD_MSYS2_PACKAGES[@]}"
    return $?
  fi
  local pd_installed pd_package pd_missing=() pd_hookdir
  pd_installed="$("$pd_pacman" -Qq)" || {
    printf '[playground] ERROR: Could not read the existing MSYS2 package database; no packages were changed.\n' >&2
    return 1
  }
  for pd_package in "${PD_MSYS2_PACKAGES[@]}"; do
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  PD_MSYS2_ROOT="${1:?MSYS2 root is required}"
  pd_install_msys2_packages
fi
