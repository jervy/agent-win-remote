# Agent Win Remote

用于服务器、家庭网络和开发环境的 Windows 临时远程管理方案。它通过 PowerShell HTTP Agent 和 Chisel 反向隧道访问 Windows，不提供 GUI 远程桌面或交互式终端。

仅限管理你拥有或明确获授权的设备。

## 工作方式

- Windows Agent 只监听 `127.0.0.1:18888`
- Windows 主动通过 Chisel 连接 Linux 中继服务器
- 中继服务器通过反向端口访问 Windows Agent
- 管理接口使用 Bearer Token
- 简单命令使用 `/run`，完整脚本使用 `/stdin-run`
- 不安装 Windows 服务，不写注册表自启动，不做持久化

```text
管理端 / Linux
      │ SSH 或 HTTP
      ▼
Linux 中继服务器
  ├─ Chisel Server
  └─ 反向端口：19101、19102……
      ▲
      │ Chisel reverse tunnel
      ▼
Windows
  ├─ agent.ps1：127.0.0.1:18888
  └─ chisel.exe client
```

示例映射：

```text
win-lab-a：127.0.0.1:18888 → 中继服务器 127.0.0.1:19101
win-lab-b：127.0.0.1:18888 → 中继服务器 127.0.0.1:19102
```

## 快速开始

以下命令使用示例地址 `192.0.2.44`，部署时替换成自己的中继服务器公网 IP。

### 1. 准备 Linux 中继服务器

要求：Linux x86_64 或兼容 Chisel 的系统，以及 Bash、curl、jq 和 OpenSSH 客户端。中继服务器需要能被 Windows 主动访问，防火墙只开放必要的 Chisel Server 端口。

```bash
git clone https://github.com/jervy/agent-win-remote.git
cd agent-win-remote

mkdir -p relay-secrets
cp public/relay-settings.sample.json relay-secrets/relay-settings.json
chmod 600 relay-secrets/relay-settings.json
export AGENT_CONFIG="$PWD/relay-secrets/relay-settings.json"
```

编辑私有配置，填写 `server_url`、`chisel_auth`、`agent_token` 和端口映射。例如：

```text
server_url：  http://192.0.2.44:28271
win-lab-a：       192.0.2.44:19101
win-lab-b：       192.0.2.44:19102
win-test-c：      192.0.2.44:19103
```

### 2. 启动 Chisel Server

将项目放到中继服务器的私有目录，例如 `/opt/agent-win-remote`：

```bash
cd /opt/agent-win-remote
chmod +x server/*.sh bin/chisel
export AGENT_CONFIG="$PWD/relay-secrets/relay-settings.json"
bash server/start-chisel-server.sh
bash server/status.sh
```

### 3. 准备 Windows 文件

Windows 工作目录需要：

```text
agent.ps1
start.ps1
stop.ps1
status.ps1
chisel.exe
relay-settings.json
```

将 `public/relay-settings.sample.json` 复制为 Windows 工作目录中的 `relay-settings.json`，填写与中继服务器一致的 `server_url`、`chisel_auth`、`agent_token` 和 `remote_port`。例如目录可以是 `%TEMP%\agent-win-agent`。

### 4. 启动并检查 Agent

在 Windows PowerShell 中执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd "$env:TEMP\agent-win-agent"
.\start.ps1 -HostId win-lab-a -Action start
curl.exe -s http://127.0.0.1:18888/health
.\start.ps1 -Action status
```

Windows 连接成功后，在中继服务器上检查反向端口：

```bash
curl -sS http://127.0.0.1:19101/health
```

### 5. 从管理端访问

先通过 SSH 登录中继服务器，再使用对应的反向端口访问 Windows Agent：

```bash
ssh -i ~/.ssh/<你的私钥> <用户>@192.0.2.44
curl -sS http://127.0.0.1:19101/health
```

需要认证的接口，按实际部署方式附加 `agent_token` 对应的 Bearer Token。不要把 Token 写入 Git、脚本或日志。

### 6. 执行 PowerShell 脚本

复杂任务使用 `/stdin-run`，简单探活才使用 `/run`：

```bash
cat >/tmp/main.ps1 <<'EOF'
Write-Output "hello from Windows"
Write-Output (Get-Date)
EOF

curl -sS 'http://127.0.0.1:19101/stdin-run?timeout=120&cleanup=true' \
  --data-binary @/tmp/main.ps1
```

实际调用时，为请求附加 Bearer Token。返回结果包含 `ok`、`run_id`、`stdout`、`stderr`、`exit_code`、`duration_ms`、`timeout` 和 `truncated`。

## 多台 Windows 主机

为每台 Windows 分配不同的反向端口：

```text
win-lab-a  → 19101
win-lab-b  → 19102
win-test-c → 19103
```

每台 Windows 都可以使用本地端口 `127.0.0.1:18888`，只需设置不同的 `HostId` 和 `remote_port`。

## 配置和敏感信息

公开仓库只提供：

```text
public/relay-settings.sample.json
```

部署时自行创建私有配置：

```text
relay-secrets/relay-settings.json
```

以下内容不要提交到 Git：

- SSH 私钥和中继服务器密码
- `chisel_auth`、`agent_token`
- 真实中继服务器地址和端口规划
- 真实 Windows 主机名、局域网地址
- 运行日志、PID 文件和临时文件

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

## 设计取舍

反向隧道避免开放 Windows 公网入站端口，也不要求家庭路由器配置端口转发，适合 NAT 和动态 IP 环境。OpenSSH 用于管理 Linux 中继服务器，Chisel 负责转发到 Windows；Agent 则以 HTTP/JSON 形式返回自动化结果。

## 安全边界

这是一个具备远程 PowerShell 执行能力的管理工具，风险较高。当前设计包括：

- Agent 仅监听 `127.0.0.1`
- 管理接口使用 Bearer Token
- `/stdin-run` 限制脚本、超时和输出大小
- 脚本写入临时目录后执行
- 不提供交互式终端、PTY 或 WebSocket Shell
- 不安装服务、不设置持久化自启动

请妥善保护 Token 和中继服务器，只在授权设备上使用。

## 故障排查

1. Windows 本机 `/health` 不通：检查 Agent 是否启动。
2. Windows 本机正常但反向端口不通：检查 Chisel 客户端、认证信息、防火墙和中继日志。
3. 反向端口存在但返回 `401`：检查 `agent_token`。
4. `/stdin-run` 超时：拆分任务，或让 Windows 后台执行并轮询日志。
5. Windows 重启后断线：项目默认不持久化，需要手动重新启动。

## 第三方组件和许可证

项目使用 Chisel 作为反向隧道组件。仓库内二进制版本和 SHA-256 校验值见 `THIRD_PARTY_NOTICES.md`，第三方组件许可证以其上游条款为准。

本项目采用 MIT License，详见 `LICENSE`。
