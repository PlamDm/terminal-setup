# Shared Bash helpers for the user-owned playground layout.
pd_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

pd_write_environment() {
  local pd_ps_bin
  mkdir -p "$PD_ROOT/config/shell" "$PD_ROOT/config/bash" "$PD_ROOT/config/tmux" \
    "$PD_ROOT/config/rustifiedgit" "$PD_ROOT/config/yazi" "$PD_ROOT/config/btop" \
    "$PD_ROOT/config/fzf" "$PD_ROOT/config/codex" "$PD_ROOT/config/wezterm" \
    "$PD_ROOT/config/path" "$PD_ROOT/state/bash" "$PD_ROOT/config/copilot" \
    "$PD_ROOT/config/vscode" "$PD_ROOT/config/notepad++" "$PD_ROOT/config/git" \
    "$PD_ROOT/cache/yazi" "$PD_ROOT/cache/copilot" "$PD_ROOT/state/zoxide" \
    "$PD_ROOT/state/tmux" "$PD_ROOT/state/data" "$PD_ROOT/state/yazi" "$PD_ROOT/tmp"
  if [ ! -e "$PD_ROOT/config/copilot/settings.json" ]; then
    printf '{"autoUpdate":false}\n' > "$PD_ROOT/config/copilot/settings.json"
  fi
  mkdir -p "$PD_ROOT/config/vscode/user-data/User" "$PD_ROOT/config/vscode/extensions" "$PD_ROOT/config/vscode/tmp"
  if [ ! -e "$PD_ROOT/config/vscode/user-data/User/settings.json" ]; then
    printf '{"update.mode":"none"}\n' > "$PD_ROOT/config/vscode/user-data/User/settings.json"
  fi
  {
    printf '# Managed by terminal-setup; usable by Bash, Zsh and POSIX shells.\n'
    printf '_pd_playground_bin=%s\n' "$(pd_quote "$PD_ROOT/bin")"
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
    printf '_pd_playground_bin=%s\n' "$(pd_quote "$PD_ROOT/bin")"
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
  printf 'fish_add_path --move --prepend --path "%s"\n' \
    "$PD_ROOT/bin" > "$PD_ROOT/config/shell/env.fish"
  printf 'fish_add_path --move --append --path "%s"\n' \
    "$PD_ROOT/bin" > "$PD_ROOT/config/shell/env-extra.fish"
  if [ "${PD_OS:-}" = windows ]; then
    pd_ps_bin="$(cygpath -w "$PD_ROOT/bin")"
  else
    pd_ps_bin="$PD_ROOT/bin"
  fi
  pd_ps_bin="$(printf '%s' "$pd_ps_bin" | sed "s/'/''/g")"
  {
    printf '# Extra tools for the current PowerShell session; persistent PATH is untouched.\n& {\n'
    printf '  $terminalSetupBin = %s\n' "'$pd_ps_bin'"
    cat <<'EOF'
  $terminalSetupSeparator = [IO.Path]::PathSeparator
  $terminalSetupComparison = if ($terminalSetupSeparator -eq ';') {
    [StringComparison]::OrdinalIgnoreCase
  } else { [StringComparison]::Ordinal }
  $terminalSetupEntries = @($env:PATH -split [regex]::Escape([string]$terminalSetupSeparator) | Where-Object {
    $_ -and -not [string]::Equals($_.TrimEnd([char[]]'\/'), $terminalSetupBin.TrimEnd([char[]]'\/'), $terminalSetupComparison)
  })
  $env:PATH = (@($terminalSetupEntries) + @($terminalSetupBin)) -join $terminalSetupSeparator
}
EOF
  } > "$PD_ROOT/config/shell/env-extra.ps1"
  printf '# Source this file to add the tools to an existing shell.\n. %s\n' \
    "$(pd_quote "$PD_ROOT/config/shell/env-extra.sh")" > "$PD_ROOT/activate.sh"
  printf '. "$PSScriptRoot/config/shell/env-extra.ps1"\n' > "$PD_ROOT/activate.ps1"
  if [ ! -e "$PD_ROOT/config/bash/bashrc" ]; then
    {
      printf '. %s\n' "$(pd_quote "$PD_ROOT/config/shell/env.sh")"
      printf 'HISTFILE=%s\n' "$(pd_quote "$PD_ROOT/state/bash/history")"
    } > "$PD_ROOT/config/bash/bashrc"
  fi
  if [ ! -e "$PD_ROOT/config/tmux/tmux.conf" ]; then
    printf 'set -g default-shell "%s"\n' "$PD_ROOT/bin/bash" \
      > "$PD_ROOT/config/tmux/tmux.conf"
  fi
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
  ln -s "$pd_payload" "$pd_link"
}

pd_profile_hook() {
  local pd_file="$1" pd_staging
  mkdir -p "$(dirname "$pd_file")"
  pd_staging="$(mktemp "$PD_ROOT/tmp/profile.XXXXXX")"
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
    printf '[ ! -r %s ] || . %s\n' \
      "$(pd_quote "$PD_ROOT/config/shell/env.sh")" \
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
    printf '. %s\n' "$(pd_quote "$PD_ROOT/config/shell/env.sh")"
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
  local pd_name="$1" pd_target="$2" pd_root_q pd_target_q
  case "$pd_target" in "$PD_ROOT/install/"*) ;; *) die "Tool outside playground: $pd_target." ;; esac
  pd_root_q="$(pd_quote "$PD_ROOT")"
  pd_target_q="$(pd_quote "$pd_target")"
  {
    printf '#!/bin/sh\n# Managed playground launcher.\nPD_PLAYGROUND_ROOT=%s\n' "$pd_root_q"
    printf '. "$PD_PLAYGROUND_ROOT/config/shell/env.sh"\n'
    printf 'export XDG_CONFIG_HOME="$PD_PLAYGROUND_ROOT/config"\n'
    cat <<'EOF'
export XDG_CACHE_HOME="$PD_PLAYGROUND_ROOT/cache"
export XDG_DATA_HOME="$PD_PLAYGROUND_ROOT/state/data"
export XDG_STATE_HOME="$PD_PLAYGROUND_ROOT/state"
export TMPDIR="$PD_PLAYGROUND_ROOT/tmp"
export _ZO_DATA_DIR="$PD_PLAYGROUND_ROOT/state/zoxide"
export GIT_CONFIG_GLOBAL="$PD_PLAYGROUND_ROOT/config/git/config"
case "$(uname -s)" in
  MSYS*|MINGW*)
    export TEMP="$(cygpath -m "$PD_PLAYGROUND_ROOT/tmp")"
    export TMP="$TEMP"
    export PATH="$PD_PLAYGROUND_ROOT/bin:$PD_PLAYGROUND_ROOT/install/msys2/ucrt64/bin:$PD_PLAYGROUND_ROOT/install/msys2/usr/bin:$PATH" ;;
  *) export PATH="$PD_PLAYGROUND_ROOT/bin:$PD_PLAYGROUND_ROOT/install/homebrew/bin:$PATH" ;;
esac
EOF
    case "$pd_name" in
      codex)
        cat <<'EOF'
_pd_codex_home="$PD_PLAYGROUND_ROOT/config/codex"
case "$(uname -s)" in MSYS*|MINGW*) _pd_codex_home="$(cygpath -m "$_pd_codex_home")" ;; esac
EOF
        printf 'exec env CODEX_HOME="$_pd_codex_home" %s "$@"\n' "$pd_target_q" ;;
      rustifiedgit) printf 'exec %s --use-config-dir "$PD_PLAYGROUND_ROOT/config/rustifiedgit" "$@"\n' "$pd_target_q" ;;
      tmux) printf 'exec %s -S "$PD_PLAYGROUND_ROOT/state/tmux/socket" -f "$PD_PLAYGROUND_ROOT/config/tmux/tmux.conf" "$@"\n' "$pd_target_q" ;;
      copilot)
        if [ "${PD_OS:-}" = windows ]; then
          printf 'export PATH=%s:"$PATH"\n' "$(pd_quote "$(dirname "$PD_PWSH")")"
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
        printf 'exec %s "$@"\n' "$pd_target_q" ;;
      code)
        if [ "${PD_OS:-}" = windows ]; then
          printf 'export VSCODE_PORTABLE="$(cygpath -m "$PD_PLAYGROUND_ROOT/config/vscode")"\n'
          printf 'export ELECTRON_RUN_AS_NODE=1\n'
          printf 'exec %s %s --user-data-dir "$VSCODE_PORTABLE/user-data" --extensions-dir "$VSCODE_PORTABLE/extensions" "$@"\n' \
            "$pd_target_q" "$(pd_quote "$(dirname "$pd_target")/resources/app/out/cli.js")"
        else
          printf 'export VSCODE_PORTABLE="$PD_PLAYGROUND_ROOT/config/vscode"\n'
          printf 'exec %s --user-data-dir "$PD_PLAYGROUND_ROOT/config/vscode/user-data" --extensions-dir "$PD_PLAYGROUND_ROOT/config/vscode/extensions" "$@"\n' "$pd_target_q"
        fi ;;
      notepad++) printf 'exec %s -multiInst -settingsDir="$(cygpath -m "$PD_PLAYGROUND_ROOT/config/notepad++")" "$@"\n' "$pd_target_q" ;;
      wezterm) printf 'exec %s --config-file "$PD_PLAYGROUND_ROOT/config/wezterm/wezterm.lua" "$@"\n' "$pd_target_q" ;;
      bash)
        printf 'export BASH_ENV="$PD_PLAYGROUND_ROOT/config/bash/bashrc"\n'
        printf 'exec %s --rcfile "$PD_PLAYGROUND_ROOT/config/bash/bashrc" "$@"\n' "$pd_target_q" ;;
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
    export YAZI_FILE_ONE="$(cygpath -m "$PD_PLAYGROUND_ROOT/install/msys2/usr/bin/file.exe")" ;;
esac
EOF
        printf 'exec %s "$@"\n' "$pd_target_q" ;;
      *) printf 'exec %s "$@"\n' "$pd_target_q" ;;
    esac
  } > "$PD_ROOT/bin/$pd_name"
  chmod 755 "$PD_ROOT/bin/$pd_name"
}
