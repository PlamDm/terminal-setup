#!/usr/bin/env bash
# User-owned terminal tools for macOS, Linux and native Windows.
set -euo pipefail
PD_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PD_ROOT="$(pwd -P)"
PD_ROOT_EXPLICIT=0
PD_USER_HOME="${PD_USER_HOME:-$HOME}"
PD_REPO="https://github.com/PlamDm/RustifiedGit.git"
PD_REF="7a2be2ebfa45cfc5be78e788a820ee145953f36b"
PD_DRY_RUN=0
PD_ONLY_CODEX=0
PD_ACTIVATE=0
PD_INTERACTIVE=0
PD_USE_EXISTING_MSYS2=0
PD_MSYS2_READ_ONLY=0
PD_MSYS2_ROOT_ARG=""
PD_MSYS2_SEARCH_PATH_ARG=""
PD_PREVIEW_OS=""
PD_TEMP=""
PD_PACKAGE_DIR=""
PD_OFFLINE=0
PD_DOWNLOAD_ONLY=0
PD_TOOLS_EXPLICIT=0
PD_SELECTION_MODE="${PD_SELECTION_MODE:-all}"
PD_SELECTED_TOOLS="${PD_SELECTED_TOOLS:-}"

log() { printf '[playground] %s\n' "$*"; }
die() { printf '[playground] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
fetch() { curl --fail --location --show-error --retry 3 --connect-timeout 20 "$1" --output "$2"; }
pd_selected() {
  local pd_id="$1"
  if [ "$PD_ONLY_CODEX" -eq 1 ]; then
    [ "$pd_id" = codex ]
    return
  fi
  [ "$PD_SELECTION_MODE" = explicit ] || return 0
  case ",$PD_SELECTED_TOOLS," in *,"$pd_id",*) return 0 ;; esac
  return 1
}
usage() {
  cat <<'EOF'
Usage: bash install.sh [options]

Install terminal tools, Yazi helpers, Copilot CLI, VS Code and portable editors.
Default layout: the invocation directory/{install,bin,templates,config,state,cache,tmp}.
By default, leaves profiles and persistent PATH unchanged. Source env-extra.sh.

  --interactive         Choose install folder and tools in an interactive menu.
  --tools LIST         Select comma-separated tool IDs without an interactive menu.
  --package-dir DIR    Read verified archives from a local offline bundle.
  --offline            Never download; missing or corrupted packages fail explicitly.
  --download-only      Prepare a verified archive bundle without installing tools.
  --dry-run            Preview without downloads or filesystem changes.
  --only-codex         Install only the managed Codex CLI.
  --no-activate        Install without changing profiles or persistent PATH.
  --activate           Opt in to shell hooks and desktop user PATH registration.
  --root DIR           Choose another absolute playground directory.
  --use-existing-msys2 Reuse MSYS2; install missing packages without changing installed packages.
  --msys2-read-only    Reuse installed MSYS2 packages only; fail for unavailable selections.
  --msys2-root DIR     Select an existing MSYS2 root on Windows.
  --msys2-search-path DIR  Search this folder and its subfolders for MSYS2.
  --rustifiedgit-ref REF    Compatibility option; only the reviewed locked ref is allowed.
  --platform OS        Preview macos, linux or windows; requires --dry-run.
  -h, --help           Show help.

Windows: use install.ps1, or run this from an existing MSYS2/Git Bash.
macOS/Linux: verified binary packages and their dependencies stay under install/conda.
EOF
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --interactive) PD_INTERACTIVE=1; shift ;;
    --offline) PD_OFFLINE=1; shift ;;
    --download-only) PD_DOWNLOAD_ONLY=1; shift ;;
    --dry-run) PD_DRY_RUN=1; shift ;;
    --only-codex) PD_ONLY_CODEX=1; shift ;;
    --no-activate) PD_ACTIVATE=0; shift ;;
    --activate) PD_ACTIVATE=1; shift ;;
    --use-existing-msys2) PD_USE_EXISTING_MSYS2=1; shift ;;
    --msys2-read-only) PD_MSYS2_READ_ONLY=1; shift ;;
    --root|--tools|--package-dir|--msys2-root|--msys2-search-path|--rustifiedgit-ref|--platform)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "Missing value for $1."
      case "$1" in
        --root) PD_ROOT="$2"; PD_ROOT_EXPLICIT=1 ;;
        --tools) PD_SELECTED_TOOLS="$2"; PD_SELECTION_MODE=explicit; PD_TOOLS_EXPLICIT=1 ;;
        --package-dir) PD_PACKAGE_DIR="$2" ;;
        --msys2-root) PD_MSYS2_ROOT_ARG="$2" ;;
        --msys2-search-path) PD_MSYS2_SEARCH_PATH_ARG="$2" ;;
        --rustifiedgit-ref) PD_REF="$2" ;;
        --platform) PD_PREVIEW_OS="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help." ;;
  esac
done
[ "$PD_ONLY_CODEX" -ne 1 ] || [ "$PD_TOOLS_EXPLICIT" -ne 1 ] || die "Choose --only-codex or --tools, not both."
[ "$PD_INTERACTIVE" -ne 1 ] || [ "$PD_TOOLS_EXPLICIT" -ne 1 ] || die "Choose --interactive or --tools, not both."
[ "$PD_DOWNLOAD_ONLY" -ne 1 ] || [ "$PD_INTERACTIVE" -ne 1 ] || die "Use --tools, not --interactive, to select an offline bundle."
[[ "$PD_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "Invalid RustifiedGit ref."
[ "$PD_REF" = 7a2be2ebfa45cfc5be78e788a820ee145953f36b ] || die "Source overrides require a reviewed locked package recipe."
[ "$PD_DRY_RUN" -eq 1 ] || [ -z "$PD_PREVIEW_OS" ] || die "--platform requires --dry-run."
case "$PD_ROOT" in /*) ;; *) die "--root must be an absolute path." ;; esac
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
case "$PD_ROOT" in
  /|*:*|*$'\n'*|*$'\r'*) die "Choose a dedicated playground directory." ;;
  "$HOME") [ "$PD_OS" = windows ] || die "Choose a dedicated playground directory." ;;
esac
if [ "$PD_SELECTION_MODE" = explicit ]; then
  [ -n "$PD_SELECTED_TOOLS" ] || die "--tools must select at least one tool."
  pd_selection="$PD_SELECTED_TOOLS"
  while [ -n "$pd_selection" ]; do
    pd_id="${pd_selection%%,*}"
    [ -n "$pd_id" ] || die "Empty tool ID in --tools."
    awk -F '\t' -v id="$pd_id" -v os="$PD_OS" '$1 == id && index("," $3 ",", "," os ",") { found = 1 } END { exit !found }' \
      "$PD_DIR/lib/interactive-tools.tsv" || die "Unsupported tool selection: $pd_id on $PD_OS."
    case "$pd_selection" in *,*) pd_selection="${pd_selection#*,}"; [ -n "$pd_selection" ] || die "Empty tool ID in --tools." ;; *) break ;; esac
  done
  if [ "$PD_OS" = windows ] && pd_selected copilot && ! pd_selected pwsh; then PD_SELECTED_TOOLS="$PD_SELECTED_TOOLS,pwsh"; fi
fi
if [ "$PD_MSYS2_READ_ONLY" -eq 1 ] && [ "$PD_OS" != windows ]; then
  die "--msys2-read-only is only available on Windows."
fi

if [ "$PD_DRY_RUN" -eq 1 ]; then
  log "Preview only; no downloads or changes."
  log "Root: $PD_ROOT"
  log "Installations: $PD_ROOT/install; commands: $PD_ROOT/bin; configuration: $PD_ROOT/config."
  if [ "$PD_SELECTION_MODE" = explicit ]; then log "Selected tools: $PD_SELECTED_TOOLS"
  elif [ "$PD_ONLY_CODEX" -eq 1 ]; then log "Selected tools: codex"
  elif [ "$PD_INTERACTIVE" -eq 1 ]; then
    log "Interactive selection is required; no tools have been selected yet."
  else
    pd_catalog_tools="$(awk -F '\t' -v os="$PD_OS" '$1 !~ /^#/ && index("," $3 ",", "," os ",") { printf "%s%s", separator, $1; separator = "," }' \
      "$PD_DIR/lib/interactive-tools.tsv")"
    log "Selected tools: $pd_catalog_tools"
  fi
  if [ "$PD_OS" = windows ]; then
    log "Windows downloads use native HTTPS trust and pinned package hashes."
    log "The default MSYS2 runtime and all managed configuration stay under the root."
    if [ "$PD_MSYS2_READ_ONLY" -eq 1 ]; then
      log "Read-only reuse fails explicitly for selected tools missing from the existing MSYS2 runtime."
    fi
  else
    log "Unix packages and dependencies use pinned hashes under $PD_ROOT/install/conda."
  fi
  if [ "$PD_ONLY_CODEX" -eq 1 ] || pd_selected codex; then
    log "Codex configuration and state stay under $PD_ROOT/config/codex."
  fi
  if [ "$PD_ACTIVATE" -eq 1 ]; then
    log "Opt in to registering $PD_ROOT/bin in supported shell PATH settings."
    if [ "$PD_OS" = windows ]; then log "Also update the persistent Windows user PATH for PowerShell/CMD/apps."; fi
  else
    log "Leave profiles and persistent PATH unchanged."
  fi
  exit 0
fi

if [ "$PD_OS" = windows ] && { [ "${PD_MSYS2_READY:-}" != 1 ] || [ "$PD_INTERACTIVE" -eq 1 ]; }; then
  have powershell.exe && have cygpath || die "Run install.ps1 from Windows PowerShell."
  pd_windows_args=()
  if [ "$PD_ONLY_CODEX" -eq 1 ]; then pd_windows_args+=(-OnlyCodex); fi
  if [ "$PD_INTERACTIVE" -eq 1 ]; then pd_windows_args+=(-Interactive); fi
  if [ "$PD_ACTIVATE" -eq 1 ]; then pd_windows_args+=(-Activate); else pd_windows_args+=(-NoActivate); fi
  if [ "$PD_USE_EXISTING_MSYS2" -eq 1 ]; then pd_windows_args+=(-UseExistingMsys2); fi
  if [ "$PD_MSYS2_READ_ONLY" -eq 1 ]; then pd_windows_args+=(-Msys2ReadOnly); fi
  if [ "$PD_SELECTION_MODE" = explicit ]; then pd_windows_args+=(-Tools "$PD_SELECTED_TOOLS"); fi
  if [ "$PD_OFFLINE" -eq 1 ]; then pd_windows_args+=(-Offline); fi
  if [ "$PD_DOWNLOAD_ONLY" -eq 1 ]; then pd_windows_args+=(-DownloadOnly); fi
  if [ -n "$PD_PACKAGE_DIR" ]; then pd_windows_args+=(-PackageDirectory "$(cygpath -w "$PD_PACKAGE_DIR")"); fi
  if [ -n "$PD_MSYS2_ROOT_ARG" ]; then
    pd_windows_args+=(-Msys2Root "$(cygpath -w "$PD_MSYS2_ROOT_ARG")")
  fi
  if [ -n "$PD_MSYS2_SEARCH_PATH_ARG" ]; then
    pd_windows_args+=(-Msys2SearchPath "$(cygpath -w "$PD_MSYS2_SEARCH_PATH_ARG")")
  fi
  exec powershell.exe -NoProfile -NonInteractive -File \
    "$(cygpath -w "$PD_DIR/install.ps1")" -PlaygroundRoot "$(cygpath -w "$PD_ROOT")" \
    -RustifiedGitRef "$PD_REF" "${pd_windows_args[@]}"
fi

if [ "$PD_INTERACTIVE" -eq 1 ]; then
  . "$PD_DIR/lib/interactive.sh"
  trap 'pd_tui_restore 2>/dev/null || true' EXIT
  trap 'pd_tui_restore 2>/dev/null || true; exit 130' INT
  trap 'pd_tui_restore 2>/dev/null || true; exit 143' TERM
  PD_INSTALL="$PD_ROOT/install"
  PD_BIN="$PD_ROOT/bin"
  if [ "$PD_SELECTION_MODE" != explicit ]; then
    pd_choose_install_directory "$PD_ROOT" || exit 0
    case "$PD_ROOT" in /*) ;; *) die "The selected install folder must be an absolute path." ;; esac
    case "$PD_ROOT" in /|"$HOME"|*:*|*$'\n'*|*$'\r'*) die "Choose a dedicated playground directory." ;; esac
    PD_INSTALL="$PD_ROOT/install"
    PD_BIN="$PD_ROOT/bin"
    pd_show_tool_menu || exit 0
  fi
  if [ -z "$PD_SELECTED_TOOLS" ] && [ "$PD_SELECTION_MODE" = explicit ]; then
    log "No tools selected; nothing was installed."
    exit 0
  fi
fi

PD_INSTALL="$PD_ROOT/install"
PD_BIN="$PD_ROOT/bin"
. "$PD_DIR/lib/environment.sh"
. "$PD_DIR/lib/rustifiedgit.sh"
. "$PD_DIR/lib/portable.sh"
. "$PD_DIR/lib/yazi.sh"
. "$PD_DIR/lib/msys2.sh"
if [ "$PD_OS" != windows ]; then
  . "$PD_DIR/lib/unix.sh"
  pd_unix_preflight
fi
[ "${EUID:-$(id -u)}" -ne 0 ] || die "Run from your normal user account."
if [ "$PD_ONLY_CODEX" -ne 1 ]; then
  if [ "$PD_OS" = windows ]; then
    case "$PD_ROOT" in *[[:space:]]*) die "MSYS2 requires an install path without whitespace." ;; esac
  fi
fi
umask 077
mkdir -p "$PD_ROOT"
PD_ROOT="$(CDPATH= cd -- "$PD_ROOT" && pwd)"
PD_INSTALL="$PD_ROOT/install"
PD_BIN="$PD_ROOT/bin"
if [ "$PD_OS" = windows ]; then
  PD_MSYS2_ROOT="$PD_MSYS2_ROOT_ARG"
  [ -n "$PD_MSYS2_ROOT" ] || PD_MSYS2_ROOT="$PD_INSTALL/msys2"
  case "$PD_MSYS2_ROOT" in *[[:space:]]*) die "MSYS2 requires a path without whitespace." ;; esac
  [ -x "${PD_MSYS2_ROOT%/}/usr/bin/bash.exe" ] || die "MSYS2 was not found at $PD_MSYS2_ROOT."
fi
mkdir -p "$PD_INSTALL" "$PD_BIN" "$PD_ROOT/config" "$PD_ROOT/state" "$PD_ROOT/cache" "$PD_ROOT/tmp"
export TMPDIR="$PD_ROOT/tmp"
PD_TEMP="$(mktemp -d "$PD_ROOT/tmp/install.XXXXXX")"
cleanup() {
  if type pd_tui_restore >/dev/null 2>&1; then pd_tui_restore 2>/dev/null || true; fi
  if [ -n "$PD_TEMP" ] && [ -d "$PD_TEMP" ]; then rm -rf -- "$PD_TEMP"; fi
}
trap cleanup EXIT
trap 'pd_tui_restore 2>/dev/null || true; exit 130' INT
trap 'pd_tui_restore 2>/dev/null || true; exit 143' TERM
trap 'printf "[playground] Failed at line %s. Fix the reported error and rerun.\n" "$LINENO" >&2' ERR
if [ "$PD_DOWNLOAD_ONLY" -ne 1 ]; then pd_write_environment; fi
if [ "$PD_OS" != windows ] && [ "$PD_DOWNLOAD_ONLY" -ne 1 ] && [ "$PD_ROOT" != "$PD_DIR" ]; then
  for pd_file in install.sh install.ps1 wezterm.lua; do
    if [ ! -e "$PD_ROOT/$pd_file" ] && [ ! -L "$PD_ROOT/$pd_file" ]; then cp "$PD_DIR/$pd_file" "$PD_ROOT/$pd_file"; fi
  done
  for pd_directory in lib packages patches yazi; do
    while IFS= read -r -d '' pd_file; do
      pd_destination="$PD_ROOT/$pd_directory/${pd_file#"$PD_DIR/$pd_directory/"}"
      if [ ! -e "$pd_destination" ] && [ ! -L "$pd_destination" ]; then
        mkdir -p "$(dirname "$pd_destination")"
        cp "$pd_file" "$pd_destination"
      fi
    done < <(find "$PD_DIR/$pd_directory" -type f -print0)
  done
fi
pd_wants_unix_tools() {
  local pd_id
  for pd_id in bash git tmux yazi btop fzf; do
    pd_selected "$pd_id" && return 0
  done
  return 1
}
install_windows_tools() {
  [ -x /usr/bin/pacman.exe ] || die "Use install.ps1 to initialize MSYS2."
  [ "$(uname -m)" = x86_64 ] || die "The MSYS2 package set requires x64."
  if [ "$PD_MSYS2_READ_ONLY" -eq 1 ]; then
    log "Using installed MSYS2 packages as-is; selected unavailable tools will fail."
  else
    [ "${PD_MSYS2_PACKAGES_READY:-0}" = 1 ] || die "Use install.ps1 to prepare hash-locked MSYS2 dependencies."
  fi
  export PATH="/ucrt64/bin:/usr/bin:$PATH"
  PD_TOOL_BIN="${PD_MSYS2_ROOT%/}/ucrt64/bin"
  PD_WEZTERM=""; PD_BTOP=""; PD_COPILOT=""; PD_CODE=""; PD_NOTEPAD=""; PD_PWSH=""
  if pd_selected wezterm; then
    [ -n "${PD_WEZTERM_EXE:-}" ] || die "WezTerm was selected but its executable path was not provided."
    PD_WEZTERM="$(cygpath -u -U "$PD_WEZTERM_EXE")"
  fi
  if pd_selected btop; then
    [ -n "${PD_BTOP_EXE:-}" ] || die "btop was selected but its executable path was not provided."
    PD_BTOP="$(cygpath -u -U "$PD_BTOP_EXE")"
  fi
  if pd_selected copilot; then
    [ -n "${PD_COPILOT_EXE:-}" ] || die "Copilot CLI was selected but its executable path was not provided."
    PD_COPILOT="$(cygpath -u -U "$PD_COPILOT_EXE")"
  fi
  if pd_selected vscode; then
    [ -n "${PD_CODE_EXE:-}" ] || die "VS Code was selected but its executable path was not provided."
    PD_CODE="$(cygpath -u -U "$PD_CODE_EXE")"
  fi
  if pd_selected notepadpp; then
    [ -n "${PD_NOTEPAD_EXE:-}" ] || die "Notepad++ was selected but its executable path was not provided."
    PD_NOTEPAD="$(cygpath -u -U "$PD_NOTEPAD_EXE")"
  fi
  if pd_selected pwsh; then
    [ -n "${PD_PWSH_EXE:-}" ] || die "PowerShell 7 was selected but its executable path was not provided."
    PD_PWSH="$(cygpath -u -U "$PD_PWSH_EXE")"
  fi
}
install_codex() {
  if [ "$PD_OS" = windows ]; then
    [ -x "$PD_INSTALL/codex/bin/codex.exe" ] || die "Run install.ps1 to install native Codex."
  else
    install_portable_codex_unix
  fi
}
register_command() {
  local pd_name="$1" pd_target="$2"
  [ -x "$pd_target" ] || die "Installed executable not found: $pd_target."
  pd_write_launcher "$pd_name" "$pd_target"
  if [ "$PD_OS" = windows ]; then
    case "$pd_target" in
      "$PD_ROOT"/*) pd_manifest_target="${pd_target#"$PD_ROOT"/}" ;;
      *) pd_manifest_target="$(cygpath -w "$pd_target")" ;;
    esac
    printf '%s\t%s\n' "$pd_name" "$pd_manifest_target" >> "$PD_TEMP/windows-commands.tsv"
  fi
}
unregister_command() {
  local pd_name="$1" pd_launcher="$PD_BIN/$1"
  if [ -f "$pd_launcher" ] && grep -Fq '# Managed playground launcher.' "$pd_launcher"; then
    rm -f -- "$pd_launcher"
  fi
  if [ "$PD_OS" = windows ] && [ -f "$PD_TEMP/windows-commands.previous.tsv" ] &&
      awk -F '\t' -v name="$pd_name" '$1 == name { found = 1 } END { exit !found }' \
        "$PD_TEMP/windows-commands.previous.tsv"; then
    rm -f -- "$PD_BIN/$pd_name.cmd"
  fi
}
register_available_command() {
  local pd_name="$1" pd_target="$2"
  if [ -x "$pd_target" ]; then
    register_command "$pd_name" "$pd_target"
  elif [ "$PD_MSYS2_READ_ONLY" -eq 1 ]; then
    die "Selected command '$pd_name' is unavailable in read-only MSYS2."
  else
    register_command "$pd_name" "$pd_target"
  fi
}

pd_windows_command_selected() {
  case "$1" in
    bash|git|tmux|fzf|yazi|rustifiedgit|wezterm|btop|codex|copilot)
      pd_selected "$1" ;;
    ya|file|ffmpeg|ffprobe|7z|7zz|jq|pdftoppm|pdftotext|pdfinfo|fd|rg|zoxide|resvg|magick|xclip|wl-copy|wl-paste|gio)
      pd_selected yazi ;;
    code) pd_selected vscode ;;
    'notepad++') pd_selected notepadpp ;;
    pwsh) pd_selected pwsh ;;
    *) return 1 ;;
  esac
}

if [ "$PD_OS" = windows ]; then
  if [ "$PD_ONLY_CODEX" -ne 1 ]; then install_windows_tools; fi
elif pd_wants_unix_tools; then
  install_unix_tools
else
  PD_TOOL_BIN="$PD_INSTALL/conda/bin"
fi
if [ "$PD_OS" != windows ] &&
    { pd_selected copilot || pd_selected vscode || pd_selected wezterm; }; then
  install_portable_unix_tools
fi
if pd_selected rustifiedgit; then
  if [ "$PD_OS" = windows ]; then install_rustifiedgit; else install_portable_rustifiedgit_unix; fi
fi
if [ "$PD_OS" = windows ] && pd_selected yazi; then install_portable_yazi_windows; fi
if pd_selected codex; then install_codex; fi
if [ "$PD_DOWNLOAD_ONLY" -eq 1 ]; then
  log "Verified offline bundle is ready in $PD_ROOT/cache; no selected tools or profiles were installed."
  exit 0
fi

if [ "$PD_OS" = windows ]; then
  if [ -f "$PD_ROOT/state/windows-commands.tsv" ]; then
    cp "$PD_ROOT/state/windows-commands.tsv" "$PD_TEMP/windows-commands.previous.tsv"
  fi
  if [ "$PD_SELECTION_MODE" = explicit ] || [ "$PD_ONLY_CODEX" -eq 1 ]; then
    : > "$PD_TEMP/windows-commands.tsv"
    if [ -f "$PD_TEMP/windows-commands.previous.tsv" ]; then
      while IFS=$'\t' read -r pd_name pd_target; do
        [ -n "$pd_name" ] || continue
        if ! pd_windows_command_selected "$pd_name"; then
          printf '%s\t%s\n' "$pd_name" "$pd_target" >> "$PD_TEMP/windows-commands.tsv"
        fi
      done < "$PD_TEMP/windows-commands.previous.tsv"
    fi
  else
    : > "$PD_TEMP/windows-commands.tsv"
  fi
fi
if pd_selected codex; then
  if [ "$PD_OS" = windows ]; then
    register_command codex "$PD_INSTALL/codex/bin/codex.exe"
  else
    register_command codex "$PD_INSTALL/codex/bin/codex"
  fi
fi
if [ "$PD_OS" = windows ]; then
  if pd_selected bash; then register_command bash "${PD_MSYS2_ROOT%/}/usr/bin/bash.exe"; fi
  if pd_selected tmux; then register_available_command tmux "${PD_MSYS2_ROOT%/}/usr/bin/tmux.exe"; fi
  if pd_selected git; then register_available_command git "${PD_MSYS2_ROOT%/}/usr/bin/git.exe"; fi
  if pd_selected yazi; then
    for pd_cmd in yazi ya; do register_available_command "$pd_cmd" "$PD_INSTALL/yazi/bin/$pd_cmd.exe"; done
  fi
  if pd_selected fzf; then register_available_command fzf "${PD_MSYS2_ROOT%/}/ucrt64/bin/fzf.exe"; fi
  if pd_selected btop; then register_command btop "$PD_BTOP"; fi
  if pd_selected rustifiedgit; then register_available_command rustifiedgit "$PD_INSTALL/rustifiedgit/bin/rustifiedgit.exe"; fi
  if pd_selected copilot; then register_command copilot "$PD_COPILOT"; fi
  if pd_selected vscode; then register_command code "$PD_CODE"; fi
  if pd_selected notepadpp; then register_command 'notepad++' "$PD_NOTEPAD"; fi
  if pd_selected pwsh; then register_command pwsh "$PD_PWSH"; fi
else
  for pd_cmd in bash tmux yazi ya git btop fzf; do
    pd_id="$pd_cmd"
    [ "$pd_cmd" != ya ] || pd_id=yazi
    if pd_selected "$pd_id"; then register_command "$pd_cmd" "$PD_TOOL_BIN/$pd_cmd"; fi
  done
  if pd_selected rustifiedgit; then register_command rustifiedgit "$PD_INSTALL/rustifiedgit/bin/rustifiedgit"; fi
  if pd_selected wezterm; then register_command wezterm "$PD_WEZTERM"; fi
  if pd_selected copilot; then register_command copilot "$PD_COPILOT"; fi
  if pd_selected vscode; then register_command code "$PD_CODE"; fi
fi
if pd_selected wezterm && [ "$PD_OS" = windows ]; then
  register_command wezterm "$PD_WEZTERM"
fi
if pd_selected yazi; then
  if [ "$PD_OS" = windows ] && [ ! -x "$PD_TOOL_BIN/7z.exe" ] && [ ! -x "$PD_TOOL_BIN/7zz.exe" ]; then
    die "Selected Yazi helper '7-Zip' is unavailable."
  fi
  for pd_cmd in file ffmpeg ffprobe 7z 7zz jq pdftoppm pdftotext pdfinfo fd rg zoxide resvg magick xclip wl-copy wl-paste gio; do
    pd_suffix=""; if [ "$PD_OS" = windows ]; then pd_suffix=.exe; fi
    if [ -x "$PD_TOOL_BIN/$pd_cmd$pd_suffix" ]; then register_command "$pd_cmd" "$PD_TOOL_BIN/$pd_cmd$pd_suffix";
    elif [ "$PD_OS" = windows ] && [ "$pd_cmd" = file ]; then register_available_command file "${PD_MSYS2_ROOT%/}/usr/bin/file.exe"
    elif [ "$PD_OS" = windows ]; then
      case "$pd_cmd" in
        ffmpeg|ffprobe|jq|pdftoppm|pdftotext|pdfinfo|fd|rg|zoxide|resvg|magick)
          register_available_command "$pd_cmd" "$PD_TOOL_BIN/$pd_cmd.exe" ;;
      esac
    fi
  done
  for pd_config in keymap.toml yazi.toml; do
    if [ ! -e "$PD_ROOT/config/yazi/$pd_config" ]; then cp "$PD_DIR/yazi/$pd_config" "$PD_ROOT/config/yazi/$pd_config"; fi
  done
fi
if pd_selected wezterm && [ ! -e "$PD_ROOT/config/wezterm/wezterm.lua" ]; then
  cp "$PD_DIR/wezterm.lua" "$PD_ROOT/config/wezterm/wezterm.lua"
fi
if [ "$PD_OS" = windows ]; then mv "$PD_TEMP/windows-commands.tsv" "$PD_ROOT/state/windows-commands.tsv"; fi
if [ "$PD_ACTIVATE" -eq 1 ]; then pd_register_path; fi
if pd_selected codex; then "$PD_BIN/codex" --version; fi
if [ "$PD_ACTIVATE" -eq 1 ]; then
  log "Ready. Restart existing terminals/apps to inherit $PD_BIN."
else
  log "Ready. Load extra tools in Bash/Zsh with: . \"$PD_ROOT/config/shell/env-extra.sh\""
fi
if [ "$PD_ONLY_CODEX" -ne 1 ]; then
  for pd_cmd in bash tmux yazi rustifiedgit fzf btop wezterm copilot code; do
    if [ -x "$PD_BIN/$pd_cmd" ]; then log "$pd_cmd -> $PD_BIN/$pd_cmd"; fi
  done
fi
