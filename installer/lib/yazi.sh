# Windows' stock Yazi uses Windows Known Folders for cache/state, ignoring XDG.
# Build the pinned release with two directory overrides instead of redirecting
# the user's AppData or creating junctions outside the selected root.
install_portable_yazi_windows() {
  local pd_yazi_source pd_yazi_version=8dd895c695a5950330c2623eb43debf323b60654-portable-v1 pd_yazi_command
  if [ -x "$PD_INSTALL/yazi/bin/yazi.exe" ] && [ -x "$PD_INSTALL/yazi/bin/ya.exe" ]; then
    log "Keeping installed Yazi."
    return
  fi
  if [ -e "$PD_INSTALL/yazi/bin/yazi.exe" ] || [ -e "$PD_INSTALL/yazi/bin/ya.exe" ]; then
    die "Yazi installation is incomplete; choose another root to reinstall without replacing existing executables."
  fi
  if [ "${PD_OS:-}" = windows ] && [ "${PD_MSYS2_READ_ONLY:-0}" = 1 ] &&
      ! pd_require_readonly_msys2_build_tools Yazi; then
    return 0
  fi
  pd_install_rust
  log "Building Yazi 26.9.1 with cache and state inside the selected folder."
  [ -n "${PD_YAZI_SOURCE:-}" ] ||
    die "Run install.ps1 to prepare the locked offline Yazi source."
  pd_yazi_source="$PD_YAZI_SOURCE"
  git -C "$pd_yazi_source" apply "$PD_DIR/patches/yazi-portable-dirs.patch"
  (
    cd "$pd_yazi_source"
    env -u RUSTUP_TOOLCHAIN -u RUSTC_WRAPPER -u RUSTC_WORKSPACE_WRAPPER \
      CARGO_HOME="$(pd_native_path "$PD_ROOT/cache/cargo")" \
      RUSTC="$(pd_native_path "$PD_RUSTC")" \
      "$PD_CARGO" build --profile release-windows --locked ${PD_YAZI_SOURCE:+--offline} \
      --target-dir "$(pd_native_path "$PD_ROOT/cache/yazi-target")"
  )
  local pd_yazi_staging="$PD_TEMP/yazi-bin"
  mkdir -p "$pd_yazi_staging" "$PD_INSTALL/yazi"
  for pd_yazi_command in yazi ya; do
    cp "$PD_ROOT/cache/yazi-target/release-windows/$pd_yazi_command.exe" "$pd_yazi_staging/$pd_yazi_command.exe"
    YAZI_CONFIG_HOME="$(pd_native_path "$PD_ROOT/config/yazi")" \
      YAZI_CACHE_HOME="$(pd_native_path "$PD_ROOT/cache/yazi")" \
      YAZI_STATE_HOME="$(pd_native_path "$PD_ROOT/state/yazi")" \
      "$pd_yazi_staging/$pd_yazi_command.exe" --version
  done
  if [ -d "$PD_INSTALL/yazi/bin" ]; then
    rmdir "$PD_INSTALL/yazi/bin" || die "Refusing to replace a non-empty Yazi installation."
  fi
  mv "$pd_yazi_staging" "$PD_INSTALL/yazi/bin"
  printf '%s\n' "$pd_yazi_version" > "$PD_ROOT/state/yazi.commit"
}
