# 贡献指南

感谢参与 Agent Win Remote。

## 提交前检查

```bash
bash server/check.sh
python3 -m json.tool public/relay-settings.sample.json >/dev/null
```

不要提交：

- `public/relay-settings.json`
- Token、密码、SSH 私钥
- VPS 私有地址和真实主机信息
- 运行日志、PID 文件和临时输出
- 未说明来源的第三方二进制

## 代码原则

- 保持 Windows Agent 只监听回环地址，除非有明确的安全设计和文档
- 新增远程接口必须说明认证、输入限制、超时和输出限制
- 不引入持久化、自启动、提权或禁用安全防护功能
- 复杂 PowerShell 任务继续使用 `/stdin-run`
- 修改 `public/` 运行文件后同步检查 `manifest.json`
- 修改批处理菜单时保持 GBK、CRLF、无 BOM 的兼容性要求

## 提交格式

提交信息使用简短、清晰的英文动词开头，例如：

```text
Fix stdin-run timeout handling
Improve setup documentation
Add configuration validation
```
