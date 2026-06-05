# Server Monitor

Server Monitor 是一套轻量级分布式服务器硬件状态采集与上传脚本。它适合在多台 Linux 服务器上部署采集节点，由一台主控节点集中拉取监控 JSON，并将格式化后的基础硬件性能数据上传到飞书多维表格。

## 项目用途

本项目用于定时采集多台服务器的基础硬件状态，并把结果集中写入飞书多维表格，便于日常巡检、资产观察和服务器状态留档。

整体链路如下：

```text
agent 节点本地采集 -> agent 本地 JSON 落盘 -> master SSH/SCP 拉取 -> master 格式化 -> 飞书多维表格上传
```

职责边界：

- `agent/`：部署在每台被监控服务器上，只负责本机采集并生成 `data_*.json`。
- `master/`：部署在主控服务器上，负责拉取各 agent 的 JSON、格式化数据、上传飞书、归档上传结果。
- `data/`、`logs/`、`tmp/`、`keys/`：运行时目录，默认不提交到 Git。

## 主要功能

### agent 采集能力

agent 每次执行 `collect_local.sh` 后，会在本机生成一份 `data_*.json`。当前采集内容包括：

| 类别 | 内容 |
| --- | --- |
| CPU | CPU 型号、核心数、使用率 |
| 内存 | 总内存、已用内存、使用率 |
| 磁盘 | 磁盘列表、类型、容量、使用率 |
| S.M.A.R.T. | 磁盘健康状态、温度 |
| GPU | GPU 型号、显存、序列号、使用率、温度 |
| 网络 | 指定网卡收发字节数 |
| 系统 | load average、进程数 |

agent 侧已有的稳健性处理：

- CPU 使用率通过 `/proc/stat` 双采样计算，避免依赖 `top` 输出格式。
- JSON 字符串通过 Python `json.dumps` 转义，减少特殊字符导致的 JSON 损坏。
- 数值字段会校验，异常值回落为 `0`。
- 嵌套 JSON 字段会校验，异常值回落为 `{}` 或 `[]`。
- 输出文件写入后会再次做 JSON 格式校验。
- JSON 读取兼容普通 UTF-8 与带 BOM 的 UTF-8。
- 磁盘列表只保留 `TYPE=disk` 的真实磁盘设备。

### master 拉取能力

master 根据 `master/config.sh` 中的 `AGENT_NODES` 连接各 agent 节点，通过 SSH/SCP 拉取远端 `data_*.json`。

节点配置格式：

```text
节点名|SSH用户|IP|SSH端口|SSH私钥路径|远程数据目录
```

拉取后的数据会进入：

```text
/share/server-monitor/data/staging/{node}/data_*.json
```

如果启用 `--clean-remote`，master 会先校验本地拉取到的 JSON，只有校验通过后才会清理远端 agent 的 `data_*.json`。

### 飞书上传能力

master 会将 JSON 格式化为飞书多维表格字段，当前字段包括：

- `时间`
- `IP地址`
- `CPU信息`
- `CPU使用率`
- `内存`
- `内存使用率`
- `磁盘列表`
- `磁盘使用率`
- `磁盘S.M.A.R.T.`
- `GPU列表`
- `GPU使用率`

上传认证支持两种方式：

- `FEISHU_ACCESS_TOKEN`：适合临时测试。
- `FEISHU_APP_ID` + `FEISHU_APP_SECRET`：脚本自动刷新 `tenant_access_token`，适合长期运行。

上传状态流转：

- dry-run：只格式化输出，不上传，不移动文件。
- 实际上传成功：文件移动到 `data/uploaded/`。
- 解析失败或上传失败：文件移动到 `data/failed/`。
- 归档文件重名时会自动追加时间戳，避免覆盖。

## 目录结构

```text
server-monitor/
├── agent/
│   ├── config.sh                  # agent 脱敏示例配置，可按节点实际情况修改
│   ├── config.example.sh          # agent 配置模板
│   ├── lib_common.sh              # agent 公共函数
│   ├── collect_local.sh           # agent 本地采集入口
│   └── setup_cron.sh              # agent cron 安装/测试/状态/健康检查脚本
├── master/
│   ├── config.sh                  # master 脱敏示例配置，可按部署实际情况修改
│   ├── config.example.sh          # master 配置模板
│   ├── lib_common.sh              # master 公共函数
│   ├── pull_agent_data.sh         # 从 agent 拉取 JSON
│   ├── run_monitor.sh             # master 编排入口
│   ├── agent_upload.py            # 飞书上传核心逻辑
│   └── upload_to_feishu.sh        # 上传包装入口
├── README.md                      # 项目说明
└── .gitignore                     # 排除运行数据、日志、密钥、缓存
```

生产部署时通常还会有以下运行目录：

```text
/share/server-monitor/data/
/share/server-monitor/data/staging/
/share/server-monitor/data/uploaded/
/share/server-monitor/data/failed/
/share/server-monitor/logs/
/share/server-monitor/tmp/
/share/server-monitor/keys/
```

## 环境要求

agent 节点建议具备：

- Linux
- Bash
- Python 3
- `awk`、`sed`、`grep`、`nproc`、`df`、`lsblk`、`ps`
- `smartctl`，可选，用于磁盘 S.M.A.R.T. 信息
- `nvidia-smi`，可选，用于 NVIDIA GPU 信息

master 节点建议具备：

- Linux
- Bash
- Python 3
- `ssh`、`scp`
- 可访问所有 agent 节点的 SSH 私钥
- 可访问飞书开放平台 API

## agent 使用方法

### 1. 部署脚本

将 `agent/` 目录放到被监控服务器，例如：

```bash
/share/server-monitor/agent
```

### 2. 配置本机参数

可以直接修改 `agent/config.sh`，也可以从模板复制：

```bash
cd /share/server-monitor/agent
cp config.example.sh config.sh
chmod 600 config.sh
```

每台服务器上的 agent 都需要配置自己的 `config.sh`。至少需要确认：

```bash
NODE_NAME="${NODE_NAME:-your-agent-node}"
NODE_IP="${NODE_IP:-192.168.2.101}"
DEV_ETH0="${DEV_ETH0:-eth0}"
DEV_ETH1="${DEV_ETH1:-eth1}"
LOG_DIR="${LOG_DIR:-/share/server-monitor/logs}"
DATA_DIR="${DATA_DIR:-/share/server-monitor/data}"
TMP_DIR="${TMP_DIR:-/share/server-monitor/tmp}"
```

其中：

- `NODE_NAME` 建议每台服务器唯一，生成文件名和 master 识别都会用到。
- `NODE_IP` 建议填写该服务器实际管理 IP。
- `DEV_ETH0`、`DEV_ETH1` 需要按当前服务器真实网卡名调整。
- `DATA_DIR` 要与 master 中该节点的远程数据目录一致。

### 3. 健康检查

```bash
cd /share/server-monitor/agent
bash setup_cron.sh doctor
```

### 4. 手动采集测试

```bash
cd /share/server-monitor/agent
bash setup_cron.sh test
```

或直接执行：

```bash
bash /share/server-monitor/agent/collect_local.sh
```

成功后会生成：

```text
/share/server-monitor/data/data_${NODE_NAME}_${YYYYmmdd_HHMMSS}.json
```

### 5. 安装定时采集

每天 09:30 采集：

```bash
cd /share/server-monitor/agent
bash setup_cron.sh install -t 9:30
```

每 5 分钟采集：

```bash
bash setup_cron.sh install -m 5
```

查看状态：

```bash
bash setup_cron.sh status
```

移除定时任务：

```bash
bash setup_cron.sh uninstall
```

## master 使用方法

### 1. 部署脚本

将 `master/` 目录放到主控服务器，例如：

```bash
/share/server-monitor/master
```

并准备运行目录：

```bash
mkdir -p /share/server-monitor/{data,logs,tmp,keys}
mkdir -p /share/server-monitor/data/{staging,uploaded,failed}
```

### 2. 配置 master

可以直接修改 `master/config.sh`，也可以从模板复制：

```bash
cd /share/server-monitor/master
cp config.example.sh config.sh
chmod 600 config.sh
```

需要配置飞书多维表格信息：

```bash
FEISHU_APP_TOKEN="${FEISHU_APP_TOKEN:-your_bitable_app_token}"
FEISHU_TABLE_ID="${FEISHU_TABLE_ID:-your_table_id}"
FEISHU_ACCESS_TOKEN="${FEISHU_ACCESS_TOKEN:-}"
FEISHU_APP_ID="${FEISHU_APP_ID:-your_app_id}"
FEISHU_APP_SECRET="${FEISHU_APP_SECRET:-your_app_secret}"
```

长期运行建议配置 `FEISHU_APP_ID` 和 `FEISHU_APP_SECRET`，由脚本自动刷新 token。

还需要配置 agent 节点列表：

```bash
AGENT_NODES=(
    "node-1|user|192.168.2.101|22|/share/server-monitor/keys/id_rsa-node-1|/share/server-monitor/data"
)
```

SSH 私钥建议放在：

```text
/share/server-monitor/keys/
```

并设置权限：

```bash
chmod 600 /share/server-monitor/keys/id_rsa-node-1
```

### 3. 检查飞书 token

```bash
cd /share/server-monitor/master
source ./config.sh
export FEISHU_APP_TOKEN FEISHU_TABLE_ID FEISHU_ACCESS_TOKEN FEISHU_APP_ID FEISHU_APP_SECRET
python3 ./agent_upload.py --check-token
```

token 检查成功只能证明 App ID / Secret 可用，不代表目标多维表格一定有写入权限。若真实上传遇到 `403` 或飞书业务错误，需要检查应用权限、字段名和多维表格协作者权限。

### 4. 拉取 agent 数据

拉取所有节点：

```bash
cd /share/server-monitor/master
bash pull_agent_data.sh
```

只拉取指定节点：

```bash
bash pull_agent_data.sh --node node-1
```

拉取后清理远端 JSON：

```bash
bash pull_agent_data.sh --clean-remote
```

### 5. 上传或 dry-run

只格式化已有数据，不上传：

```bash
cd /share/server-monitor/master
python3 agent_upload.py --all --data-dir /share/server-monitor/data
```

实际上传：

```bash
python3 agent_upload.py --all --upload --data-dir /share/server-monitor/data
```

列出待处理数据文件：

```bash
python3 agent_upload.py --list --data-dir /share/server-monitor/data
```

处理单个文件：

```bash
python3 agent_upload.py --file /share/server-monitor/data/staging/node-1/data_node-1_20260605_093000.json --upload
```

### 6. 运行完整 master 流程

完整 dry-run：拉取 + 格式化，不上传飞书，不清理远程。

```bash
cd /share/server-monitor/master
bash run_monitor.sh --dry-run
```

只拉取：

```bash
bash run_monitor.sh --pull-only
```

只上传已有 staging 数据：

```bash
bash run_monitor.sh --upload-only
```

正式运行：拉取 + 上传 + 本地 JSON 校验通过后清理远程数据。

```bash
bash run_monitor.sh --clean-remote
```

### 7. 安装 master 定时任务

例如 agent 每天 09:30 采集，master 每天 09:45 拉取并上传：

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
45 9 * * * /share/server-monitor/master/run_monitor.sh --clean-remote >> /share/server-monitor/logs/master_cron.log 2>&1
```

## 日志和数据流转

agent 日志：

```text
/share/server-monitor/logs/cron.log
```

master 日志：

```text
/share/server-monitor/logs/run_monitor_YYYYmmdd_HHMMSS.log
/share/server-monitor/logs/summary_YYYYmmdd_HHMMSS.log
/share/server-monitor/logs/errors_YYYYmmdd_HHMMSS.log
/share/server-monitor/logs/master_cron.log
```

master 数据目录：

```text
/share/server-monitor/data/staging/{node}/data_*.json  # 拉取后的待上传文件
/share/server-monitor/data/uploaded/data_*.json        # 上传成功归档
/share/server-monitor/data/failed/data_*.json          # 解析或上传失败文件
```

## 配置和安全建议

- `agent/config.sh` 与 `master/config.sh` 在仓库中是脱敏示例，生产部署必须按实际环境修改。
- `master/config.sh` 可能包含飞书 App Secret，应在生产环境设置为 `600` 权限。
- SSH 私钥不应提交到 Git，建议放入 `/share/server-monitor/keys/` 并设置为 `600` 权限。
- `data/`、`logs/`、`tmp/`、`keys/` 都是运行时目录，不应提交到仓库。
- 如果真实飞书密钥或 SSH 私钥被提交或泄露，应立即在对应平台轮换。

## 运维注意事项

- `--clean-remote` 当前会在本地 JSON 校验通过后执行远程 `rm -f data_*.json`。更稳妥的生产方案是改为远端归档目录，而不是直接删除。
- 上传逻辑已有成功/失败文件流转，但没有全局幂等去重。如果手动把 `uploaded/` 文件复制回 staging，仍可能重复上传。
- 首次真实上传前，建议先执行 `run_monitor.sh --dry-run`，确认字段格式、节点列表、SSH 密钥和飞书权限都正确。
- `agent/setup_cron.sh install -t 9:30` 推荐使用非前导零写法，避免部分 Bash 场景中的前导零解析问题。

## 首次部署检查清单

agent 节点：

```bash
cd /share/server-monitor/agent
bash setup_cron.sh doctor
bash setup_cron.sh test
bash setup_cron.sh install -t 9:30
```

master 节点：

```bash
cd /share/server-monitor/master
source ./config.sh
export FEISHU_APP_TOKEN FEISHU_TABLE_ID FEISHU_ACCESS_TOKEN FEISHU_APP_ID FEISHU_APP_SECRET
python3 ./agent_upload.py --check-token
bash ./run_monitor.sh --dry-run
bash ./run_monitor.sh --clean-remote
```
