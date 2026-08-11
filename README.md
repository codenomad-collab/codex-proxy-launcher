# Codex 代理启动器

一个仅针对 Codex 桌面客户端的 macOS 启动器。它同时提供普通主窗口和菜单栏入口，不会修改 macOS 系统代理，也不会修改 Clash Verge 配置。

> 当前版本：0.2.0。预编译版本可在 GitHub Releases 下载；也可以按下方步骤从源码构建。

## 功能

- 通过 Clash Verge mixed port 单独启动 Codex，无需开启 TUN 模式。
- 每 2 秒统计 Codex 主进程和全部子进程的实时上下行流量。
- 显示会话累计流量、被观察进程数和活动代理连接数。
- 审计已建立的 TCP 连接，提示是否出现绕过 Clash 的外部直连。
- 通过 Clash 查询代理出口 IP、国家/地区、城市、ASN、运营商和时区。
- 提供完整仪表盘与菜单栏紧凑面板。

启动 Codex 时注入两类设置：

- Electron `--proxy-server` 参数，覆盖 Codex UI 的 HTTP、HTTPS 和 WebSocket 代理。
- `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 等环境变量，供 Codex app-server 和支持代理的任务子进程继承。

默认代理地址为 Clash Verge mixed port：`127.0.0.1:7890`。

## 构建

要求 macOS 13 或更新版本，以及 Xcode Command Line Tools。

```bash
cd codex-proxy-launcher
swift test
./Scripts/build-app.sh
```

产物位于：

```text
dist/Codex 代理启动器.app
```

当前构建脚本使用 ad-hoc 签名，适合本机测试。分发给其他机器前应改用 Developer ID 签名并完成 notarization。

## 使用

1. 保持 Clash Verge 正常运行，确认 mixed port 为 `7890`。
2. 关闭 Clash Verge 的 TUN 模式和 macOS 系统代理。
3. 打开 `Codex 代理启动器.app`；应用会显示主窗口，同时在菜单栏显示网络图标。
4. 点击“启动 Codex（使用代理）”。如果 Codex 已运行，按钮会先请求它正常退出再重启。
5. 在 Codex 中测试对话、流式输出、Git、curl、npm、pip 等功能。

出口 IP 查询使用 `ipwho.is`，请求本身强制经过配置的 Clash 代理；Clash 不可达时不会回退到直连。IP 归属位置来自网络数据库估算，不代表设备的 GPS 位置。

## 边界

这是启动器方案，不是 Network Extension。它不能强制代理不识别环境变量的原始 Socket、UDP/QUIC 或 SSH 流量。连接审计当前覆盖已建立的 TCP 连接，不等价于内核级防泄漏。应用在 7890 不可达时会拒绝启动 Codex，但 Codex 启动后若 Clash 退出，Electron 或个别子进程是否回退直连仍取决于相应网络库。
