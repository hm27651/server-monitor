#!/bin/bash
# =============================================================================
# 数据收集脚本 - 主控节点专用
# =============================================================================
# 从所有采集节点拉取监控数据 JSON 文件到本地
# 使用 scp 从远程服务器拉取，拉取后可选删除远程已拉取文件
#
# 使用方式：
#   ./pull_agent_data.sh                  # 拉取所有节点数据
#   ./pull_agent_data.sh --node srv1      # 仅拉取指定节点
#   ./pull_agent_data.sh --clean-remote   # 拉取后删除远程文件
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib_common.sh"

CLEAN_REMOTE="0"
TARGET_NODE=""

validate_pulled_files() {
    local node_staging="$1"
    local fail=0
    local checked=0

    shopt -s nullglob
    local files=("${node_staging}"/data_*.json)
    shopt -u nullglob

    if [[ ${#files[@]} -eq 0 ]]; then
        log_error "本地暂存目录无数据文件: ${node_staging}"
        return 1
    fi

    for json_file in "${files[@]}"; do
        ((checked++))
        if ! validate_json_file "${json_file}"; then
            ((fail++))
        fi
    done

    if [[ ${fail} -gt 0 ]]; then
        log_error "JSON 校验失败: ${fail}/${checked} 个文件无效"
        return 1
    fi

    log_success "JSON 校验通过: ${checked} 个文件"
    return 0
}
pull_from_node() {
    local name="$1"
    local user="$2"
    local ip="$3"
    local port="$4"
    local key="$5"
    local remote_data_dir="$6"

    log_info "从节点 ${name}(${ip}) 拉取数据..."

    if ! validate_ssh_key "${key}"; then
        log_error "节点 ${name} SSH 密钥验证失败"
        return 1
    fi

    local node_staging="${STAGING_DIR}/${name}"
    mkdir -p "${node_staging}"

    local file_count
    file_count="$(ssh_remote "ls ${remote_data_dir}/data_*.json 2>/dev/null | wc -l" "${ip}" "${port}" "${user}" "${key}" 2>/dev/null)" || file_count="0"
    file_count="$(echo "${file_count}" | tr -d '[:space:]')"

    if [[ "${file_count}" == "0" || -z "${file_count}" ]]; then
        log_warn "节点 ${name}(${ip}) 无待拉取的数据文件"
        return 0
    fi

    log_info "节点 ${name} 发现 ${file_count} 个数据文件"

    local scp_exit=0
    scp -i "${key}" -P "${port}" \
        -o "StrictHostKeyChecking=${STRICT_HOST_CHECK}" \
        -o "UserKnownHostsFile=/dev/null" \
        -o "LogLevel=ERROR" \
        "${user}@${ip}:${remote_data_dir}/data_*.json" \
        "${node_staging}/" 2>/dev/null || scp_exit=$?

    if [[ ${scp_exit} -ne 0 ]]; then
        log_error "从节点 ${name}(${ip}) scp 拉取失败 (exit=${scp_exit})"
        return 1
    fi

    local pulled_count
    pulled_count="$(ls "${node_staging}"/data_*.json 2>/dev/null | wc -l)"
    log_success "节点 ${name} 拉取完成: ${pulled_count} 个文件 → ${node_staging}"

    if ! validate_pulled_files "${node_staging}"; then
        log_error "节点 ${name} 拉取文件校验失败，跳过远程清理"
        return 1
    fi

    if [[ "${CLEAN_REMOTE}" == "1" ]]; then
        log_info "清理节点 ${name} 远程已拉取文件..."
        if ssh_remote "rm -f ${remote_data_dir}/data_*.json" "${ip}" "${port}" "${user}" "${key}" 2>/dev/null; then
            log_info "节点 ${name} 远程文件已清理"
        else
            log_error "节点 ${name} 远程文件清理失败"
            return 1
        fi
    fi

    return 0
}

pull_all_nodes() {
    log_info "=========================================="
    log_info " 开始从所有采集节点拉取数据"
    log_info " 时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "=========================================="

    ensure_directories

    local success_count=0
    local fail_count=0

    for node_entry in "${AGENT_NODES[@]}"; do
        [[ -z "${node_entry}" ]] && continue

        IFS='|' read -r name user ip port key remote_dir <<< "${node_entry}"
        name="${name:-node}"
        user="${user:-root}"
        port="${port:-22}"
        key="${key:-}"
        remote_dir="${remote_dir:-/share/server-monitor/data}"

        if [[ -n "${TARGET_NODE}" && "${name}" != "${TARGET_NODE}" ]]; then
            log_debug "跳过节点 ${name}（未匹配 --node ${TARGET_NODE}）"
            continue
        fi

        if pull_from_node "${name}" "${user}" "${ip}" "${port}" "${key}" "${remote_dir}"; then
            ((success_count++))
        else
            ((fail_count++))
            log_error "节点 ${name}(${ip}) 拉取失败"
        fi
    done

    log_info "=========================================="
    log_info " 数据拉取完成"
    log_info " 成功: ${success_count}, 失败: ${fail_count}"
    log_info "=========================================="

    if [[ ${fail_count} -gt 0 ]]; then
        return 1
    fi
    return 0
}

main() {
    while [[ $# -gt 0 ]]; do
        case "${1}" in
            --clean-remote) CLEAN_REMOTE=1; shift ;;
            --node) TARGET_NODE="${2:-}"; shift 2 ;;
            --help|-h)
                echo "用法: pull_agent_data.sh [--clean-remote] [--node 节点名]"
                exit 0
                ;;
            *) shift ;;
        esac
    done

    pull_all_nodes
    return $?
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

