#!/usr/bin/env bash
# ============================================================
#  hooks.sh -- Service commands for OpenClaw + Ollama
# ============================================================
#  Source this file:  source hooks.sh
#  Or call directly:  ./hooks.sh <command>
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCLAW_DIR="${SCRIPT_DIR}/openclaw"
WORKSPACE_SRC="${SCRIPT_DIR}/workspace"
WORKSPACE_DST="${HOME}/.openclaw/workspace"
CONFIG_DIR="${HOME}/.openclaw"
LOG_DIR="${SCRIPT_DIR}/logs"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"

# Colors
_R="\033[0;31m"
_G="\033[0;32m"
_Y="\033[0;33m"
_B="\033[0;34m"
_D="\033[2m"
_N="\033[0m"

# ============================================================
# HELPERS
# ============================================================

_log()  { echo -e "  ${_B}>>>${_N} $1"; }
_ok()   { echo -e "  ${_G}[OK]${_N} $1"; }
_err()  { echo -e "  ${_R}[ERR]${_N} $1" >&2; }
_warn() { echo -e "  ${_Y}[--]${_N} $1"; }

_port_alive() { lsof -ti:"$1" > /dev/null 2>&1; }

_kill_port() {
    local port="$1"
    local pids
    pids=$(lsof -ti:"${port}" 2>/dev/null) || true
    for pid in ${pids}; do
        kill "${pid}" 2>/dev/null || true
    done
    sleep 1
    if _port_alive "${port}"; then
        pids=$(lsof -ti:"${port}" 2>/dev/null) || true
        for pid in ${pids}; do
            kill -9 "${pid}" 2>/dev/null || true
        done
    fi
}

# ============================================================
# OLLAMA (system service -- always running via brew)
# ============================================================

ollama_status() {
    if _port_alive "${OLLAMA_PORT}"; then
        local loaded
        loaded=$(curl -s "http://localhost:${OLLAMA_PORT}/api/ps" 2>/dev/null \
            | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    ms=d.get('models',[])
    if ms:
        for m in ms:
            vram=m.get('size_vram',0)/(1024**3)
            print(f'{m[\"name\"]} ({vram:.1f}GB)')
    else: print('no model loaded')
except: print('idle')
" 2>/dev/null)
        echo -e "  ${_G}●${_N} Ollama        ${_G}running${_N}  ${_D}${loaded}${_N}"
    else
        echo -e "  ${_R}○${_N} Ollama        ${_R}down${_N}  ${_D}(brew services start ollama)${_N}"
    fi
}

ollama_warmup() {
    if ! _port_alive "${OLLAMA_PORT}"; then
        _warn "Ollama not running"
        return 1
    fi
    # Read model from config
    local model
    model=$(python3 -c "
import json
try:
    c=json.load(open('${CONFIG_DIR}/openclaw.json'))
    ms=c.get('models',{}).get('providers',{}).get('ollama',{}).get('models',[])
    if ms: print(ms[0].get('id','qwen2.5:7b'))
    else: print('qwen2.5:7b')
except: print('qwen2.5:7b')
" 2>/dev/null)
    _log "Warming up ${model}..."
    curl -s -X POST "http://localhost:${OLLAMA_PORT}/api/generate" \
        -d "{\"model\":\"${model}\",\"prompt\":\"hi\",\"keep_alive\":\"1h\",\"options\":{\"num_predict\":1}}" \
        > /dev/null 2>&1
    _ok "${model} loaded (1h idle timeout)"
}

ollama_unload() {
    if ! _port_alive "${OLLAMA_PORT}"; then
        _warn "Ollama not running"
        return 1
    fi
    local loaded
    loaded=$(curl -s "http://localhost:${OLLAMA_PORT}/api/ps" 2>/dev/null \
        | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(' '.join(m['name'] for m in d.get('models',[])))
except: pass
" 2>/dev/null)
    if [[ -z "${loaded}" ]]; then
        _ok "No models loaded"
        return 0
    fi
    for model in ${loaded}; do
        _log "Unloading ${model}..."
        curl -s -X POST "http://localhost:${OLLAMA_PORT}/api/generate" \
            -d "{\"model\":\"${model}\",\"keep_alive\":0}" > /dev/null 2>&1
        _ok "Unloaded ${model}"
    done
}

ollama_info() {
    echo ""
    echo -e "  ${_B}Ollama${_N}"
    echo -e "  ${_D}────────────────────${_N}"
    echo ""

    # Brew service status
    local brew_status
    brew_status=$(brew services list 2>/dev/null | grep ollama || echo "not installed")
    echo -e "  ${_D}Service:${_N}  ${brew_status}"
    echo ""

    if ! _port_alive "${OLLAMA_PORT}"; then
        echo -e "  ${_R}Ollama not running${_N}"
        echo ""
        return 1
    fi

    # Version
    local version
    version=$(curl -s "http://localhost:${OLLAMA_PORT}/api/version" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','unknown'))" 2>/dev/null || echo "unknown")
    echo -e "  ${_D}Version:${_N}  ${version}"

    # Installed models
    echo ""
    echo -e "  ${_B}Installed Models${_N}"
    curl -s "http://localhost:${OLLAMA_PORT}/api/tags" 2>/dev/null \
        | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for m in d.get('models',[]):
        size=m.get('size',0)/(1024**3)
        quant=m.get('details',{}).get('quantization_level','')
        params=m.get('details',{}).get('parameter_size','')
        print(f\"  {m['name']:24s} {params:>6s}  {quant:>6s}  {size:.1f}GB\")
except: print('  (error reading models)')
" 2>/dev/null

    # Running models (loaded in VRAM)
    echo ""
    echo -e "  ${_B}Loaded in VRAM${_N}"
    curl -s "http://localhost:${OLLAMA_PORT}/api/ps" 2>/dev/null \
        | python3 -c "
import sys,json
from datetime import datetime, timezone
try:
    d=json.load(sys.stdin)
    ms=d.get('models',[])
    if not ms:
        print('  (none)')
    for m in ms:
        vram=m.get('size_vram',0)/(1024**3)
        ctx=m.get('context_length',0)
        exp=m.get('expires_at','')
        print(f\"  {m['name']:24s} {vram:.1f}GB VRAM  ctx:{ctx}\")
        if exp:
            print(f\"  {'':24s} expires: {exp[:19]}\")
except: print('  (error)')
" 2>/dev/null

    echo ""
}

ollama_models() {
    if ! _port_alive "${OLLAMA_PORT}"; then
        _warn "Ollama not running"
        return 1
    fi
    echo ""
    echo -e "  ${_B}Available Models${_N}"
    echo -e "  ${_D}────────────────────${_N}"
    curl -s "http://localhost:${OLLAMA_PORT}/api/tags" 2>/dev/null \
        | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for i,m in enumerate(d.get('models',[]),1):
        size=m.get('size',0)/(1024**3)
        params=m.get('details',{}).get('parameter_size','')
        print(f\"  {i}) {m['name']:24s} {params:>6s}  {size:.1f}GB\")
except: print('  (error)')
" 2>/dev/null
    echo ""
}

ollama_pull() {
    local model="${1:-}"
    if [[ -z "${model}" ]]; then
        _err "Usage: hooks.sh pull <model>"
        echo -e "  ${_D}Example: hooks.sh pull llama3.2:3b${_N}"
        return 1
    fi
    if ! _port_alive "${OLLAMA_PORT}"; then
        _warn "Ollama not running"
        return 1
    fi
    _log "Pulling ${model}..."
    ollama pull "${model}"
}

ollama_bench() {
    if ! _port_alive "${OLLAMA_PORT}"; then
        _warn "Ollama not running"
        return 1
    fi
    local model="${1:-}"
    echo ""
    echo -e "  ${_B}Benchmark${_N}"
    echo -e "  ${_D}────────────────────${_N}"

    # Get list of installed models if none specified
    local models_to_bench
    if [[ -n "${model}" ]]; then
        models_to_bench="${model}"
    else
        models_to_bench=$(curl -s "http://localhost:${OLLAMA_PORT}/api/tags" 2>/dev/null \
            | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(' '.join(m['name'] for m in d.get('models',[])))
except: pass
" 2>/dev/null)
    fi

    local prompt="Explain what a neural network is in exactly two sentences."

    for m in ${models_to_bench}; do
        echo ""
        echo -e "  ${_B}${m}${_N}"
        echo -e "  ${_D}Prompt: ${prompt}${_N}"
        echo ""

        local result
        result=$(curl -s -X POST "http://localhost:${OLLAMA_PORT}/api/generate" \
            -d "{\"model\":\"${m}\",\"prompt\":\"${prompt}\",\"stream\":false,\"options\":{\"num_predict\":100}}" 2>/dev/null)

        echo "${result}" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    resp=d.get('response','(no response)')
    total=d.get('total_duration',0)/1e9
    prompt_eval=d.get('prompt_eval_duration',0)/1e9
    eval_dur=d.get('eval_duration',0)/1e9
    eval_count=d.get('eval_count',0)
    prompt_count=d.get('prompt_eval_count',0)
    speed=eval_count/(eval_dur if eval_dur>0 else 1)
    print(f'  {resp.strip()[:200]}')
    print()
    print(f'  Prompt tokens:  {prompt_count}')
    print(f'  Prompt eval:    {prompt_eval:.1f}s')
    print(f'  Output tokens:  {eval_count}')
    print(f'  Output speed:   {speed:.0f} tok/s')
    print(f'  Total time:     {total:.1f}s')
except Exception as e:
    print(f'  Error: {e}')
" 2>/dev/null
    done
    echo ""
}

ollama_switch() {
    if ! _port_alive "${OLLAMA_PORT}"; then
        _warn "Ollama not running"
        return 1
    fi

    # List models with numbers
    echo ""
    echo -e "  ${_B}Switch Gateway Model${_N}"
    echo -e "  ${_D}────────────────────${_N}"
    echo ""

    local model_list
    model_list=$(curl -s "http://localhost:${OLLAMA_PORT}/api/tags" 2>/dev/null \
        | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for m in d.get('models',[]):
        print(m['name'])
except: pass
" 2>/dev/null)

    local i=1
    local models=()
    while IFS= read -r m; do
        [[ -z "${m}" ]] && continue
        models+=("${m}")
        echo -e "  ${i}) ${m}"
        i=$((i + 1))
    done <<< "${model_list}"

    # Show current
    local current
    current=$(python3 -c "
import json
try:
    c=json.load(open('${CONFIG_DIR}/openclaw.json'))
    p=c.get('models',{}).get('providers',{}).get('ollama',{})
    ms=p.get('models',[])
    if ms: print(ms[0].get('id','unknown'))
    else: print('unknown')
except: print('unknown')
" 2>/dev/null)
    echo ""
    echo -e "  ${_D}Current: ${current}${_N}"
    echo ""
    printf "  Pick model (1-${#models[@]}): "
    read -rsn1 choice
    echo ""

    if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le "${#models[@]}" ]]; then
        local picked="${models[$((choice - 1))]}"
        _log "Switching to ${picked}..."

        # Update openclaw.json
        python3 -c "
import json
path='${CONFIG_DIR}/openclaw.json'
c=json.load(open(path))
p=c.setdefault('models',{}).setdefault('providers',{}).setdefault('ollama',{})
ms=p.get('models',[])
if ms:
    ms[0]['id']='${picked}'
    ms[0]['name']='${picked}'
json.dump(c,open(path,'w'),indent=4)
print('done')
" 2>/dev/null

        _ok "Config updated to ${picked}"
        echo -e "  ${_Y}Restart gateway to apply${_N}"
    else
        _warn "Cancelled"
    fi
    echo ""
}

ollama_chat() {
    if ! _port_alive "${OLLAMA_PORT}"; then
        _warn "Ollama not running"
        return 1
    fi
    local model="${1:-qwen2.5:7b}"
    echo ""
    echo -e "  ${_B}Quick Chat${_N} ${_D}(${model})${_N}"
    echo -e "  ${_D}Type a message, or 'q' to quit${_N}"
    echo ""

    while true; do
        printf "  ${_G}you>${_N} "
        local input
        read -r input
        [[ "${input}" = "q" || "${input}" = "quit" || -z "${input}" ]] && break

        printf "  ${_B}ai>${_N}  "
        curl -s -X POST "http://localhost:${OLLAMA_PORT}/api/generate" \
            -d "{\"model\":\"${model}\",\"prompt\":\"${input}\",\"stream\":true,\"options\":{\"num_predict\":200}}" 2>/dev/null \
            | python3 -c "
import sys,json
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        d=json.loads(line)
        r=d.get('response','')
        if r: print(r,end='',flush=True)
        if d.get('done'):
            dur=d.get('total_duration',0)/1e9
            toks=d.get('eval_count',0)
            speed=toks/(d.get('eval_duration',1)/1e9) if d.get('eval_duration') else 0
            print(f'\n  \033[2m({toks} tokens, {speed:.0f} tok/s, {dur:.1f}s)\033[0m')
    except: pass
" 2>/dev/null
        echo ""
    done
}

# ============================================================
# OPENCLAW GATEWAY
# ============================================================

gateway_start() {
    if _port_alive "${OPENCLAW_PORT}"; then
        _ok "Gateway already running on ${OPENCLAW_PORT}"
        return 0
    fi
    if [[ ! -d "${OPENCLAW_DIR}" ]]; then
        _err "OpenClaw not found at ${OPENCLAW_DIR}"
        _err "Clone OpenClaw into ./openclaw first"
        return 1
    fi
    mkdir -p "${LOG_DIR}"
    if [[ ! -f "${OPENCLAW_DIR}/dist/control-ui/index.html" ]]; then
        _log "Building UI (first time)..."
        build_ui || { _err "UI build failed"; return 1; }
    fi
    _log "Starting gateway on ${OPENCLAW_PORT}..."
    (cd "${OPENCLAW_DIR}" && npm run openclaw -- gateway --port "${OPENCLAW_PORT}" >> "${LOG_DIR}/gateway.log" 2>&1) &
    local tries=0
    while [[ "${tries}" -lt 12 ]]; do
        sleep 1
        if _port_alive "${OPENCLAW_PORT}"; then
            _ok "Gateway running on ${OPENCLAW_PORT}"
            return 0
        fi
        tries=$((tries + 1))
    done
    _err "Gateway failed to start (timeout)"
    return 1
}

gateway_stop() {
    if ! _port_alive "${OPENCLAW_PORT}"; then
        _warn "Gateway not running"
        return 0
    fi
    _log "Stopping gateway..."
    _kill_port "${OPENCLAW_PORT}"
    _ok "Gateway stopped"
}

gateway_status() {
    if _port_alive "${OPENCLAW_PORT}"; then
        echo -e "  ${_G}●${_N} Gateway       ${_G}running${_N}  :${OPENCLAW_PORT}"
    else
        echo -e "  ${_R}○${_N} Gateway       ${_D}off${_N}"
    fi
}

# ============================================================
# UI BUILD
# ============================================================

UI_MODE_FILE="${SCRIPT_DIR}/.ui-mode"

_ui_mode() {
    if [[ -f "${UI_MODE_FILE}" ]]; then
        cat "${UI_MODE_FILE}"
    else
        echo "standalone"
    fi
}

build_ui() {
    local mode="${1:-$(_ui_mode)}"
    local UI_DST="${OPENCLAW_DIR}/dist/control-ui"

    case "${mode}" in
        standalone)
            local UI_SRC="${SCRIPT_DIR}/ui"
            if [[ ! -d "${UI_SRC}" ]]; then
                _err "UI source not found at ${UI_SRC}"
                return 1
            fi
            mkdir -p "${UI_DST}"
            _log "Copying standalone UI..."
            cp "${UI_SRC}/index.html"     "${UI_DST}/index.html"
            cp "${UI_SRC}/chat.css"       "${UI_DST}/chat.css"
            cp "${UI_SRC}/gateway.js"     "${UI_DST}/gateway.js"
            cp "${UI_SRC}/chat.js"        "${UI_DST}/chat.js"
            cp "${UI_SRC}/marked.min.js"  "${UI_DST}/marked.min.js"
            cp "${UI_SRC}/purify.min.js"  "${UI_DST}/purify.min.js"
            echo "standalone" > "${UI_MODE_FILE}"
            _ok "Standalone UI copied (6 files)"
            ;;
        original)
            if [[ ! -d "${OPENCLAW_DIR}" ]]; then
                _err "OpenClaw not found at ${OPENCLAW_DIR}"
                return 1
            fi
            _log "Building original UI (npm)..."
            (cd "${OPENCLAW_DIR}" && npm run ui:build 2>&1) || {
                _err "UI build failed"; return 1;
            }
            echo "original" > "${UI_MODE_FILE}"
            _ok "Original UI built"
            ;;
        *)
            _err "Unknown UI mode: ${mode}"
            echo "  Usage: ./hooks.sh build [standalone|original]"
            return 1
            ;;
    esac
}

ui_switch() {
    local current
    current=$(_ui_mode)
    local target="${1:-}"

    if [[ -z "${target}" ]]; then
        echo ""
        echo -e "  ${_B}UI Mode${_N}"
        echo -e "  ${_D}────────────────────${_N}"
        echo -e "  Current: ${_G}${current}${_N}"
        echo ""
        echo -e "  ${_D}Switch:${_N}"
        echo -e "    ./hooks.sh ui standalone   ${_D}-- 4-file vanilla JS (default)${_N}"
        echo -e "    ./hooks.sh ui original     ${_D}-- full framework (npm build)${_N}"
        echo ""
        return 0
    fi

    if [[ "${target}" = "${current}" ]]; then
        _ok "Already using ${target} UI"
        return 0
    fi

    build_ui "${target}" || return 1

    if _port_alive "${OPENCLAW_PORT}"; then
        echo ""
        _warn "Gateway is running -- restart to serve the new UI"
        echo -e "  ${_D}./hooks.sh stop && ./hooks.sh start${_N}"
    fi
}

# ============================================================
# WORKSPACE SYNC
# ============================================================

workspace_status() {
    echo ""
    echo -e "  ${_B}Workspace${_N}"
    echo -e "  ${_D}Source files are your templates. Destination is what the model sees.${_N}"
    echo -e "  ${_D}Sync copies source → destination. Clear wipes destination.${_N}"
    echo ""

    # Source
    echo -e "  ${_B}Source${_N}  ${_D}${WORKSPACE_SRC}${_N}"
    if [[ -d "${WORKSPACE_SRC}" ]]; then
        local src_count=0
        for f in "${WORKSPACE_SRC}"/*; do
            [[ -f "${f}" ]] || continue
            local fname fsize
            fname=$(basename "${f}")
            fsize=$(du -h "${f}" 2>/dev/null | cut -f1)
            echo -e "    ${_D}${fname}  ${fsize}${_N}"
            src_count=$((src_count + 1))
        done
        if [[ "${src_count}" -eq 0 ]]; then
            echo -e "    ${_D}(empty)${_N}"
        fi
    else
        echo -e "    ${_R}(not found)${_N}"
    fi

    echo ""

    # Destination
    echo -e "  ${_B}Destination${_N}  ${_D}${WORKSPACE_DST}${_N}"
    if [[ -d "${WORKSPACE_DST}" ]]; then
        local dst_count=0
        local extras=0
        for item in "${WORKSPACE_DST}"/* "${WORKSPACE_DST}"/.*; do
            local bname
            bname=$(basename "${item}")
            [[ "${bname}" = "." || "${bname}" = ".." || "${bname}" = ".DS_Store" ]] && continue
            [[ -e "${item}" ]] || continue
            dst_count=$((dst_count + 1))
            if [[ -d "${item}" ]]; then
                echo -e "    ${_Y}${bname}/${_N}  ${_Y}(directory -- not from source)${_N}"
                extras=$((extras + 1))
            elif [[ -f "${WORKSPACE_SRC}/${bname}" ]]; then
                local fsize
                fsize=$(du -h "${item}" 2>/dev/null | cut -f1)
                echo -e "    ${_D}${bname}  ${fsize}${_N}"
            else
                local fsize
                fsize=$(du -h "${item}" 2>/dev/null | cut -f1)
                echo -e "    ${_Y}${bname}  ${fsize}${_N}  ${_Y}(not in source)${_N}"
                extras=$((extras + 1))
            fi
        done
        if [[ "${dst_count}" -eq 0 ]]; then
            echo -e "    ${_D}(empty)${_N}"
        elif [[ "${extras}" -gt 0 ]]; then
            echo ""
            echo -e "  ${_Y}${extras} extra item(s)${_N} in destination not in source"
        fi
    else
        echo -e "    ${_D}(not found)${_N}"
    fi
    echo ""
}

sync_workspace() {
    if [[ ! -d "${WORKSPACE_SRC}" ]]; then
        _err "Workspace source not found at ${WORKSPACE_SRC}"
        return 1
    fi
    mkdir -p "${WORKSPACE_DST}"
    local count=0
    for f in "${WORKSPACE_SRC}"/*; do
        [[ -f "${f}" ]] || continue
        cp "${f}" "${WORKSPACE_DST}/$(basename "${f}")"
        count=$((count + 1))
    done
    _ok "Synced ${count} files to ${WORKSPACE_DST}"
}

clear_workspace() {
    echo ""
    if [[ ! -d "${WORKSPACE_DST}" ]]; then
        _warn "Destination not found at ${WORKSPACE_DST}"
        return 0
    fi

    # Show what will be removed
    local count=0
    for item in "${WORKSPACE_DST}"/* "${WORKSPACE_DST}"/.*; do
        local bname
        bname=$(basename "${item}")
        [[ "${bname}" = "." || "${bname}" = ".." ]] && continue
        [[ -e "${item}" ]] || continue
        count=$((count + 1))
    done

    if [[ "${count}" -eq 0 ]]; then
        _ok "Destination already empty"
        return 0
    fi

    _log "Removing ${count} item(s) from ${WORKSPACE_DST}..."
    rm -rf "${WORKSPACE_DST}"
    mkdir -p "${WORKSPACE_DST}"
    _ok "Workspace cleared"
    echo ""
}

reset_workspace() {
    echo ""
    _log "Clearing destination..."
    clear_workspace
    _log "Syncing from source..."
    sync_workspace
    echo ""
    _ok "Workspace reset to source"
    echo ""
}

# ============================================================
# OPEN CHAT
# ============================================================

open_chat() {
    if ! _port_alive "${OPENCLAW_PORT}"; then
        _err "Gateway not running on ${OPENCLAW_PORT}"
        return 1
    fi
    # ensure UI is current before opening
    build_ui > /dev/null 2>&1
    local token
    token=$(python3 -c "import json; print(json.load(open('${CONFIG_DIR}/openclaw.json')).get('gateway',{}).get('auth',{}).get('token',''))" 2>/dev/null) || token=""
    local url="http://localhost:${OPENCLAW_PORT}"
    if [[ -n "${token}" ]]; then
        url="${url}?token=${token}"
        echo ""
        echo -e "  ${_Y}Token:${_N} ${token}"
        echo ""
    fi
    local mode
    mode=$(_ui_mode)
    _log "Opening ${url%%\?*}  ${_D}(${mode} UI)${_N}"
    open "${url}" 2>/dev/null || echo "  Visit: ${url}"
}

# ============================================================
# START / STOP ALL
# ============================================================

start_all() {
    echo ""
    if ! _port_alive "${OLLAMA_PORT}"; then
        _log "Starting Ollama service..."
        brew services start ollama 2>/dev/null
        local tries=0
        while [[ "${tries}" -lt 10 ]]; do
            sleep 1
            if _port_alive "${OLLAMA_PORT}"; then break; fi
            tries=$((tries + 1))
        done
        if ! _port_alive "${OLLAMA_PORT}"; then
            _err "Ollama failed to start"
            return 1
        fi
        _ok "Ollama started"
    fi
    ollama_warmup
    gateway_start
    sync_workspace
    echo ""
    _ok "Gateway up"
}

stop_all() {
    echo ""
    gateway_stop
    # Kill any orphaned openclaw node processes
    local orphans
    orphans=$(pgrep -f "openclaw.*gateway" 2>/dev/null) || true
    if [[ -n "${orphans}" ]]; then
        _log "Cleaning orphaned processes..."
        echo "${orphans}" | while read -r pid; do
            kill "${pid}" 2>/dev/null || true
        done
        sleep 1
    fi
    # Verify gateway is down
    echo ""
    if _port_alive "${OPENCLAW_PORT}"; then
        _err "Gateway port ${OPENCLAW_PORT} still open!"
    else
        _ok "Gateway down (verified)"
    fi
}

stop_everything() {
    echo ""
    stop_all
    _log "Stopping Ollama service..."
    brew services stop ollama 2>/dev/null
    sleep 1
    if _port_alive "${OLLAMA_PORT}"; then
        _err "Ollama port ${OLLAMA_PORT} still open!"
    else
        _ok "Ollama down (verified)"
    fi
    echo ""
    _ok "Everything stopped"
    echo -e "  ${_D}To restart: brew services start ollama${_N}"
}

status_all() {
    echo ""
    ollama_status
    gateway_status
    echo ""
}

# ============================================================
# SECURITY
# ============================================================

security_check() {
    echo ""
    echo -e "  ${_B}Security Audit${_N}"
    echo -e "  ${_D}────────────────────${_N}"
    echo ""

    local issues=0

    # 1. Ollama network binding
    if _port_alive "${OLLAMA_PORT}"; then
        local ollama_bind
        ollama_bind=$(lsof -i:"${OLLAMA_PORT}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' | head -1)
        if echo "${ollama_bind}" | grep -q "^\*:"; then
            echo -e "  ${_R}FAIL${_N}  Ollama bound to ${_R}0.0.0.0${_N} (network exposed, no auth)"
            issues=$((issues + 1))
        else
            echo -e "  ${_G}PASS${_N}  Ollama bound to localhost only"
        fi
    else
        echo -e "  ${_G}PASS${_N}  Ollama not running (no listener)"
    fi

    # 2. OLLAMA_HOST env var
    local ollama_host="${OLLAMA_HOST:-}"
    if [[ -n "${ollama_host}" ]]; then
        if echo "${ollama_host}" | grep -q "0\.0\.0\.0"; then
            echo -e "  ${_R}FAIL${_N}  OLLAMA_HOST=${ollama_host} (network exposed)"
            issues=$((issues + 1))
        else
            echo -e "  ${_G}PASS${_N}  OLLAMA_HOST=${ollama_host}"
        fi
    else
        echo -e "  ${_G}PASS${_N}  OLLAMA_HOST not set (defaults to localhost)"
    fi

    # 3. Gateway network binding
    if _port_alive "${OPENCLAW_PORT}"; then
        local gw_bind
        gw_bind=$(lsof -i:"${OPENCLAW_PORT}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' | head -1)
        if echo "${gw_bind}" | grep -q "^\*:"; then
            echo -e "  ${_Y}WARN${_N}  Gateway bound to ${_Y}0.0.0.0${_N} (token auth required)"
            issues=$((issues + 1))
        else
            echo -e "  ${_G}PASS${_N}  Gateway bound to localhost only"
        fi
    else
        echo -e "  ${_G}PASS${_N}  Gateway not running (no listener)"
    fi

    # 4. Auth token exists
    local token
    token=$(python3 -c "
import json
try:
    c=json.load(open('${CONFIG_DIR}/openclaw.json'))
    print(c.get('gateway',{}).get('auth',{}).get('token',''))
except: print('')
" 2>/dev/null)
    if [[ -z "${token}" ]]; then
        echo -e "  ${_R}FAIL${_N}  No gateway auth token configured"
        issues=$((issues + 1))
    else
        echo -e "  ${_G}PASS${_N}  Gateway auth token set (${#token} chars)"
    fi

    # 5. Sensitive files (contain auth tokens + conversation data)
    echo ""
    echo -e "  ${_B}Sensitive Files${_N}"
    echo -e "  ${_D}These files contain credentials or conversation data.${_N}"
    echo -e "  ${_D}Only your user account should be able to read them (perms 600).${_N}"
    echo ""

    # Config -- has auth token
    local cfg="${CONFIG_DIR}/openclaw.json"
    if [[ -f "${cfg}" ]]; then
        local cfg_perms
        cfg_perms=$(stat -f "%Lp" "${cfg}" 2>/dev/null || echo "???")
        if [[ "${cfg_perms}" = "600" ]]; then
            echo -e "  ${_G}${cfg_perms}${_N}  config         ${_D}owner-only (has auth token)${_N}"
        else
            echo -e "  ${_R}${cfg_perms}${_N}  config         ${_R}readable by others${_N} -- has auth token"
            echo -e "         ${_D}fix: chmod 600 ${cfg}${_N}"
            issues=$((issues + 1))
        fi
    fi

    # Gateway log -- has conversation data
    local gw_log="${LOG_DIR}/gateway.log"
    if [[ -f "${gw_log}" ]]; then
        local gw_perms gw_size
        gw_perms=$(stat -f "%Lp" "${gw_log}" 2>/dev/null || echo "???")
        gw_size=$(du -h "${gw_log}" 2>/dev/null | cut -f1)
        if [[ "${gw_perms}" = "600" ]]; then
            echo -e "  ${_G}${gw_perms}${_N}  gateway.log    ${_D}owner-only  ${gw_size}${_N}"
        else
            echo -e "  ${_R}${gw_perms}${_N}  gateway.log    ${_R}readable by others${_N} -- has conversation data  ${_D}${gw_size}${_N}"
            echo -e "         ${_D}fix: chmod 600 ${gw_log}${_N}"
            issues=$((issues + 1))
        fi
    else
        echo -e "  ${_D} --${_N}  gateway.log    ${_D}(not found)${_N}"
    fi

    # Ollama log -- has prompts and responses
    local ol_log="/opt/homebrew/var/log/ollama.log"
    if [[ -f "${ol_log}" ]]; then
        local ol_perms ol_size
        ol_perms=$(stat -f "%Lp" "${ol_log}" 2>/dev/null || echo "???")
        ol_size=$(du -h "${ol_log}" 2>/dev/null | cut -f1)
        if [[ "${ol_perms}" = "600" ]]; then
            echo -e "  ${_G}${ol_perms}${_N}  ollama.log     ${_D}owner-only  ${ol_size}${_N}"
        else
            echo -e "  ${_R}${ol_perms}${_N}  ollama.log     ${_R}readable by others${_N} -- has prompts/responses  ${_D}${ol_size}${_N}"
            echo -e "         ${_D}fix: chmod 600 ${ol_log}${_N}"
            issues=$((issues + 1))
        fi
    else
        echo -e "  ${_D} --${_N}  ollama.log     ${_D}(not found)${_N}"
    fi

    # 6. Workspace -- directory perms + contents
    echo ""
    echo -e "  ${_B}Workspace${_N}"
    echo -e "  ${_D}Files here are injected into every prompt sent to the model.${_N}"
    echo -e "  ${_D}A dropped file = prompt injection. Directory should be 700.${_N}"
    echo ""
    local ws_files=0
    local ws_size=0
    if [[ -d "${WORKSPACE_DST}" ]]; then
        local ws_dir_perms
        ws_dir_perms=$(stat -f "%Lp" "${WORKSPACE_DST}" 2>/dev/null || echo "???")
        if [[ "${ws_dir_perms}" = "700" ]]; then
            echo -e "  ${_G}${ws_dir_perms}${_N}  workspace/     ${_D}owner-only${_N}"
        else
            echo -e "  ${_R}${ws_dir_perms}${_N}  workspace/     ${_R}others can add files${_N}"
            echo -e "         ${_D}fix: chmod 700 ${WORKSPACE_DST}${_N}"
            issues=$((issues + 1))
        fi
        for f in "${WORKSPACE_DST}"/*; do
            [[ -f "${f}" ]] || continue
            local fsize f_perms
            fsize=$(stat -f "%z" "${f}" 2>/dev/null || echo 0)
            f_perms=$(stat -f "%Lp" "${f}" 2>/dev/null || echo "???")
            local fname
            fname=$(basename "${f}")
            ws_files=$((ws_files + 1))
            ws_size=$((ws_size + fsize))
            local file_issues=""
            if [[ "${f_perms}" != "600" ]]; then
                file_issues="readable by others"
                issues=$((issues + 1))
            fi
            if [[ "${fsize}" -gt 50000 ]]; then
                file_issues="${file_issues}${file_issues:+, }large file slows inference"
                issues=$((issues + 1))
            fi
            if [[ -n "${file_issues}" ]]; then
                echo -e "  ${_Y}${f_perms}${_N}  ${fname}  ${_Y}${file_issues}${_N}  ${_D}$(( fsize / 1024 ))K${_N}"
            else
                echo -e "  ${_D}${f_perms}${_N}  ${fname}  ${_D}$(( fsize / 1024 ))K${_N}"
            fi
        done
    else
        echo -e "  ${_D} --${_N}  workspace/     ${_D}(not found)${_N}"
    fi
    if [[ "${ws_files}" -eq 0 ]] && [[ -d "${WORKSPACE_DST}" ]]; then
        echo -e "  ${_G}PASS${_N}  Empty -- no prompt injection risk"
    elif [[ "${ws_files}" -gt 0 ]]; then
        echo -e "  ${_D}       ${ws_files} file(s), $(( ws_size / 1024 ))K total${_N}"
    fi

    # 8. Open ports summary
    echo ""
    echo -e "  ${_B}Listening Ports${_N}"
    local ports_found=0
    for port in "${OLLAMA_PORT}" "${OPENCLAW_PORT}"; do
        if _port_alive "${port}"; then
            local pname
            pname=$(lsof -i:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1}' | head -1)
            echo -e "  ${_Y}OPEN${_N}  :${port}  ${_D}${pname}${_N}"
            ports_found=$((ports_found + 1))
        fi
    done
    if [[ "${ports_found}" -eq 0 ]]; then
        echo -e "  ${_G}PASS${_N}  No ports open"
    fi

    # Summary
    echo ""
    echo -e "  ${_D}────────────────────${_N}"
    if [[ "${issues}" -eq 0 ]]; then
        echo -e "  ${_G}All clear${_N} -- no issues found"
    else
        echo -e "  ${_Y}${issues} issue(s)${_N} found"
    fi
    echo ""
}

# ============================================================
# LOGGING & DIAGNOSTICS
# ============================================================

view_logs() {
    local lines="${1:-30}"
    local gw_log="${LOG_DIR}/gateway.log"
    local ol_log="/opt/homebrew/var/log/ollama.log"

    echo ""
    echo -e "  ${_B}Log Audit${_N}"
    echo -e "  ${_D}────────────────────${_N}"
    echo ""

    # Gateway log
    if [[ -f "${gw_log}" ]]; then
        local gw_size gw_perms gw_owner
        gw_size=$(du -h "${gw_log}" 2>/dev/null | cut -f1)
        gw_perms=$(stat -f "%Lp" "${gw_log}" 2>/dev/null || echo "???")
        gw_owner=$(stat -f "%Su:%Sg" "${gw_log}" 2>/dev/null || echo "???")
        if [[ "${gw_perms}" = "644" || "${gw_perms}" = "600" ]]; then
            echo -e "  ${_G}PASS${_N}  gateway.log"
        else
            echo -e "  ${_Y}WARN${_N}  gateway.log  ${_Y}perms ${gw_perms} (recommend 644)${_N}"
        fi
        echo -e "         ${_D}${gw_log}${_N}"
        echo -e "         ${_D}size: ${gw_size}  perms: ${gw_perms}  owner: ${gw_owner}${_N}"
        echo ""
        echo -e "  ${_D}── last ${lines} lines ──${_N}"
        tail -n "${lines}" "${gw_log}" | sed 's/^/  /'
    else
        echo -e "  ${_D}  --${_N}  gateway.log  ${_D}not found${_N}"
        echo -e "         ${_D}${gw_log}${_N}"
    fi

    echo ""

    # Ollama log
    if [[ -f "${ol_log}" ]]; then
        local ol_size ol_perms ol_owner
        ol_size=$(du -h "${ol_log}" 2>/dev/null | cut -f1)
        ol_perms=$(stat -f "%Lp" "${ol_log}" 2>/dev/null || echo "???")
        ol_owner=$(stat -f "%Su:%Sg" "${ol_log}" 2>/dev/null || echo "???")
        if [[ "${ol_perms}" = "644" || "${ol_perms}" = "600" ]]; then
            echo -e "  ${_G}PASS${_N}  ollama.log"
        else
            echo -e "  ${_Y}WARN${_N}  ollama.log  ${_Y}perms ${ol_perms} (recommend 644)${_N}"
        fi
        echo -e "         ${_D}${ol_log}${_N}"
        echo -e "         ${_D}size: ${ol_size}  perms: ${ol_perms}  owner: ${ol_owner}${_N}"
        echo ""
        echo -e "  ${_D}── last ${lines} lines ──${_N}"
        tail -n "${lines}" "${ol_log}" | sed 's/^/  /'
    else
        echo -e "  ${_D}  --${_N}  ollama.log  ${_D}not found${_N}"
        echo -e "         ${_D}${ol_log}${_N}"
    fi

    echo ""
}

health_check() {
    echo ""
    echo -e "  ${_B}Health Check${_N}"
    echo -e "  ${_D}────────────────────${_N}"
    echo ""

    # Ollama
    if _port_alive "${OLLAMA_PORT}"; then
        local models
        models=$(curl -s "http://localhost:${OLLAMA_PORT}/api/ps" 2>/dev/null)
        if [[ -n "${models}" ]]; then
            local loaded
            loaded=$(echo "${models}" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for m in d.get('models',[]):
        vram=m.get('size_vram',0)/(1024**3)
        print(f\"  {m['name']} ({vram:.1f}GB VRAM)\")
except: print('  (parse error)')
" 2>/dev/null)
            echo -e "  ${_G}●${_N} Ollama        ${_G}healthy${_N}"
            echo "${loaded}"
        else
            echo -e "  ${_Y}●${_N} Ollama        ${_Y}port open, no response${_N}"
        fi
    else
        echo -e "  ${_R}○${_N} Ollama        ${_R}down${_N}"
    fi

    echo ""

    # Gateway
    if _port_alive "${OPENCLAW_PORT}"; then
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${OPENCLAW_PORT}/" 2>/dev/null)
        if [[ "${http_code}" = "200" || "${http_code}" = "304" ]]; then
            echo -e "  ${_G}●${_N} Gateway       ${_G}healthy${_N}  HTTP ${http_code}"
        else
            echo -e "  ${_Y}●${_N} Gateway       ${_Y}port open${_N}  HTTP ${http_code}"
        fi
        # Check WebSocket connections
        local ws_conns
        ws_conns=$(lsof -i:"${OPENCLAW_PORT}" 2>/dev/null | grep -c ESTABLISHED || echo 0)
        echo -e "     ${_D}${ws_conns} active connection(s)${_N}"
    else
        echo -e "  ${_R}○${_N} Gateway       ${_R}down${_N}"
    fi

    echo ""

    # Files
    echo -e "  ${_B}Files${_N}"
    local issues=0

    # Config file -- contains auth token, should not be world-readable
    local cfg="${CONFIG_DIR}/openclaw.json"
    if [[ -f "${cfg}" ]]; then
        local cfg_perms
        cfg_perms=$(stat -f "%Lp" "${cfg}" 2>/dev/null || echo "???")
        if [[ "${cfg_perms}" = "600" ]]; then
            echo -e "  ${_G}${cfg_perms}${_N}  config        ${_D}owner-only (has auth token)${_N}"
        elif [[ "${cfg_perms}" = "644" ]]; then
            echo -e "  ${_Y}${cfg_perms}${_N}  config        ${_Y}world-readable${_N}  ${_D}(has auth token -- recommend 600)${_N}"
            issues=$((issues + 1))
        else
            echo -e "  ${_Y}${cfg_perms}${_N}  config        ${_Y}unexpected${_N}"
            issues=$((issues + 1))
        fi
    fi

    # Gateway log -- contains conversation data
    local gw_log="${LOG_DIR}/gateway.log"
    if [[ -f "${gw_log}" ]]; then
        local gw_perms gw_size
        gw_perms=$(stat -f "%Lp" "${gw_log}" 2>/dev/null || echo "???")
        gw_size=$(du -h "${gw_log}" 2>/dev/null | cut -f1)
        if [[ "${gw_perms}" = "600" ]]; then
            echo -e "  ${_G}${gw_perms}${_N}  gateway.log   ${_D}owner-only  ${gw_size}${_N}"
        else
            echo -e "  ${_Y}${gw_perms}${_N}  gateway.log   ${_Y}readable by others${_N}  ${_D}${gw_size} (has conversation data -- recommend 600)${_N}"
            issues=$((issues + 1))
        fi
    else
        echo -e "  ${_D} --${_N}  gateway.log   ${_D}(not found)${_N}"
    fi

    # Ollama log -- contains prompts and responses
    local ol_log="/opt/homebrew/var/log/ollama.log"
    if [[ -f "${ol_log}" ]]; then
        local ol_perms ol_size
        ol_perms=$(stat -f "%Lp" "${ol_log}" 2>/dev/null || echo "???")
        ol_size=$(du -h "${ol_log}" 2>/dev/null | cut -f1)
        if [[ "${ol_perms}" = "600" ]]; then
            echo -e "  ${_G}${ol_perms}${_N}  ollama.log    ${_D}owner-only  ${ol_size}${_N}"
        else
            echo -e "  ${_Y}${ol_perms}${_N}  ollama.log    ${_Y}readable by others${_N}  ${_D}${ol_size} (has prompts/responses -- recommend 600)${_N}"
            issues=$((issues + 1))
        fi
    else
        echo -e "  ${_D} --${_N}  ollama.log    ${_D}(not found)${_N}"
    fi

    # Workspace -- files here get injected into every prompt
    if [[ -d "${WORKSPACE_DST}" ]]; then
        local ws_perms
        ws_perms=$(stat -f "%Lp" "${WORKSPACE_DST}" 2>/dev/null || echo "???")
        if [[ "${ws_perms}" = "700" ]]; then
            echo -e "  ${_G}${ws_perms}${_N}  workspace/    ${_D}owner-only (files injected into prompts)${_N}"
        else
            echo -e "  ${_Y}${ws_perms}${_N}  workspace/    ${_Y}others can add files${_N} -- contents injected into every prompt"
            echo -e "         ${_D}fix: chmod 700 ${WORKSPACE_DST}${_N}"
            issues=$((issues + 1))
        fi
        # Check individual files
        for f in "${WORKSPACE_DST}"/*; do
            [[ -f "${f}" ]] || continue
            local f_perms f_size fname
            f_perms=$(stat -f "%Lp" "${f}" 2>/dev/null || echo "???")
            f_size=$(du -h "${f}" 2>/dev/null | cut -f1)
            fname=$(basename "${f}")
            if [[ "${f_perms}" = "600" ]]; then
                echo -e "  ${_D}       ${f_perms}  ${fname}  ${f_size}${_N}"
            else
                echo -e "  ${_Y}       ${f_perms}${_N}  ${fname}  ${_Y}readable by others${_N}  ${_D}${f_size}${_N}"
                issues=$((issues + 1))
            fi
        done
    else
        echo -e "  ${_D} --${_N}  workspace/    ${_D}(not found)${_N}"
    fi

    echo ""

    # System resources
    local mem_free
    mem_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); printf "%.0f MB", $3*16384/1048576}' || echo "unknown")
    echo -e "  ${_D}Free memory: ${mem_free}${_N}"

    # Summary
    if [[ "${issues}" -gt 0 ]]; then
        echo ""
        echo -e "  ${_Y}${issues} issue(s)${_N}"
    fi
    echo ""
}

debug_info() {
    echo ""
    echo -e "  ${_B}Debug Info${_N}"
    echo -e "  ${_D}────────────────────${_N}"
    echo ""
    echo -e "  ${_D}OpenClaw dir:${_N}  ${OPENCLAW_DIR}"
    echo -e "  ${_D}Workspace:${_N}     ${WORKSPACE_DST}"
    echo -e "  ${_D}Config:${_N}        ${CONFIG_DIR}/openclaw.json"
    echo -e "  ${_D}Logs:${_N}          ${LOG_DIR}/"
    echo -e "  ${_D}Gateway port:${_N}  ${OPENCLAW_PORT}"
    echo -e "  ${_D}Ollama port:${_N}   ${OLLAMA_PORT}"
    echo ""

    # UI build info
    local index_html="${OPENCLAW_DIR}/dist/control-ui/index.html"
    if [[ -f "${index_html}" ]]; then
        local js_hash
        js_hash=$(grep -o 'index-[A-Za-z0-9_-]*\.js' "${index_html}" 2>/dev/null || echo "unknown")
        local build_time
        build_time=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "${index_html}" 2>/dev/null || echo "unknown")
        echo -e "  ${_D}UI build:${_N}      ${js_hash}  (${build_time})"
    else
        echo -e "  ${_Y}UI not built${_N}"
    fi

    # Git status of openclaw customizations
    local mod_count
    mod_count=$(cd "${OPENCLAW_DIR}" && git diff --stat 2>/dev/null | tail -1 || echo "clean")
    echo -e "  ${_D}Customizations:${_N} ${mod_count}"
    echo ""

    # Process info
    if _port_alive "${OPENCLAW_PORT}"; then
        local gw_pid
        gw_pid=$(lsof -ti:"${OPENCLAW_PORT}" 2>/dev/null | head -1)
        if [[ -n "${gw_pid}" ]]; then
            echo -e "  ${_D}Gateway PID:${_N}   ${gw_pid}"
            local gw_uptime
            gw_uptime=$(ps -o etime= -p "${gw_pid}" 2>/dev/null | xargs)
            echo -e "  ${_D}Uptime:${_N}        ${gw_uptime}"
        fi
    fi
    if _port_alive "${OLLAMA_PORT}"; then
        local ol_pid
        ol_pid=$(lsof -ti:"${OLLAMA_PORT}" 2>/dev/null | head -1)
        if [[ -n "${ol_pid}" ]]; then
            echo -e "  ${_D}Ollama PID:${_N}    ${ol_pid}"
        fi
    fi
    echo ""
}

nuke_logs() {
    echo ""
    local stamp
    stamp=$(date "+%Y-%m-%d %H:%M:%S")
    local header="── logs reset ${stamp} ──"

    # Gateway log
    local gw_log="${LOG_DIR}/gateway.log"
    if [[ -f "${gw_log}" ]]; then
        local gw_size
        gw_size=$(du -h "${gw_log}" 2>/dev/null | cut -f1)
        echo "${header}" > "${gw_log}"
        _ok "Gateway log wiped (was ${gw_size})"
    else
        mkdir -p "${LOG_DIR}"
        echo "${header}" > "${gw_log}"
        _ok "Gateway log created"
    fi

    # Ollama log
    local ol_log="/opt/homebrew/var/log/ollama.log"
    if [[ -f "${ol_log}" ]]; then
        local ol_size
        ol_size=$(du -h "${ol_log}" 2>/dev/null | cut -f1)
        echo "${header}" > "${ol_log}"
        _ok "Ollama log wiped (was ${ol_size})"
    else
        _warn "Ollama log not found at ${ol_log}"
    fi

    echo ""
}

command_index() {
    local mode
    mode=$(_ui_mode)
    echo ""
    echo -e "  ${_B}Command Index${_N}"
    echo -e "  ${_D}────────────────────────────────────────────${_N}"
    echo ""
    echo -e "  ${_B}Services${_N}"
    echo -e "    start              ${_D}Start gateway + warm Ollama + sync workspace${_N}"
    echo -e "    stop               ${_D}Stop gateway${_N}"
    echo -e "    stop-all           ${_D}Stop gateway + Ollama (full shutdown)${_N}"
    echo -e "    status             ${_D}Show service status${_N}"
    echo -e "    gateway-start      ${_D}Start gateway only${_N}"
    echo -e "    gateway-stop       ${_D}Stop gateway only${_N}"
    echo ""
    echo -e "  ${_B}Chat${_N}"
    echo -e "    chat               ${_D}Open chat UI in browser${_N}"
    echo ""
    echo -e "  ${_B}UI${_N}  ${_D}(current: ${_G}${mode}${_D})${_N}"
    echo -e "    build [mode]       ${_D}Build UI (standalone|original)${_N}"
    echo -e "    ui                 ${_D}Show current UI mode${_N}"
    echo -e "    ui standalone      ${_D}Switch to 4-file vanilla JS UI${_N}"
    echo -e "    ui original        ${_D}Switch to full framework (npm build)${_N}"
    echo ""
    echo -e "  ${_B}Workspace${_N}"
    echo -e "    workspace          ${_D}Show workspace source + destination${_N}"
    echo -e "    sync               ${_D}Sync workspace (source -> destination)${_N}"
    echo -e "    clear-workspace    ${_D}Wipe destination workspace${_N}"
    echo -e "    reset-workspace    ${_D}Clear + re-sync from source${_N}"
    echo ""
    echo -e "  ${_B}Ollama${_N}"
    echo -e "    ollama             ${_D}Ollama info (version, models, VRAM)${_N}"
    echo -e "    models             ${_D}List installed models${_N}"
    echo -e "    warmup             ${_D}Pre-load model (1h idle timeout)${_N}"
    echo -e "    unload             ${_D}Unload models from VRAM${_N}"
    echo -e "    pull <model>       ${_D}Pull a model (e.g. pull llama3.2:3b)${_N}"
    echo -e "    bench [model]      ${_D}Benchmark models (or specific model)${_N}"
    echo -e "    switch             ${_D}Switch gateway model (interactive)${_N}"
    echo -e "    quick-chat [model] ${_D}Direct chat with Ollama (bypass gateway)${_N}"
    echo ""
    echo -e "  ${_B}Diagnostics${_N}"
    echo -e "    health             ${_D}Run health check${_N}"
    echo -e "    security           ${_D}Security audit${_N}"
    echo -e "    debug              ${_D}Show paths, PIDs, uptime, UI build info${_N}"
    echo -e "    logs [n]           ${_D}Show last n lines of logs (default 40)${_N}"
    echo -e "    nuke-logs          ${_D}Wipe all logs (gateway + ollama)${_N}"
    echo -e "    commands           ${_D}This index${_N}"
    echo ""
}

# ============================================================
# CLI DISPATCH (when run directly)
# ============================================================

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    cmd="${1:-help}"
    shift || true
    case "${cmd}" in
        start)          start_all ;;
        stop)           stop_all ;;
        stop-all)       stop_everything ;;
        status)         status_all ;;
        chat)           open_chat ;;
        sync)           sync_workspace ;;
        gateway-start)  gateway_start ;;
        gateway-stop)   gateway_stop ;;
        warmup)         ollama_warmup ;;
        unload)         ollama_unload ;;
        ollama)         ollama_info ;;
        models)         ollama_models ;;
        pull)           ollama_pull "${1:-}" ;;
        build)          build_ui "${1:-}" ;;
        ui)             ui_switch "${1:-}" ;;
        bench)          ollama_bench "${1:-}" ;;
        switch)         ollama_switch ;;
        quick-chat)     ollama_chat "${1:-}" ;;
        logs)           view_logs "${1:-40}" ;;
        security)       security_check ;;
        health)         health_check ;;
        debug)          debug_info ;;
        nuke-logs)      nuke_logs ;;
        workspace)      workspace_status ;;
        clear-workspace) clear_workspace ;;
        reset-workspace) reset_workspace ;;
        commands)       command_index ;;
        *)
            echo "Usage: ./hooks.sh <command>"
            echo ""
            echo "  start       Start gateway + warm Ollama + sync workspace"
            echo "  stop        Stop gateway"
            echo "  status      Show service status"
            echo "  chat        Open chat UI in browser"
            echo ""
            echo "  commands    Show all available commands"
            echo ""
            ;;
    esac
fi
