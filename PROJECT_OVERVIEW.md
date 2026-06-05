# Server Monitor 项目当前状态与运维说明

> 更新时间：2026-06-04  
> 项目位置：`/share/server-monitor`  
> 当前角色：本机为 master 主控节点  
> 当前状态：agent 定时采集已配置，master 定时上传已配置，飞书 token 已支持自动刷新

## 1. 项目定位

本项目是一套轻量级分布式服务器硬件状态采集与上传脚本，采用以下架构：

```text
agent 节点本地采集 -> agent 本地 JSON 落盘 -> master SSH/SCP 拉取 -> master 格式化 -> 飞书多维表格上传
```

职责边界：

- `agent/`：部署在每台被监控服务器上，只负责本机采集并生成 `data_*.json`。
- `master/`：部署在当前主控节点上，负责拉取各 agent JSON、上传飞书、归档上传结果。
- `PROJECT_OVERVIEW.md`：本文档，记录当前真实部署状态、运行方式和剩余风险。

当前项目目录不是 Git 仓库。

## 2. 当前目录结构

```text
/share/server-monitor/
├── agent/                         # 采集节点脚本包
│   ├── config.example.sh          # agent 配置模板
│   ├── config.sh                  # agent 实际配置
│   ├── lib_common.sh              # agent 公共函数
│   ├── collect_local.sh           # agent 本地采集入口
│   └── setup_cron.sh              # agent cron 安装/测试/状态脚本
├── master/                        # master 主控脚本包
│   ├── config.sh                  # master 实际配置，含飞书和 agent 节点配置
│   ├── lib_common.sh              # master 公共函数
│   ├── pull_agent_data.sh         # 从 agent 拉取 JSON
│   ├── run_monitor.sh             # master 编排入口
│   ├── agent_upload.py            # 飞书上传核心逻辑
│   └── upload_to_feishu.sh        # 上传包装入口
├── data/                          # master 本地数据目录
│   └── staging/{node}/            # master 从各 agent 拉取后的暂存目录
├── keys/                          # master 连接 agent 的 SSH 私钥
├── logs/                          # master 日志目录
├── tmp/                           # 临时目录
└── PROJECT_OVERVIEW.md            # 当前文档
```

## 3. 当前自动化排程

### 3.1 agent 定时采集

三台 agent 均已配置每天上午 `09:30` 自动采集：

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 9 * * * /share/server-monitor/agent/collect_local.sh >> /share/server-monitor/logs/cron.log 2>&1
```

已确认节点：

| 节点名 | SSH 用户 | IP | 端口 | agent 状态 | 定时任务 |
| --- | --- | --- | --- | --- | --- |
| `kid-pc` | `kid` | `192.168.2.213` | `22` | 手动采集成功 | 每天 `09:30` |
| `hecsgl-System-Product-Name` | `hecsgl` | `192.168.2.222` | `22` | 手动采集成功 | 每天 `09:30` |
| `b318server` | `hecs` | `192.168.2.233` | `11318` | 手动采集成功 | 每天 `09:30` |

三台 agent 的必需依赖已检查通过，监控网卡存在，`smartctl` 与 `nvidia-smi` 也可用。

### 3.2 master 定时拉取并上传

master 当前用户 `gaoliang` 已配置每天上午 `09:45` 自动运行：

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
45 9 * * * /share/server-monitor/master/run_monitor.sh --clean-remote >> /share/server-monitor/logs/master_cron.log 2>&1
```

该任务会执行完整流程：

1. 从所有 agent 拉取 `data_*.json` 到 master staging。
2. 对拉取到的 JSON 做本地校验。
3. 自动刷新飞书 `tenant_access_token`。
4. 上传记录到飞书多维表格。
5. 上传成功文件归档到 `data/uploaded/`，失败文件移动到 `data/failed/`。
6. 因为启用了 `--clean-remote`，本地 JSON 校验通过后会删除远端 agent 的 `data_*.json`。

当前日期为 `2026-06-04`，今天的 `09:30` 和 `09:45` 均已过去，所以首次自动采集和上传会在 `2026-06-05` 执行。

## 4. 飞书 token 自动刷新

master 已支持自动刷新飞书 `tenant_access_token`，不再需要手工维护 2 小时有效期的 `FEISHU_ACCESS_TOKEN`。

相关配置位于：

```text
/share/server-monitor/master/config.sh
```

当前已配置：

- `FEISHU_APP_TOKEN`
- `FEISHU_TABLE_ID`
- `FEISHU_APP_ID`
- `FEISHU_APP_SECRET`

安全状态：

- `master/config.sh` 权限已设置为 `600`。
- `master/agent_upload.py`、`master/run_monitor.sh`、`master/upload_to_feishu.sh` 权限已设置为 `700`。
- 本文档不记录 App Secret 明文。

验证命令：

```bash
cd /share/server-monitor/master
source ./config.sh
export FEISHU_APP_TOKEN FEISHU_TABLE_ID FEISHU_ACCESS_TOKEN FEISHU_APP_ID FEISHU_APP_SECRET
python3 ./agent_upload.py --check-token
```

最近一次验证结果：`tenant_access_token` 自动刷新成功，飞书返回有效期约 `4923s`。

注意：token 获取成功只能证明 App ID / Secret 正确，不等于该飞书应用一定有目标多维表格写入权限。实际上传时若遇到 `403` 或飞书业务错误，需要检查应用权限和多维表格协作者权限。

## 5. 主流程说明

### 5.1 agent 采集流程

agent 每次执行：

```bash
/share/server-monitor/agent/collect_local.sh
```

输出文件：

```text
/share/server-monitor/data/data_${NODE_NAME}_${YYYYmmdd_HHMMSS}.json
```

采集指标包括：

| 类别 | 内容 |
| --- | --- |
| CPU | CPU 型号、核心数、使用率 |
| 内存 | 总内存、已用内存、使用率 |
| 磁盘 | 磁盘列表、类型、容量、使用率 |
| S.M.A.R.T. | 磁盘健康状态、温度 |
| GPU | GPU 型号、显存、序列号、使用率、温度 |
| 网络 | 指定网卡收发字节数 |
| 系统 | load average、进程数 |

JSON 写入后会做格式校验，读取使用 `utf-8-sig`，兼容普通 UTF-8 和带 BOM 的 UTF-8 文件。

### 5.2 master 拉取流程

master 拉取脚本：

```bash
/share/server-monitor/master/pull_agent_data.sh
```

按 `master/config.sh` 中的 `AGENT_NODES` 连接三台 agent：

```text
节点名|SSH用户|IP|SSH端口|SSH私钥路径|远程数据目录
```

当前节点列表：

```text
kid-pc|kid|192.168.2.213|22|/share/server-monitor/keys/id_rsa-kid|/share/server-monitor/data
hecsgl-System-Product-Name|hecsgl|192.168.2.222|22|/share/server-monitor/keys/id_rsa-hecsgl|/share/server-monitor/data
b318server|hecs|192.168.2.233|11318|/share/server-monitor/keys/id_rsa-hecs|/share/server-monitor/data
```

拉取后的文件保存在：

```text
/share/server-monitor/data/staging/{node}/data_*.json
```

### 5.3 master 上传流程

master 主入口：

```bash
/share/server-monitor/master/run_monitor.sh
```

常用命令：

```bash
# 完整 dry-run：拉取 + 格式化，不上传飞书，不清理远程
/share/server-monitor/master/run_monitor.sh --dry-run

# 只检查已有 staging 数据的飞书字段格式化
/share/server-monitor/master/run_monitor.sh --dry-run --upload-only

# 正式运行：拉取 + 上传 + 本地校验通过后清理远程 JSON
/share/server-monitor/master/run_monitor.sh --clean-remote

# 仅刷新并检查飞书 token
cd /share/server-monitor/master
source ./config.sh
export FEISHU_APP_TOKEN FEISHU_TABLE_ID FEISHU_ACCESS_TOKEN FEISHU_APP_ID FEISHU_APP_SECRET
python3 ./agent_upload.py --check-token
```

## 6. 最近验证记录

### 2026-06-04 17:24 手动 agent 采集测试

三台 agent 均手动采集成功：

| 节点 | 生成文件 |
| --- | --- |
| `kid-pc` | `/share/server-monitor/data/data_kid-pc_20260604_172419.json` |
| `hecsgl-System-Product-Name` | `/share/server-monitor/data/data_hecsgl-System-Product-Name_20260604_172418.json` |
| `b318server` | `/share/server-monitor/data/data_b318server_20260604_172419.json` |

### 2026-06-04 17:25 master 全链路 dry-run

执行：

```bash
bash /share/server-monitor/master/run_monitor.sh --dry-run
```

结果：

- agent 拉取成功：`3/3`
- JSON 校验成功：`3/3`
- 飞书字段格式化成功：`3/3`
- 未实际上传飞书
- 未清理远程 agent JSON

### 2026-06-04 17:34 token 与上传阶段 dry-run

执行 token 检查成功：

```bash
python3 /share/server-monitor/master/agent_upload.py --check-token
```

执行上传阶段 dry-run 成功：

```bash
/share/server-monitor/master/run_monitor.sh --dry-run --upload-only
```

结果：已有 staging 中的 3 条记录格式化成功，未上传飞书。

## 7. 当前数据状态

当前 master staging 中存在 3 个测试 JSON：

```text
/share/server-monitor/data/staging/kid-pc/data_kid-pc_20260604_172419.json
/share/server-monitor/data/staging/hecsgl-System-Product-Name/data_hecsgl-System-Product-Name_20260604_172418.json
/share/server-monitor/data/staging/b318server/data_b318server_20260604_172419.json
```

对应的远端 agent 数据文件也仍存在，因为之前只执行了 dry-run，没有启用远端清理。

重要：下一次正式执行 `run_monitor.sh --clean-remote` 时，这 3 条测试数据会被作为待上传数据处理。若不希望测试数据进入飞书，需要在首次正式自动运行前手动清理或移动这些 staging 和远端测试 JSON。

## 8. 日志位置

master 日志：

```text
/share/server-monitor/logs/run_monitor_YYYYmmdd_HHMMSS.log
/share/server-monitor/logs/summary_YYYYmmdd_HHMMSS.log
/share/server-monitor/logs/errors_YYYYmmdd_HHMMSS.log
/share/server-monitor/logs/master_cron.log
```

agent cron 日志：

```text
/share/server-monitor/logs/cron.log
```

常用查看命令：

```bash
# master 最近运行日志
ls -lt /share/server-monitor/logs

# master 定时任务
crontab -l

# agent 定时任务示例
ssh -i /share/server-monitor/keys/id_rsa-kid -p 22 kid@192.168.2.213 'crontab -l'
ssh -i /share/server-monitor/keys/id_rsa-hecsgl -p 22 hecsgl@192.168.2.222 'crontab -l'
ssh -i /share/server-monitor/keys/id_rsa-hecs -p 11318 hecs@192.168.2.233 'crontab -l'
```

## 9. 运维注意事项

1. `--clean-remote` 当前采用远程 `rm -f data_*.json`。目前有本地 JSON 校验保护，但生产上更稳的方式是远端移动到 backup 目录。
2. 上传逻辑已有成功/失败文件流转，但还没有全局幂等去重。如果手工把 `uploaded/` 文件复制回 staging，仍可能重复上传。
3. 首次正式上传前请确认是否要保留当前 3 条测试 JSON。
4. 飞书 token 自动刷新已验证成功，但目标多维表格写入权限仍需通过首次真实上传确认。
5. `agent/setup_cron.sh install -t 09:30` 存在 Bash 前导零解析问题；应使用 `9:30`，或直接写入等价 cron。当前三台 agent 已直接写入正确 crontab。
6. `agent/setup_cron.sh` 在空用户 crontab 场景下可能被 `set -e/pipefail` 中断。当前三台 agent 的 crontab 已手动写入并验证。
7. `master/config.sh` 含飞书应用凭证，应保持 `600` 权限，不应复制到公开位置或写入文档。

## 10. 正式运行检查清单

首次正式运行前建议确认：

```bash
# 1. master token 自动刷新
cd /share/server-monitor/master
source ./config.sh
export FEISHU_APP_TOKEN FEISHU_TABLE_ID FEISHU_ACCESS_TOKEN FEISHU_APP_ID FEISHU_APP_SECRET
python3 ./agent_upload.py --check-token

# 2. master dry-run
/share/server-monitor/master/run_monitor.sh --dry-run

# 3. 确认是否清理测试数据
rg --files /share/server-monitor/data

# 4. 正式运行
/share/server-monitor/master/run_monitor.sh --clean-remote
```

正式自动排程已经配置完成：agent 每天 `09:30` 采集，master 每天 `09:45` 拉取并上传。
