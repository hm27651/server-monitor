#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
服务器监控数据上传脚本。

处理硬件监控数据：时间、IP、CPU、内存、磁盘列表、磁盘使用率、S.M.A.R.T.、GPU列表、GPU使用率。
默认 dry-run，仅在传入 --upload 时写入飞书多维表格。
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
import shutil
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

FEISHU_APP_TOKEN = os.environ.get("FEISHU_APP_TOKEN", "")
FEISHU_TABLE_ID = os.environ.get("FEISHU_TABLE_ID", "")
FEISHU_ACCESS_TOKEN = os.environ.get("FEISHU_ACCESS_TOKEN", "")
FEISHU_APP_ID = os.environ.get("FEISHU_APP_ID", "")
FEISHU_APP_SECRET = os.environ.get("FEISHU_APP_SECRET", "")
FEISHU_TOKEN_EXPIRES_AT = 0.0

FEISHU_FIELD_TIME = os.environ.get("FEISHU_FIELD_TIME", "时间")
FEISHU_FIELD_IP = os.environ.get("FEISHU_FIELD_IP", "IP地址")
FEISHU_FIELD_DEVICE_NAME = os.environ.get("FEISHU_FIELD_DEVICE_NAME", "设备名称")
FEISHU_FIELD_CPU_INFO = os.environ.get("FEISHU_FIELD_CPU_INFO", "CPU信息")
FEISHU_FIELD_CPU_USAGE = os.environ.get("FEISHU_FIELD_CPU_USAGE", "CPU使用率")
FEISHU_FIELD_CPU_TEMP = os.environ.get("FEISHU_FIELD_CPU_TEMP", "CPU温度")
FEISHU_FIELD_MEMORY = os.environ.get("FEISHU_FIELD_MEMORY", "内存")
FEISHU_FIELD_MEM_USAGE = os.environ.get("FEISHU_FIELD_MEM_USAGE", "内存使用率")
FEISHU_FIELD_DISK_LIST = os.environ.get("FEISHU_FIELD_DISK_LIST", "磁盘列表")
FEISHU_FIELD_DISK_USAGE = os.environ.get("FEISHU_FIELD_DISK_USAGE", "磁盘使用率")
FEISHU_FIELD_DISK_SMART = os.environ.get("FEISHU_FIELD_DISK_SMART", "磁盘S.M.A.R.T.")
FEISHU_FIELD_GPU_LIST = os.environ.get("FEISHU_FIELD_GPU_LIST", "GPU列表")
FEISHU_FIELD_GPU_USAGE = os.environ.get("FEISHU_FIELD_GPU_USAGE", "GPU使用率")

DATA_DIR = Path(os.environ.get("DATA_DIR", "/share/server-monitor/data"))
MAX_RETRIES = int(os.environ.get("MAX_RETRIES", "3"))
RETRY_DELAY = int(os.environ.get("RETRY_DELAY", "2"))
BATCH_DELAY = 1
UPLOADED_DIR_NAME = "uploaded"
FAILED_DIR_NAME = "failed"


def timestamp_now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def log_info(msg: str) -> None:
    print(f"[INFO]  {timestamp_now()} {msg}", file=sys.stderr)


def log_warn(msg: str) -> None:
    print(f"[WARN]  {timestamp_now()} {msg}", file=sys.stderr)


def log_error(msg: str) -> None:
    print(f"[ERROR] {timestamp_now()} {msg}", file=sys.stderr)


def log_debug(msg: str) -> None:
    if os.environ.get("DEBUG") == "1":
        print(f"[DEBUG] {timestamp_now()} {msg}", file=sys.stderr)


def format_timestamp(value: Any) -> str:
    if not value:
        return datetime.now().strftime("%Y-%m-%d %H:%M")
    text = str(value)
    match = re.match(r"^(\d{4}-\d{2}-\d{2})[T\s]([0-9]{2}:[0-9]{2})", text)
    if match:
        return f"{match.group(1)} {match.group(2)}"
    return text[:16] if len(text) >= 16 else text


def to_float(value: Any, default: float = 0.0) -> float:
    if value is None:
        return default
    try:
        return float(str(value).strip().rstrip("%"))
    except (TypeError, ValueError):
        return default


def format_percent(value: Any) -> str:
    return f"{to_float(value):.1f}%"


def format_cpu_temperature(value: Any) -> str:
    if value is None:
        return "N/A"
    text = str(value).strip()
    if not text or text.upper() == "N/A":
        return "N/A"
    if text.endswith("°C"):
        return text
    return f"{text.rstrip('C').strip()}°C"


def format_cpu_info(metrics: Dict[str, Any]) -> str:
    cpu_info = metrics.get("cpu_info") if isinstance(metrics.get("cpu_info"), dict) else {}
    model = cpu_info.get("model") or "未知型号"
    cores = cpu_info.get("cores") or 0
    return f"{model} ({cores}核)"


def format_memory(metrics: Dict[str, Any]) -> str:
    memory = metrics.get("memory") if isinstance(metrics.get("memory"), dict) else {}
    total_gb = to_float(memory.get("total_kb")) / 1024 / 1024
    used_gb = to_float(memory.get("used_kb")) / 1024 / 1024
    return f"{total_gb:.2f}GB总, {used_gb:.2f}GB已用"

def format_disk_list(value: Any) -> str:
    if not value:
        return "无数据"
    if not isinstance(value, list):
        return str(value)
    parts = []
    for disk in value:
        if not isinstance(disk, dict):
            continue
        device = disk.get("device", "unknown")
        disk_type = disk.get("type", "disk")
        vendor = disk.get("vendor", "Unknown")
        size = disk.get("size", "N/A")
        sn = disk.get("sn", "N/A")
        parts.append(f"{device}({disk_type},{vendor}):{size},SN:{sn}")
    return " | ".join(parts) if parts else "无数据"


def format_disk_smart(value: Any) -> str:
    if not value:
        return "无数据"
    if not isinstance(value, dict):
        text = str(value).strip()
        if "awk" in text.lower() or "cmd. line" in text.lower():
            return "采集异常"
        return text or "无数据"
    parts = []
    for device, info in sorted(value.items()):
        if isinstance(info, str):
            if "awk" in info.lower() or "cmd. line" in info.lower():
                return "采集异常"
            parts.append(f"{device}:{info}")
            continue
        if not isinstance(info, dict):
            continue
        status = info.get("status", "UNKNOWN")
        temp = info.get("temperature", "N/A")
        parts.append(f"{device}:{status}({temp}°C)")
    return " | ".join(parts) if parts else "无数据"


def format_disk_usage(value: Any) -> str:
    if not value:
        return "无数据"
    if isinstance(value, dict):
        parts = []
        for device, pct in sorted(value.items()):
            device_text = str(device)
            pct_text = str(pct).strip().rstrip("%")
            if "awk" in device_text.lower() or "cmd. line" in pct_text.lower():
                return "采集异常"
            parts.append(f"{device_text}:{pct_text}%")
        return " | ".join(parts) if parts else "无数据"
    text = str(value).strip()
    if "awk" in text.lower() or "cmd. line" in text.lower():
        return "采集异常"
    return text or "无数据"


def format_gpu_usage(value: Any) -> str:
    if not value:
        return "无GPU"
    if not isinstance(value, list):
        return str(value)
    parts = []
    for gpu in value:
        if not isinstance(gpu, dict):
            continue
        idx = gpu.get("index", "0")
        pct = str(gpu.get("usage_percent", "0")).strip().rstrip("%")
        temp = gpu.get("temperature", "N/A")
        parts.append(f"GPU{idx}:{pct}%({temp}°C)")
    return " | ".join(parts) if parts else "无GPU"

def format_gpu_list(value: Any) -> str:
    if not value:
        return "无GPU"
    if not isinstance(value, list):
        return str(value)
    parts = []
    for gpu in value:
        if not isinstance(gpu, dict):
            continue
        idx = gpu.get("index", "0")
        vendor = gpu.get("vendor", "Unknown")
        model = gpu.get("model", "Unknown")
        memory = gpu.get("memory", "N/A")
        sn = gpu.get("sn", "N/A")
        parts.append(f"GPU{idx}:{vendor} {model} {memory},SN:{sn}")
    return " | ".join(parts) if parts else "无GPU"


def parse_server_data(json_path: str) -> Dict[str, Any]:
    with open(json_path, "r", encoding="utf-8-sig") as file_obj:
        data = json.load(file_obj)

    if not isinstance(data, dict):
        raise ValueError("JSON 顶层结构必须是对象")

    metrics = data.get("metrics")
    if not isinstance(metrics, dict):
        metrics = {}

    return {
        "time": format_timestamp(data.get("timestamp")),
        "ip": str(data.get("host") or data.get("node_name") or ""),
        "device_name": str(data.get("node_name") or data.get("host") or ""),
        "cpu_info": format_cpu_info(metrics),
        "cpu_usage": format_percent(metrics.get("cpu_usage_percent")),
        "cpu_temperature": format_cpu_temperature(metrics.get("cpu_temperature")),
        "memory": format_memory(metrics),
        "mem_usage": format_percent(metrics.get("memory_usage_percent")),
        "disk_list": format_disk_list(metrics.get("disks")),
        "disk_usage": format_disk_usage(metrics.get("disk_usage")),
        "disk_smart": format_disk_smart(metrics.get("disk_smart")),
        "gpu_list": format_gpu_list(metrics.get("gpu")),
        "gpu_usage": format_gpu_usage(metrics.get("gpu_usage")),
    }


def format_for_feishu(record: Dict[str, Any]) -> Dict[str, Any]:
    field_map = {
        "time": FEISHU_FIELD_TIME,
        "ip": FEISHU_FIELD_IP,
        "device_name": FEISHU_FIELD_DEVICE_NAME,
        "cpu_info": FEISHU_FIELD_CPU_INFO,
        "cpu_usage": FEISHU_FIELD_CPU_USAGE,
        "cpu_temperature": FEISHU_FIELD_CPU_TEMP,
        "memory": FEISHU_FIELD_MEMORY,
        "mem_usage": FEISHU_FIELD_MEM_USAGE,
        "disk_list": FEISHU_FIELD_DISK_LIST,
        "disk_usage": FEISHU_FIELD_DISK_USAGE,
        "disk_smart": FEISHU_FIELD_DISK_SMART,
        "gpu_list": FEISHU_FIELD_GPU_LIST,
        "gpu_usage": FEISHU_FIELD_GPU_USAGE,
    }
    return {
        feishu_name: record[internal_name]
        for internal_name, feishu_name in field_map.items()
        if record.get(internal_name) is not None
    }


def refresh_tenant_access_token() -> Tuple[bool, str]:
    global FEISHU_ACCESS_TOKEN, FEISHU_TOKEN_EXPIRES_AT

    if not FEISHU_APP_ID or not FEISHU_APP_SECRET:
        return False, "FEISHU_APP_ID 或 FEISHU_APP_SECRET 未配置"

    url = "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal"
    body = {"app_id": FEISHU_APP_ID, "app_secret": FEISHU_APP_SECRET}
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp_body = resp.read().decode("utf-8")
            data = json.loads(resp_body) if resp_body else {}
    except urllib.error.HTTPError as exc:
        try:
            data = json.loads(exc.read().decode("utf-8"))
        except Exception:
            data = {"msg": str(exc)}
        return False, f"HTTP {exc.code}: {data.get('msg', data)}"
    except Exception as exc:
        return False, str(exc)

    if data.get("code") != 0:
        return False, str(data.get("msg", data))

    token = data.get("tenant_access_token")
    if not token:
        return False, "响应中未包含 tenant_access_token"

    try:
        expire_seconds = int(data.get("expire", 7200))
    except (TypeError, ValueError):
        expire_seconds = 7200

    FEISHU_ACCESS_TOKEN = token
    FEISHU_TOKEN_EXPIRES_AT = time.time() + max(expire_seconds - 60, 60)
    os.environ["FEISHU_ACCESS_TOKEN"] = token
    log_info(f"已自动刷新飞书 tenant_access_token，有效期约 {expire_seconds}s")
    return True, "ok"


def ensure_feishu_access_token(force_refresh: bool = False) -> bool:
    if FEISHU_APP_ID and FEISHU_APP_SECRET:
        if force_refresh or not FEISHU_ACCESS_TOKEN or time.time() >= FEISHU_TOKEN_EXPIRES_AT:
            ok, msg = refresh_tenant_access_token()
            if not ok:
                log_error(f"刷新飞书 tenant_access_token 失败: {msg}")
            return ok
        return True

    if FEISHU_ACCESS_TOKEN:
        return True

    log_error("FEISHU_ACCESS_TOKEN 未设置，且 FEISHU_APP_ID/FEISHU_APP_SECRET 未配置")
    return False


def is_feishu_auth_error(status: int, resp: Dict[str, Any]) -> bool:
    code = str(resp.get("code", ""))
    msg = str(resp.get("msg", "")).lower()
    auth_codes = {
        "99991663",
        "99991664",
        "99991665",
        "99991668",
        "99991671",
    }
    return (
        status in (401, 403)
        or code in auth_codes
        or ("access token" in msg and ("invalid" in msg or "expired" in msg))
    )


def feishu_api_call(method: str, path: str, body: Optional[Dict] = None) -> Tuple[int, Dict]:
    url = f"https://open.feishu.cn/open-apis{path}"
    req_data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body else None
    req = urllib.request.Request(
        url,
        data=req_data,
        headers={
            "Authorization": f"Bearer {FEISHU_ACCESS_TOKEN}",
            "Content-Type": "application/json; charset=utf-8",
        },
        method=method,
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp_body = resp.read().decode("utf-8")
            return resp.status, json.loads(resp_body) if resp_body else {}
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read().decode("utf-8"))
        except Exception:
            return exc.code, {"msg": str(exc)}
    except Exception as exc:
        return -1, {"msg": str(exc)}


def create_bitablerecord(fields: Dict[str, Any], retry: int = MAX_RETRIES) -> Tuple[bool, str, Dict]:
    path = f"/bitable/v1/apps/{FEISHU_APP_TOKEN}/tables/{FEISHU_TABLE_ID}/records"
    body = {"fields": fields}
    resp: Dict[str, Any] = {}
    refreshed_after_auth_error = False

    for attempt in range(1, retry + 1):
        log_debug(f"飞书 API 调用尝试 {attempt}/{retry}: POST {path}")
        status, resp = feishu_api_call("POST", path, body)

        if status == 200 and resp.get("code", 0) == 0:
            record_id = resp.get("data", {}).get("record", {}).get("record_id", "")
            return True, record_id, resp

        msg = str(resp.get("msg", ""))
        code = resp.get("code", "")
        if is_feishu_auth_error(status, resp) and not refreshed_after_auth_error:
            refreshed_after_auth_error = True
            log_warn("飞书访问令牌可能已失效，尝试刷新 token 后重试...")
            if ensure_feishu_access_token(force_refresh=True):
                continue

        if status == 429 or "rate limit" in msg.lower():
            log_warn(f"触发速率限制，等待 {RETRY_DELAY}s 后重试...")
            time.sleep(RETRY_DELAY)
            continue

        log_error(f"飞书 API 错误: status={status}, code={code}, msg={msg}")
        return False, msg, resp

    return False, f"达到最大重试次数（{retry}）", resp


def data_dirs(data_dir: Path) -> List[Path]:
    return [data_dir, data_dir / "staging"]


def find_all_json_files(data_dir: Path = DATA_DIR) -> List[Path]:
    found: List[Path] = []
    seen = set()
    search_patterns = [
        (data_dir, "data_*.json"),
        (data_dir / "staging", "**/data_*.json"),
    ]
    for directory, pattern in search_patterns:
        if not directory.exists():
            continue
        for path in sorted(directory.glob(pattern)):
            resolved = str(path.resolve())
            if resolved not in seen:
                found.append(path)
                seen.add(resolved)
    return found


def state_dir(data_dir: Path, name: str) -> Path:
    path = data_dir / name
    path.mkdir(parents=True, exist_ok=True)
    return path


def unique_destination(directory: Path, filename: str) -> Path:
    dest = directory / filename
    if not dest.exists():
        return dest
    stem = Path(filename).stem
    suffix = Path(filename).suffix
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    index = 1
    while True:
        candidate = directory / f"{stem}_{ts}_{index}{suffix}"
        if not candidate.exists():
            return candidate
        index += 1


def move_to_state(json_path: Path, data_dir: Path, state_name: str) -> Path:
    dest_dir = state_dir(data_dir, state_name)
    dest = unique_destination(dest_dir, json_path.name)
    shutil.move(str(json_path), str(dest))
    return dest


def server_name_from_path(json_path: str) -> str:
    return Path(json_path).stem.replace("data_", "")


def upload_single_server(json_path: str, do_upload: bool = False) -> Tuple[bool, str, Optional[str]]:
    server_name = server_name_from_path(json_path)
    log_info(f"处理服务器数据: {json_path}")

    try:
        record = parse_server_data(json_path)
    except FileNotFoundError:
        log_error(f"文件不存在: {json_path}")
        return False, server_name, None
    except json.JSONDecodeError as exc:
        log_error(f"JSON 解析失败: {json_path}, 错误: {exc}")
        return False, server_name, None
    except Exception as exc:
        log_error(f"解析数据失败: {json_path}, 错误: {exc}")
        return False, server_name, None

    feishu_fields = format_for_feishu(record)
    print("=== FEISHU_RECORD_START ===")
    print(json.dumps(feishu_fields, ensure_ascii=False, indent=2))
    print("=== FEISHU_RECORD_END ===")

    if not do_upload:
        log_info(f"服务器 [{server_name}] 格式化完成（dry-run，未上传）")
        return True, server_name, None

    if not ensure_feishu_access_token():
        return False, server_name, None

    success, result, _resp = create_bitablerecord(feishu_fields)
    if success:
        log_info(f"服务器 [{server_name}] 上传成功: record_id={result}")
        return True, server_name, result

    log_error(f"服务器 [{server_name}] 上传失败: {result}")
    return False, server_name, None


def upload_all_servers(data_dir: Path = DATA_DIR, do_upload: bool = False) -> Dict[str, int]:
    log_info("=" * 50)
    log_info("开始处理所有服务器硬件监控数据...")
    log_info(f"数据目录: {data_dir}")
    log_info(f"上传模式: {'实际上传' if do_upload else 'dry-run（仅格式化）'}")
    if do_upload:
        log_info(f"成功文件目录: {data_dir / UPLOADED_DIR_NAME}")
        log_info(f"失败文件目录: {data_dir / FAILED_DIR_NAME}")
    log_info("=" * 50)

    json_files = find_all_json_files(data_dir)
    if not json_files:
        log_error(f"未找到任何数据文件（搜索: {data_dir} 和 {data_dir / 'staging'}）")
        return {"total": 0, "success": 0, "fail": 1, "moved_uploaded": 0, "moved_failed": 0}

    total = success = fail = moved_uploaded = moved_failed = 0
    for json_path in json_files:
        ok, _server_name, _record_id = upload_single_server(str(json_path), do_upload)
        total += 1
        if ok:
            success += 1
            if do_upload:
                dest = move_to_state(json_path, data_dir, UPLOADED_DIR_NAME)
                moved_uploaded += 1
                log_info(f"已归档上传成功文件: {dest}")
        else:
            fail += 1
            if do_upload:
                try:
                    dest = move_to_state(json_path, data_dir, FAILED_DIR_NAME)
                    moved_failed += 1
                    log_warn(f"已移动上传失败文件: {dest}")
                except FileNotFoundError:
                    log_warn(f"失败文件不存在，无法移动: {json_path}")
        if do_upload and ok:
            time.sleep(BATCH_DELAY)

    log_info("=" * 50)
    log_info("处理完成汇总")
    log_info(f"总记录数:       {total}")
    log_info(f"成功数:         {success}")
    log_info(f"失败数:         {fail}")
    if do_upload:
        log_info(f"归档成功文件数: {moved_uploaded}")
        log_info(f"移动失败文件数: {moved_failed}")
    log_info("=" * 50)
    return {
        "total": total,
        "success": success,
        "fail": fail,
        "moved_uploaded": moved_uploaded,
        "moved_failed": moved_failed,
    }


class ServerMonitorAgent:
    CONFIG = {
        "app_token": FEISHU_APP_TOKEN,
        "table_id": FEISHU_TABLE_ID,
        "access_token": FEISHU_ACCESS_TOKEN,
        "app_id": FEISHU_APP_ID,
        "app_secret": FEISHU_APP_SECRET,
        "data_dir": str(DATA_DIR),
        "max_retries": MAX_RETRIES,
        "retry_delay": RETRY_DELAY,
        "batch_delay": BATCH_DELAY,
    }

    def __init__(self, config: Optional[Dict] = None):
        self.config = {**self.CONFIG, **(config or {})}

    def list_data_files(self) -> List[str]:
        return [str(path) for path in find_all_json_files(Path(self.config["data_dir"]))]

    def get_record(self, json_path: str) -> Dict[str, Any]:
        return format_for_feishu(parse_server_data(json_path))

    def process_file(self, json_path: str, do_upload: bool = False) -> Dict[str, Any]:
        ok, server_name, record_id = upload_single_server(json_path, do_upload)
        fields = format_for_feishu(parse_server_data(json_path)) if ok else {}
        return {
            "success": ok,
            "server_name": server_name,
            "record_id": record_id,
            "fields": fields,
            "error": None if ok else "process failed",
        }

    def process_all(self, do_upload: bool = False) -> Dict[str, Any]:
        stats = upload_all_servers(Path(self.config["data_dir"]), do_upload)
        return {**stats, "results": []}


def main() -> None:
    parser = argparse.ArgumentParser(
        description="服务器硬件监控数据上传",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--file", "-f", help="指定单个 JSON 数据文件路径")
    parser.add_argument("--all", "-a", action="store_true", help="处理 DATA_DIR 下所有数据文件（默认）")
    parser.add_argument("--list", "-l", action="store_true", help="仅列出数据文件，不处理")
    parser.add_argument("--upload", "-u", action="store_true", help="启用实际上传（默认 dry-run）")
    parser.add_argument("--dry-run", action="store_true", help="仅格式化，不上传（默认）")
    parser.add_argument("--data-dir", default=str(DATA_DIR), help=f"数据目录（默认: {DATA_DIR}）")
    parser.add_argument("--debug", action="store_true", help="启用调试日志")
    parser.add_argument("--check-token", action="store_true", help="仅刷新并检查飞书 tenant_access_token")
    args = parser.parse_args()

    if args.debug:
        os.environ["DEBUG"] = "1"

    data_dir = Path(args.data_dir)
    do_upload = args.upload

    if args.check_token:
        sys.exit(0 if ensure_feishu_access_token(force_refresh=True) else 1)

    if do_upload and not FEISHU_ACCESS_TOKEN and not (FEISHU_APP_ID and FEISHU_APP_SECRET):
        log_warn("FEISHU_ACCESS_TOKEN 未设置，且未配置自动刷新凭证，实际上传会失败")

    if args.list:
        files = find_all_json_files(data_dir)
        if not files:
            log_info(f"数据目录为空: {data_dir}")
        for file_path in files:
            print(str(file_path))
        return

    if args.file:
        ok, _server_name, _record_id = upload_single_server(args.file, do_upload)
        sys.exit(0 if ok else 1)

    stats = upload_all_servers(data_dir, do_upload)
    sys.exit(0 if stats["fail"] == 0 else 1)


if __name__ == "__main__":
    main()


