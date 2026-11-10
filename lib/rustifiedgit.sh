# Build RustifiedGit with an isolated toolchain and persistent dependency caches.
pd_native_path() {
  if [ "$PD_OS" = windows ]; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

pd_install_rust() {
  if [ "$PD_OS" = windows ]; then
    PD_CARGO="$PD_INSTALL/msys2/ucrt64/bin/cargo.exe"
    PD_RUSTC="$PD_INSTALL/msys2/ucrt64/bin/rustc.exe"
  else
    PD_CARGO="$PD_INSTALL/rust/bin/cargo"
    PD_RUSTC="$PD_INSTALL/rust/bin/rustc"
    if [ ! -x "$PD_CARGO" ] || [ ! -x "$PD_RUSTC" ]; then
      log "Installing the Rust toolchain inside playground."
      fetch https://sh.rustup.rs "$PD_TEMP/rustup-init.sh"
      env -u RUSTUP_TOOLCHAIN CARGO_HOME="$PD_INSTALL/rust" RUSTUP_HOME="$PD_INSTALL/rustup" \
        sh "$PD_TEMP/rustup-init.sh" -y --no-modify-path --profile minimal --default-toolchain 1.88.0
    fi
  fi
  [ -x "$PD_CARGO" ] && [ -x "$PD_RUSTC" ] || die "Rust compiler or Cargo is missing from $PD_INSTALL."
}

pd_rustifiedgit_cached() {
  [ -x "$PD_INSTALL/rustifiedgit/bin/rustifiedgit$pd_suffix" ] && \
    [ -f "$PD_ROOT/state/rustifiedgit.commit" ] && \
    [ "$(cat "$PD_ROOT/state/rustifiedgit.commit")" = "$1" ]
}

install_rustifiedgit() {
  local pd_source="$PD_TEMP/rustifiedgit" pd_commit pd_suffix="" pd_target pd_staged
  [ "$PD_OS" != windows ] || pd_suffix=".exe"
  mkdir -p "$PD_INSTALL/rustifiedgit/bin" "$PD_ROOT/cache/cargo" "$PD_ROOT/cache/rustifiedgit-target"
  if [[ "$PD_REF" =~ ^[a-fA-F0-9]{40}$ ]] && pd_rustifiedgit_cached "$PD_REF"; then
    log "Requested RustifiedGit revision is already installed."
    return
  fi
  git init -q "$pd_source"
  git -C "$pd_source" remote add origin "$PD_REPO"
  git -C "$pd_source" fetch --depth 1 origin "$PD_REF"
  git -C "$pd_source" checkout -q --detach FETCH_HEAD
  pd_commit="$(git -C "$pd_source" rev-parse HEAD)"
  if pd_rustifiedgit_cached "$pd_commit"; then
    log "RustifiedGit ref resolves to the already installed revision."
    return
  fi
  pd_install_rust
  log "Building RustifiedGit at $pd_commit."
  pd_target="$PD_ROOT/cache/rustifiedgit-target"
  (
    cd "$pd_source"
    env -u RUSTUP_TOOLCHAIN -u RUSTC_WRAPPER -u RUSTC_WORKSPACE_WRAPPER \
      CARGO_HOME="$(pd_native_path "$PD_ROOT/cache/cargo")" \
      RUSTUP_HOME="$(pd_native_path "$PD_INSTALL/rustup")" \
      RUSTC="$(pd_native_path "$PD_RUSTC")" \
      "$PD_CARGO" build --release --locked --target-dir "$pd_target"
  )
  pd_staged="$PD_INSTALL/rustifiedgit/bin/.rustifiedgit-install-$$$pd_suffix"
  cp "$pd_target/release/rustifiedgit$pd_suffix" "$pd_staged"
  chmod 755 "$pd_staged"
  if ! "$pd_staged" --version; then
    rm -f "$pd_staged"
    die "The built RustifiedGit executable could not run. Existing installation was kept."
  fi
  mv -f "$pd_staged" "$PD_INSTALL/rustifiedgit/bin/rustifiedgit$pd_suffix"
  printf '%s\n' "$pd_commit" > "$PD_ROOT/state/rustifiedgit.commit.tmp"
  mv -f "$PD_ROOT/state/rustifiedgit.commit.tmp" "$PD_ROOT/state/rustifiedgit.commit"
}
