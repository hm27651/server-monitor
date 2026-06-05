#!/bin/bash
# =============================================================================
# 采集节点定时任务管理
# =============================================================================
# 用法:
#   ./setup_cron.sh install          # 安装每日定时采集
#   ./setup_cron.sh install -t 02:00 # 每日凌晨2点采集
#   ./setup_cron.sh install -m 5     # 每5分钟采集
#   ./setup_cron.sh uninstall        # 移除定时任务
#   ./setup_cron.sh status           # 查看状态
#   ./setup_cron.sh test             # 测试运行一次
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib_common.sh"

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARNING]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

set_permissions() {
    info "设置文件安全权限..."
    chmod 600 "${SCRIPT_DIR}/config.sh" 2>/dev/null
    for f in "${SCRIPT_DIR}"/*.sh; do
        [[ -f "${f}" ]] && chmod 700 "${f}"
    done
    chmod 755 "${SCRIPT_DIR}"
    success "权限设置完成"
}

generate_cron_entry() {
    local interval="${1:-0}"
    local specific_time="${2:-}"
    local script_path="${SCRIPT_DIR}/collect_local.sh"
    local log_path="${LOG_DIR}/cron.log"

    if [[ -n "${specific_time}" ]]; then
        local hour minute
        IFS=':' read -r hour minute <<< "${specific_time}"
        if [[ "${hour}" =~ ^[0-9]{1,2}$ && "${minute}" =~ ^[0-9]{1,2}$ && "${hour}" -le 23 && "${minute}" -le 59 ]]; then
            echo "${minute} ${hour} * * * ${script_path} >> ${log_path} 2>&1"
        else
            error "无效的时间格式: ${specific_time}"
            return 1
        fi
    else
        echo "*/${interval} * * * * ${script_path} >> ${log_path} 2>&1"
    fi
}

install_cron() {
    local interval="${CRON_INTERVAL:-5}"
    local specific_time="${SPECIFIC_TIME:-}"

    info "安装采集节点定时任务..."
    set_permissions

    local cron_entry
    cron_entry="$(generate_cron_entry "${interval}" "${specific_time}")" || return 1

    info "Cron 任务配置:"
    echo "${cron_entry}"
    echo ""

    if [[ -w "/etc/cron.d" ]]; then
        echo "# 服务器监控采集节点 - ${NODE_NAME}
${cron_entry}" > /etc/cron.d/server_monitor_agent
        chmod 644 /etc/cron.d/server_monitor_agent
        success "定时任务已安装到 /etc/cron.d/server_monitor_agent"
    else
        (crontab -l 2>/dev/null | grep -v "collect_local.sh"; echo "${cron_entry}") | crontab -
        success "定时任务已安装到用户 crontab"
    fi

    echo ""
    success "安装完成！"
    echo "  节点名称: ${NODE_NAME}"
    echo "  数据目录: ${DATA_DIR}"
    echo "  日志目录: ${LOG_DIR}"
    echo ""
    info "测试运行: ${SCRIPT_DIR}/setup_cron.sh test"
}

uninstall_cron() {
    info "移除采集节点定时任务..."
    local removed=false

    if [[ -f "/etc/cron.d/server_monitor_agent" ]]; then
        rm -f /etc/cron.d/server_monitor_agent
        success "已移除 /etc/cron.d/server_monitor_agent"
        removed=true
    fi

    local crontab_content
    crontab_content="$(crontab -l 2>/dev/null | grep -v "collect_local.sh" || true)"
    if [[ -n "${crontab_content}" ]]; then
        echo "${crontab_content}" | crontab -
        removed=true
    fi

    if ${removed}; then
        success "定时任务已移除"
    else
        warn "未找到已安装的定时任务"
    fi
}

status_cron() {
    info "=== 采集节点状态 ==="
    echo "  节点名称: ${NODE_NAME}"
    echo "  数据目录: ${DATA_DIR}"
    echo "  日志目录: ${LOG_DIR}"
    echo ""

    info "=== Cron 任务 ==="
    if [[ -f "/etc/cron.d/server_monitor_agent" ]]; then
        cat /etc/cron.d/server_monitor_agent
    else
        crontab -l 2>/dev/null | grep "collect_local" || echo "(未找到)"
    fi

    echo ""
    info "=== 最近采集文件 ==="
    if [[ -d "${DATA_DIR}" ]]; then
        ls -lt "${DATA_DIR}"/data_*.json 2>/dev/null | head -5 || echo "(无数据文件)"
    else
        echo "(数据目录不存在)"
    fi

    echo ""
    info "=== 磁盘使用 ==="
    du -sh "${DATA_DIR}" 2>/dev/null || echo "(无法统计)"
}

check_command() {
    local cmd="$1"
    local required="${2:-required}"
    if command -v "${cmd}" &>/dev/null; then
        success "依赖可用: ${cmd}"
        return 0
    fi
    if [[ "${required}" == "optional" ]]; then
        warn "可选依赖缺失: ${cmd}"
        return 0
    fi
    error "必需依赖缺失: ${cmd}"
    return 1
}

check_writable_dir() {
    local dir="$1"
    mkdir -p "${dir}" 2>/dev/null || {
        error "无法创建目录: ${dir}"
        return 1
    }
    if [[ ! -w "${dir}" ]]; then
        error "目录不可写: ${dir}"
        return 1
    fi
    success "目录可写: ${dir}"
}

check_network_device() {
    local dev="$1"
    if [[ -z "${dev}" ]]; then
        warn "网卡名为空，跳过检查"
        return 0
    fi
    if ! validate_device_name "${dev}"; then
        error "网卡名不合法: ${dev}"
        return 1
    fi
    if [[ -d "/sys/class/net/${dev}" ]]; then
        success "监控网卡存在: ${dev}"
    else
        warn "监控网卡不存在: ${dev}，请按实际网卡名调整 DEV_ETH0"
    fi
}

doctor_check() {
    local fail=0

    info "=== 采集节点健康检查 ==="
    echo "  节点名称: ${NODE_NAME}"
    echo "  节点 IP: ${NODE_IP:-自动获取}"
    echo "  数据目录: ${DATA_DIR}"
    echo "  日志目录: ${LOG_DIR}"
    echo "  主网卡: ${DEV_ETH0}"
    echo ""

    check_command bash || fail=1
    check_command python3 || fail=1
    check_command awk || fail=1
    check_command sed || fail=1
    check_command grep || fail=1
    check_command nproc || fail=1
    check_command free || fail=1
    check_command df || fail=1
    check_command lsblk || fail=1
    check_command top || fail=1
    check_command smartctl optional || true
    check_command nvidia-smi optional || true

    check_writable_dir "${DATA_DIR}" || fail=1
    check_writable_dir "${LOG_DIR}" || fail=1
    check_writable_dir "${TMP_DIR}" || fail=1
    check_network_device "${DEV_ETH0}" || fail=1

    if (( fail == 0 )); then
        success "健康检查通过"
    else
        error "健康检查存在失败项"
        return 1
    fi
}
test_run() {
    info "执行测试采集..."
    "${SCRIPT_DIR}/collect_local.sh"
    if [[ $? -ne 0 ]]; then
        error "测试采集失败"
        return 1
    fi

    success "测试采集成功"
    info "数据文件:"
    ls -lt "${DATA_DIR}"/data_*.json 2>/dev/null | head -3

    local latest_file
    latest_file="$(ls -t "${DATA_DIR}"/data_*.json 2>/dev/null | head -1 || true)"
    if [[ -z "${latest_file}" ]]; then
        error "未找到测试采集生成的数据文件"
        return 1
    fi

    if validate_json_file "${latest_file}"; then
        success "JSON 校验通过: ${latest_file}"
    else
        error "JSON 校验失败: ${latest_file}"
        return 1
    fi
}

main() {
    local command="${1:-install}"

    case "${command}" in
        install)
            shift
            while [[ $# -gt 0 ]]; do
                case "${1}" in
                    -m|--minute)  CRON_INTERVAL="${2:-5}"; shift 2 ;;
                    -t|--time)    SPECIFIC_TIME="${2:-}"; shift 2 ;;
                    *) shift ;;
                esac
            done
            install_cron
            ;;
        uninstall) uninstall_cron ;;
        status)    status_cron ;;
        test)      test_run ;;
        doctor)    doctor_check ;;
        help|--help|-h)
            echo "用法: setup_cron.sh [install|uninstall|status|test|doctor] [-m 分钟|-t HH:MM]"
            ;;
        *)
            error "未知命令: ${command}"
            exit 1
            ;;
    esac
}

main "$@"


