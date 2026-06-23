#!/bin/bash
# Install Server Monitor agent scripts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PREFIX="/share/server-monitor"
CRON_TIME="9:30"
CRON_MINUTE=""
INSTALL_CRON="1"
DRY_RUN="0"

usage() {
    cat <<'EOF'
Usage: install_agent.sh [options]

Options:
  --prefix PATH   install root (default: /share/server-monitor)
  --time HH:MM    install daily cron at time (default: 9:30)
  --minute N      install cron every N minutes
  --no-cron       do not install cron
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

copy_file() {
    local src="$1"
    local dest="$2"
    run install -m 700 "${src}" "${dest}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX="${2:-}"; shift 2 ;;
        --time) CRON_TIME="${2:-}"; CRON_MINUTE=""; shift 2 ;;
        --minute) CRON_MINUTE="${2:-}"; shift 2 ;;
        --no-cron) INSTALL_CRON="0"; shift ;;
        --dry-run) DRY_RUN="1"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

TARGET_AGENT="${PREFIX}/agent"

echo "Installing agent to ${TARGET_AGENT}"
run mkdir -p "${TARGET_AGENT}" "${PREFIX}/data" "${PREFIX}/logs" "${PREFIX}/tmp"
run mkdir -p "${TARGET_AGENT}/collectors"

copy_file "${REPO_ROOT}/agent/collect_local.sh" "${TARGET_AGENT}/collect_local.sh"
copy_file "${REPO_ROOT}/agent/setup_cron.sh" "${TARGET_AGENT}/setup_cron.sh"
copy_file "${REPO_ROOT}/agent/lib_common.sh" "${TARGET_AGENT}/lib_common.sh"
run install -m 600 "${REPO_ROOT}/agent/config.example.sh" "${TARGET_AGENT}/config.example.sh"
run install -m 700 "${REPO_ROOT}/agent/collectors/disk_smart.py" "${TARGET_AGENT}/collectors/disk_smart.py"

if [[ ! -f "${TARGET_AGENT}/config.sh" ]]; then
    run install -m 600 "${REPO_ROOT}/agent/config.example.sh" "${TARGET_AGENT}/config.sh"
else
    echo "Keeping existing ${TARGET_AGENT}/config.sh"
fi

if [[ "${INSTALL_CRON}" == "1" ]]; then
    if [[ -n "${CRON_MINUTE}" ]]; then
        run bash "${TARGET_AGENT}/setup_cron.sh" install -m "${CRON_MINUTE}"
    else
        run bash "${TARGET_AGENT}/setup_cron.sh" install -t "${CRON_TIME}"
    fi
else
    echo "Cron installation skipped"
fi

echo "Agent install complete"
