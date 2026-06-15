#!/bin/bash
# =============================================================================
# 本地数据采集脚本 - 采集节点专用
# =============================================================================
# 部署在每台被监控的服务器上，由 cron 每日定时触发
# 仅采集本机指标，输出 JSON 到 DATA_DIR
# 不依赖 SSH，不依赖飞书，不依赖远程连接
#
# 使用方式：
#   ./collect_local.sh                  # 采集本机数据
#   ./collect_local.sh --once           # 同上（显式单次）
#   DEBUG=1 ./collect_local.sh          # 调试模式
#
# cron 示例：
#   0 2 * * * /share/server-monitor/collect_local.sh >> /share/server-monitor/logs/cron.log 2>&1
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/lib_common.sh"

IS_LOCAL="1"
REMOTE_HOST="${NODE_IP:-$(hostname -I 2>/dev/null | awk '{print $1}' || hostname)}"
REMOTE_PORT="0"
REMOTE_USER="$(whoami)"
REMOTE_KEY_PATH=""

# =============================================================================
# 本地命令执行（替代 ssh_remote）
# =============================================================================

ssh_remote() {
    local cmd="$1"
    local exit_code=0
    local output

    output="$(bash -c "${cmd}" 2>&1)" || exit_code=$?

    if [[ ${exit_code} -ne 0 ]]; then
        debug_log "命令执行失败 (exit=${exit_code}): ${cmd}"
    fi

    echo "${output}"
    return ${exit_code}
}

# =============================================================================
# 通用采集函数（带重试）
# =============================================================================

collect_with_retry() {
    local var_name="$1"
    local collect_func="$2"
    shift 2
    local retries=0
    local result=""

    while [[ ${retries} -lt ${MAX_RETRIES} ]]; do
        result="$("${collect_func}" "$@")" && [[ -n "${result}" ]] && break
        ((retries++))
        sleep 1
    done

    printf -v "${var_name}" '%s' "${result}"
}

# =============================================================================
# 数据采集函数（与 collect_data.sh 完全一致）
# =============================================================================

collect_cpu_model() {
    local cmd="cat /proc/cpuinfo 2>/dev/null | grep 'model name' | head -1 | cut -d: -f2 | sed 's/^ *//' || echo '未知'"
    ssh_remote "${cmd}"
}

collect_cpu_cores() {
    local cmd="nproc 2>/dev/null || echo '0'"
    ssh_remote "${cmd}"
}

collect_cpu_usage() {
    local cmd='python3 -c "
import time

def read_cpu():
    with open(\"/proc/stat\", \"r\", encoding=\"utf-8\") as f:
        parts = f.readline().split()[1:]
    values = [int(x) for x in parts]
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    total = sum(values)
    return idle, total

try:
    idle1, total1 = read_cpu()
    time.sleep(0.2)
    idle2, total2 = read_cpu()
    idle_delta = idle2 - idle1
    total_delta = total2 - total1
    usage = 0.0 if total_delta <= 0 else (1.0 - idle_delta / total_delta) * 100.0
    print(f\"{usage:.2f}\")
except Exception:
    print(\"0\")
"'
    ssh_remote "${cmd}"
}

collect_cpu_temperature() {
    local cmd='python3 -c "
import os, re, subprocess

def normalize_temp(value):
    try:
        temp = float(value)
    except (TypeError, ValueError):
        return None
    if 0 <= temp <= 130:
        return temp
    return None

def collect_from_sensors():
    preferred = []
    fallback = []
    try:
        output = subprocess.check_output([\"sensors\"], text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return []
    for line in output.split(\"\\n\"):
        match = re.search(r\"([+-]?\\d+(?:\\.\\d+)?)\\s*°?C\", line)
        if not match:
            continue
        temp = normalize_temp(match.group(1))
        if temp is None:
            continue
        if re.search(r\"Package|Tctl|Tdie|CPU|Core\", line, re.IGNORECASE):
            preferred.append(temp)
        else:
            fallback.append(temp)
    return preferred or fallback

def collect_from_sysfs():
    temps = []
    base = \"/sys/class/thermal\"
    try:
        zones = sorted(name for name in os.listdir(base) if name.startswith(\"thermal_zone\"))
    except Exception:
        return temps
    for zone in zones:
        temp_path = os.path.join(base, zone, \"temp\")
        try:
            raw = open(temp_path, \"r\", encoding=\"utf-8\").read().strip()
            value = float(raw)
            if value > 1000:
                value = value / 1000.0
            temp = normalize_temp(value)
            if temp is not None:
                temps.append(temp)
        except Exception:
            continue
    return temps

temps = collect_from_sensors() or collect_from_sysfs()
if temps:
    print(f\"{max(temps):.0f}\")
else:
    print(\"N/A\")
"'
    ssh_remote "${cmd}"
}

collect_memory_info() {
    local cmd='python3 -c "
mem = {}
try:
    with open(\"/proc/meminfo\", \"r\", encoding=\"utf-8\") as f:
        for line in f:
            key, value = line.split(\":\", 1)
            mem[key] = int(value.strip().split()[0])
    total = mem.get(\"MemTotal\", 0)
    available = mem.get(
        \"MemAvailable\",
        mem.get(\"MemFree\", 0) + mem.get(\"Buffers\", 0) + mem.get(\"Cached\", 0),
    )
    used = max(total - available, 0) if total > 0 else 0
    print(f\"{total} {used}\")
except Exception:
    print(\"0 0\")
"'
    ssh_remote "${cmd}"
}

collect_memory_usage() {
    local cmd='python3 -c "
mem = {}
try:
    with open(\"/proc/meminfo\", \"r\", encoding=\"utf-8\") as f:
        for line in f:
            key, value = line.split(\":\", 1)
            mem[key] = int(value.strip().split()[0])
    total = mem.get(\"MemTotal\", 0)
    available = mem.get(
        \"MemAvailable\",
        mem.get(\"MemFree\", 0) + mem.get(\"Buffers\", 0) + mem.get(\"Cached\", 0),
    )
    used = max(total - available, 0) if total > 0 else 0
    usage = (used / total * 100.0) if total > 0 else 0.0
    print(f\"{usage:.2f}\")
except Exception:
    print(\"0\")
"'
    ssh_remote "${cmd}"
}

collect_disk_usage_all() {
    local cmd='python3 -c "
import json, subprocess
result = {}
try:
    df = subprocess.check_output([\"df\", \"-h\"], text=True, stderr=subprocess.DEVNULL)
    for line in df.strip().split(\"\\n\")[1:]:
        parts = line.split()
        if len(parts) < 6 or not parts[0].startswith(\"/dev/\"):
            continue
        if parts[0].startswith(\"/dev/loop\"):
            continue
        result[parts[0]] = parts[4].rstrip(\"%\")
except Exception:
    pass
print(json.dumps(result))
" 2>/dev/null || echo \"{}\"'
    ssh_remote "${cmd}"
}

collect_disk_list() {
    local cmd='python3 -c "
import json, subprocess

def smartctl_info(device):
    for cmd in ([\"sudo\", \"-n\", \"smartctl\", \"-i\", device], [\"smartctl\", \"-i\", device]):
        try:
            return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
        except Exception:
            continue
    return \"\"

result = []
try:
    lsblk = subprocess.check_output([\"lsblk\", \"-d\", \"-o\", \"NAME,TYPE,SIZE\", \"-n\"], text=True)
    for line in lsblk.strip().split(\"\\n\"):
        parts = line.split()
        if len(parts) >= 2 and parts[1] == \"disk\":
            device_name = parts[0]
            if device_name.startswith(\"loop\"):
                continue
            device = \"/dev/\" + device_name
            dev_type = parts[1] if len(parts) > 1 else \"disk\"
            size = parts[2] if len(parts) > 2 else \"N/A\"
            disk_info = {\"device\": device, \"type\": dev_type.upper(), \"vendor\": \"Unknown\", \"size\": size, \"sn\": \"N/A\"}
            sn = smartctl_info(device)
            for sn_line in sn.split(\"\\n\"):
                if \"Serial Number\" in sn_line:
                    disk_info[\"sn\"] = sn_line.split(\":\", 1)[-1].strip()
                if \"Vendor\" in sn_line or \"Model Number\" in sn_line or \"Device Model\" in sn_line:
                    disk_info[\"vendor\"] = sn_line.split(\":\", 1)[-1].strip()
            try:
                rot = subprocess.check_output([\"cat\", \"/sys/block/\" + device_name + \"/queue/rotational\"], text=True)
                disk_info[\"type\"] = \"HDD\" if rot.strip() == \"1\" else \"SSD\"
            except Exception:
                pass
            result.append(disk_info)
except Exception:
    pass
print(json.dumps(result))
" 2>/dev/null || echo "[]"'
    ssh_remote "${cmd}"
}

collect_disk_smart() {
    local cmd
    cmd="$(cat <<'SMART_CMD'
python3 - <<'PYSMART'
import json
import re
import subprocess


def base_result(status="N/A", temperature="N/A", source="direct"):
    health_map = {"PASS": "正常", "WARN": "关注", "FAIL": "失败", "N/A": "未知"}
    return {
        "status": status,
        "health": health_map.get(status, "未知"),
        "temperature": str(temperature) if temperature not in (None, "") else "N/A",
        "source": source,
    }


def set_metric(result, key, value):
    if value in (None, "", "N/A"):
        return
    try:
        if isinstance(value, float) and value.is_integer():
            value = int(value)
    except Exception:
        pass
    result[key] = str(value)


def first_int(value):
    if value is None:
        return None
    match = re.search(r"-?\d+", str(value))
    return int(match.group(0)) if match else None


def run_smartctl(args):
    for prefix in (["sudo", "-n"], []):
        try:
            return subprocess.check_output(prefix + ["smartctl"] + args, text=True, stderr=subprocess.STDOUT)
        except Exception:
            continue
    return ""


def run_nvme_smart_log(device):
    for prefix in (["sudo", "-n"], []):
        try:
            return subprocess.check_output(prefix + ["nvme", "smart-log", device, "-o", "json"], text=True, stderr=subprocess.STDOUT)
        except Exception:
            continue
    return ""


def health_from_status(status):
    return {"PASS": "正常", "WARN": "关注", "FAIL": "失败", "N/A": "未知"}.get(status, "未知")


def finalize(result):
    status = result.get("status", "N/A")
    result["health"] = health_from_status(status)
    return result


def status_from_critical(status, values):
    if status == "FAIL":
        return status
    for value in values:
        try:
            if int(value) != 0:
                return "WARN"
        except Exception:
            continue
    return status


def parse_nvme_smart_log(output, source="nvme_cli"):
    try:
        data = json.loads(output)
    except Exception:
        return base_result(source=source)

    status = status_from_critical("PASS", [data.get("critical_warning", 0), data.get("media_errors", 0)])
    temp = data.get("temperature")
    if isinstance(temp, (int, float)) and temp > 200:
        temp = round(temp - 273.15)
    temp = first_int(temp) if temp is not None else "N/A"
    result = base_result(status=status, temperature=temp, source=source)
    set_metric(result, "media_errors", data.get("media_errors"))
    set_metric(result, "percentage_used", data.get("percentage_used", data.get("percent_used")))
    set_metric(result, "available_spare", data.get("available_spare", data.get("avail_spare")))
    set_metric(result, "power_on_hours", data.get("power_on_hours"))
    return finalize(result)


def smart_attr_value(attr):
    raw = attr.get("raw", {})
    if isinstance(raw, dict):
        for key in ("value", "string"):
            if raw.get(key) is not None:
                return first_int(raw.get(key))
    if attr.get("raw_value") is not None:
        return first_int(attr.get("raw_value"))
    return first_int(attr.get("current"))


def smart_temp_value(attr):
    raw = attr.get("raw", {})
    if isinstance(raw, dict):
        raw_string = raw.get("string")
        if raw_string is not None:
            return first_int(raw_string)
        raw_value = raw.get("value")
        if isinstance(raw_value, (int, float)) and 0 <= raw_value <= 130:
            return int(raw_value)
    for key in ("current", "value"):
        value = attr.get(key)
        if isinstance(value, (int, float)) and 0 <= value <= 130:
            return int(value)
    return None


def parse_json_smart(output, source="direct"):
    try:
        data = json.loads(output)
    except Exception:
        return base_result(source=source)

    status = "PASS"
    smart_status = data.get("smartctl", {}).get("exit_status", 0)
    if smart_status & 0x01:
        status = "FAIL"
    if data.get("smart_status", {}).get("passed") is False:
        status = "FAIL"

    result = base_result(status=status, source=source)
    attrs_by_id = {}
    attrs_by_name = {}
    for attr in data.get("ata_smart_attributes", {}).get("table", []):
        attr_id = attr.get("id")
        name = attr.get("name")
        value = smart_attr_value(attr)
        if attr_id is not None:
            attrs_by_id[int(attr_id)] = value
        if name:
            attrs_by_name[str(name)] = value
        if name in ("Temperature_Celsius", "Airflow_Temperature_Cel") or attr_id in (190, 194):
            set_metric(result, "temperature", smart_temp_value(attr))

    top_temp = data.get("temperature")
    if result.get("temperature") == "N/A":
        if isinstance(top_temp, dict):
            set_metric(result, "temperature", top_temp.get("current"))
        elif isinstance(top_temp, (int, float)):
            set_metric(result, "temperature", top_temp)

    power_on_time = data.get("power_on_time")
    if isinstance(power_on_time, dict):
        set_metric(result, "power_on_hours", power_on_time.get("hours"))
    set_metric(result, "reallocated_sectors", data.get("scsi_grown_defect_list"))

    nvme = data.get("nvme_smart_health_information_log", {})
    if isinstance(nvme, dict):
        if result.get("temperature") == "N/A" and nvme.get("temperature") is not None:
            set_metric(result, "temperature", nvme.get("temperature"))
        set_metric(result, "media_errors", nvme.get("media_errors"))
        set_metric(result, "percentage_used", nvme.get("percentage_used"))
        set_metric(result, "available_spare", nvme.get("available_spare"))
        set_metric(result, "power_on_hours", nvme.get("power_on_hours"))
        result["status"] = status_from_critical(result.get("status", "PASS"), [nvme.get("critical_warning", 0), nvme.get("media_errors", 0)])

    metric_map = {
        "reallocated_sectors": [5, "Reallocated_Sector_Ct"],
        "pending_sectors": [197, "Current_Pending_Sector"],
        "uncorrectable_errors": [198, "Offline_Uncorrectable", "Reported_Uncorrect"],
        "crc_errors": [199, "UDMA_CRC_Error_Count"],
        "power_on_hours": [9, "Power_On_Hours"],
        "media_errors": [187, "Reported_Uncorrect"],
    }
    for metric, keys in metric_map.items():
        for key in keys:
            value = attrs_by_id.get(key) if isinstance(key, int) else attrs_by_name.get(key)
            if value is not None:
                set_metric(result, metric, value)
                break

    warn_values = [
        result.get("reallocated_sectors"),
        result.get("pending_sectors"),
        result.get("uncorrectable_errors"),
        result.get("media_errors"),
    ]
    result["status"] = status_from_critical(result.get("status", "PASS"), warn_values)
    return finalize(result)


def parse_text_smart(output, source="direct"):
    if not output:
        return base_result(source=source)
    lowered = output.lower()
    status = "PASS"
    if "smart overall-health self-assessment test result: failed" in lowered:
        status = "FAIL"
    warn_patterns = ("read nvme smart/health information failed", "input/output error", "permission denied")
    if any(pattern in lowered for pattern in warn_patterns):
        status = "WARN"
    if "smart support is:     unavailable" in lowered or "device lacks smart capability" in lowered:
        status = "N/A"

    result = base_result(status=status, source=source)
    for line in output.split("\n"):
        if "Current Drive Temperature" in line:
            match = re.search(r"(-?\d+)\s*C", line)
            if match:
                set_metric(result, "temperature", match.group(1))
            continue
        if "Temperature_Celsius" in line or "Airflow_Temperature_Cel" in line:
            parts = line.split()
            value = parts[9] if len(parts) >= 10 else line
            set_metric(result, "temperature", first_int(value))
            continue
        if line.strip().startswith("Temperature:"):
            set_metric(result, "temperature", first_int(line))
            continue
        if "Accumulated power on time" in line:
            set_metric(result, "power_on_hours", first_int(line.split(":", 1)[-1]))
            continue
        if "Elements in grown defect list" in line:
            set_metric(result, "reallocated_sectors", first_int(line.split(":", 1)[-1]))
            continue

        attr_map = {
            "Reallocated_Sector_Ct": "reallocated_sectors",
            "Current_Pending_Sector": "pending_sectors",
            "Offline_Uncorrectable": "uncorrectable_errors",
            "Reported_Uncorrect": "media_errors",
            "UDMA_CRC_Error_Count": "crc_errors",
            "Power_On_Hours": "power_on_hours",
            "Media_Wearout_Indicator": "percentage_used",
        }
        for marker, metric in attr_map.items():
            if marker in line:
                parts = line.split()
                if len(parts) >= 10:
                    set_metric(result, metric, first_int(parts[9]))
                break

    warn_values = [
        result.get("reallocated_sectors"),
        result.get("pending_sectors"),
        result.get("uncorrectable_errors"),
        result.get("media_errors"),
    ]
    result["status"] = status_from_critical(result.get("status", status), warn_values)
    return finalize(result)


def collect_standard_device(result, device_name):
    device = "/dev/" + device_name
    try:
        smart = run_smartctl(["-A", "-j", device])
        if smart.strip().startswith("{"):
            result[device] = parse_json_smart(smart, source="direct")
        else:
            result[device] = parse_text_smart(run_smartctl(["-A", device]), source="direct")
        if result[device].get("temperature") == "N/A" and device_name.startswith("nvme"):
            nvme = parse_nvme_smart_log(run_nvme_smart_log(device), source="nvme_cli")
            if nvme.get("temperature") != "N/A":
                result[device] = nvme
    except Exception:
        result[device] = parse_text_smart(run_smartctl(["-A", device]), source="direct")


def scan_raid_devices():
    output = run_smartctl(["--scan-open"])
    devices = []
    seen = set()
    for line in output.split("\n"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r"^(\S+)\s+-d\s+([^\s#]+)", line)
        if not match:
            continue
        device, dev_type = match.groups()
        if not ("megaraid" in dev_type or "aacraid" in dev_type or "cciss" in dev_type):
            continue
        key = (device, dev_type)
        if key in seen:
            continue
        seen.add(key)
        devices.append(key)
    return devices


def collect_raid_device(result, device, dev_type):
    label = f"{device}[{dev_type}]"
    output_json = run_smartctl(["-A", "-j", "-d", dev_type, device])
    if output_json.strip().startswith("{"):
        result[label] = parse_json_smart(output_json, source="raid_physical")
    else:
        output = run_smartctl(["-A", "-d", dev_type, device])
        result[label] = parse_text_smart(output, source="raid_physical")


def drop_raid_logical_noise(result):
    has_raid_physical = any(isinstance(v, dict) and v.get("source") == "raid_physical" for v in result.values())
    if not has_raid_physical:
        return result
    cleaned = {}
    for device, info in result.items():
        if not isinstance(info, dict):
            cleaned[device] = info
            continue
        if info.get("source") == "direct" and info.get("temperature") == "N/A" and device.startswith("/dev/sd"):
            continue
        cleaned[device] = info
    return cleaned


result = {}
try:
    lsblk = subprocess.check_output(["lsblk", "-d", "-o", "NAME", "-n"], text=True)
    for line in lsblk.strip().split("\n"):
        device_name = line.strip()
        if not device_name or device_name.startswith("loop"):
            continue
        collect_standard_device(result, device_name)
except Exception:
    pass

try:
    for raid_device, raid_type in scan_raid_devices():
        collect_raid_device(result, raid_device, raid_type)
except Exception:
    pass

print(json.dumps(drop_raid_logical_noise(result)))
PYSMART
SMART_CMD
)"
    ssh_remote "${cmd}"
}


collect_gpu_info() {
    local cmd='python3 -c "
import json, subprocess
result = []
try:
    nvidia = subprocess.check_output([\"nvidia-smi\", \"--query-gpu=index,name,memory.total,serial\", \"--format=csv,noheader,nounits\"], text=True)
    for line in nvidia.strip().split(\"\\n\"):
        if not line.strip():
            continue
        parts = [p.strip() for p in line.split(\",\")]
        if len(parts) >= 4:
            idx = parts[0]
            model = parts[1]
            memory_mb = parts[2]
            try:
                memory_gb = round(float(memory_mb) / 1024, 1)
                memory_str = f\"{memory_gb}GB\"
            except (ValueError, TypeError):
                memory_str = parts[2] + \"MB\" if parts[2] else \"N/A\"
            sn = parts[3] if parts[3] else \"N/A\"
            result.append({\"index\": idx, \"vendor\": \"NVIDIA\", \"model\": model, \"memory\": memory_str, \"sn\": sn})
except Exception:
    pass
print(json.dumps(result))
" 2>/dev/null || echo "[]"'
    ssh_remote "${cmd}"
}

collect_gpu_usage() {
    local cmd='python3 -c "
import json, subprocess
result = []
try:
    nvidia = subprocess.check_output([\"nvidia-smi\", \"--query-gpu=index,utilization.gpu,temperature.gpu\", \"--format=csv,noheader,nounits\"], text=True)
    for line in nvidia.strip().split(\"\\n\"):
        if not line.strip():
            continue
        parts = [p.strip() for p in line.split(\",\")]
        if len(parts) >= 3:
            result.append({\"index\": parts[0], \"usage_percent\": parts[1], \"temperature\": parts[2]})
except Exception:
    pass
print(json.dumps(result))
" 2>/dev/null || echo "[]"'
    ssh_remote "${cmd}"
}

collect_network() {
    local iface="${1}"
    local safe_iface
    if ! validate_device_name "${iface}"; then
        return 1
    fi
    safe_iface="$(printf '%s' "${iface}" | tr -cd 'a-zA-Z0-9_:.-')"
    local cmd="cat /sys/class/net/${safe_iface}/statistics/rx_bytes /sys/class/net/${safe_iface}/statistics/tx_bytes 2>/dev/null | tr '\n' ' '"
    ssh_remote "${cmd}"
}

collect_loadavg() {
    local cmd="cat /proc/loadavg 2>/dev/null | awk '{print \$1, \$2, \$3}' || echo '0 0 0'"
    ssh_remote "${cmd}"
}

collect_processes() {
    local cmd="ps aux | wc -l 2>/dev/null || echo '0'"
    ssh_remote "${cmd}"
}

# =============================================================================
# 数据格式化
# =============================================================================

json_quote() {
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}

valid_number_or_zero() {
    local value="$1"
    if [[ "${value}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s' "${value}"
    else
        printf '0'
    fi
}

valid_json_or_default() {
    local value="$1"
    local default_value="$2"
    python3 -c 'import json, sys; json.loads(sys.argv[1])' "${value}" 2>/dev/null && {
        printf '%s' "${value}"
        return
    }
    printf '%s' "${default_value}"
}

format_json() {
    local cpu_model="$1"
    local cpu_cores="$2"
    local cpu_usage="$3"
    local mem_total_kb="$4"
    local mem_used_kb="$5"
    local mem_usage="$6"
    local disk_list_json="$7"
    local disk_usage_json="$8"
    local disk_smart_json="$9"
    local gpu_list_json="${10}"
    local gpu_usage_json="${11}"
    local net_rx="${12}"
    local net_tx="${13}"
    local loadavg="${14}"
    local processes="${15}"
    local cpu_temp="${16:-N/A}"
    local timestamp
    timestamp="$(date -Iseconds)"

    local timestamp_json host_json node_name_json cpu_model_json cpu_temp_json
    timestamp_json="$(json_quote "${timestamp}")"
    host_json="$(json_quote "${REMOTE_HOST}")"
    node_name_json="$(json_quote "${NODE_NAME}")"
    cpu_model_json="$(json_quote "${cpu_model}")"
    cpu_temp_json="$(json_quote "${cpu_temp:-N/A}")"

    cpu_usage="$(valid_number_or_zero "${cpu_usage:-0}")"
    mem_total_kb="$(valid_number_or_zero "${mem_total_kb:-0}")"
    mem_used_kb="$(valid_number_or_zero "${mem_used_kb:-0}")"
    mem_usage="$(valid_number_or_zero "${mem_usage:-0}")"
    net_rx="$(valid_number_or_zero "${net_rx:-0}")"
    net_tx="$(valid_number_or_zero "${net_tx:-0}")"
    processes="$(valid_number_or_zero "${processes:-0}")"
    cpu_cores="$(valid_number_or_zero "${cpu_cores:-0}")"

    local load_1 load_5 load_15
    load_1="$(valid_number_or_zero "$(echo "${loadavg}" | awk '{print $1}')")"
    load_5="$(valid_number_or_zero "$(echo "${loadavg}" | awk '{print $2}')")"
    load_15="$(valid_number_or_zero "$(echo "${loadavg}" | awk '{print $3}')")"

    disk_list_json="$(valid_json_or_default "${disk_list_json:-[]}" '[]')"
    disk_usage_json="$(valid_json_or_default "${disk_usage_json:-}" '{}')"
    disk_smart_json="$(valid_json_or_default "${disk_smart_json:-}" '{}')"
    gpu_list_json="$(valid_json_or_default "${gpu_list_json:-[]}" '[]')"
    gpu_usage_json="$(valid_json_or_default "${gpu_usage_json:-[]}" '[]')"

    cat <<EOF
{
  "timestamp": ${timestamp_json},
  "host": ${host_json},
  "node_name": ${node_name_json},
  "metrics": {
    "cpu_info": {
      "model": ${cpu_model_json},
      "cores": ${cpu_cores}
    },
    "cpu_usage_percent": ${cpu_usage},
    "cpu_temperature": ${cpu_temp_json},
    "memory": {
      "total_kb": ${mem_total_kb},
      "used_kb": ${mem_used_kb}
    },
    "memory_usage_percent": ${mem_usage},
    "disks": ${disk_list_json},
    "disk_usage": ${disk_usage_json},
    "disk_smart": ${disk_smart_json},
    "gpu": ${gpu_list_json},
    "gpu_usage": ${gpu_usage_json},
    "network_rx_bytes": ${net_rx},
    "network_tx_bytes": ${net_tx},
    "load_average": {
      "1min": ${load_1},
      "5min": ${load_5},
      "15min": ${load_15}
    },
    "process_count": ${processes}
  },
  "thresholds": {
    "cpu": $(valid_number_or_zero "${THRESHOLD_CPU}"),
    "memory": $(valid_number_or_zero "${THRESHOLD_MEM}"),
    "disk": $(valid_number_or_zero "${THRESHOLD_DISK}")
  }
}
EOF
}

clean_json_string() {
    local json_str="$1"
    json_str="$(echo "${json_str}" | tr -d '\n\r')"
    if [[ "${json_str}" == *awk:* ]] || [[ "${json_str}" == *syntax*error* ]]; then
        echo "{}"
        return
    fi
    echo "${json_str}"
}

# =============================================================================
# 主采集流程
# =============================================================================

main_collect() {
    log_info "=========================================="
    log_info " 本地数据采集 - ${NODE_NAME}"
    log_info " 时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "=========================================="

    ensure_directories
    if [[ ! -w "${DATA_DIR}" ]]; then
        log_error "数据目录不可写: ${DATA_DIR}"
        return 1
    fi

    local cpu_model="未知" cpu_cores="0" cpu_usage="0" cpu_temp="N/A"
    local mem_total="0" mem_used="0" mem_usage="0"
    local disk_list="[]" disk_usage="{}" disk_smart="{}"
    local gpu_list="[]" gpu_usage="[]"
    local net_rx="0" net_tx="0" loadavg="0 0 0" processes="0"

    collect_with_retry cpu_model collect_cpu_model
    cpu_model="${cpu_model:-未知}"

    collect_with_retry cpu_cores collect_cpu_cores
    cpu_cores="${cpu_cores:-0}"

    collect_with_retry cpu_usage collect_cpu_usage
    cpu_usage="${cpu_usage:-0}"

    collect_with_retry cpu_temp collect_cpu_temperature
    cpu_temp="${cpu_temp:-N/A}"

    local mem_line=""
    collect_with_retry mem_line collect_memory_info
    mem_total="$(echo "${mem_line}" | awk '{print $1}')"
    mem_used="$(echo "${mem_line}" | awk '{print $2}')"
    mem_total="${mem_total:-0}"
    mem_used="${mem_used:-0}"

    collect_with_retry mem_usage collect_memory_usage
    mem_usage="${mem_usage:-0}"

    collect_with_retry disk_list collect_disk_list
    disk_list="${disk_list:-[]}"

    collect_with_retry disk_usage collect_disk_usage_all
    disk_usage="${disk_usage:-}"
    disk_usage="$(clean_json_string "${disk_usage}")"

    collect_with_retry disk_smart collect_disk_smart
    disk_smart="${disk_smart:-}"
    disk_smart="$(clean_json_string "${disk_smart}")"

    collect_with_retry gpu_list collect_gpu_info
    gpu_list="${gpu_list:-[]}"

    collect_with_retry gpu_usage collect_gpu_usage
    gpu_usage="${gpu_usage:-[]}"

    local net_rxtx=""
    collect_with_retry net_rxtx collect_network "${DEV_ETH0}"
    net_rx="$(echo "${net_rxtx}" | awk '{print $1}')"
    net_tx="$(echo "${net_rxtx}" | awk '{print $2}')"
    net_rx="${net_rx:-0}"
    net_tx="${net_tx:-0}"

    collect_with_retry loadavg collect_loadavg
    loadavg="${loadavg:-0 0 0}"

    collect_with_retry processes collect_processes
    processes="${processes:-0}"

    local json_output
    json_output="$(format_json \
        "${cpu_model}" "${cpu_cores}" "${cpu_usage}" \
        "${mem_total}" "${mem_used}" "${mem_usage}" \
        "${disk_list}" "${disk_usage}" "${disk_smart}" \
        "${gpu_list}" "${gpu_usage}" \
        "${net_rx}" "${net_tx}" "${loadavg}" "${processes}" "${cpu_temp}")"

    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"
    local output_file="${DATA_DIR}/data_${NODE_NAME}_${ts}.json"

    printf '%s\n' "${json_output}" > "${output_file}"
    if ! validate_json_file "${output_file}"; then
        log_error "采集结果 JSON 校验失败: ${output_file}"
        return 1
    fi
    log_info "数据已保存到: ${output_file}"

    log_info "CPU: ${cpu_model} (${cpu_cores}核) ${cpu_usage}% Temp: ${cpu_temp}°C"
    log_info "内存: ${mem_usage}%"
    log_info "磁盘: $(echo "${disk_usage}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(", ".join([f"{k}:{v}%" for k,v in d.items()]))' 2>/dev/null || echo 'N/A')"

    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_collect "$@"
fi




