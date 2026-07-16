# Agent Win Remote

一个用于服务器和开发环境的 Windows 临时远程管理方案。（非GUI交互式远程桌面）

它由以下部分组成：

- HTTP Agent脚本：只监听 Windows 本机回环地址
- Chisel 反向隧道：让没有公网入站条件的 Windows 主机主动连接中转服务器
- Linux 中继服务器 管理端脚本：通过反向端口访问 Windows Agent

## 主要特点

- Windows 端不需要开放公网入站端口
- Agent 默认只监听 `127.0.0.1`
- Windows 主动通过 Chisel 连接中转服务器，适合家庭宽带、NAT、动态公网地址和无端口转发环境
- 正式任务通过 `POST /stdin-run` 提交完整 PowerShell 脚本，避免复杂命令塞进 JSON 字符串
- 所有管理接口默认使用 Bearer Token
- 不安装 Windows 服务，不写注册表自启动，不做持久化
- 支持多台 Windows 主机使用不同的反向端口
- 可通过原生 OpenSSH 管理 Linux 中继服务器侧的部署、日志和端口

## 架构

```text
管理端 / Linux / agent
        │  OpenSSH 或 HTTP
        ▼
中继服务器 / Linux
  ├─ Chisel Server
  ├─ 静态文件服务（仅用于公开运行文件）
  └─ 反向端口：19101、19102……
        ▲
        │ Chisel reverse tunnel（Windows 主动连接）
        │
Windows
  ├─ agent.ps1：127.0.0.1:18888
  └─ chisel.exe client
```

示例端口映射：

```text
Windows win-1 的 127.0.0.1:18888 → 中继服务器的 127.0.0.1:19101
Windows win-2 的 127.0.0.1:18888 → 中继服务器的 127.0.0.1:19102
```

## 快速开始

### 1. 准备 Linux 中继服务器

要求：

- Linux x86_64 或兼容 Chisel 的 Linux 主机
- Bash、curl、jq、OpenSSH 客户端
- 一个可从 Windows 访问的中继服务器
- 中继服务器防火墙只按需开放 Chisel Server 端口
- 推荐使用 SSH 公钥登录中继服务器

以下步骤使用示例中继服务器地址 `192.0.2.44`，部署时替换成自己的中继服务器公网 IP。

克隆项目后进入目录：

```bash
git clone https://github.com/jervy/agent-win-remote.git
cd agent-win-remote
```

创建私有配置：

```bash
mkdir -p relay-secrets
cp public/relay-settings.sample.json relay-secrets/relay-settings.json
chmod 600 relay-secrets/relay-settings.json
export AGENT_CONFIG="$PWD/relay-secrets/relay-settings.json"
```

编辑私有配置中的 `server_url`、认证信息和端口映射。文档示例为：

```text
server_url:  http://192.0.2.44:28271
win-lab-a:       192.0.2.44:19101
win-lab-b:       192.0.2.44:19102
win-test-c:       192.0.2.44:19103
```

部署时将 `192.0.2.44` 替换成自己的中继服务器公网 IP。

### 2. 启动 中继服务器侧 Chisel Server

把项目部署到 中继服务器私有目录，例如：

```bash
/opt/agent-win-remote
```

然后执行：

```bash
chmod +x server/*.sh bin/chisel
export HERMES_CONFIG=/opt/agent-win-remote/relay-secrets/relay-settings.json
bash server/start-chisel-server.sh
bash server/status.sh
```

启动脚本从 `HERMES_CONFIG` 指定的私有配置读取认证信息。它不会把完整认证字符串打印到终端。

### 3. 准备 Windows 文件

Windows 端需要：

```text
agent.ps1
start.ps1
stop.ps1
status.ps1
chisel.exe
relay-settings.json
```

把这些文件复制到 Windows 的工作目录，例如 `%TEMP%\hermes-win-agent`。将 `relay-settings.sample.json` 复制为该目录下的 `relay-settings.json`，并填写与中继服务器一致的 `server_url`、`chisel_auth`、`agent_token` 和 `remote_port`。

### 4. 启动 Windows Agent

在 Windows PowerShell 中执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd "$env:TEMP\hermes-win-agent"
.\start.ps1 -HostId win-lab-a -Action start
```

检查本机 Agent：

```powershell
curl.exe -s http://127.0.0.1:18888/health
.\start.ps1 -Action status
```

如果 Windows 通过 Chisel 成功连接 中继服务器，在 中继服务器上检查：

```bash
curl -sS http://127.0.0.1:19101/health
```

### 5. 使用原生 OpenSSH 从管理端访问

推荐使用 SSH 密钥登录中继服务器：

```bash
ssh -i ~/.ssh/<你的私钥> <用户>@192.0.2.44
```

这里的 `192.0.2.44` 为示例地址，部署时替换成自己的中继服务器公网 IP。登录后访问 Windows Agent：

```bash
curl -sS http://127.0.0.1:19101/health
```

如果需要认证的接口，从 中继服务器上安全读取私有配置，不要把 Token 写进 Git：

```bash
TOKEN=$(jq -r .agent_token /opt/agent-win-remote/relay-secrets/relay-settings.json)
curl -sS http://127.0.0.1:19101/status \
  -H "Authorization: Bearer $TOKEN"
```

### 6. 正式执行 PowerShell 脚本

复杂任务必须使用 `/stdin-run`，不要把多行 PowerShell 塞进 `/run` 的 JSON 字段：

```bash
cat >/tmp/main.ps1 <<'EOF'
Write-Output "hello from Windows"
Write-Output (Get-Date)
EOF

TOKEN=$(jq -r .agent_token /opt/agent-win-remote/relay-secrets/relay-settings.json)
curl -sS 'http://127.0.0.1:19101/stdin-run?timeout=120&cleanup=true' \
  -H "Authorization: Bearer $TOKEN" \
  --data-binary @/tmp/main.ps1
```

返回结果包含：

- `ok`
- `run_id`
- `stdout`
- `stderr`
- `exit_code`
- `duration_ms`
- `timeout`
- `truncated`

`/run` 仅适合 `hostname`、`whoami`、`Get-Date` 等简单探活命令。

## 多台 Windows 主机

为每台 Windows 分配不同的中继服务器反向端口。下面是一组与实际部署无关的文档示例：

```text
win-lab-a → 19101
win-lab-b → 19102
win-test-c → 19103
```

每台 Windows 的本地 Agent 仍然可以监听 `127.0.0.1:18888`，只需要为对应主机设置不同的 `remote_port` 和主机标识。

## 配置文件

仓库只提供：

```text
public/relay-settings.sample.json
```

部署者自行创建：

```text
public/relay-settings.json
```

以下信息请勿提交到公开仓库：

- 中继服务器 IP 或域名（如果不希望公开）
- SSH 私钥
-中继服务器密码
- `chisel_auth`
- `agent_token`
- 私有端口规划
- 真实 Windows 主机名和局域网地址
- 运行日志

## 目录结构

```text
agent-win-remote/
├── README.md
├── LICENSE
├── SECURITY.md
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
├── CHANGELOG.md
├── .gitignore
├── .github/workflows/ci.yml
├── public/
│   ├── agent.ps1
│   ├── start.ps1
│   ├── stop.ps1
│   ├── status.ps1
│   ├── menu.bat
│   ├── relay-settings.sample.json
│   ├── manifest.json
│   └── chisel.exe
├── bin/
│   └── chisel
└── server/
    ├── start-chisel-server.sh
    ├── stop-chisel-server.sh
    ├── restart-chisel-server.sh
    ├── status.sh
    └── check.sh
```

## 为什么使用穿透 + 原生 OpenSSH

### 相比直接开放 Windows 端口

- Windows 不需要暴露 HTTP Agent 到公网
- 不需要在每个家庭路由器上做端口转发
- Windows 只需要主动访问 中继服务器，适合 NAT 和动态 IP 环境
- 外部访问集中在 中继服务器，便于做防火墙限制、审计和统一停用

### 相比只使用 OpenSSH 直连 Windows

- Windows 原生 OpenSSH 需要服务端持续运行，并需要处理 Windows 防火墙、端口暴露、账号权限和密钥部署
- 穿透链路可以让 Windows 不接受公网入站连接，减少暴露面
- Agent 提供结构化 HTTP/JSON 返回，适合自动化 Agent、脚本和 CI 调用
- `stdin-run` 可以一次提交完整脚本并返回 stdout、stderr、退出码、超时状态

### 原生 OpenSSH 的作用

Chisel 负责“让连接穿透到 Windows”，OpenSSH 负责“管理 Linux 中继服务器 这一侧”。两者分工清晰：

- SSH 登录中继服务器
- 查看 Chisel 服务状态和日志
- 检查反向端口是否出现
- 上传或同步部署文件
- 在中继服务器本机通过 `127.0.0.1:<remote-port>` 调用 Windows Agent
- 使用 SSH 密钥认证，不把中继服务器密码写进脚本

这种组合比把所有管理逻辑塞进一个自定义 TCP 服务更容易维护，也更容易替换中转机或接入现有 Linux 运维流程。

## 安全边界

这是一个具有远程 PowerShell 执行能力的管理工具，风险较高。当前设计原则：

- Agent 只监听 `127.0.0.1`
- 管理接口使用 Bearer Token
- `/stdin-run` 限制脚本大小、超时时间和输出大小
- 脚本写入临时目录后执行
- 不支持交互式终端、PTY、WebSocket shell
- 不安装服务、不写持久化自启动
- 不提供专门的任意删除、格式化磁盘、提权、禁用安全软件接口

## 故障排查

1. Windows 本机 `127.0.0.1:18888/health` 不通：检查 Agent 是否启动。
2. Windows 本机正常、中继服务器反向端口不通：检查 Chisel 客户端、认证信息、中继服务器防火墙和日志。
3. 中继服务器反向端口存在但返回 401：检查 Agent Token。
4. `/stdin-run` 超时：拆分任务；长任务使用 Windows 后台进程和日志轮询。
5. Windows 重启后断线：本项目默认不持久化，需要手动重新启动。

## 第三方组件

本项目使用 Chisel 作为反向隧道组件。仓库内的二进制文件仅用于方便部署，版本和 SHA256 校验值见 `THIRD_PARTY_NOTICES.md`。使用前请确认你接受 Chisel 的许可证和上游发布条款。

## 许可证

本项目采用 MIT License。第三方组件不一定采用相同许可证，请查看 `THIRD_PARTY_NOTICES.md`。
