# 部署指南

本文只描述通用示例。中继服务器地址、端口、Token、Chisel 认证和主机映射请在部署时替换为自己的值。

## 一、准备中继服务器

要求：

- Linux x86_64
- Bash、curl、jq、ss
- OpenSSH Server
- Windows 能够主动访问中继服务器的 Chisel 端口
- 推荐通过 SSH 公钥登录中继服务器

本文使用示例中继服务器地址 `192.0.2.44`，部署时替换成自己的中继服务器公网 IP。

建议目录：

```text
/opt/agent-win-remote
/opt/agent-win-remote/relay-secrets/relay-settings.json
```

把项目复制到 中继服务器 后，创建私有配置：

```bash
cd /opt/agent-win-remote
mkdir -p relay-secrets
cp public/relay-settings.sample.json relay-secrets/relay-settings.json
chmod 600 relay-secrets/relay-settings.json
```

注意：启动脚本支持 `HERMES_CONFIG` 环境变量。不要把含真实凭据的配置放入公开静态文件目录。

## 二、配置中继服务器端 Chisel Server

在私有配置目录创建配置文件：

```bash
cp public/relay-settings.sample.json relay-secrets/relay-settings.json
chmod 600 relay-secrets/relay-settings.json
export HERMES_CONFIG="$PWD/relay-secrets/relay-settings.json"
```

编辑私有 `relay-settings.json`：

```json
{
  "server_url": "http://192.0.2.44:28271",
  "chisel_auth": "your-user:your-long-random-password",
  "agent_token": "your-long-random-agent-token",
  "server_port": 28271,
  "remote_port": 19101,
  "local_agent_port": 18888
}
```

启动：

```bash
chmod +x bin/chisel server/*.sh
bash server/start-chisel-server.sh
bash server/status.sh
```

如果脚本读取的是 `public/relay-settings.json`，请确认该文件只存在于 中继服务器私有部署目录，并且没有被公开静态文件服务发布。

## 三、准备 Windows 文件

Windows 端需要：

```text
agent.ps1
start.ps1
stop.ps1
status.ps1
chisel.exe
relay-settings.json
```

把 `public/relay-settings.sample.json` 复制成 Windows 端的 `relay-settings.json`，填写同一组：

- `server_url`
- `chisel_auth`
- `agent_token`
- `remote_port`
- `local_agent_port`

建议工作目录：

```text
%TEMP%\hermes-win-agent
```

## 四、启动 Windows Agent

在 Windows PowerShell 中执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd "$env:TEMP\hermes-win-agent"
.\start.ps1 -HostId win-lab-a -Action start
```

检查 Windows 本地 Agent：

```powershell
curl.exe -s http://127.0.0.1:18888/health
.\start.ps1 -Action status
```

## 五、检查反向隧道

在中继服务器上执行：

```bash
bash server/status.sh
curl -sS http://127.0.0.1:19101/health
```

如果反向端口没有出现，按以下顺序检查：

1. Windows Agent 是否监听 `127.0.0.1:18888`
2. Windows Chisel 客户端是否运行
3. Windows 与 中继服务器的 `chisel_auth` 是否一致
4. `server_url` 是否正确
5. 中继服务器 防火墙是否允许 Chisel Server 端口
6. Windows 和 中继服务器 两侧 Chisel 日志

## 六、使用原生 OpenSSH

从管理机登录中继服务器：

```bash
ssh -i ~/.ssh/<private-key> <user>@192.0.2.44
```

`192.0.2.44` 为示例地址，部署时替换成自己的中继服务器公网 IP。登录后，通过中继服务器本机回环地址访问 Windows Agent：

```bash
curl -sS http://127.0.0.1:19101/health
```

这是推荐方式：反向管理端口可以只监听 中继服务器的 localhost，不必直接暴露给公网。

## 七、多台 Windows 主机

为每台 Windows 分配不同的中继服务器 `remote_port`。以下仅为公开文档示例：

```text
win-lab-a → 19101
win-lab-b → 19102
win-test-c → 19103
```

每台 Windows 的本地 Agent 可以继续使用：

```text
127.0.0.1:18888
```

## 八、停止

中继服务器：

```bash
bash server/stop-chisel-server.sh
```

Windows：

```powershell
.\start.ps1 -Action stop
```

本项目默认不安装服务、不创建注册表自启动。Windows 重启后需要按照部署者自己的流程重新启动。
