#!/bin/bash
# =============================================================================
# 采集节点公共函数库（精简版）
# =============================================================================
# 仅包含采集节点所需的函数：日志、重试、格式化、JSON校验
# 不包含 SSH 远程执行函数（采集节点仅本地执行）
# =============================================================================

_LIB_COMMON_LOADED="1"

if [[ -t 1 ]]; then
    _LOG_COLOR_RED='\033[0;31m'
    _LOG_COLOR_GREEN='\033[0;32m'
    _LOG_COLOR_YELLOW='\033[1;33m'
    _LOG_COLOR_BLUE='\033[0;34m'
    _LOG_COLOR_RESET='\033[0m'
else
    _LOG_COLOR_RED=''
    _LOG_COLOR_GREEN=''
    _LOG_COLOR_YELLOW=''
    _LOG_COLOR_BLUE=''
    _LOG_COLOR_RESET=''
fi

_LOG_FILE="${_LOG_FILE:-}"

_log_init() {
    local log_dir="$1"
    local prefix="$2"
    mkdir -p "${log_dir}"
    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"
    _LOG_FILE="${log_dir}/${prefix}_${ts}.log"
    : > "${_LOG_FILE}"
}

_log() {
    local level="$1"
    shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
    printf '%s\n' "${msg}"
    if [[ -n "${_LOG_FILE}" ]]; then
        printf '%s\n' "${msg}" >> "${_LOG_FILE}"
    fi
}

log_info()  { _log "INFO"    "$@"; }
log_warn()  { _log "WARN"    "$@"; }
log_error() { _log "ERROR"   "$@" >&2; }
log_debug() {
    [[ "${DEBUG:-0}" == "1" ]] || [[ "${DEBUG^^}" == "TRUE" ]] || return 0
    _log "DEBUG" "$@"
}
log_success() { _log "SUCCESS" "$@"; }

retry_execute() {
    local desc="$1"
    local max_retries="${2:-3}"
    local retry_delay="${3:-5}"
    shift 3

    local attempt=1
    local exit_code=0

    while (( attempt <= max_retries )); do
        log_info "[${attempt}/${max_retries}] ${desc}"
        if (( attempt > 1 )); then
            log_warn "等待 ${retry_delay}s 后重试..."
            sleep "${retry_delay}"
        fi
        "$@"
        exit_code=$?
        if (( exit_code == 0 )); then
            log_info "[${attempt}/${max_retries}] ${desc} - 成功"
            return 0
        fi
        log_warn "[${attempt}/${max_retries}] ${desc} - 失败 (exit=${exit_code})"
        ((attempt++))
    done
    log_error "${desc} 在 ${max_retries} 次尝试后仍然失败"
    return 1
}

format_bytes() {
    local bytes="$1"
    if [[ -z "${bytes}" || "${bytes}" == "0" || "${bytes}" == "N/A" ]]; then
        echo "0 B"
        return
    fi
    awk -v b="${bytes}" 'BEGIN {
        if (b >= 1073741824) printf "%.2f GB", b/1073741824
        else if (b >= 1048576) printf "%.2f MB", b/1048576
        else if (b >= 1024) printf "%.2f KB", b/1024
        else printf "%d B", b
    }' 2>/dev/null || echo "${bytes} B"
}

format_uptime() {
    local seconds="$1"
    if [[ -z "${seconds}" || "${seconds}" == "N/A" ]]; then
        echo "N/A"
        return
    fi
    local days=$((seconds / 86400))
    local hours=$(( (seconds % 86400) / 3600 ))
    local minutes=$(( (seconds % 3600) / 60 ))
    if [[ ${days} -gt 0 ]]; then
        printf "%dd %dh %dm" "${days}" "${hours}" "${minutes}"
    elif [[ ${hours} -gt 0 ]]; then
        printf "%dh %dm" "${hours}" "${minutes}"
    else
        printf "%dm" "${minutes}"
    fi
}

validate_json_file() {
    local json_file="$1"
    if [[ ! -f "${json_file}" ]]; then
        log_error "JSON 文件不存在: ${json_file}"
        return 1
    fi
    if [[ ! -s "${json_file}" ]]; then
        log_error "JSON 文件为空: ${json_file}"
        return 1
    fi
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1],'r',encoding='utf-8-sig'))" "${json_file}" 2>/dev/null; then
        log_error "JSON 文件格式无效: ${json_file}"
        return 1
    fi
    return 0
}

rotate_logs() {
    local log_dir="$1"
    local days="${2:-7}"
    local prefix="${3:-}"
    if [[ ! -d "${log_dir}" ]]; then
        return
    fi
    if [[ -n "${prefix}" ]]; then
        find "${log_dir}" -maxdepth 1 -name "${prefix}*.log" -mtime +"${days}" -delete 2>/dev/null
    else
        find "${log_dir}" -maxdepth 1 -name '*.log' -mtime +"${days}" -delete 2>/dev/null
    fi
}

