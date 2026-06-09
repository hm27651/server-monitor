#!/bin/bash
# =============================================================================
# 主控节点编排脚本 - 分布式架构版
# =============================================================================
# 流程：拉取数据 → 格式化基础硬件性能数据 → 上传飞书
#
# 使用方式：
#   ./run_monitor.sh                  # 完整流程
#   ./run_monitor.sh --dry-run        # 仅拉取+格式化，不上传
#   ./run_monitor.sh --pull-only      # 仅拉取数据
#   ./run_monitor.sh --upload-only    # 仅上传已有数据
# =============================================================================

set -o pipefail
set -o errtrace
set -o functrace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULL_SCRIPT="${SCRIPT_DIR}/pull_agent_data.sh"
UPLOAD_SCRIPT="${SCRIPT_DIR}/agent_upload.py"

MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-15}"
DRY_RUN="${DRY_RUN:-0}"
PULL_ONLY="0"
UPLOAD_ONLY="0"

declare -i EXIT_CODE=0

init_logging() {
    mkdir -p "${LOG_DIR}"
    TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
    LOG_FILE="${LOG_DIR}/run_monitor_${TIMESTAMP}.log"
    SUMMARY_FILE="${LOG_DIR}/summary_${TIMESTAMP}.log"
    ERROR_FILE="${LOG_DIR}/errors_${TIMESTAMP}.log"
    : > "${LOG_FILE}"
    : > "${SUMMARY_FILE}"
    : > "${ERROR_FILE}"
    rotate_logs "${LOG_DIR}" "${LOG_ROTATE_DAYS}"
}

run_log_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s\n' "${msg}" | tee -a "${LOG_FILE}"
    else
        printf '%s\n' "${msg}"
    fi
}

run_log_warn() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*"
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s\n' "${msg}" | tee -a "${LOG_FILE}"
    else
        printf '%s\n' "${msg}"
    fi
}

run_log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"
    if [[ -n "${LOG_FILE:-}" && -n "${ERROR_FILE:-}" ]]; then
        printf '%s\n' "${msg}" | tee -a "${LOG_FILE}" | tee -a "${ERROR_FILE}" >&2
    else
        printf '%s\n' "${msg}" >&2
    fi
}

run_log_summary() { printf '%s\n' "$*" >> "${SUMMARY_FILE}"; }

preflight_check() {
    run_log_info "========== 前置检查 =========="

    if [[ ! -f "${PULL_SCRIPT}" ]]; then
        run_log_error "数据拉取脚本不存在: ${PULL_SCRIPT}"
        return 1
    fi
    if [[ ! -x "${PULL_SCRIPT}" ]]; then
        chmod +x "${PULL_SCRIPT}" 2>/dev/null
    fi

    if [[ ! -f "${UPLOAD_SCRIPT}" ]]; then
        run_log_error "上传脚本不存在: ${UPLOAD_SCRIPT}"
        return 1
    fi

    if ! command -v python3 &>/dev/null; then
        run_log_error "python3 未找到"
        return 1
    fi

    if [[ -z "${FEISHU_ACCESS_TOKEN:-}" && "${DRY_RUN}" != "1" && "${PULL_ONLY}" != "1" ]]; then
        if [[ -n "${FEISHU_APP_ID:-}" && -n "${FEISHU_APP_SECRET:-}" ]]; then
            run_log_info "FEISHU_ACCESS_TOKEN 未设置，将通过 FEISHU_APP_ID/FEISHU_APP_SECRET 自动刷新"
        else
            run_log_warn "FEISHU_ACCESS_TOKEN 未设置，且未配置自动刷新凭证，上传可能失败"
        fi
    fi

    run_log_info "飞书字段: ${FEISHU_FIELD_TIME}, ${FEISHU_FIELD_IP}, ${FEISHU_FIELD_DEVICE_NAME}, ${FEISHU_FIELD_CPU_INFO}, ${FEISHU_FIELD_CPU_USAGE}, ${FEISHU_FIELD_CPU_TEMP}, ${FEISHU_FIELD_MEMORY}, ${FEISHU_FIELD_MEM_USAGE}, ${FEISHU_FIELD_DISK_LIST}, ${FEISHU_FIELD_DISK_USAGE}, ${FEISHU_FIELD_DISK_SMART}, ${FEISHU_FIELD_GPU_LIST}, ${FEISHU_FIELD_GPU_USAGE}"
    run_log_info "✓ 前置检查通过"
    return 0
}

step_pull() {
    run_log_info ""
    run_log_info "========== 步骤1: 拉取采集节点数据 =========="

    local pull_args=""
    if [[ "${CLEAN_REMOTE:-0}" == "1" ]]; then
        pull_args="--clean-remote"
    fi

    if retry_execute "拉取采集节点数据" "${MAX_RETRIES}" "${RETRY_DELAY}" "${PULL_SCRIPT}" ${pull_args}; then
        run_log_summary "[数据拉取] 成功"
    else
        run_log_error "数据拉取失败"
        run_log_summary "[数据拉取] 失败"
        EXIT_CODE=1
        return 1
    fi
    return 0
}

step_upload() {
    run_log_info ""
    run_log_info "========== 步骤2: 格式化并上传基础硬件性能数据 =========="

    if [[ "${DRY_RUN}" == "1" ]]; then
        run_log_warn "DRY_RUN=1，跳过实际上传"
        run_log_summary "[基础硬件数据上传] 跳过 (dry-run)"

        run_log_info "dry-run: 扫描待上传的基础硬件数据文件..."
        python3 "${UPLOAD_SCRIPT}" --all --data-dir "${DATA_DIR}" 2>&1 | tee -a "${LOG_FILE}" || true
        return 0
    fi

    if retry_execute "上传基础硬件性能数据到飞书" "${MAX_RETRIES}" "${RETRY_DELAY}" python3 "${UPLOAD_SCRIPT}" --all --upload --data-dir "${DATA_DIR}"; then
        run_log_summary "[基础硬件数据上传] 成功"
    else
        run_log_error "基础硬件数据上传失败"
        run_log_summary "[基础硬件数据上传] 失败"
        EXIT_CODE=1
        return 1
    fi
    return 0
}

print_summary() {
    run_log_info ""
    run_log_info "=========================================="
    run_log_info "执行结果摘要"
    run_log_info "=========================================="
    run_log_info "开始时间: ${TIMESTAMP}"
    run_log_info "结束时间: $(date '+%Y-%m-%d %H:%M:%S')"
    run_log_info "Dry-Run:  ${DRY_RUN}"
    run_log_info "详细日志: ${LOG_FILE}"
    run_log_info "错误日志: ${ERROR_FILE}"
    run_log_info "摘要日志: ${SUMMARY_FILE}"
    run_log_info "=========================================="

    echo ""
    echo "========== 执行结果摘要 =========="
    cat "${SUMMARY_FILE}"
    echo "==================================="

    if (( EXIT_CODE == 0 )); then
        echo "✅ 全部成功"
    else
        echo "❌ 存在失败，请检查 ${ERROR_FILE}"
    fi
}

on_trap() {
    local lineno="${1:-unknown}"
    run_log_error "脚本被中断 (触发行: ${lineno})"
    print_summary
    exit 3
}

show_help() {
    cat << 'EOF'
用法: run_monitor.sh [选项]

选项:
  --dry-run       仅拉取+格式化基础硬件性能数据，不上传到飞书
  --pull-only     仅拉取数据，不上传
  --upload-only   仅上传已有数据，不拉取
  --clean-remote  拉取后删除远程节点已拉取的文件
  --max-retries N 设置最大重试次数 (默认: 3)
  --retry-delay N 设置重试间隔秒数 (默认: 15)
  --help          显示本帮助信息

环境变量:
  DRY_RUN=1             同 --dry-run
  FEISHU_ACCESS_TOKEN   飞书访问令牌（上传时必须）
  FEISHU_APP_TOKEN      飞书 App Token
  FEISHU_TABLE_ID       飞书 Table ID
  MAX_RETRIES=5         最大重试次数
  DEBUG=1               启用调试输出

示例:
  ./run_monitor.sh                    # 完整流程
  ./run_monitor.sh --dry-run         # 仅拉取+格式化基础硬件性能数据
  ./run_monitor.sh --pull-only       # 仅拉取数据
  ./run_monitor.sh --upload-only     # 仅上传已有数据
  ./run_monitor.sh --clean-remote    # 拉取后清理远程文件
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)      DRY_RUN=1; shift ;;
            --pull-only)    PULL_ONLY=1; shift ;;
            --upload-only)  UPLOAD_ONLY=1; shift ;;
            --clean-remote) CLEAN_REMOTE=1; shift ;;
            --max-retries)  MAX_RETRIES="$2"; shift 2 ;;
            --retry-delay)  RETRY_DELAY="$2"; shift 2 ;;
            --help)         show_help; exit 0 ;;
            -*)             run_log_error "未知选项: $1"; show_help; exit 1 ;;
            *)              shift ;;
        esac
    done

    source "${SCRIPT_DIR}/lib_common.sh"
    source "${SCRIPT_DIR}/config.sh"
    export FEISHU_APP_TOKEN FEISHU_TABLE_ID FEISHU_ACCESS_TOKEN FEISHU_APP_ID FEISHU_APP_SECRET
    export FEISHU_FIELD_TIME FEISHU_FIELD_IP FEISHU_FIELD_DEVICE_NAME FEISHU_FIELD_CPU_INFO FEISHU_FIELD_CPU_USAGE FEISHU_FIELD_CPU_TEMP
    export FEISHU_FIELD_MEMORY FEISHU_FIELD_MEM_USAGE FEISHU_FIELD_DISK_LIST
    export FEISHU_FIELD_DISK_USAGE FEISHU_FIELD_DISK_SMART FEISHU_FIELD_GPU_LIST
    export FEISHU_FIELD_GPU_USAGE

    init_logging

    trap 'on_trap ${LINENO}' INT TERM

    run_log_info "=========================================="
    run_log_info "主控节点监控任务开始"
    run_log_info "=========================================="

    if ! preflight_check; then
        run_log_error "前置检查失败"
        exit 1
    fi

    if [[ "${UPLOAD_ONLY}" == "1" ]]; then
        step_upload
    elif [[ "${PULL_ONLY}" == "1" ]]; then
        step_pull
    else
        if step_pull; then
            step_upload
        else
            run_log_warn "数据拉取失败，跳过上传"
        fi
    fi

    print_summary
    return "${EXIT_CODE}"
}

main "$@"



