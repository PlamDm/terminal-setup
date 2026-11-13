# Build RustifiedGit with an isolated toolchain and persistent dependency caches.
pd_native_path() {
  if [ "$PD_OS" = windows ]; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

pd_install_rust() {
  if [ "$PD_OS" = windows ]; then
    PD_CARGO="${PD_MSYS2_ROOT%/}/ucrt64/bin/cargo.exe"
    PD_RUSTC="${PD_MSYS2_ROOT%/}/ucrt64/bin/rustc.exe"
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

pd_require_readonly_msys2_build_tools() {
  local pd_feature="$1" pd_missing=()
  [ -x "${PD_MSYS2_ROOT%/}/ucrt64/bin/cargo.exe" ] || pd_missing+=(cargo)
  [ -x "${PD_MSYS2_ROOT%/}/ucrt64/bin/rustc.exe" ] || pd_missing+=(rustc)
  command -v git >/dev/null 2>&1 || pd_missing+=(git)
  if [ "${#pd_missing[@]}" -ne 0 ]; then
    log "Skipping $pd_feature; read-only MSYS2 lacks build prerequisites: ${pd_missing[*]}."
    return 1
  fi
}

pd_rustifiedgit_cached() {
  [ -x "$PD_INSTALL/rustifiedgit/bin/rustifiedgit$pd_suffix" ] && \
    [ -f "$PD_ROOT/state/rustifiedgit.commit" ] && \
    [ "$(cat "$PD_ROOT/state/rustifiedgit.commit")" = "$1" ]
}

install_rustifiedgit() {
  local pd_source="$PD_TEMP/rustifiedgit" pd_commit pd_suffix="" pd_target pd_staged
  [ "$PD_OS" != windows ] || pd_suffix=".exe"
  if [ "$PD_OS" = windows ] && [ -x "$PD_INSTALL/rustifiedgit/bin/rustifiedgit.exe" ]; then
    log "Keeping installed RustifiedGit."
    return
  fi
  mkdir -p "$PD_INSTALL/rustifiedgit/bin" "$PD_ROOT/cache/cargo" "$PD_ROOT/cache/rustifiedgit-target"
  if [[ "$PD_REF" =~ ^[a-fA-F0-9]{40}$ ]] && pd_rustifiedgit_cached "$PD_REF"; then
    log "Requested RustifiedGit revision is already installed."
    return
  fi
  if [ "${PD_OS:-}" = windows ] && [ "${PD_MSYS2_READ_ONLY:-0}" = 1 ] &&
      ! pd_require_readonly_msys2_build_tools RustifiedGit; then
    return 0
  fi
  if [ "$PD_OS" = windows ]; then
    [ -n "${PD_RUSTIFIEDGIT_SOURCE:-}" ] ||
      die "Run install.ps1 to prepare the locked offline RustifiedGit source."
    pd_source="$PD_RUSTIFIEDGIT_SOURCE"
    pd_commit="$PD_REF"
  else
    git init -q "$pd_source"
    git -C "$pd_source" remote add origin "$PD_REPO"
    git -C "$pd_source" fetch --depth 1 origin "$PD_REF"
    git -C "$pd_source" checkout -q --detach FETCH_HEAD
    pd_commit="$(git -C "$pd_source" rev-parse HEAD)"
  fi
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
      "$PD_CARGO" build --release --locked --target-dir "$pd_target" ${PD_RUSTIFIEDGIT_SOURCE:+--offline}
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
