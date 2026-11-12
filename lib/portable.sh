# Standalone Unix tools are resolved only from reviewed packages/artifacts.tsv.
. "$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/packages.sh"

pd_install_locked_tool() {
  local pd_id="$1" pd_destination="$2" pd_file pd_target pd_stage pd_container pd_candidate pd_count pd_payload
  PD_LOCKED_EXECUTABLE=""
  pd_locked_artifact "$pd_id"
  pd_file="$(pd_fetch_locked "$PD_ARTIFACT_SHA256" "$PD_ARTIFACT_URL")"
  [ "${PD_DOWNLOAD_ONLY:-0}" != 1 ] || return 0
  pd_target="$pd_destination/$PD_ARTIFACT_EXECUTABLE"
  if [ -x "$pd_target" ] && [ -f "$pd_destination/.artifact-sha256" ] &&
      [ "$(cat "$pd_destination/.artifact-sha256")" = "$PD_ARTIFACT_SHA256" ]; then
    PD_LOCKED_EXECUTABLE="$pd_target"
    return
  fi
  pd_stage="$PD_ROOT/tmp/artifact-$pd_id-$$"
  pd_container="$pd_stage"
  pd_require_managed_path "$pd_stage"
  [ ! -e "$pd_stage" ] || die "Artifact staging directory already exists: $pd_stage."
  mkdir -p "$pd_stage"
  case "$PD_ARTIFACT_ARCHIVE" in
    appimage)
      cp "$pd_file" "$pd_stage/appimage"
      chmod 755 "$pd_stage/appimage"
      (cd "$pd_stage" && ./appimage --appimage-extract >/dev/null) ||
        die "Cannot extract the locked $pd_id AppImage (no FUSE is required)."
      rm -f "$pd_stage/appimage"
      ;;
    exe) mkdir -p "$(dirname -- "$pd_stage/$PD_ARTIFACT_EXECUTABLE")"
      cp "$pd_file" "$pd_stage/$PD_ARTIFACT_EXECUTABLE" ;;
    source|sfx) die "No approved compiler-free Unix artifact for $pd_id." ;;
    *) pd_extract_locked "$pd_file" "$PD_ARTIFACT_ARCHIVE" "$pd_stage" ;;
  esac
  if [ ! -f "$pd_stage/$PD_ARTIFACT_EXECUTABLE" ]; then
    # Some releases wrap their payload in one directory (VS Code tarballs and
    # extracted AppImages). Normalize that envelope, not arbitrary components.
    pd_count=0; pd_payload=""
    for pd_candidate in "$pd_stage/"* "$pd_stage/".[!.]* "$pd_stage/"..?*; do
      [ -e "$pd_candidate" ] || [ -L "$pd_candidate" ] || continue
      pd_count=$((pd_count + 1)); pd_payload="$pd_candidate"
    done
    if [ "$pd_count" -eq 1 ] && [ -d "$pd_payload" ] && [ ! -L "$pd_payload" ] &&
        [ -f "$pd_payload/$PD_ARTIFACT_EXECUTABLE" ]; then pd_stage="$pd_payload"; fi
  fi
  [ -f "$pd_stage/$PD_ARTIFACT_EXECUTABLE" ] ||
    die "Locked $pd_id archive lacks $PD_ARTIFACT_EXECUTABLE."
  chmod 755 "$pd_stage/$PD_ARTIFACT_EXECUTABLE"
  printf '%s\n' "$PD_ARTIFACT_SHA256" > "$pd_stage/.artifact-sha256"
  # Only the named managed payload is replaced, never configuration or state.
  case "$pd_destination" in "$PD_ROOT/install/"*) ;; *) die "Unsafe artifact installation path." ;; esac
  pd_require_managed_path "$pd_destination"
  [ ! -L "$PD_ROOT/install" ] && [ ! -L "$pd_destination" ] ||
    die "Refusing to replace a symlinked installation."
  if [ "$pd_id" = codex ] && [ -d "$pd_destination/packages" ]; then
    [ ! -e "$pd_stage/packages" ] || die "Codex archive conflicts with retained package state."
    mv "$pd_destination/packages" "$pd_stage/packages"
  fi
  rm -rf -- "$pd_destination"
  mkdir -p "$(dirname -- "$pd_destination")"
  mv "$pd_stage" "$pd_destination"
  if [ "$pd_stage" != "$pd_container" ]; then rmdir "$pd_container"; fi
  PD_LOCKED_EXECUTABLE="$pd_target"
}

install_portable_unix_tools() {
  if pd_selected copilot; then
    pd_install_locked_tool copilot "$PD_INSTALL/copilot"
    PD_COPILOT="${PD_LOCKED_EXECUTABLE:-}"
  fi
  if pd_selected vscode; then
    pd_install_locked_tool vscode "$PD_INSTALL/vscode"
    if [ "${PD_DOWNLOAD_ONLY:-0}" != 1 ]; then
      PD_CODE="$PD_LOCKED_EXECUTABLE"
      pd_require_managed_path "$PD_ROOT/config/vscode/tmp"
      pd_require_managed_path "$PD_ROOT/config/vscode/user-data"
      pd_require_managed_path "$PD_ROOT/config/vscode/extensions"
      mkdir -p "$PD_ROOT/config/vscode/tmp" "$PD_ROOT/config/vscode/user-data" "$PD_ROOT/config/vscode/extensions"
      # Relative links survive a move; user data never lives in the payload.
      local pd_link pd_relative pd_back=..
      if [ "$PD_OS" = macos ]; then
        pd_link="$(dirname -- "${PD_CODE%/Contents/Resources/app/bin/code}")/code-portable-data"
      else pd_link="${PD_CODE%/bin/code}/data"; fi
      pd_relative="${pd_link%/*}"; pd_relative="${pd_relative#"$PD_ROOT"/}"
      while [ "${pd_relative#*/}" != "$pd_relative" ]; do
        pd_back="$pd_back/.."; pd_relative="${pd_relative#*/}"
      done
      if [ ! -e "$pd_link" ] && [ ! -L "$pd_link" ]; then ln -s "$pd_back/config/vscode" "$pd_link"; fi
    fi
  fi
  if pd_selected wezterm; then install_portable_font; fi
}

install_portable_font() {
  local pd_file
  pd_locked_artifact font
  pd_file="$(pd_fetch_locked "$PD_ARTIFACT_SHA256" "$PD_ARTIFACT_URL")"
  [ "${PD_DOWNLOAD_ONLY:-0}" != 1 ] || return 0
  if [ -f "$PD_INSTALL/fonts/.artifact-sha256" ] &&
      [ "$(cat "$PD_INSTALL/fonts/.artifact-sha256")" = "$PD_ARTIFACT_SHA256" ]; then return; fi
  pd_require_managed_path "$PD_INSTALL/fonts/.artifact-sha256"
  mkdir -p "$PD_INSTALL/fonts"
  pd_extract_locked "$pd_file" "$PD_ARTIFACT_ARCHIVE" "$PD_INSTALL/fonts"
  printf '%s\n' "$PD_ARTIFACT_SHA256" > "$PD_INSTALL/fonts/.artifact-sha256"
}

install_portable_codex_unix() {
  pd_install_locked_tool codex "$PD_INSTALL/codex"
  [ "${PD_DOWNLOAD_ONLY:-0}" != 1 ] || return 0
  PD_CODEX="$PD_LOCKED_EXECUTABLE"
  mkdir -p "$PD_INSTALL/codex/bin"
  if [ "$PD_CODEX" != "$PD_INSTALL/codex/bin/codex" ]; then
    ln -sf "../${PD_CODEX#"$PD_INSTALL/codex/"}" "$PD_INSTALL/codex/bin/codex"
  fi
}

install_portable_rustifiedgit_unix() {
  [ "$(pd_unix_platform)" != linux-arm64 ] ||
    die "RustifiedGit v0.1.0 has no Linux arm64 release; no approved locked build recipe exists."
  pd_install_locked_tool rustifiedgit "$PD_INSTALL/rustifiedgit"
  [ "${PD_DOWNLOAD_ONLY:-0}" != 1 ] || return 0
  mkdir -p "$PD_INSTALL/rustifiedgit/bin"
  if [ "$PD_LOCKED_EXECUTABLE" != "$PD_INSTALL/rustifiedgit/bin/rustifiedgit" ]; then
    ln -sf "../${PD_LOCKED_EXECUTABLE#"$PD_INSTALL/rustifiedgit/"}" "$PD_INSTALL/rustifiedgit/bin/rustifiedgit"
  fi
}
