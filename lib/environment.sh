# Shared Bash helpers for the user-owned playground layout.
_PD_ENVIRONMENT_DIR="$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

pd_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

pd_copy_missing_tree() {
  local pd_source="$1" pd_destination="$2" pd_file pd_relative
  [ -d "$pd_source" ] || return 0
  while IFS= read -r -d '' pd_file; do
    pd_relative="${pd_file#"$pd_source"/}"
    [ ! -e "$pd_destination/$pd_relative" ] && [ ! -L "$pd_destination/$pd_relative" ] || continue
    mkdir -p "$(dirname -- "$pd_destination/$pd_relative")"
    cp "$pd_file" "$pd_destination/$pd_relative"
  done < <(find "$pd_source" -type f -print0)
}

pd_seed_templates() {
  local pd_repository="${PD_DIR:-$_PD_ENVIRONMENT_DIR/..}" pd_file
  # The original repository configs remain user-editable template sources.
  for pd_file in wezterm/wezterm.lua yazi/yazi.toml yazi/keymap.toml; do
    if [ ! -e "$PD_ROOT/templates/$pd_file" ] && [ ! -L "$PD_ROOT/templates/$pd_file" ]; then
      mkdir -p "$(dirname -- "$PD_ROOT/templates/$pd_file")"
      case "$pd_file" in
        wezterm/*) cp "$pd_repository/wezterm.lua" "$PD_ROOT/templates/$pd_file" ;;
        *) cp "$pd_repository/$pd_file" "$PD_ROOT/templates/$pd_file" ;;
      esac
    fi
  done
  pd_copy_missing_tree "$pd_repository/templates" "$PD_ROOT/templates"
  pd_copy_missing_tree "$PD_ROOT/templates" "$PD_ROOT/config"
}

# POSIX shells cannot discover the filename of a dot-sourced file. They must
# receive an explicit root; Bash and Zsh always discover it from this file.
pd_emit_shell_root() {
  cat <<'EOF'
_pd_playground_source=
if [ -n "${BASH_VERSION:-}" ]; then
  _pd_playground_source="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  eval '_pd_playground_source=${(%):-%x}'
elif [ -n "${PD_PLAYGROUND_ROOT:-}" ]; then
  _pd_playground_source="$PD_PLAYGROUND_ROOT/config/shell/env.sh"
else
  printf '%s\n' 'terminal-setup: set PD_PLAYGROUND_ROOT before sourcing in a POSIX shell, or use Bash/Zsh.' >&2
  return 1
fi
EOF
  printf '_pd_playground_levels=%s\n' "$(pd_quote "$1")"
  cat <<'EOF'
if [ -z "${BASH_VERSION:-}${ZSH_VERSION:-}" ]; then _pd_playground_levels=../..; fi
if ! _pd_playground_root="$(CDPATH= cd -P -- "$(dirname -- "$_pd_playground_source")/$_pd_playground_levels" && pwd)"; then
  printf '%s\n' 'terminal-setup: cannot resolve the folder containing this activation file.' >&2
  unset _pd_playground_source _pd_playground_levels _pd_playground_root
  return 1
fi
if [ ! -d "$_pd_playground_root/bin" ] || [ ! -r "$_pd_playground_root/config/shell/env.sh" ]; then
  printf '%s\n' 'terminal-setup: cannot resolve the folder containing this activation file.' >&2
  unset _pd_playground_source _pd_playground_levels _pd_playground_root
  return 1
fi
export PD_PLAYGROUND_ROOT="$_pd_playground_root"
unset _pd_playground_source _pd_playground_levels _pd_playground_root
EOF
}

pd_emit_relocation() {
  cat <<'EOF'
if [ -f "$PD_PLAYGROUND_ROOT/lib/relocate.sh" ]; then
  BASH_ENV= ENV= /bin/bash --noprofile --norc "$PD_PLAYGROUND_ROOT/lib/relocate.sh" "$PD_PLAYGROUND_ROOT" || return 1
fi
EOF
}

pd_write_environment() {
  local pd_msys2
  mkdir -p "$PD_ROOT/bin" "$PD_ROOT/templates" "$PD_ROOT/config/shell" "$PD_ROOT/config/bash" "$PD_ROOT/config/tmux" \
    "$PD_ROOT/config/rustifiedgit" "$PD_ROOT/config/yazi" "$PD_ROOT/config/btop" \
    "$PD_ROOT/config/fzf" "$PD_ROOT/config/codex" "$PD_ROOT/config/wezterm" \
    "$PD_ROOT/config/path" "$PD_ROOT/state/bash" "$PD_ROOT/config/copilot" \
    "$PD_ROOT/config/vscode" "$PD_ROOT/config/notepad++" \
    "$PD_ROOT/cache/yazi" "$PD_ROOT/cache/copilot" "$PD_ROOT/state/zoxide" \
    "$PD_ROOT/state/tmux" "$PD_ROOT/state/data" "$PD_ROOT/state/home" "$PD_ROOT/state/yazi" "$PD_ROOT/tmp"
  mkdir -p "$PD_ROOT/config/vscode/user-data/User" "$PD_ROOT/config/vscode/extensions" "$PD_ROOT/config/vscode/tmp"
  pd_seed_templates
  if [ "${PD_OS:-}" = windows ]; then
    case "${PD_MSYS2_ROOT%/}" in
      "$PD_ROOT"/*) pd_msys2="${PD_MSYS2_ROOT#"$PD_ROOT"/}" ;;
      *) pd_msys2="$(cygpath -m "$PD_MSYS2_ROOT")" ;;
    esac
    printf '%s\n' "$pd_msys2" > "$PD_ROOT/config/path/msys2-root.txt"
  fi
  {
    printf '# Managed by terminal-setup; usable by Bash, Zsh and POSIX shells.\n'
    pd_emit_shell_root ../..
    pd_emit_relocation
    printf '_pd_playground_bin="$PD_PLAYGROUND_ROOT/bin"\n'
    if [ "${PD_OS:-}" = windows ]; then
      cat <<'EOF'
_pd_playground_msys2="$(cat "$PD_PLAYGROUND_ROOT/config/path/msys2-root.txt")" || return 1
case "$_pd_playground_msys2" in
  /*|[A-Za-z]:/*|[A-Za-z]:\\*) ;;
  *) _pd_playground_msys2="$PD_PLAYGROUND_ROOT/$_pd_playground_msys2" ;;
esac
case "$(uname -s)" in
  MSYS*|MINGW*) _pd_playground_msys2="$(cygpath -u "$_pd_playground_msys2")" || return 1 ;;
esac
export PD_PLAYGROUND_MSYS2_ROOT="$_pd_playground_msys2"
unset _pd_playground_msys2
EOF
    fi
    cat <<'EOF'
_pd_playground_path="$(printf '%s\n' "$PATH" | awk -v pd_bin="$_pd_playground_bin" '
  BEGIN { FS = ":" }
  { out = pd_bin; for (i = 1; i <= NF; i++)
      if ($i != "" && $i != pd_bin) out = out ":" $i;
    print out }')"
export PATH="$_pd_playground_path"
unset _pd_playground_bin _pd_playground_path
EOF
  } > "$PD_ROOT/config/shell/env.sh"
  {
    printf '# Extra tools for an existing Bash/Zsh/POSIX shell; existing commands keep priority.\n'
    pd_emit_shell_root ../..
    pd_emit_relocation
    printf '_pd_playground_bin="$PD_PLAYGROUND_ROOT/bin"\n'
    cat <<'EOF'
_pd_playground_path="$(printf '%s\n' "$PATH" | awk -v pd_bin="$_pd_playground_bin" '
  BEGIN { FS = ":" }
  { out = ""; for (i = 1; i <= NF; i++)
      if ($i != "" && $i != pd_bin) out = out (out == "" ? "" : ":") $i;
    print out (out == "" ? "" : ":") pd_bin }')"
export PATH="$_pd_playground_path"
unset _pd_playground_bin _pd_playground_path
EOF
  } > "$PD_ROOT/config/shell/env-extra.sh"
  {
    printf 'set -gx PD_PLAYGROUND_ROOT (cd (dirname (status filename))/../..; and pwd -P)\n'
    printf 'test -d "$PD_PLAYGROUND_ROOT/bin"; or return 1\n'
    printf 'if test -f "$PD_PLAYGROUND_ROOT/lib/relocate.sh"\n'
    printf '  command env BASH_ENV= ENV= /bin/bash --noprofile --norc "$PD_PLAYGROUND_ROOT/lib/relocate.sh" "$PD_PLAYGROUND_ROOT"; or return 1\n'
    printf 'end\n'
    printf 'fish_add_path --move --prepend --path "$PD_PLAYGROUND_ROOT/bin"\n'
  } > "$PD_ROOT/config/shell/env.fish"
  sed 's/--prepend/--append/' "$PD_ROOT/config/shell/env.fish" > "$PD_ROOT/config/shell/env-extra.fish"
  {
    printf '# Extra tools for the current PowerShell session; persistent PATH is untouched.\n& {\n'
    printf '  $env:PD_PLAYGROUND_ROOT = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "../.."))\n'
    printf '  $terminalSetupBin = Join-Path $env:PD_PLAYGROUND_ROOT "bin"\n'
    cat <<'EOF'
  $terminalSetupRelocator = Join-Path $env:PD_PLAYGROUND_ROOT "lib/relocate.sh"
  if ([IO.Path]::PathSeparator -eq ':' -and (Test-Path -LiteralPath $terminalSetupRelocator)) {
    & /usr/bin/env BASH_ENV= ENV= /bin/bash --noprofile --norc $terminalSetupRelocator $env:PD_PLAYGROUND_ROOT
    if ($LASTEXITCODE -ne 0) { throw 'terminal-setup: offline package relocation failed.' }
  }
  $terminalSetupSeparator = [IO.Path]::PathSeparator
  $terminalSetupComparison = if ($terminalSetupSeparator -eq ';') {
    [StringComparison]::OrdinalIgnoreCase
  } else { [StringComparison]::Ordinal }
  if ($terminalSetupSeparator -eq ';') {
    $terminalSetupBin = $terminalSetupBin.Replace('/', '\')
  }
  $terminalSetupBin = $terminalSetupBin.TrimEnd([char[]]'\/')
  $terminalSetupEntries = @($env:PATH -split [regex]::Escape([string]$terminalSetupSeparator) | Where-Object {
    $terminalSetupEntry = $_
    if ($terminalSetupSeparator -eq ';') {
      $terminalSetupEntry = $terminalSetupEntry.Replace('/', '\')
    }
    $_ -and -not [string]::Equals($terminalSetupEntry.TrimEnd([char[]]'\/'), $terminalSetupBin, $terminalSetupComparison)
  })
  $env:PATH = (@($terminalSetupEntries) + @($terminalSetupBin)) -join $terminalSetupSeparator
}
EOF
  } > "$PD_ROOT/config/shell/env-extra.ps1"
  {
    printf '# Source this file to add the tools to an existing shell.\n'
    pd_emit_shell_root .
    printf '. "$PD_PLAYGROUND_ROOT/config/shell/env-extra.sh"\n'
  } > "$PD_ROOT/activate.sh"
  printf '. "$PSScriptRoot/config/shell/env-extra.ps1"\n' > "$PD_ROOT/activate.ps1"
}

pd_codex_packages() {
  local pd_link="$PD_ROOT/config/codex/packages" pd_payload="$PD_ROOT/install/codex/packages"
  mkdir -p "$PD_ROOT/install/codex" "$PD_ROOT/config/codex"
  if [ -L "$pd_link" ]; then
    [ -d "$pd_payload" ] && \
      [ "$(CDPATH= cd -P -- "$pd_link" && pwd)" = "$(CDPATH= cd -P -- "$pd_payload" && pwd)" ] || \
      die "Codex package link points outside its playground installation."
    return
  fi
  if [ -e "$pd_link" ]; then
    [ ! -e "$pd_payload" ] || die "Two Codex package directories exist; refusing to merge them."
    mv "$pd_link" "$pd_payload"
  else
    mkdir -p "$pd_payload"
  fi
  ln -s '../../install/codex/packages' "$pd_link"
}

pd_profile_hook() {
  local pd_file="$1" pd_staging
  mkdir -p "$(dirname "$pd_file")"
  pd_staging="$PD_ROOT/tmp/profile.$$.$RANDOM"
  (umask 077; set -C; : > "$pd_staging") || die "Cannot stage profile hook."
  if [ -f "$pd_file" ]; then
    if grep -Fq '# >>> pd-playground PATH >>>' "$pd_file" && \
       ! grep -Fq '# <<< pd-playground PATH <<<' "$pd_file"; then
      rm -f "$pd_staging"
      die "Incomplete playground hook in $pd_file; repair its end marker."
    fi
    awk '
      $0 == "# >>> pd-playground PATH >>>" { skip = 1; next }
      $0 == "# <<< pd-playground PATH <<<" { skip = 0; next }
      !skip { print }
    ' "$pd_file" > "$pd_staging"
  fi
  {
    printf '# >>> pd-playground PATH >>>\n'
    printf '[ ! -r %s ] || { export PD_PLAYGROUND_ROOT=%s; . %s; }\n' \
      "$(pd_quote "$PD_ROOT/config/shell/env.sh")" \
      "$(pd_quote "$PD_ROOT")" \
      "$(pd_quote "$PD_ROOT/config/shell/env.sh")"
    printf '# <<< pd-playground PATH <<<\n'
  } >> "$pd_staging"
  cat "$pd_staging" > "$pd_file"
  rm -f "$pd_staging"
}

pd_register_path() {
  local pd_file pd_login="$PD_USER_HOME/.bash_profile" pd_fish_dir
  for pd_file in "$PD_USER_HOME/.bash_profile" "$PD_USER_HOME/.bash_login" "$PD_USER_HOME/.profile"; do
    if [ -f "$pd_file" ]; then pd_login="$pd_file"; break; fi
  done
  for pd_file in "$PD_USER_HOME/.bashrc" "$pd_login" "$PD_USER_HOME/.profile" \
      "$PD_USER_HOME/.zshrc" "$PD_USER_HOME/.zprofile"; do
    pd_profile_hook "$pd_file"
  done
  pd_fish_dir="${XDG_CONFIG_HOME:-$PD_USER_HOME/.config}/fish/conf.d"
  mkdir -p "$pd_fish_dir"
  printf 'source "%s"\n' "$PD_ROOT/config/shell/env.fish" \
    > "$pd_fish_dir/pd-playground.fish"
  . "$PD_ROOT/config/shell/env.sh"
  [ "${PD_SKIP_DESKTOP_PATH:-0}" != 1 ] || return 0
  case "$PD_OS" in
    macos) pd_register_macos_gui ;;
    linux) pd_register_linux_gui ;;
    windows) : ;; # The PowerShell bootstrap writes the Windows user PATH.
  esac
}

pd_register_macos_gui() {
  local pd_agent="$PD_USER_HOME/Library/LaunchAgents/local.pd.playground.path.plist"
  local pd_script="$PD_ROOT/config/path/set-gui-path.sh" pd_xml_path pd_uid
  mkdir -p "$(dirname "$pd_agent")"
  {
    printf '#!/bin/sh\n'
    printf 'export PD_PLAYGROUND_ROOT="$(CDPATH= cd -P -- "$(dirname -- "$0")/../.." && pwd)" || exit 1\n'
    printf '. "$PD_PLAYGROUND_ROOT/config/shell/env.sh" || exit 1\n'
    printf '/bin/launchctl setenv PATH "$PATH"\n'
  } > "$pd_script"
  pd_xml_path="$(printf '%s' "$pd_script" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
  cat > "$PD_ROOT/config/path/launch-agent.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.pd.playground.path</string>
<key>ProgramArguments</key><array><string>/bin/sh</string><string>$pd_xml_path</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
EOF
  if [ -e "$pd_agent" ] && [ ! -L "$pd_agent" ]; then
    die "A non-managed LaunchAgent already exists at $pd_agent."
  fi
  ln -sfn "$PD_ROOT/config/path/launch-agent.plist" "$pd_agent"
  pd_uid="$(id -u)"
  if /bin/launchctl print "gui/$pd_uid" >/dev/null 2>&1; then
    /bin/launchctl bootout "gui/$pd_uid/local.pd.playground.path" >/dev/null 2>&1 || true
    /bin/launchctl bootstrap "gui/$pd_uid" "$pd_agent"
    /bin/sh "$pd_script"
  fi
}

pd_register_linux_gui() {
  local pd_environment="${XDG_CONFIG_HOME:-$PD_USER_HOME/.config}/environment.d"
  mkdir -p "$pd_environment"
  printf 'PATH=%s/bin:${PATH}\n' "$PD_ROOT" > "$PD_ROOT/config/path/environment.conf"
  if [ -e "$pd_environment/90-pd-playground.conf" ] && \
     [ ! -L "$pd_environment/90-pd-playground.conf" ]; then
    die "A non-managed environment file exists at $pd_environment/90-pd-playground.conf."
  fi
  ln -sfn "$PD_ROOT/config/path/environment.conf" "$pd_environment/90-pd-playground.conf"
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user import-environment PATH
  fi
  if command -v dbus-update-activation-environment >/dev/null 2>&1 && \
     [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    dbus-update-activation-environment PATH
  fi
}

pd_write_launcher() {
  local pd_name="$1" pd_target="$2" pd_target_base pd_target_relative
  case "$pd_target" in
    "$PD_ROOT/install/"*)
      pd_target_base=PD_PLAYGROUND_ROOT
      pd_target_relative="${pd_target#"$PD_ROOT"/}" ;;
    *)
      if [ "${PD_OS:-}" != windows ] || [[ "$pd_target" != "${PD_MSYS2_ROOT%/}/"* ]]; then
        die "Tool outside playground and selected MSYS2: $pd_target."
      fi
      pd_target_base=PD_PLAYGROUND_MSYS2_ROOT
      pd_target_relative="${pd_target#"${PD_MSYS2_ROOT%/}"/}" ;;
  esac
  case "/$pd_target_relative/" in
    */../*) die "Launcher target contains a parent traversal: $pd_target." ;;
  esac
  mkdir -p "$PD_ROOT/bin"
  {
    printf '#!/bin/sh\n# Managed playground launcher.\n'
    printf 'export PD_PLAYGROUND_ROOT="$(CDPATH= cd -P -- "$(dirname -- "$0")/.." && pwd)" || exit 1\n'
    printf '. "$PD_PLAYGROUND_ROOT/config/shell/env.sh" || exit 1\n'
    printf '_pd_target="${%s%%/}/"%s\n' "$pd_target_base" "$(pd_quote "$pd_target_relative")"
    if [ "$pd_name" != git ]; then
      printf 'export XDG_CONFIG_HOME="$PD_PLAYGROUND_ROOT/config"\n'
      cat <<'EOF'
export XDG_CACHE_HOME="$PD_PLAYGROUND_ROOT/cache"
export XDG_DATA_HOME="$PD_PLAYGROUND_ROOT/state/data"
export XDG_STATE_HOME="$PD_PLAYGROUND_ROOT/state"
export TMPDIR="$PD_PLAYGROUND_ROOT/tmp"
export _ZO_DATA_DIR="$PD_PLAYGROUND_ROOT/state/zoxide"
EOF
    fi
    cat <<'EOF'
case "$(uname -s)" in
  MSYS*|MINGW*)
    export TEMP="$(cygpath -m "$PD_PLAYGROUND_ROOT/tmp")"
    export TMP="$TEMP"
    export PD_PLAYGROUND_MSYS2_ROOT
    export PATH="$PD_PLAYGROUND_ROOT/bin:${PD_PLAYGROUND_MSYS2_ROOT%/}/ucrt64/bin:${PD_PLAYGROUND_MSYS2_ROOT%/}/usr/bin:$PATH" ;;
  *) export PATH="$PD_PLAYGROUND_ROOT/bin:$PD_PLAYGROUND_ROOT/install/conda/bin:$PATH" ;;
esac
EOF
    case "$pd_name" in
      codex)
        cat <<'EOF'
_pd_codex_home="$PD_PLAYGROUND_ROOT/config/codex"
case "$(uname -s)" in MSYS*|MINGW*) _pd_codex_home="$(cygpath -m "$_pd_codex_home")" ;; esac
EOF
        printf 'exec env CODEX_HOME="$_pd_codex_home" "$_pd_target" "$@"\n' ;;
      rustifiedgit) printf 'exec "$_pd_target" --use-config-dir "$PD_PLAYGROUND_ROOT/config/rustifiedgit" "$@"\n' ;;
      tmux) printf 'exec "$_pd_target" -S "$PD_PLAYGROUND_ROOT/state/tmux/socket" -f "$PD_PLAYGROUND_ROOT/config/tmux/tmux.conf" "$@"\n' ;;
      copilot)
        if [ "${PD_OS:-}" = windows ] && [ -n "${PD_PWSH:-}" ]; then
          case "$PD_PWSH" in
            "$PD_ROOT/install/"*)
              printf 'export PATH="$PD_PLAYGROUND_ROOT/"%s:"$PATH"\n' \
                "$(pd_quote "$(dirname -- "${PD_PWSH#"$PD_ROOT"/}")")" ;;
            *) die "PowerShell dependency outside playground: $PD_PWSH." ;;
          esac
        fi
        cat <<'EOF'
export COPILOT_HOME="$PD_PLAYGROUND_ROOT/config/copilot"
export COPILOT_CACHE_HOME="$PD_PLAYGROUND_ROOT/cache/copilot"
export COPILOT_AUTO_UPDATE=false
case "$(uname -s)" in MSYS*|MINGW*)
  COPILOT_HOME="$(cygpath -m "$COPILOT_HOME")"
  COPILOT_CACHE_HOME="$(cygpath -m "$COPILOT_CACHE_HOME")" ;;
esac
EOF
        printf 'exec "$_pd_target" "$@"\n' ;;
      code)
        if [ "${PD_OS:-}" = windows ]; then
          printf 'export VSCODE_PORTABLE="$(cygpath -m "$PD_PLAYGROUND_ROOT/config/vscode")"\n'
          printf 'exec sh "$(dirname -- "$_pd_target")/bin/code" --user-data-dir "$VSCODE_PORTABLE/user-data" --extensions-dir "$VSCODE_PORTABLE/extensions" "$@"\n'
        else
          printf 'export VSCODE_PORTABLE="$PD_PLAYGROUND_ROOT/config/vscode"\n'
          printf 'exec "$_pd_target" --user-data-dir "$PD_PLAYGROUND_ROOT/config/vscode/user-data" --extensions-dir "$PD_PLAYGROUND_ROOT/config/vscode/extensions" "$@"\n'
        fi ;;
      notepad++) printf 'exec "$_pd_target" -multiInst -settingsDir="$(cygpath -m "$PD_PLAYGROUND_ROOT/config/notepad++")" "$@"\n' ;;
      wezterm)
        printf 'export HOME="$PD_PLAYGROUND_ROOT/state/home"\n'
        printf 'export XDG_RUNTIME_DIR="$PD_PLAYGROUND_ROOT/tmp"\n'
        printf 'exec "$_pd_target" --config-file "$PD_PLAYGROUND_ROOT/config/wezterm/wezterm.lua" "$@"\n' ;;
      bash)
        printf 'export BASH_ENV="$PD_PLAYGROUND_ROOT/config/bash/bashrc"\n'
        printf 'exec "$_pd_target" --rcfile "$PD_PLAYGROUND_ROOT/config/bash/bashrc" "$@"\n' ;;
      yazi|ya)
        cat <<'EOF'
export YAZI_CONFIG_HOME="$PD_PLAYGROUND_ROOT/config/yazi"
export YAZI_CACHE_HOME="$PD_PLAYGROUND_ROOT/cache/yazi"
export YAZI_STATE_HOME="$PD_PLAYGROUND_ROOT/state/yazi"
export XDG_RUNTIME_DIR="$PD_PLAYGROUND_ROOT/tmp"
case "$(uname -s)" in
  MSYS*|MINGW*)
    YAZI_CONFIG_HOME="$(cygpath -m "$YAZI_CONFIG_HOME")"
    YAZI_CACHE_HOME="$(cygpath -m "$YAZI_CACHE_HOME")"
    YAZI_STATE_HOME="$(cygpath -m "$YAZI_STATE_HOME")"
    XDG_RUNTIME_DIR="$(cygpath -m "$XDG_RUNTIME_DIR")"
    export YAZI_CONFIG_HOME
    unset YAZI_FILE_ONE
    if [ -x "${PD_PLAYGROUND_MSYS2_ROOT%/}/usr/bin/file.exe" ]; then
      export YAZI_FILE_ONE="$(cygpath -m "${PD_PLAYGROUND_MSYS2_ROOT%/}/usr/bin/file.exe")"
    fi ;;
esac
EOF
        printf 'exec "$_pd_target" "$@"\n' ;;
      *) printf 'exec "$_pd_target" "$@"\n' ;;
    esac
  } > "$PD_ROOT/bin/$pd_name"
  chmod 755 "$PD_ROOT/bin/$pd_name"
}
