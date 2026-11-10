# Windows' stock Yazi uses Windows Known Folders for cache/state, ignoring XDG.
# Build the pinned release with two directory overrides instead of redirecting
# the user's AppData or creating junctions outside the selected root.
install_portable_yazi_windows() {
  local pd_yazi_ref=8dd895c695a5950330c2623eb43debf323b60654
  local pd_yazi_source="$PD_TEMP/yazi-source" pd_yazi_version="$pd_yazi_ref-portable-v1" pd_yazi_command
  if [ -x "$PD_INSTALL/yazi/bin/yazi.exe" ] && [ -x "$PD_INSTALL/yazi/bin/ya.exe" ] && \
     [ -f "$PD_ROOT/state/yazi.commit" ] && [ "$(cat "$PD_ROOT/state/yazi.commit")" = "$pd_yazi_version" ]; then return; fi
  pd_install_rust
  log "Building Yazi 26.9.1 with cache and state inside the selected folder."
  git init -q "$pd_yazi_source"
  git -C "$pd_yazi_source" remote add origin https://github.com/sxyazi/yazi.git
  git -C "$pd_yazi_source" fetch --depth 1 origin "$pd_yazi_ref"
  git -C "$pd_yazi_source" checkout --detach -q FETCH_HEAD
  git -C "$pd_yazi_source" apply "$PD_DIR/patches/yazi-portable-dirs.patch"
  (
    cd "$pd_yazi_source"
    env -u RUSTUP_TOOLCHAIN -u RUSTC_WRAPPER -u RUSTC_WORKSPACE_WRAPPER \
      CARGO_HOME="$(pd_native_path "$PD_ROOT/cache/cargo")" \
      RUSTC="$(pd_native_path "$PD_RUSTC")" \
      "$PD_CARGO" build --profile release-windows --locked \
      --target-dir "$(pd_native_path "$PD_ROOT/cache/yazi-target")"
  )
  mkdir -p "$PD_INSTALL/yazi/bin"
  for pd_yazi_command in yazi ya; do
    cp "$PD_ROOT/cache/yazi-target/release-windows/$pd_yazi_command.exe" "$PD_INSTALL/yazi/bin/$pd_yazi_command.exe.new"
    mv -f "$PD_INSTALL/yazi/bin/$pd_yazi_command.exe.new" "$PD_INSTALL/yazi/bin/$pd_yazi_command.exe"
  done
  printf '%s\n' "$pd_yazi_version" > "$PD_ROOT/state/yazi.commit"
}
