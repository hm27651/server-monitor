#!/bin/bash
# Remove Server Monitor scripts and cron entries. Data is preserved by default.

set -euo pipefail

PREFIX="/share/server-monitor"
TARGET="all"
PURGE_DATA="0"
DRY_RUN="0"

usage() {
    cat <<'EOF'
Usage: uninstall.sh [--agent|--master|--all] [options]

Options:
  --prefix PATH   install root (default: /share/server-monitor)
  --agent         uninstall agent only
  --master        uninstall master only
  --all           uninstall agent and master (default)
  --purge-data    also remove data/logs/tmp; keys are preserved
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

remove_user_cron_matching() {
    local pattern="$1"
    if [[ "${DRY_RUN}" == "1" ]]; then
        echo "[dry-run] remove user crontab entries matching: ${pattern}"
        return 0
    fi
    local current
    current="$(crontab -l 2>/dev/null | grep -v "${pattern}" || true)"
    printf '%s\n' "${current}" | crontab -
}

uninstall_agent() {
    if [[ -x "${PREFIX}/agent/setup_cron.sh" ]]; then
        run bash "${PREFIX}/agent/setup_cron.sh" uninstall
    else
        remove_user_cron_matching "collect_local.sh"
        run rm -f /etc/cron.d/server_monitor_agent
    fi
    run rm -rf "${PREFIX}/agent"
}

uninstall_master() {
    remove_user_cron_matching "server-monitor-master\\|run_monitor.sh"
    run rm -rf "${PREFIX}/master"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX="${2:-}"; shift 2 ;;
        --agent) TARGET="agent"; shift ;;
        --master) TARGET="master"; shift ;;
        --all) TARGET="all"; shift ;;
        --purge-data) PURGE_DATA="1"; shift ;;
        --dry-run) DRY_RUN="1"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

case "${TARGET}" in
    agent) uninstall_agent ;;
    master) uninstall_master ;;
    all) uninstall_agent; uninstall_master ;;
esac

if [[ "${PURGE_DATA}" == "1" ]]; then
    run rm -rf "${PREFIX}/data" "${PREFIX}/logs" "${PREFIX}/tmp"
else
    echo "Preserved ${PREFIX}/data, ${PREFIX}/logs, ${PREFIX}/tmp and ${PREFIX}/keys"
fi

echo "Uninstall complete"
