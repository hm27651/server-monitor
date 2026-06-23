#!/bin/bash
# Update installed Server Monitor scripts while preserving local config and data.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PREFIX="/share/server-monitor"
TARGET="all"
DRY_RUN="0"

usage() {
    cat <<'EOF'
Usage: update.sh [--agent|--master|--all] [options]

Options:
  --prefix PATH   install root (default: /share/server-monitor)
  --agent         update agent only
  --master        update master only
  --all           update agent and master (default)
  --dry-run       print actions without changing files
  -h, --help      show help
EOF
}

run() {
    if [[ "${DRY_RUN}" == "1" ]]; then
        printf '[dry-run]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

copy_exec() {
    run install -m 700 "$1" "$2"
}

update_agent() {
    local target="${PREFIX}/agent"
    run mkdir -p "${target}/collectors"
    copy_exec "${REPO_ROOT}/agent/collect_local.sh" "${target}/collect_local.sh"
    copy_exec "${REPO_ROOT}/agent/setup_cron.sh" "${target}/setup_cron.sh"
    copy_exec "${REPO_ROOT}/agent/lib_common.sh" "${target}/lib_common.sh"
    copy_exec "${REPO_ROOT}/agent/collectors/disk_smart.py" "${target}/collectors/disk_smart.py"
    run install -m 600 "${REPO_ROOT}/agent/config.example.sh" "${target}/config.example.sh"
    echo "Keeping existing ${target}/config.sh"
}

update_master() {
    local target="${PREFIX}/master"
    run mkdir -p "${target}"
    copy_exec "${REPO_ROOT}/master/run_monitor.sh" "${target}/run_monitor.sh"
    copy_exec "${REPO_ROOT}/master/pull_agent_data.sh" "${target}/pull_agent_data.sh"
    copy_exec "${REPO_ROOT}/master/upload_to_feishu.sh" "${target}/upload_to_feishu.sh"
    copy_exec "${REPO_ROOT}/master/lib_common.sh" "${target}/lib_common.sh"
    copy_exec "${REPO_ROOT}/master/agent_upload.py" "${target}/agent_upload.py"
    run install -m 600 "${REPO_ROOT}/master/config.example.sh" "${target}/config.example.sh"
    echo "Keeping existing ${target}/config.sh"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX="${2:-}"; shift 2 ;;
        --agent) TARGET="agent"; shift ;;
        --master) TARGET="master"; shift ;;
        --all) TARGET="all"; shift ;;
        --dry-run) DRY_RUN="1"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

case "${TARGET}" in
    agent) update_agent ;;
    master) update_master ;;
    all) update_agent; update_master ;;
esac

echo "Update complete"
