#!/usr/bin/env bash
# ============================================================
#  tui.sh -- TUI for OpenClaw + Ollama
# ============================================================
#  Design: maestro.sh patterns (arrow-key menu, submenus)
#  Requires: lib/tui.sh (arrow-key menu library)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/hooks.sh"
source "${SCRIPT_DIR}/lib/tui.sh"

# ============================================================
# HEADER
# ============================================================

_header() {
    tput clear 2>/dev/null || true
    echo ""
    echo -e "  ${_C_BLUE}OpenClaw + Ollama${_C_RESET}"
    echo -e "  ${_C_DIM}────────────────────${_C_RESET}"
    echo ""
    status_all
    echo -e "  ${_C_DIM}────────────────────${_C_RESET}"
}

_wait() {
    echo ""
    echo -e "  ${_C_DIM}press any key...${_C_RESET}"
    read -rsn1
}

# ============================================================
# OLLAMA SUBMENU
# ============================================================

_ollama_menu() {
    while true; do
        tput clear 2>/dev/null || true
        echo ""
        echo -e "  ${_C_BLUE}Ollama${_C_RESET}"
        echo -e "  ${_C_DIM}────────────────────${_C_RESET}"
        echo ""
        ollama_status
        echo ""
        echo -e "  ${_C_DIM}────────────────────${_C_RESET}"

        tui_menu "Ollama" \
            "Info" \
            "Models" \
            "Warm up" \
            "Benchmark" \
            "Switch model" \
            "Quick chat" \
            "Unload (free VRAM)" \
            "Back" || true

        case "${TUI_INDEX}" in
            0) tput clear 2>/dev/null; ollama_info; _wait ;;
            1) tput clear 2>/dev/null; ollama_models; _wait ;;
            2) tput clear 2>/dev/null; ollama_warmup; _wait ;;
            3) tput clear 2>/dev/null; ollama_bench; _wait ;;
            4) tput clear 2>/dev/null; ollama_switch; _wait ;;
            5) tput clear 2>/dev/null; ollama_chat ;;
            6) tput clear 2>/dev/null; ollama_unload; _wait ;;
            7|*) return ;;
        esac

        if [[ "${TUI_INDEX}" -eq -1 ]]; then
            return
        fi
    done
}

# ============================================================
# WORKSPACE SUBMENU
# ============================================================

_workspace_menu() {
    while true; do
        tput clear 2>/dev/null || true
        echo ""
        echo -e "  ${_C_BLUE}Workspace${_C_RESET}"
        echo -e "  ${_C_DIM}────────────────────${_C_RESET}"

        tui_menu "Workspace" \
            "Status" \
            "Sync (source -> destination)" \
            "Clear destination" \
            "Reset (clear + sync)" \
            "Back" || true

        case "${TUI_INDEX}" in
            0) tput clear 2>/dev/null; workspace_status; _wait ;;
            1) tput clear 2>/dev/null; sync_workspace; _wait ;;
            2) tput clear 2>/dev/null; clear_workspace; _wait ;;
            3) tput clear 2>/dev/null; reset_workspace; _wait ;;
            4|*) return ;;
        esac

        if [[ "${TUI_INDEX}" -eq -1 ]]; then
            return
        fi
    done
}

# ============================================================
# DEBUG SUBMENU
# ============================================================

_debug_menu() {
    while true; do
        tput clear 2>/dev/null || true
        echo ""
        echo -e "  ${_C_BLUE}Debug${_C_RESET}"
        echo -e "  ${_C_DIM}────────────────────${_C_RESET}"

        tui_menu "Debug" \
            "Security audit" \
            "Health check" \
            "Debug info" \
            "View logs" \
            "Nuke logs" \
            "Command index" \
            "Workspace" \
            "Back" || true

        case "${TUI_INDEX}" in
            0) tput clear 2>/dev/null; security_check; _wait ;;
            1) tput clear 2>/dev/null; health_check; _wait ;;
            2) tput clear 2>/dev/null; debug_info; _wait ;;
            3) tput clear 2>/dev/null; view_logs; _wait ;;
            4) tput clear 2>/dev/null; nuke_logs; _wait ;;
            5) tput clear 2>/dev/null; command_index; _wait ;;
            6) _workspace_menu ;;
            7|*) return ;;
        esac

        if [[ "${TUI_INDEX}" -eq -1 ]]; then
            return
        fi
    done
}

# ============================================================
# MAIN LOOP
# ============================================================

while true; do
    _header

    tui_menu "Main" \
        "Start all" \
        "Stop gateway" \
        "Stop everything" \
        "Security" \
        "Ollama" \
        "Debug" \
        "Chat" \
        "Quit" || true

    case "${TUI_INDEX}" in
        0) start_all || true; _wait ;;
        1) stop_all || true; _wait ;;
        2) stop_everything || true; _wait ;;
        3) tput clear 2>/dev/null; security_check || true; _wait ;;
        4) _ollama_menu ;;
        5) _debug_menu ;;
        6) open_chat || true ;;
        7) tput clear 2>/dev/null; echo ""; echo -e "  ${_C_DIM}bye${_C_RESET}"; echo ""; exit 0 ;;
        *) ;;
    esac

    if [[ "${TUI_INDEX}" -eq -1 ]]; then
        tput clear 2>/dev/null; echo ""; echo -e "  ${_C_DIM}bye${_C_RESET}"; echo ""; exit 0
    fi
done
