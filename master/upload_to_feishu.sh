#!/bin/bash
# =============================================================================
# 基础硬件性能数据上传脚本 - 主控节点薄包装层
# =============================================================================
# 内部调用 agent_upload.py 执行实际工作
#
# 使用方式：
#   ./upload_to_feishu.sh -a                # dry-run：查看基础硬件性能数据
#   ./upload_to_feishu.sh -a --upload       # 实际上传基础硬件性能数据
#   DO_UPLOAD=true ./upload_to_feishu.sh -a # 通过环境变量启用上传
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

PYTHON_SCRIPT="${SCRIPT_DIR}/agent_upload.py"

if ! command -v python3 &>/dev/null; then
    echo "[ERROR] python3 未安装" >&2
    exit 1
fi

if [[ ! -f "${PYTHON_SCRIPT}" ]]; then
    echo "[ERROR] 上传脚本不存在: ${PYTHON_SCRIPT}" >&2
    exit 1
fi

ARGS=()
DO_UPLOAD_FLAG=""
HAS_DATA_DIR_ARG="0"

while [[ $# -gt 0 ]]; do
    case "${1}" in
        -u|--upload)
            DO_UPLOAD_FLAG="--upload"
            shift
            ;;
        --dry-run|--no-upload)
            DO_UPLOAD_FLAG=""
            shift
            ;;
        -f|--file)
            ARGS+=("--file" "${2:-}")
            shift 2
            ;;
        -a|--all)
            ARGS+=("--all")
            shift
            ;;
        --data-dir)
            HAS_DATA_DIR_ARG="1"
            ARGS+=("--data-dir" "${2:-}")
            shift 2
            ;;
        -s|--server)
            ARGS+=("--file")
            shift
            target_server="${1:-}"
            if [[ -n "${target_server}" ]]; then
                matched_file="$(find "${STAGING_DIR}" "${DATA_DIR}" -name "data_*${target_server}*.json" -type f 2>/dev/null | sort | tail -1)"
                if [[ -n "${matched_file}" ]]; then
                    ARGS+=("${matched_file}")
                else
                    echo "[ERROR] 未找到服务器 ${target_server} 的数据文件" >&2
                    exit 1
                fi
            fi
            shift
            ;;
        -h|--help)
            python3 "${PYTHON_SCRIPT}" --help
            exit 0
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

if [[ "${DO_UPLOAD}" == "true" || "${DO_UPLOAD}" == "1" ]]; then
    DO_UPLOAD_FLAG="--upload"
fi

if [[ ${#ARGS[@]} -eq 0 ]]; then
    ARGS+=("--all")
fi

if [[ "${HAS_DATA_DIR_ARG}" != "1" ]]; then
    ARGS+=("--data-dir" "${DATA_DIR}")
fi

export FEISHU_APP_TOKEN
export FEISHU_TABLE_ID
export FEISHU_ACCESS_TOKEN
export FEISHU_APP_ID
export FEISHU_APP_SECRET
export DATA_DIR

exec python3 "${PYTHON_SCRIPT}" ${DO_UPLOAD_FLAG} "${ARGS[@]}"
