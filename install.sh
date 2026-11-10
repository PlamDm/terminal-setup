#!/usr/bin/env bash
# User-owned terminal tools for macOS, Linux and native Windows.
set -euo pipefail
PD_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PD_ROOT="$HOME/playground"
PD_USER_HOME="${PD_USER_HOME:-$HOME}"
PD_REPO="https://github.com/PlamDm/RustifiedGit.git"
PD_REF="7a2be2ebfa45cfc5be78e788a820ee145953f36b"
PD_DRY_RUN=0
PD_ONLY_CODEX=0
PD_ACTIVATE=0
PD_PREVIEW_OS=""
PD_TEMP=""

log() { printf '[playground] %s\n' "$*"; }
die() { printf '[playground] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
usage() {
  cat <<'EOF'
Usage: bash install.sh [options]

Install terminal tools, Yazi helpers, Copilot CLI, VS Code and portable editors.
Default layout: ~/playground/{install,bin,config,state,cache,tmp}.
By default, leaves profiles and persistent PATH unchanged. Source env-extra.sh.

  --dry-run            Preview without downloads or filesystem changes.
  --only-codex         Install only the managed Codex CLI.
  --no-activate        Install without changing profiles or persistent PATH.
  --activate           Opt in to shell hooks and desktop user PATH registration.
  --root DIR           Choose another absolute playground directory.
  --rustifiedgit-ref REF    Build a commit, tag or branch from PlamDm/RustifiedGit.
  --platform OS        Preview macos, linux or windows; requires --dry-run.
  -h, --help           Show help.

Windows: use install.ps1, or run this from an existing MSYS2/Git Bash.
macOS/Linux: an isolated Homebrew prefix is placed under playground/install.
EOF
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) PD_DRY_RUN=1; shift ;;
    --only-codex) PD_ONLY_CODEX=1; shift ;;
    --no-activate) PD_ACTIVATE=0; shift ;;
    --activate) PD_ACTIVATE=1; shift ;;
    --root|--rustifiedgit-ref|--platform)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "Missing value for $1."
      case "$1" in
        --root) PD_ROOT="$2" ;;
        --rustifiedgit-ref) PD_REF="$2" ;;
        --platform) PD_PREVIEW_OS="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help." ;;
  esac
done
[[ "$PD_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "Invalid RustifiedGit ref."
[ "$PD_DRY_RUN" -eq 1 ] || [ -z "$PD_PREVIEW_OS" ] || die "--platform requires --dry-run."
case "$PD_ROOT" in /*) ;; *) die "--root must be an absolute path." ;; esac
case "$PD_ROOT" in /|"$HOME"|*:*|*$'\n'*|*$'\r'*) die "Choose a dedicated playground directory." ;; esac
detect_os() {
  case "$(uname -s)" in
    Darwin) printf 'macos\n' ;;
    Linux) printf 'linux\n' ;;
    MSYS*|MINGW*|CYGWIN*) printf 'windows\n' ;;
    *) die "Unsupported operating system: $(uname -s)." ;;
  esac
}
PD_OS="${PD_PREVIEW_OS:-$(detect_os)}"
case "$PD_OS" in macos|linux|windows) ;; *) die "Unknown platform: $PD_OS." ;; esac

if [ "$PD_DRY_RUN" -eq 1 ]; then
  log "Preview only; no downloads or changes."
  log "Root: $PD_ROOT"
  log "Installations: $PD_ROOT/install; commands: $PD_ROOT/bin; configuration: $PD_ROOT/config."
  if [ "$PD_ONLY_CODEX" -ne 1 ]; then
    case "$PD_OS" in
      macos|linux)
        log "Create an isolated Homebrew at $PD_ROOT/install/homebrew."
        log "Install bash tmux yazi git file btop fzf in that prefix."
        log "Add Yazi helpers: ffmpeg sevenzip jq poppler fd ripgrep zoxide resvg imagemagick."
        log "Install portable GitHub Copilot CLI, VS Code and a private Nerd Font."
        log "Notepad++ is Windows-only; its menu action is available on Windows."
        log "Install an isolated Rust toolchain under $PD_ROOT/install/rust and rustup."
        log "Install WezTerm under $PD_ROOT/install (apps/WezTerm.app on macOS)."
        log "Custom prefixes can require compilation and can exceed 10 minutes." ;;
      windows)
        log "Install MSYS2 at $PD_ROOT/install/msys2; update it in two Bash processes."
        log "Install bash tmux git file and UCRT64 rust fzf through its pacman."
        log "Build Yazi with portable cache and state directory overrides."
        log "Download portable WezTerm and btop4win under $PD_ROOT/install."
        log "Add Yazi preview/search helpers, portable PowerShell 7, GitHub Copilot CLI, VS Code, Notepad++ and a private Nerd Font."
        log "Expose btop4win with the command btop." ;;
    esac
    log "Build $PD_REPO at ref $PD_REF into $PD_ROOT/install/rustifiedgit."
  fi
  log "Install official standalone Codex CLI into $PD_ROOT/install/codex."
  log "Keep Codex config, authentication and package state under $PD_ROOT/config/codex."
  if [ "$PD_ACTIVATE" -eq 1 ]; then
    log "Register $PD_ROOT/bin in Bash, Zsh, Fish and desktop user PATH settings."
    if [ "$PD_OS" = windows ]; then log "Also update the persistent Windows user PATH for PowerShell/CMD/apps."; fi
  else
    log "Leave profiles and persistent PATH unchanged; generate env-extra.sh, env-extra.fish and env-extra.ps1 for manual activation."
  fi
  exit 0
fi

if [ "$PD_OS" = windows ] && [ "${PD_MSYS2_READY:-}" != 1 ]; then
  have powershell.exe && have cygpath || die "Run install.ps1 from Windows PowerShell."
  pd_windows_args=()
  if [ "$PD_ONLY_CODEX" -eq 1 ]; then pd_windows_args+=(-OnlyCodex); fi
  if [ "$PD_ACTIVATE" -eq 1 ]; then pd_windows_args+=(-Activate); else pd_windows_args+=(-NoActivate); fi
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
    "$(cygpath -w "$PD_DIR/install.ps1")" -PlaygroundRoot "$(cygpath -w "$PD_ROOT")" \
    -RustifiedGitRef "$PD_REF" "${pd_windows_args[@]}"
fi

[ "${EUID:-$(id -u)}" -ne 0 ] || die "Run from your normal user account."
if [ "$PD_ONLY_CODEX" -ne 1 ]; then
  case "$PD_ROOT" in *[[:space:]]*) die "Homebrew/MSYS2 requires an install path without whitespace." ;; esac
fi
umask 077
mkdir -p "$PD_ROOT"
PD_ROOT="$(CDPATH= cd -- "$PD_ROOT" && pwd)"
PD_INSTALL="$PD_ROOT/install"
PD_BIN="$PD_ROOT/bin"
PD_BREW="$PD_INSTALL/homebrew"
mkdir -p "$PD_INSTALL" "$PD_BIN" "$PD_ROOT/config" "$PD_ROOT/state" "$PD_ROOT/cache" "$PD_ROOT/tmp"
export TMPDIR="$PD_ROOT/tmp"
PD_TEMP="$(mktemp -d "$PD_ROOT/tmp/install.XXXXXX")"
cleanup() { if [ -n "$PD_TEMP" ] && [ -d "$PD_TEMP" ]; then rm -rf -- "$PD_TEMP"; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "[playground] Failed at line %s. Fix the reported error and rerun.\n" "$LINENO" >&2' ERR
. "$PD_DIR/lib/environment.sh"
. "$PD_DIR/lib/rustifiedgit.sh"
. "$PD_DIR/lib/portable.sh"
. "$PD_DIR/lib/yazi.sh"
pd_write_environment

fetch() { curl --fail --location --show-error --retry 3 --connect-timeout 20 "$1" --output "$2"; }
pd_brew() {
  env -u HOMEBREW_PREFIX -u HOMEBREW_REPOSITORY -u HOMEBREW_CELLAR \
    HOMEBREW_CACHE="$PD_ROOT/cache/homebrew" HOMEBREW_LOGS="$PD_ROOT/state/homebrew-logs" \
    HOMEBREW_TEMP="$PD_ROOT/tmp/homebrew" HOMEBREW_NO_ANALYTICS=1 \
    "$PD_BREW/bin/brew" "$@"
}
install_unix_tools() {
  have git && have curl && have tar || die "Bootstrap requires existing git, curl and tar."
  mkdir -p "$PD_ROOT/tmp/homebrew"
  if [ ! -x "$PD_BREW/bin/brew" ]; then
    log "Creating isolated Homebrew in $PD_BREW (existing system Homebrew is not reused)."
    git clone --depth 1 https://github.com/Homebrew/brew.git "$PD_BREW"
  fi
  [ "$(pd_brew --prefix)" = "$PD_BREW" ] || die "Homebrew resolved outside playground."
  log "Installing tools into the playground Homebrew prefix."
  pd_brew install bash tmux yazi git file btop fzf ffmpeg sevenzip jq poppler fd ripgrep zoxide resvg imagemagick
  if [ "$PD_OS" = linux ]; then pd_brew install xclip wl-clipboard xdg-utils; fi
  if [ "$PD_OS" = macos ]; then
    mkdir -p "$PD_INSTALL/apps"
    pd_brew install --cask --appdir="$PD_INSTALL/apps" wezterm
    PD_WEZTERM="$PD_INSTALL/apps/WezTerm.app/Contents/MacOS/wezterm"
  else
    pd_brew install wezterm/wezterm-linuxbrew/wezterm
    PD_WEZTERM="$PD_BREW/bin/wezterm"
  fi
  PD_TOOL_BIN="$PD_BREW/bin"
  export PATH="$PD_TOOL_BIN:$PATH"
}
install_windows_tools() {
  [ -x /usr/bin/pacman.exe ] || die "Use install.ps1 to initialize MSYS2."
  [ "$(uname -m)" = x86_64 ] || die "The MSYS2 package set requires x64."
  /usr/bin/pacman -S --needed --noconfirm bash tmux git file \
    mingw-w64-ucrt-x86_64-rust mingw-w64-ucrt-x86_64-fzf \
    mingw-w64-ucrt-x86_64-ffmpeg mingw-w64-ucrt-x86_64-7zip mingw-w64-ucrt-x86_64-jq \
    mingw-w64-ucrt-x86_64-poppler mingw-w64-ucrt-x86_64-fd mingw-w64-ucrt-x86_64-ripgrep \
    mingw-w64-ucrt-x86_64-zoxide mingw-w64-ucrt-x86_64-resvg mingw-w64-ucrt-x86_64-imagemagick
  export PATH="/ucrt64/bin:/usr/bin:$PATH"
  PD_WEZTERM="$(cygpath -u "$PD_WEZTERM_EXE")"
  PD_BTOP="$(cygpath -u "$PD_BTOP_EXE")"
  PD_TOOL_BIN="$PD_INSTALL/msys2/ucrt64/bin"
  PD_COPILOT="$(cygpath -u "$PD_COPILOT_EXE")"
  PD_CODE="$(cygpath -u "$PD_CODE_EXE")"
  PD_NOTEPAD="$(cygpath -u "$PD_NOTEPAD_EXE")"
  PD_PWSH="$(cygpath -u "$PD_PWSH_EXE")"
}
install_codex() {
  if [ "$PD_OS" = windows ]; then
    [ -x "$PD_INSTALL/codex/bin/codex.exe" ] || die "Run install.ps1 to install native Codex."
  else
    have curl || die "curl is required to download Codex."
    pd_codex_packages
    fetch https://chatgpt.com/codex/install.sh "$PD_TEMP/codex-install.sh"
    # CODEX_HOME is deliberately scoped to this Codex installation only.
    # Hide other Codex commands from the delegated installer so its conflict
    # handling cannot add shell hooks or touch an existing package installation.
    local pd_codex_path="$PD_INSTALL/codex/bin" pd_path_entry pd_saved_ifs="$IFS"
    IFS=:
    for pd_path_entry in $PATH; do
      if [ -n "$pd_path_entry" ] && [ "$pd_path_entry" != "$PD_INSTALL/codex/bin" ] && [ ! -x "$pd_path_entry/codex" ]; then
        pd_codex_path="$pd_codex_path:$pd_path_entry"
      fi
    done
    IFS="$pd_saved_ifs"
    PATH="$pd_codex_path" \
      CODEX_HOME="$PD_ROOT/config/codex" CODEX_INSTALL_DIR="$PD_INSTALL/codex/bin" \
      CODEX_NON_INTERACTIVE=1 sh "$PD_TEMP/codex-install.sh"
  fi
}
register_command() {
  local pd_name="$1" pd_target="$2"
  [ -x "$pd_target" ] || die "Installed executable not found: $pd_target."
  pd_write_launcher "$pd_name" "$pd_target"
  if [ "$PD_OS" = windows ]; then
    printf '%s\t%s\n' "$pd_name" "$(cygpath -w "$pd_target")" >> "$PD_ROOT/state/windows-commands.tsv"
  fi
}

if [ "$PD_ONLY_CODEX" -ne 1 ]; then
  case "$PD_OS" in macos|linux) install_unix_tools ;; windows) install_windows_tools ;; esac
  if [ "$PD_OS" != windows ]; then install_portable_unix_tools; fi
  install_rustifiedgit
  if [ "$PD_OS" = windows ]; then install_portable_yazi_windows; fi
fi
install_codex
if [ "$PD_OS" = windows ]; then
  : > "$PD_ROOT/state/windows-commands.tsv"
  register_command codex "$PD_INSTALL/codex/bin/codex.exe"
else
  register_command codex "$PD_INSTALL/codex/bin/codex"
fi
if [ "$PD_ONLY_CODEX" -ne 1 ]; then
  if [ "$PD_OS" = windows ]; then
    register_command bash "$PD_INSTALL/msys2/usr/bin/bash.exe"
    register_command tmux "$PD_INSTALL/msys2/usr/bin/tmux.exe"
    register_command git "$PD_INSTALL/msys2/usr/bin/git.exe"
    for pd_cmd in yazi ya; do register_command "$pd_cmd" "$PD_INSTALL/yazi/bin/$pd_cmd.exe"; done
    register_command fzf "$PD_INSTALL/msys2/ucrt64/bin/fzf.exe"
    register_command btop "$PD_BTOP"
    register_command rustifiedgit "$PD_INSTALL/rustifiedgit/bin/rustifiedgit.exe"
  else
    for pd_cmd in bash tmux yazi ya git btop fzf; do register_command "$pd_cmd" "$PD_TOOL_BIN/$pd_cmd"; done
    register_command rustifiedgit "$PD_INSTALL/rustifiedgit/bin/rustifiedgit"
  fi
  register_command wezterm "$PD_WEZTERM"
  register_command copilot "$PD_COPILOT"
  register_command code "$PD_CODE"
  if [ "$PD_OS" = windows ]; then
    register_command notepad++ "$PD_NOTEPAD"
    register_command pwsh "$PD_PWSH"
  fi
  for pd_cmd in file ffmpeg ffprobe 7z 7zz jq pdftoppm pdftotext pdfinfo fd rg zoxide resvg magick xclip wl-copy wl-paste xdg-open; do
    pd_suffix=""; if [ "$PD_OS" = windows ]; then pd_suffix=.exe; fi
    if [ -x "$PD_TOOL_BIN/$pd_cmd$pd_suffix" ]; then register_command "$pd_cmd" "$PD_TOOL_BIN/$pd_cmd$pd_suffix";
    elif [ "$PD_OS" = windows ] && [ "$pd_cmd" = file ]; then register_command file "$PD_INSTALL/msys2/usr/bin/file.exe"; fi
  done
  for pd_config in keymap.toml yazi.toml; do
    if [ ! -e "$PD_ROOT/config/yazi/$pd_config" ]; then cp "$PD_DIR/yazi/$pd_config" "$PD_ROOT/config/yazi/$pd_config"; fi
  done
  if [ ! -e "$PD_ROOT/config/wezterm/wezterm.lua" ]; then cp "$PD_DIR/wezterm.lua" "$PD_ROOT/config/wezterm/wezterm.lua"; fi
fi
if [ "$PD_ACTIVATE" -eq 1 ]; then pd_register_path; fi
"$PD_BIN/codex" --version
if [ "$PD_ACTIVATE" -eq 1 ]; then
  log "Ready. Restart existing terminals/apps to inherit $PD_BIN."
else
  log "Ready. Load extra tools in Bash/Zsh with: . \"$PD_ROOT/config/shell/env-extra.sh\""
fi
if [ "$PD_ONLY_CODEX" -ne 1 ]; then
  for pd_cmd in bash tmux yazi rustifiedgit fzf btop wezterm copilot code; do log "$pd_cmd -> $PD_BIN/$pd_cmd"; done
fi
