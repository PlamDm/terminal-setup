# Verified, portable downloads. All destinations are inside the selected root.
pd_verify_sha256() {
  local pd_file="$1" pd_expected="$2" pd_actual
  [[ "$pd_expected" =~ ^[a-fA-F0-9]{64}$ ]] || die "Missing published SHA-256 for $pd_file."
  if have sha256sum; then pd_actual="$(sha256sum "$pd_file")";
  else pd_actual="$(shasum -a 256 "$pd_file")"; fi
  [ "${pd_actual%% *}" = "$pd_expected" ] || die "SHA-256 verification failed for $pd_file."
}

pd_github_asset() {
  local pd_repo="$1" pd_asset="$2" pd_metadata="$PD_TEMP/release.json" pd_url pd_hash
  fetch "https://api.github.com/repos/$pd_repo/releases/latest" "$pd_metadata"
  pd_url="$("$PD_TOOL_BIN/jq" -er --arg name "$pd_asset" '.assets[] | select(.name == $name) | .browser_download_url' "$pd_metadata")"
  pd_hash="$("$PD_TOOL_BIN/jq" -er --arg name "$pd_asset" '.assets[] | select(.name == $name) | .digest | ltrimstr("sha256:")' "$pd_metadata")"
  fetch "$pd_url" "$PD_TEMP/$pd_asset"
  pd_verify_sha256 "$PD_TEMP/$pd_asset" "$pd_hash"
}

install_portable_unix_tools() {
  local pd_arch pd_platform pd_metadata pd_commit pd_archive pd_destination pd_code
  if pd_selected copilot || pd_selected vscode; then
    case "$(uname -m)" in arm64|aarch64) pd_arch=arm64 ;; x86_64) pd_arch=x64 ;; *) die "Portable tools require x64 or arm64." ;; esac
    case "$PD_OS" in macos) pd_platform=darwin ;; linux) pd_platform=linux ;; esac
  fi
  if pd_selected copilot; then
    log "Installing standalone GitHub Copilot CLI (no Node.js dependency)."
    pd_github_asset github/copilot-cli "copilot-$pd_platform-$pd_arch.tar.gz"
    mkdir -p "$PD_INSTALL/copilot/bin"
    tar -xzf "$PD_TEMP/copilot-$pd_platform-$pd_arch.tar.gz" -C "$PD_INSTALL/copilot/bin"
    PD_COPILOT="$PD_INSTALL/copilot/bin/copilot"
    [ -x "$PD_COPILOT" ] || die "Copilot archive did not contain copilot."
  fi

  if pd_selected vscode; then
    log "Installing portable VS Code with separate user data and extensions."
    pd_metadata="$PD_TEMP/vscode.json"
    local pd_vscode_platform="$pd_platform-$pd_arch"
    if [ "$PD_OS" = macos ] && [ "$pd_arch" = x64 ]; then pd_vscode_platform=darwin; fi
    fetch "https://update.code.visualstudio.com/api/update/$pd_vscode_platform/stable/latest" "$pd_metadata"
    pd_commit="$("$PD_TOOL_BIN/jq" -er '.version | select(test("^[a-f0-9]{40}$"))' "$pd_metadata")"
    pd_destination="$PD_INSTALL/vscode/$pd_commit"
    if [ "$PD_OS" = macos ]; then
      pd_code="$pd_destination/Visual Studio Code.app/Contents/Resources/app/bin/code"
    else
      pd_code="$pd_destination/bin/code"
    fi
    if [ ! -x "$pd_code" ]; then
      pd_archive="$PD_TEMP/vscode.archive"
      fetch "$("$PD_TOOL_BIN/jq" -er .url "$pd_metadata")" "$pd_archive"
      pd_verify_sha256 "$pd_archive" "$("$PD_TOOL_BIN/jq" -er .sha256hash "$pd_metadata")"
      mkdir -p "$pd_destination"
      if [ "$PD_OS" = macos ]; then
        if have ditto; then ditto -xk "$pd_archive" "$pd_destination";
        else unzip -q "$pd_archive" -d "$pd_destination"; fi
      else
        tar -xzf "$pd_archive" --strip-components=1 -C "$pd_destination"
      fi
    fi
    mkdir -p "$PD_ROOT/config/vscode/tmp" "$PD_ROOT/config/vscode/user-data" "$PD_ROOT/config/vscode/extensions"
    if [ "$PD_OS" = macos ]; then
      [ -e "$pd_destination/code-portable-data" ] || ln -s "$PD_ROOT/config/vscode" "$pd_destination/code-portable-data"
    else
      [ -e "$pd_destination/data" ] || ln -s "$PD_ROOT/config/vscode" "$pd_destination/data"
    fi
    PD_CODE="$pd_code"
  fi
  if pd_selected wezterm; then install_portable_font; fi
}

install_portable_font() {
  # WezTerm loads this directory directly; no OS font registration is needed.
  if [ ! -f "$PD_INSTALL/fonts/.installed" ]; then
    pd_github_asset ryanoasis/nerd-fonts JetBrainsMono.tar.xz
    mkdir -p "$PD_INSTALL/fonts"
    tar -xJf "$PD_TEMP/JetBrainsMono.tar.xz" -C "$PD_INSTALL/fonts"
    touch "$PD_INSTALL/fonts/.installed"
  fi
}
