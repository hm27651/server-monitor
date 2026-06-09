#!/bin/bash
# =============================================================================
# 主控节点配置 - 部署在主服务器上
# =============================================================================
# 包含：飞书凭证、采集节点列表、SSH连接参数、数据收集目录
# =============================================================================

# -----------------------------------------------------------------------------
# 飞书多维表格配置（敏感凭证优先从环境变量读取）
# -----------------------------------------------------------------------------
FEISHU_APP_TOKEN="${FEISHU_APP_TOKEN:-your_bitable_app_token}"
FEISHU_TABLE_ID="${FEISHU_TABLE_ID:-your_table_id}"
FEISHU_ACCESS_TOKEN="${FEISHU_ACCESS_TOKEN:-}"
FEISHU_APP_ID="${FEISHU_APP_ID:-your_app_id}"
FEISHU_APP_SECRET="${FEISHU_APP_SECRET:-your_app_secret}"

FEISHU_FIELD_TIME="时间"
FEISHU_FIELD_IP="IP地址"
FEISHU_FIELD_DEVICE_NAME="设备名称"
FEISHU_FIELD_CPU_INFO="CPU信息"
FEISHU_FIELD_CPU_USAGE="CPU使用率"
FEISHU_FIELD_CPU_TEMP="CPU温度"
FEISHU_FIELD_MEMORY="内存"
FEISHU_FIELD_MEM_USAGE="内存使用率"
FEISHU_FIELD_DISK_LIST="磁盘列表"
FEISHU_FIELD_DISK_USAGE="磁盘使用率"
FEISHU_FIELD_DISK_SMART="磁盘S.M.A.R.T."
FEISHU_FIELD_GPU_LIST="GPU列表"
FEISHU_FIELD_GPU_USAGE="GPU使用率"

# -----------------------------------------------------------------------------
# 采集节点列表（主服务器从此列表拉取数据）
# 格式: 节点名|SSH用户|IP|SSH端口|SSH密钥路径|远程数据目录
# -----------------------------------------------------------------------------
AGENT_NODES=(
    "node-1|user|192.168.2.101|22|/share/server-monitor/keys/id_rsa-node-1|/share/server-monitor/data"
)

# -----------------------------------------------------------------------------
# SSH 连接配置（主服务器连接采集节点用）
# -----------------------------------------------------------------------------
SSH_TIMEOUT="10"
STRICT_HOST_CHECK="accept-new"
MAX_RETRIES="3"

# -----------------------------------------------------------------------------
# 日志与数据目录
# -----------------------------------------------------------------------------
LOG_DIR="/share/server-monitor/logs"
DATA_DIR="/share/server-monitor/data"
STAGING_DIR="${DATA_DIR}/staging"
TMP_DIR="/share/server-monitor/tmp"

# -----------------------------------------------------------------------------
# 日志轮转
# -----------------------------------------------------------------------------
LOG_ROTATE_DAYS="${LOG_ROTATE_DAYS:-7}"

# =============================================================================
# 辅助函数
# =============================================================================

ensure_directories() {
    mkdir -p "${LOG_DIR}" "${DATA_DIR}" "${STAGING_DIR}" "${TMP_DIR}" 2>/dev/null
}

validate_ssh_key() {
    local key_path="$1"
    if [[ ! -f "${key_path}" ]]; then
        echo "ERROR: SSH 密钥文件不存在: ${key_path}" >&2
        return 1
    fi
    local key_perms
    key_perms="$(stat -c '%a' "${key_path}" 2>/dev/null)"
    if [[ "${key_perms}" != "600" && "${key_perms}" != "400" ]]; then
        echo "WARNING: SSH 密钥权限为 ${key_perms}，建议设为 600" >&2
    fi
    return 0
}

debug_log() {
    if [[ "${DEBUG}" == "1" ]]; then
        echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ensure_directories
fi
