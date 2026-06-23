#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Collect and parse disk S.M.A.R.T. data.

The module is intentionally dependency-free so it can run on minimal Linux
agent nodes. It supports direct disks, NVMe fallback via nvme-cli, and physical
drives behind common RAID controllers exposed by smartctl --scan-open.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Any, Dict, Iterable, List, Optional, Tuple


COMMAND_TIMEOUT = float(os.environ.get("SMARTCTL_TIMEOUT", "10"))
RAID_TYPES = ("megaraid", "aacraid", "cciss")


def base_result(status: str = "N/A", temperature: Any = "N/A", source: str = "direct") -> Dict[str, str]:
    health_map = {"PASS": "正常", "WARN": "关注", "FAIL": "失败", "N/A": "未知"}
    return {
        "status": status,
        "health": health_map.get(status, "未知"),
        "temperature": str(temperature) if temperature not in (None, "") else "N/A",
        "source": source,
    }


def set_metric(result: Dict[str, str], key: str, value: Any) -> None:
    if value in (None, "", "N/A"):
        return
    try:
        if isinstance(value, float) and value.is_integer():
            value = int(value)
    except Exception:
        pass
    result[key] = str(value)


def first_int(value: Any) -> Optional[int]:
    if value is None:
        return None
    match = re.search(r"-?\d+", str(value))
    return int(match.group(0)) if match else None


def _looks_like_sudo_auth_failure(output: str) -> bool:
    lowered = output.lower()
    return (
        "a password is required" in lowered
        or "sudo: a terminal is required" in lowered
        or "sudo: no tty present" in lowered
        or "not in the sudoers" in lowered
        or "command not found" in lowered
        or "no such file or directory" in lowered
    )


def run_command(args: List[str], timeout: float = COMMAND_TIMEOUT) -> str:
    try:
        completed = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            check=False,
        )
    except Exception:
        return ""
    return completed.stdout or ""


def run_privileged(tool: str, args: List[str], timeout: float = COMMAND_TIMEOUT) -> str:
    for prefix in (["sudo", "-n"], []):
        output = run_command(prefix + [tool] + args, timeout=timeout)
        if prefix and _looks_like_sudo_auth_failure(output):
            continue
        if output:
            return output
    return ""


def run_smartctl(args: List[str], timeout: float = COMMAND_TIMEOUT) -> str:
    return run_privileged("smartctl", args, timeout=timeout)


def run_nvme_smart_log(device: str, timeout: float = COMMAND_TIMEOUT) -> str:
    return run_privileged("nvme", ["smart-log", device, "-o", "json"], timeout=timeout)


def health_from_status(status: str) -> str:
    return {"PASS": "正常", "WARN": "关注", "FAIL": "失败", "N/A": "未知"}.get(status, "未知")


def finalize(result: Dict[str, str]) -> Dict[str, str]:
    result["health"] = health_from_status(result.get("status", "N/A"))
    return result


def status_from_critical(status: str, values: Iterable[Any]) -> str:
    if status == "FAIL":
        return status
    for value in values:
        try:
            if int(value) != 0:
                return "WARN"
        except Exception:
            continue
    return status


def parse_nvme_smart_log(output: str, source: str = "nvme_cli") -> Dict[str, str]:
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


def smart_attr_value(attr: Dict[str, Any]) -> Optional[int]:
    raw = attr.get("raw", {})
    if isinstance(raw, dict):
        for key in ("value", "string"):
            if raw.get(key) is not None:
                return first_int(raw.get(key))
    if attr.get("raw_value") is not None:
        return first_int(attr.get("raw_value"))
    return first_int(attr.get("current"))


def smart_temp_value(attr: Dict[str, Any]) -> Optional[int]:
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


def parse_json_smart(output: str, source: str = "direct") -> Dict[str, str]:
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
    attrs_by_id: Dict[int, Optional[int]] = {}
    attrs_by_name: Dict[str, Optional[int]] = {}
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
        result["status"] = status_from_critical(
            result.get("status", "PASS"),
            [nvme.get("critical_warning", 0), nvme.get("media_errors", 0)],
        )

    metric_map: Dict[str, List[Any]] = {
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


def parse_text_smart(output: str, source: str = "direct") -> Dict[str, str]:
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


def collect_standard_device(result: Dict[str, Dict[str, str]], device_name: str) -> None:
    device = "/dev/" + device_name
    smart = run_smartctl(["-A", "-j", device])
    if smart.strip().startswith("{"):
        result[device] = parse_json_smart(smart, source="direct")
    else:
        result[device] = parse_text_smart(run_smartctl(["-A", device]), source="direct")
    if result[device].get("temperature") == "N/A" and device_name.startswith("nvme"):
        nvme = parse_nvme_smart_log(run_nvme_smart_log(device), source="nvme_cli")
        if nvme.get("temperature") != "N/A":
            result[device] = nvme


def scan_raid_devices() -> List[Tuple[str, str]]:
    output = run_smartctl(["--scan-open"])
    devices: List[Tuple[str, str]] = []
    seen = set()
    for line in output.split("\n"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r"^(\S+)\s+-d\s+([^\s#]+)", line)
        if not match:
            continue
        device, dev_type = match.groups()
        if not any(raid_type in dev_type for raid_type in RAID_TYPES):
            continue
        key = (device, dev_type)
        if key in seen:
            continue
        seen.add(key)
        devices.append(key)
    return devices


def collect_raid_device(result: Dict[str, Dict[str, str]], device: str, dev_type: str) -> None:
    label = f"{device}[{dev_type}]"
    output_json = run_smartctl(["-A", "-j", "-d", dev_type, device])
    if output_json.strip().startswith("{"):
        result[label] = parse_json_smart(output_json, source="raid_physical")
    else:
        output = run_smartctl(["-A", "-d", dev_type, device])
        result[label] = parse_text_smart(output, source="raid_physical")


def drop_raid_logical_noise(result: Dict[str, Dict[str, str]]) -> Dict[str, Dict[str, str]]:
    has_raid_physical = any(isinstance(v, dict) and v.get("source") == "raid_physical" for v in result.values())
    if not has_raid_physical:
        return result
    cleaned: Dict[str, Dict[str, str]] = {}
    for device, info in result.items():
        if not isinstance(info, dict):
            cleaned[device] = info
            continue
        if info.get("source") == "direct" and info.get("temperature") == "N/A" and device.startswith("/dev/sd"):
            continue
        cleaned[device] = info
    return cleaned


def list_block_devices() -> List[str]:
    output = run_command(["lsblk", "-d", "-o", "NAME", "-n"])
    devices = []
    for line in output.splitlines():
        device_name = line.strip()
        if device_name and not device_name.startswith("loop"):
            devices.append(device_name)
    return devices


def collect_disk_smart() -> Dict[str, Dict[str, str]]:
    result: Dict[str, Dict[str, str]] = {}
    for device_name in list_block_devices():
        try:
            collect_standard_device(result, device_name)
        except Exception:
            result["/dev/" + device_name] = base_result(source="direct")

    for raid_device, raid_type in scan_raid_devices():
        try:
            collect_raid_device(result, raid_device, raid_type)
        except Exception:
            result[f"{raid_device}[{raid_type}]"] = base_result(source="raid_physical")

    return drop_raid_logical_noise(result)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Collect disk S.M.A.R.T. data")
    parser.add_argument("command", nargs="?", default="collect", choices=["collect"], help="command to run")
    parser.add_argument("--pretty", action="store_true", help="pretty-print JSON output")
    args = parser.parse_args(argv)

    if args.command == "collect":
        indent = 2 if args.pretty else None
        print(json.dumps(collect_disk_smart(), ensure_ascii=False, indent=indent))
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
