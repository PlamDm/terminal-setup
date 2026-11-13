PD_TUI_ACTIVE=0
PD_TUI_STTY=""
PD_TUI_KEY=""
PD_SELECTED_TOOLS="${PD_SELECTED_TOOLS:-}"

pd_tui_restore() {
  if [ "${PD_TUI_ACTIVE:-0}" -eq 1 ]; then
    stty "$PD_TUI_STTY" < /dev/tty
    PD_TUI_ACTIVE=0
  fi
}

pd_tui_start() {
  [ -t 0 ] && [ -t 1 ] && [ -r /dev/tty ] || return 1
  PD_TUI_STTY="$(stty -g < /dev/tty)" || return 1
  PD_TUI_ACTIVE=1
  if ! stty -echo -icanon min 1 time 0 < /dev/tty; then
    pd_tui_restore || true
    return 1
  fi
}

pd_tui_clear() {
  printf '\033[2J\033[H'
}

pd_tui_read_key() {
  local pd_first pd_sequence
  IFS= read -r -s -n 1 pd_first < /dev/tty || return 1
  case "$pd_first" in
    $'\033')
      pd_sequence=""
      IFS= read -r -s -n 2 -t 0.1 pd_sequence < /dev/tty || true
      case "$pd_sequence" in
        '[A') PD_TUI_KEY=up ;;
        '[B') PD_TUI_KEY=down ;;
        *) PD_TUI_KEY=escape ;;
      esac ;;
    $'\r'|$'\n') PD_TUI_KEY=enter ;;
    ' ') PD_TUI_KEY=space ;;
    $'\177'|$'\b') PD_TUI_KEY=back ;;
    *) PD_TUI_KEY="$pd_first" ;;
  esac
}

pd_tool_command() {
  case "$1" in
    bash) printf 'bash\n' ;;
    git) printf 'git\n' ;;
    tmux) printf 'tmux\n' ;;
    fzf) printf 'fzf\n' ;;
    yazi) printf 'yazi\n' ;;
    rustifiedgit) printf 'rustifiedgit\n' ;;
    wezterm) printf 'wezterm\n' ;;
    btop) printf 'btop\n' ;;
    codex) printf 'codex\n' ;;
    copilot) printf 'copilot\n' ;;
    vscode) printf 'code\n' ;;
    *) return 1 ;;
  esac
}

pd_tool_managed() {
  local pd_id="$1" pd_command pd_path
  pd_command="$(pd_tool_command "$pd_id" 2>/dev/null || true)"
  if [ -n "$pd_command" ] && [ -f "$PD_BIN/$pd_command" ] &&
      grep -Fq '# Managed playground launcher.' "$PD_BIN/$pd_command"; then
    return 0
  fi
  case "$pd_id" in
    bash|git|tmux|fzf|yazi|btop)
      [ -x "$PD_BREW/bin/$pd_id" ] && return 0 ;;
    rustifiedgit) [ -x "$PD_INSTALL/rustifiedgit/bin/rustifiedgit" ] && return 0 ;;
    wezterm)
      [ -x "$PD_INSTALL/apps/WezTerm.app/Contents/MacOS/wezterm" ] && return 0
      [ -x "$PD_BREW/bin/wezterm" ] && return 0 ;;
    codex) [ -x "$PD_INSTALL/codex/bin/codex" ] && return 0 ;;
    copilot) [ -x "$PD_INSTALL/copilot/bin/copilot" ] && return 0 ;;
    vscode)
      for pd_path in "$PD_INSTALL"/vscode/*/bin/code \
          "$PD_INSTALL"/vscode/*/'Visual Studio Code.app'/Contents/Resources/app/bin/code; do
        [ -x "$pd_path" ] && return 0
      done ;;
  esac
  return 1
}

pd_tool_available_elsewhere() {
  local pd_command pd_path
  pd_command="$(pd_tool_command "$1" 2>/dev/null || true)"
  [ -n "$pd_command" ] || return 1
  pd_path="$(command -v "$pd_command" 2>/dev/null || true)"
  [ -n "$pd_path" ] || return 1
  case "$pd_path" in "$PD_ROOT"/*) return 1 ;; esac
  return 0
}

pd_picker_add_row() {
  PD_PICKER_KINDS+=("$1")
  PD_PICKER_PATHS+=("$2")
  PD_PICKER_LABELS+=("$3")
}

pd_picker_rebuild() {
  local pd_path pd_name pd_parent
  PD_PICKER_KINDS=()
  PD_PICKER_PATHS=()
  PD_PICKER_LABELS=()
  pd_parent="$(dirname "$PD_PICKER_SUGGESTED")"
  if [ -n "$PD_PICKER_SUGGESTED" ] && [ "$PD_PICKER_CURRENT" = "$pd_parent" ]; then
    pd_picker_add_row suggested "$PD_PICKER_SUGGESTED" \
      "Use suggested destination (created on install): $PD_PICKER_SUGGESTED"
  fi
  pd_picker_add_row current "$PD_PICKER_CURRENT" "Use this directory: $PD_PICKER_CURRENT"
  pd_picker_add_row create "$PD_PICKER_CURRENT" "[Create a new subdirectory]"
  if [ "$PD_PICKER_CURRENT" != / ]; then
    pd_picker_add_row parent "$(dirname "$PD_PICKER_CURRENT")" "[..]"
  fi
  for pd_path in "$PD_PICKER_CURRENT"/* "$PD_PICKER_CURRENT"/.[!.]* "$PD_PICKER_CURRENT"/..?*; do
    [ -d "$pd_path" ] || continue
    pd_name="${pd_path##*/}"
    pd_picker_add_row directory "$pd_path" "$pd_name/"
  done
}

pd_picker_draw() {
  local pd_i pd_start pd_end pd_prefix
  pd_tui_clear
  printf '%s\n' "Select install folder (Enter selects; arrows navigate; Backspace goes up; q cancels)"
  printf 'Current: %s\n' "$PD_PICKER_CURRENT"
  printf '%s\n\n' "Choose a dedicated path without spaces; the suggested destination is not created until install."
  pd_start=$((PD_PICKER_INDEX - 7))
  [ "$pd_start" -ge 0 ] || pd_start=0
  pd_end=$((pd_start + 15))
  [ "$pd_end" -le "${#PD_PICKER_LABELS[@]}" ] || pd_end="${#PD_PICKER_LABELS[@]}"
  for ((pd_i = pd_start; pd_i < pd_end; pd_i++)); do
    pd_prefix=' '
    [ "$pd_i" -ne "$PD_PICKER_INDEX" ] || pd_prefix='>'
    printf '%s %s\n' "$pd_prefix" "${PD_PICKER_LABELS[$pd_i]}"
  done
}

pd_choose_install_directory() {
  local pd_initial="$1" pd_parent pd_name pd_new
  if [ -d "$pd_initial" ]; then
    PD_PICKER_CURRENT="$(CDPATH= cd -- "$pd_initial" && pwd -P)" || return 1
    PD_PICKER_SUGGESTED=""
  else
    PD_PICKER_SUGGESTED="$pd_initial"
    pd_parent="$(dirname "$pd_initial")"
    while [ ! -d "$pd_parent" ] && [ "$pd_parent" != / ]; do
      pd_parent="$(dirname "$pd_parent")"
    done
    [ -d "$pd_parent" ] || pd_parent="$HOME"
    PD_PICKER_CURRENT="$(CDPATH= cd -- "$pd_parent" && pwd -P)" || return 1
  fi
  PD_PICKER_INDEX=0
  pd_tui_start || die "Interactive directory selection requires a terminal."
  while :; do
    pd_picker_rebuild
    [ "$PD_PICKER_INDEX" -lt "${#PD_PICKER_LABELS[@]}" ] || PD_PICKER_INDEX=0
    pd_picker_draw
    if ! pd_tui_read_key; then
      pd_tui_restore
      return 1
    fi
    case "$PD_TUI_KEY" in
      up)
        PD_PICKER_INDEX=$((PD_PICKER_INDEX - 1))
        [ "$PD_PICKER_INDEX" -ge 0 ] || PD_PICKER_INDEX=$((${#PD_PICKER_LABELS[@]} - 1)) ;;
      down)
        PD_PICKER_INDEX=$((PD_PICKER_INDEX + 1))
        [ "$PD_PICKER_INDEX" -lt "${#PD_PICKER_LABELS[@]}" ] || PD_PICKER_INDEX=0 ;;
      back)
        PD_PICKER_CURRENT="$(dirname "$PD_PICKER_CURRENT")"
        PD_PICKER_INDEX=0 ;;
      q|escape)
        pd_tui_restore
        printf '\n'
        return 1 ;;
      enter)
        case "${PD_PICKER_KINDS[$PD_PICKER_INDEX]}" in
          current|suggested)
            PD_ROOT="${PD_PICKER_PATHS[$PD_PICKER_INDEX]}"
            pd_tui_restore
            printf '\n'
            return 0 ;;
          parent|directory)
            PD_PICKER_CURRENT="$(CDPATH= cd -- "${PD_PICKER_PATHS[$PD_PICKER_INDEX]}" && pwd -P)" || {
              pd_tui_restore
              return 1
            }
            PD_PICKER_INDEX=0 ;;
          create)
            pd_tui_restore
            printf '\nNew directory name (letters, digits, dot, underscore or hyphen): '
            IFS= read -r pd_name < /dev/tty || return 1
            if [[ "$pd_name" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$pd_name" != . ] && [ "$pd_name" != .. ]; then
              pd_new="$PD_PICKER_CURRENT/$pd_name"
              mkdir -p -- "$pd_new" || die "Could not create directory: $pd_new"
              PD_PICKER_CURRENT="$(CDPATH= cd -- "$pd_new" && pwd -P)" || return 1
              PD_PICKER_INDEX=0
            else
              printf 'Invalid directory name.\n'
              sleep 1
            fi
            pd_tui_start || die "Interactive directory selection requires a terminal." ;;
        esac ;;
    esac
  done
}

pd_menu_draw() {
  local pd_i pd_checked pd_managed pd_available
  pd_tui_clear
  printf '%s\n' "Select tools to install (Space toggles; Enter continues; q cancels)"
  printf '%s\n\n' 'Tool                         Managed here   Available elsewhere'
  for ((pd_i = 0; pd_i < ${#PD_MENU_IDS[@]}; pd_i++)); do
    pd_checked='[ ]'
    [ "${PD_MENU_CHECKED[$pd_i]}" -ne 1 ] || pd_checked='[x]'
    pd_managed="${PD_MENU_MANAGED[$pd_i]}"
    pd_available="${PD_MENU_AVAILABLE[$pd_i]}"
    printf '%s %-27s %-14s %s\n' "$pd_checked" "${PD_MENU_LABELS[$pd_i]}" "$pd_managed" "$pd_available"
  done
  printf '\nInstall root: %s\n' "$PD_ROOT"
}

pd_show_tool_menu() {
  local pd_id pd_label pd_platforms pd_index
  PD_MENU_IDS=()
  PD_MENU_LABELS=()
  PD_MENU_MANAGED=()
  PD_MENU_AVAILABLE=()
  PD_MENU_CHECKED=()
  while IFS=$'\t' read -r pd_id pd_label pd_platforms; do
    [ -n "$pd_id" ] || continue
    case ",$pd_platforms," in *,"$PD_OS",*) ;; *) continue ;; esac
    if [ "$PD_ONLY_CODEX" -eq 1 ] && [ "$pd_id" != codex ]; then continue; fi
    PD_MENU_IDS+=("$pd_id")
    PD_MENU_LABELS+=("$pd_label")
    if pd_tool_managed "$pd_id"; then
      PD_MENU_MANAGED+=(yes)
    else
      PD_MENU_MANAGED+=(no)
    fi
    if pd_tool_available_elsewhere "$pd_id"; then
      PD_MENU_AVAILABLE+=(yes)
    else
      PD_MENU_AVAILABLE+=(no)
    fi
    if pd_tool_managed "$pd_id" || pd_tool_available_elsewhere "$pd_id"; then
      PD_MENU_CHECKED+=(0)
    else
      PD_MENU_CHECKED+=(1)
    fi
  done < "$PD_DIR/lib/interactive-tools.tsv"
  [ "${#PD_MENU_IDS[@]}" -gt 0 ] || die "No tools are available for the selected platform."
  pd_index=0
  pd_tui_start || die "Interactive tool selection requires a terminal."
  while :; do
    pd_menu_draw
    if ! pd_tui_read_key; then
      pd_tui_restore
      return 1
    fi
    case "$PD_TUI_KEY" in
      up)
        pd_index=$((pd_index - 1))
        [ "$pd_index" -ge 0 ] || pd_index=$((${#PD_MENU_IDS[@]} - 1)) ;;
      down)
        pd_index=$((pd_index + 1))
        [ "$pd_index" -lt "${#PD_MENU_IDS[@]}" ] || pd_index=0 ;;
      space) PD_MENU_CHECKED[$pd_index]=$((1 - PD_MENU_CHECKED[$pd_index])) ;;
      enter)
        local pd_choices=()
        for ((pd_index = 0; pd_index < ${#PD_MENU_IDS[@]}; pd_index++)); do
          [ "${PD_MENU_CHECKED[$pd_index]}" -ne 1 ] || pd_choices+=("${PD_MENU_IDS[$pd_index]}")
        done
        PD_SELECTED_TOOLS="$(IFS=,; printf '%s' "${pd_choices[*]}")"
        PD_SELECTION_MODE=explicit
        pd_tui_restore
        printf '\n'
        return 0 ;;
      q|escape)
        pd_tui_restore
        printf '\n'
        return 1 ;;
    esac
  done
}
