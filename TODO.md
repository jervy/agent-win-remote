# TODO

## 第二阶段：已完成代码实现，当前部署检查中

### 已实现

- [x] GET /health
- [x] GET /status
- [x] GET /info
- [x] POST /run（短命令调试）
- [x] POST /stdin-run（正式主流程）
- [x] GET /logs
- [x] POST /stop
- [x] GET /help
- [x] POST /upload-text
- [x] GET /download
- [x] GET /list
- [x] Bearer token 认证
- [x] PowerShell/cmd timeout
- [x] stdout/stderr 分离
- [x] JSON 统一返回
- [x] 日志（不记录脚本内容）
- [x] start.ps1 / stop.ps1 / status.ps1 联动修正

### 待验证

- [ ] Windows 侧重新运行菜单 A 同步，然后停止并重启 agent
- [ ] Windows 本地 curl /health
- [ ] Windows 本地 curl /stdin-run（提交 main.ps1）
- [ ] Windows 本地 curl /run（短命令）
- [ ] Windows 本地 upload/download/list
- [ ] CloudStudio/VPS 通过 chisel reverse 访问中继服务器 反向端口
- [ ] CloudStudio 侧用 Hermes curl 完整验证 /stdin-run

## 第三阶段：增强功能（未实现）

- [ ] GET /processes
- [ ] GET /services
- [ ] GET /net
- [ ] 异步任务队列
- [ ] 任务取消
- [ ] 文件分片上传
- [ ] 文件分片下载
- [ ] 截图能力
- [ ] Windows 事件日志查询
- [ ] 更完整审计日志
- [ ] 多主机注册表
- [ ] Hermes 自定义工具封装
- [ ] MeshCentral/Remotely 替代方案评估

## 不实现（明确不做）

- JSON job package
- zip-run
- 交互式 terminal / WebSocket shell / PTY
- 任意删除 / 递归删除 / 格式化
- 提权 / 注册表自启动 / 系统服务
- 禁用杀软 / 防火墙


## menu.bat 稳定规则

- menu.bat 是 Windows 用户入口，默认冻结，不再通过 A 同步自动更新。
- A 同步只更新 start.ps1、agent.ps1、relay-settings.json、stop.ps1、status.ps1 等运行文件。
- 菜单显示异常时，重新从 VPS 下载 menu.bat；不要反复让自动同步覆盖菜单。
- menu.bat 使用 GBK + chcp 936 + CRLF，避免中文 Windows cmd 对 UTF-8 菜单显示不稳定。
- 只有菜单本身必须改时，才手动更新 public/menu.bat 并让用户重新下载桌面菜单。
