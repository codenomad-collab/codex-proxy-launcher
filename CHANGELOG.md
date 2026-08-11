# Changelog

## 0.2.0 - 2026-08-11

首个公开版本。

### 功能

- 通过 Clash Verge mixed port `127.0.0.1:7890` 启动 Codex。
- 为 Electron 和支持代理环境变量的 Codex 子进程注入代理配置。
- 实时显示上下行速率、会话流量与最近 3 分钟曲线。
- 监测 Codex 进程树的活动代理连接与外部 TCP 直连。
- 查询代理出口 IP、地区、ASN、运营商和时区。
- 提供主窗口、菜单栏面板和自定义应用图标。

### 发布说明

- 预编译包面向 Apple Silicon Mac，最低要求 macOS 13。
- 安装包采用 ad-hoc 签名，尚未使用 Apple Developer ID 公证。
