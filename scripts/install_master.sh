#!/bin/bash
# Install Server Monitor master scripts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PREFIX="/share/server-monitor"
CRON_TIME="9:45"
WITH_CRON="0"
DRY_RUN="0"

usage() {
    cat <<'EOF'
Usage: install_master.sh [options]

Options:
  --prefix PATH   install root (default: /share/server-monitor)
  --time HH:MM    master cron time when --with-cron is used (default: 9:45)
  --with-cron     install master cron job
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

install_master_cron() {
    local hour minute cron_entry existing
    IFS=':' read -r hour minute <<< "${CRON_TIME}"
    if [[ ! "${hour}" =~ ^[0-9]{1,2}$ || ! "${minute}" =~ ^[0-9]{1,2}$ || "${hour}" -gt 23 || "${minute}" -gt 59 ]]; then
        echo "Invalid --time: ${CRON_TIME}" >&2
        return 1
    fi

    cron_entry="${minute} ${hour} * * * ${PREFIX}/master/run_monitor.sh --clean-remote >> ${PREFIX}/logs/master_cron.log 2>&1 # server-monitor-master"
    if [[ "${DRY_RUN}" == "1" ]]; then
        echo "[dry-run] install crontab entry: ${cron_entry}"
        return 0
    fi

    existing="$(crontab -l 2>/dev/null | grep -v 'server-monitor-master' || true)"
    { printf '%s\n' "${existing}"; printf '%s\n' "${cron_entry}"; } | crontab -
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX="${2:-}"; shift 2 ;;
        --time) CRON_TIME="${2:-}"; shift 2 ;;
        --with-cron) WITH_CRON="1"; shift ;;
        --dry-run) DRY_RUN="1"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

TARGET_MASTER="${PREFIX}/master"

echo "Installing master to ${TARGET_MASTER}"
run mkdir -p "${TARGET_MASTER}" "${PREFIX}/data/staging" "${PREFIX}/data/uploaded" "${PREFIX}/data/failed"
run mkdir -p "${PREFIX}/logs" "${PREFIX}/tmp" "${PREFIX}/keys"

copy_file "${REPO_ROOT}/master/run_monitor.sh" "${TARGET_MASTER}/run_monitor.sh"
copy_file "${REPO_ROOT}/master/pull_agent_data.sh" "${TARGET_MASTER}/pull_agent_data.sh"
copy_file "${REPO_ROOT}/master/upload_to_feishu.sh" "${TARGET_MASTER}/upload_to_feishu.sh"
copy_file "${REPO_ROOT}/master/lib_common.sh" "${TARGET_MASTER}/lib_common.sh"
run install -m 700 "${REPO_ROOT}/master/agent_upload.py" "${TARGET_MASTER}/agent_upload.py"
run install -m 600 "${REPO_ROOT}/master/config.example.sh" "${TARGET_MASTER}/config.example.sh"

if [[ ! -f "${TARGET_MASTER}/config.sh" ]]; then
    run install -m 600 "${REPO_ROOT}/master/config.example.sh" "${TARGET_MASTER}/config.sh"
else
    echo "Keeping existing ${TARGET_MASTER}/config.sh"
fi

if [[ "${WITH_CRON}" == "1" ]]; then
    install_master_cron
else
    echo "Master cron not installed; pass --with-cron to enable it"
fi

echo "Master install complete"
