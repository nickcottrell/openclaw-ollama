#!/usr/bin/env bash
# ============================================================
#  tui.sh -- Minimal Arrow-Key Menu Library
# ============================================================
#  Extracted from maestro lib/tui.sh (composable subset).
#  No dialog. No whiptail. No ncurses. Just bash.
#
#  Source this file:  source lib/tui.sh
#
#  Public API:
#    tui_menu     -- Arrow-key navigable menu
#    tui_submenu  -- Looping submenu with auto "Back"
#
#  Returns:
#    TUI_RESULT   -- Selected item text
#    TUI_INDEX    -- Selected item index (0-based), -1 on escape
# ============================================================

# Guard against double-sourcing
if [[ "${_TUI_INITIALIZED:-}" = "1" ]]; then
    return 0 2>/dev/null || true
fi

# ============================================================
# STATE
# ============================================================

_TUI_COLS=80
_TUI_ROWS=24
_TUI_SAVED_STTY=""
_TUI_INITIALIZED=0

TUI_RESULT=""
TUI_INDEX=-1

# ============================================================
# COLORS (tput with fallbacks)
# ============================================================

_tui_setup_colors() {
    local colors
    colors=$(tput colors 2>/dev/null || echo 0)

    if [[ "${colors}" -ge 8 ]]; then
        _C_RESET=$(tput sgr0)
        _C_BOLD=$(tput bold)
        _C_DIM=$(tput dim 2>/dev/null || echo "")
        _C_REV=$(tput rev)
        _C_RED=$(tput setaf 1)
        _C_GREEN=$(tput setaf 2)
        _C_YELLOW=$(tput setaf 3)
        _C_BLUE=$(tput setaf 4)
        _C_MAGENTA=$(tput setaf 5)
        _C_CYAN=$(tput setaf 6)
        _C_WHITE=$(tput setaf 7)
    else
        _C_RESET="" _C_BOLD="" _C_DIM="" _C_REV=""
        _C_RED="" _C_GREEN="" _C_YELLOW="" _C_BLUE=""
        _C_MAGENTA="" _C_CYAN="" _C_WHITE=""
    fi
}

# ============================================================
# KEY CONSTANTS
# ============================================================

_KEY_UP="UP"
_KEY_DOWN="DOWN"
_KEY_ENTER="ENTER"
_KEY_ESCAPE="ESCAPE"
_KEY_CHAR="CHAR"

# ============================================================
# INIT / CLEANUP
# ============================================================

_tui_measure() {
    _TUI_COLS=$(tput cols 2>/dev/null || echo 80)
    _TUI_ROWS=$(tput lines 2>/dev/null || echo 24)
}

_tui_cleanup() {
    tput cnorm 2>/dev/null || true
    printf "%s" "${_C_RESET}" 2>/dev/null || true
    _tui_restore_stty
    stty sane 2>/dev/null || true
}

_tui_init() {
    _tui_setup_colors
    _tui_measure
    trap '_tui_measure' WINCH
    trap '_tui_cleanup' EXIT
    _TUI_INITIALIZED=1
}

# ============================================================
# KEY READING
# ============================================================

_tui_read_key() {
    _TUI_KEY=""
    _TUI_KEY_CHAR=""

    if [[ -z "${_TUI_SAVED_STTY}" ]]; then
        _TUI_SAVED_STTY=$(stty -g 2>/dev/null || echo "")
    fi
    stty -icanon -echo min 1 time 0 2>/dev/null || true

    local char=""
    IFS= read -rsn1 char

    if [[ "${char}" = $'\x1b' ]]; then
        stty min 0 time 2 2>/dev/null || true
        local seq1="" seq2=""
        IFS= read -rsn1 seq1 || true
        if [[ "${seq1}" = "[" ]]; then
            IFS= read -rsn1 seq2 || true
            case "${seq2}" in
                A) _TUI_KEY="${_KEY_UP}" ;;
                B) _TUI_KEY="${_KEY_DOWN}" ;;
                *) _TUI_KEY="${_KEY_ESCAPE}" ;;
            esac
        else
            _TUI_KEY="${_KEY_ESCAPE}"
        fi
        stty min 1 time 0 2>/dev/null || true
    elif [[ "${char}" = "" ]]; then
        _TUI_KEY="${_KEY_ENTER}"
    elif [[ "${char}" = $'\x7f' ]] || [[ "${char}" = $'\x08' ]]; then
        _TUI_KEY="${_KEY_ESCAPE}"
    else
        _TUI_KEY="${_KEY_CHAR}"
        _TUI_KEY_CHAR="${char}"
    fi
}

_tui_restore_stty() {
    if [[ -n "${_TUI_SAVED_STTY}" ]]; then
        stty "${_TUI_SAVED_STTY}" 2>/dev/null || true
        _TUI_SAVED_STTY=""
    fi
}

# ============================================================
# MENU (Arrow-key navigable)
# ============================================================
#
#  Usage:
#    tui_menu "Title" "Option A" "Option B" "Option C"
#
#  Returns:
#    TUI_RESULT = selected item text
#    TUI_INDEX  = selected index (0-based), -1 on escape

tui_menu() {
    local title="$1"
    shift
    local items=()
    while [[ $# -gt 0 ]]; do
        items+=("$1")
        shift
    done

    local count=${#items[@]}
    if [[ "${count}" -eq 0 ]]; then
        return 1
    fi

    local selected=0
    local visible_start=0
    local max_visible=$(( _TUI_ROWS - 6 ))
    if [[ "${max_visible}" -gt "${count}" ]]; then
        max_visible="${count}"
    fi

    tput civis 2>/dev/null || true

    echo ""
    echo "  ${_C_BOLD}${title}${_C_RESET}"
    echo ""

    while true; do
        # Scroll window
        if [[ "${selected}" -lt "${visible_start}" ]]; then
            visible_start="${selected}"
        fi
        if [[ "${selected}" -ge $(( visible_start + max_visible )) ]]; then
            visible_start=$(( selected - max_visible + 1 ))
        fi

        # Draw items
        local i="${visible_start}"
        local drawn=0
        while [[ "${drawn}" -lt "${max_visible}" ]] && [[ "${i}" -lt "${count}" ]]; do
            local item="${items[$i]}"
            if [[ "${i}" -eq "${selected}" ]]; then
                printf "  ${_C_REV} > %s ${_C_RESET}\n" "${item}"
            else
                printf "    %s\n" "${item}"
            fi
            i=$((i + 1))
            drawn=$((drawn + 1))
        done

        # Scroll indicator
        if [[ "${count}" -gt "${max_visible}" ]]; then
            local remaining=$(( count - visible_start - max_visible ))
            if [[ "${remaining}" -gt 0 ]]; then
                printf "  ${_C_DIM}  ... %d more${_C_RESET}\n" "${remaining}"
            else
                echo ""
            fi
        fi

        _tui_read_key

        # Lines to clear on redraw
        local clear_lines="${max_visible}"
        if [[ "${count}" -gt "${max_visible}" ]]; then
            clear_lines=$((clear_lines + 1))
        fi

        case "${_TUI_KEY}" in
            "${_KEY_UP}")
                if [[ "${selected}" -gt 0 ]]; then
                    selected=$((selected - 1))
                fi
                ;;
            "${_KEY_DOWN}")
                if [[ "${selected}" -lt $((count - 1)) ]]; then
                    selected=$((selected + 1))
                fi
                ;;
            "${_KEY_ENTER}")
                TUI_RESULT="${items[$selected]}"
                TUI_INDEX="${selected}"
                _tui_restore_stty
                tput cnorm 2>/dev/null || true
                return 0
                ;;
            "${_KEY_ESCAPE}")
                TUI_RESULT=""
                TUI_INDEX=-1
                _tui_restore_stty
                tput cnorm 2>/dev/null || true
                return 1
                ;;
        esac

        # Redraw
        printf "\033[%dA" "${clear_lines}"
        local c=0
        while [[ "${c}" -lt "${clear_lines}" ]]; do
            printf "\033[K\033[1B"
            c=$((c + 1))
        done
        printf "\033[%dA" "${clear_lines}"
    done
}

# ============================================================
# SUBMENU (looping menu with auto "Back")
# ============================================================
#
#  Usage:
#    tui_submenu "Title" \
#        "List:_my_list_fn" \
#        "Create:_my_create_fn" \
#        "Delete:_my_delete_fn"
#
#  "Back" is appended automatically.
#  Each action runs after clear, followed by "press any key".

tui_submenu() {
    local title="$1"
    shift

    local labels=()
    local handlers=()

    while [[ $# -gt 0 ]]; do
        local pair="$1"
        labels+=("${pair%%:*}")
        handlers+=("${pair#*:}")
        shift
    done

    local count=${#labels[@]}
    labels+=("Back")

    while true; do
        tui_menu "${title}" "${labels[@]}" || true

        if [[ "${TUI_INDEX}" -ge "${count}" ]] || [[ "${TUI_INDEX}" -eq -1 ]]; then
            return 0
        fi

        tput clear 2>/dev/null || true
        ${handlers[${TUI_INDEX}]} || true

        echo ""
        echo "  ${_C_DIM}press any key...${_C_RESET}"
        read -rsn1
        tput clear 2>/dev/null || true
    done
}

# ============================================================
# INITIALIZE ON SOURCE
# ============================================================

_tui_init
