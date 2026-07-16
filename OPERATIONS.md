# 常用操作

本文所有地址、端口和凭据均为示例，部署时请替换为自己的配置。

## 执行规则

- 正式远程操作使用 `POST /stdin-run` + `main.ps1`
- `/run` 只用于 `whoami`、`hostname`、`Get-Date` 等短命令探活
- 不要把复杂 PowerShell 脚本放进 `/run` 的 JSON 字段
- 不要把 Token 写入 Git、命令历史或公开日志

## 中继服务器侧部署

```bash
cd /opt/agent-win-remote
bash server/start-chisel-server.sh
bash server/status.sh
```

## Windows 侧管理

```powershell
cd "$env:TEMP\hermes-win-agent"
.\start.ps1 -Action start
.\start.ps1 -Action stop
.\start.ps1 -Action restart
.\start.ps1 -Action status
.\start.ps1 -Action check
```

本地健康检查：

```powershell
curl.exe -s http://127.0.0.1:18888/health
```

## 中继服务器侧健康检查

```bash
curl -sS http://127.0.0.1:19101/health
```

## 正式执行 PowerShell

```bash
cat >/tmp/main.ps1 <<'EOF'
Write-Output "hello from Windows"
Write-Output (Get-Date)
EOF

TOKEN=$(jq -r .agent_token /path/to/relay-secrets/relay-settings.json)
curl -sS 'http://127.0.0.1:19101/stdin-run?timeout=120&cleanup=true' \
  -H "Authorization: Bearer $TOKEN" \
  --data-binary @/tmp/main.ps1
```

返回 JSON 包含：

- `ok`
- `run_id`
- `stdout`
- `stderr`
- `exit_code`
- `duration_ms`
- `timeout`
- `truncated`

## 简单探活

```bash
TOKEN=$(jq -r .agent_token /path/to/relay-secrets/relay-settings.json)
curl -sS http://127.0.0.1:19101/run \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"shell":"powershell","cmd":"hostname","timeout":10}'
```

## 原生 OpenSSH 的推荐用法

```bash
ssh -i ~/.ssh/<private-key> <user>@<vps-host>
```

登录中继服务器 后再访问 `127.0.0.1:19101`。这样：

- 管理端口不必直接暴露到公网
- SSH 密钥由 OpenSSH 管理
- 可以使用 SSH 配置别名、跳板、端口转发和审计日志
- Chisel 只负责建立 Windows 到 中继服务器的反向路径

## 日志

Windows：

```powershell
Get-Content "$env:TEMP\hermes-win-agent\logs\agent.log" -Tail 50
Get-Content "$env:TEMP\hermes-win-agent\logs\chisel-client.log" -Tail 50
```

中继服务器：

```bash
tail -50 /opt/agent-win-remote/logs/chisel-server.log
```

## 故障排查

1. Windows 本地健康检查失败：检查 `agent.ps1` 和本地端口。
2. Windows 本地正常、VPS 端口不存在：检查 Chisel 客户端、认证信息和 中继服务器防火墙。
3. 中继服务器 端口存在但返回 401：检查 `agent_token`。
4. `/stdin-run` 超时：拆分脚本，或在 Windows 启动后台 worker 并轮询日志。
5. Windows 重启后断线：本项目默认不持久化，需要重新启动。
