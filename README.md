# Server Monitor

轻量级分布式服务器监控脚本。agent 在被监控服务器本地采集硬件与性能指标，master 通过 SSH/SCP 拉取 JSON 数据，并上传到飞书多维表格。

```text
agent 本地采集 -> JSON 落盘 -> master 拉取 -> 格式化 -> 上传飞书多维表格
```

## 功能特性

- 分布式部署：每台服务器运行独立 agent，master 统一拉取和上传。
- 本地采集：CPU、内存、磁盘、S.M.A.R.T.、GPU、网络、load average、进程数。
- 磁盘兼容：支持 `smartctl` JSON/文本输出，支持 NVMe `nvme smart-log` 回退读取。
- 安全拉取：master 拉取后先校验 JSON，通过后才可清理远端文件。
- 飞书上传：支持临时 `FEISHU_ACCESS_TOKEN`，也支持 App ID/Secret 自动刷新 token。
- 状态流转：上传成功归档到 `uploaded/`，失败文件移动到 `failed/`。
- dry-run：支持只拉取、只格式化、只上传已有数据，便于上线前验证。

## 目录结构

```text
server-monitor/
├── agent/
│   ├── collect_local.sh       # 本地采集入口
│   ├── setup_cron.sh          # cron 安装、测试、状态、健康检查
│   ├── config.sh              # agent 示例配置
│   ├── config.example.sh      # agent 配置模板
│   └── lib_common.sh
├── master/
│   ├── run_monitor.sh         # master 完整编排入口
│   ├── pull_agent_data.sh     # 从 agent 拉取 JSON
│   ├── agent_upload.py        # 飞书上传核心逻辑
│   ├── upload_to_feishu.sh    # 上传包装入口
│   ├── config.sh              # master 示例配置
│   ├── config.example.sh      # master 配置模板
│   └── lib_common.sh
└── README.md
```

运行时目录建议放在 `/share/server-monitor/`：

```text
data/       # 数据目录
logs/       # 日志目录
tmp/        # 临时目录
keys/       # master 连接 agent 的 SSH 私钥
```

## 采集指标

| 类别 | 指标 |
| --- | --- |
| CPU | 型号、核心数、使用率 |
| 内存 | 总量、已用量、使用率 |
| 磁盘 | 设备、类型、容量、使用率、序列号 |
| S.M.A.R.T. | 健康状态、温度 |
| GPU | 型号、显存、序列号、使用率、温度 |
| 网络 | 指定网卡收发字节数 |
| 系统 | load average、进程数 |

## 环境要求

agent：Linux、Bash、Python 3、`awk`、`sed`、`grep`、`nproc`、`df`、`lsblk`、`ps`。

可选依赖：

- `smartctl`：读取磁盘 S.M.A.R.T. 信息。
- `nvme`：补充 NVMe 磁盘健康状态和温度。
- `nvidia-smi`：读取 NVIDIA GPU 信息。

master：Linux、Bash、Python 3、`ssh`、`scp`，并能访问 agent 节点和飞书开放平台 API。

## 快速开始

### 1. 配置 agent

在每台被监控服务器上部署 `agent/`，修改本机配置：

```bash
cd /share/server-monitor/agent
cp config.example.sh config.sh
chmod 600 config.sh
```

重点确认：

```bash
NODE_NAME="${NODE_NAME:-your-agent-node}"
NODE_IP="${NODE_IP:-192.168.2.101}"
DEV_ETH0="${DEV_ETH0:-eth0}"
DATA_DIR="${DATA_DIR:-/share/server-monitor/data}"
```

运行检查和测试采集：

```bash
bash setup_cron.sh doctor
bash setup_cron.sh test
```

安装定时采集，例如每天 09:30：

```bash
bash setup_cron.sh install -t 9:30
```

### 2. 配置 master

在主控服务器部署 `master/`，准备目录：

```bash
mkdir -p /share/server-monitor/{data,logs,tmp,keys}
mkdir -p /share/server-monitor/data/{staging,uploaded,failed}
```

修改 master 配置：

```bash
cd /share/server-monitor/master
cp config.example.sh config.sh
chmod 600 config.sh
```

配置飞书信息：

```bash
FEISHU_APP_TOKEN="${FEISHU_APP_TOKEN:-your_bitable_app_token}"
FEISHU_TABLE_ID="${FEISHU_TABLE_ID:-your_table_id}"
FEISHU_APP_ID="${FEISHU_APP_ID:-your_app_id}"
FEISHU_APP_SECRET="${FEISHU_APP_SECRET:-your_app_secret}"
```

配置 agent 节点：

```bash
AGENT_NODES=(
    "node-1|user|192.168.2.101|22|/share/server-monitor/keys/id_rsa-node-1|/share/server-monitor/data"
)
```

检查飞书 token：

```bash
source ./config.sh
export FEISHU_APP_TOKEN FEISHU_TABLE_ID FEISHU_ACCESS_TOKEN FEISHU_APP_ID FEISHU_APP_SECRET
python3 ./agent_upload.py --check-token
```

### 3. 运行完整流程

上线前 dry-run：

```bash
cd /share/server-monitor/master
bash run_monitor.sh --dry-run
```

正式拉取并上传：

```bash
bash run_monitor.sh --clean-remote
```

常用模式：

```bash
bash run_monitor.sh --pull-only      # 只拉取
bash run_monitor.sh --upload-only    # 只上传已有数据
python3 agent_upload.py --list --data-dir /share/server-monitor/data
```

## 数据流转

```text
/share/server-monitor/data/staging/{node}/data_*.json  # master 拉取后的待上传文件
/share/server-monitor/data/uploaded/data_*.json        # 上传成功归档
/share/server-monitor/data/failed/data_*.json          # 解析或上传失败文件
```

日志：

```text
/share/server-monitor/logs/cron.log                    # agent cron 日志
/share/server-monitor/logs/master_cron.log             # master cron 日志
/share/server-monitor/logs/run_monitor_*.log           # master 运行日志
/share/server-monitor/logs/errors_*.log                # master 错误日志
```

## 定时任务示例

agent 每天 09:30 采集，master 每天 09:45 拉取并上传：

```cron
30 9 * * * /share/server-monitor/agent/collect_local.sh >> /share/server-monitor/logs/cron.log 2>&1
45 9 * * * /share/server-monitor/master/run_monitor.sh --clean-remote >> /share/server-monitor/logs/master_cron.log 2>&1
```

## 安全说明

- 仓库中的 `config.sh` 是示例配置，生产部署前必须按实际环境修改。
- 公开提交前请脱敏真实 IP、主机名、SSH 用户、飞书凭证和密钥路径。
- `master/config.sh` 可能包含飞书 App Secret，生产环境建议 `chmod 600 master/config.sh`。
- SSH 私钥建议放在 `/share/server-monitor/keys/`，并设置为 `600` 权限。
- `data/`、`logs/`、`tmp/`、`keys/` 不应提交到 Git。
