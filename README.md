# Codex 代理启动器

<p align="center">
  <img src="Assets/AppIcon-1024.png" width="128" alt="Codex 代理启动器图标">
</p>

一个仅针对 Codex macOS 桌面客户端的开源代理启动器。它让 Codex 通过本机 Clash Verge 代理联网，无需开启 Clash TUN（虚拟网卡）模式，也不会修改 macOS 系统代理。

> 当前版本：0.2.0 · [下载最新版本](https://github.com/ww1425680101/codex-proxy-launcher/releases/latest)

## 功能

- 通过 Clash Verge mixed port 单独启动 Codex。
- 每 2 秒统计 Codex 主进程及全部子进程的上下行流量。
- 显示实时速率、最近 3 分钟曲线、会话累计流量和活动代理连接数。
- 审计已建立的 TCP 连接，并在观察到外部直连时发出提示。
- 显示代理出口 IP、国家/地区、城市、ASN、运营商和时区。
- 同时提供完整仪表盘和菜单栏紧凑面板。
- Clash 代理端口不可达时拒绝启动 Codex，避免在启动阶段意外直连。

## 运行环境

使用预编译版本需要：

- Apple Silicon Mac（M1/M2/M3/M4 或更新机型）。
- macOS 13 Ventura 或更新版本。
- 已安装 Codex macOS 桌面客户端。
- 已安装并运行 Clash Verge，mixed port 为 `127.0.0.1:7890`。

Intel Mac 暂无预编译包。项目源码以 macOS 13 为最低目标，其他架构尚未经过验证。

## 安装

1. 打开 [Releases](https://github.com/ww1425680101/codex-proxy-launcher/releases) 页面。
2. 下载 `Codex-Proxy-Launcher-v0.2.0-macOS-arm64.zip`。
3. 解压后，将 `Codex 代理启动器.app` 移入“应用程序”文件夹或任意常用位置。
4. 第一次启动时，在 Finder 中右键应用并选择“打开”。

当前 Release 使用 ad-hoc 签名，没有 Apple Developer ID 公证。macOS 若阻止运行，可在“系统设置 → 隐私与安全性”中确认打开。请只从本仓库的 Releases 页面下载。

## 使用方法

1. 启动 Clash Verge，确认 mixed port 为 `7890`。
2. 关闭 Clash Verge 的 TUN 模式；macOS 系统代理也可以保持关闭。
3. 打开“Codex 代理启动器”。
4. 确认界面中的 Clash 状态显示为绿色。
5. 点击“启动 Codex（使用代理）”。如果 Codex 已经运行，启动器会先请求它正常退出，然后通过代理参数重新启动。
6. 在仪表盘中观察实时流量、活动代理连接和代理出口 IP。

如果 Codex 并非由本启动器打开，请点击“重启 Codex 并启用代理”，否则现有进程不会自动获得代理参数。

## 工作原理

启动器通过 macOS `NSWorkspace` 创建 Codex 进程，并注入两类配置：

- Electron `--proxy-server=http://127.0.0.1:7890` 参数，用于 Codex UI 的 HTTP、HTTPS 和 WebSocket 流量。
- `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 及对应小写环境变量，供 Codex app-server 和支持代理环境变量的子进程继承。

流量仪表盘使用 macOS 自带的 `nettop` 读取进程累计字节数，并根据相邻采样计算速率；连接审计使用 `lsof` 检查 Codex 进程树已经建立的 TCP 连接。上述操作不需要管理员权限。

## 隐私说明

- 应用不收集账号、对话内容或访问日志，也不包含遥测和分析 SDK。
- 出口 IP 信息由 [`ipwho.is`](https://ipwho.is/) 提供，请求被强制通过配置的 Clash 代理发送。
- IP 查询会将代理出口 IP 暴露给该查询服务；显示的位置是网络数据库估算，不是设备 GPS 位置。
- Clash 不可达时，IP 查询不会回退到直连。

## 已知边界

这是进程启动器方案，不是 macOS Network Extension 或内核级防火墙：

- 只有 Electron 流量和遵循代理参数/环境变量的子进程会使用代理。
- 原始 Socket、UDP/QUIC、SSH 或忽略代理环境变量的程序不受强制约束。
- 连接审计当前只覆盖已经建立的 TCP 连接，不等价于完整的防泄漏检测。
- Codex 启动后如果 Clash 退出，部分网络库是否回退直连取决于各自实现。
- 当前代理地址固定为 `127.0.0.1:7890`，尚未提供图形化配置入口。

## 从源码构建

需要 macOS 13 或更新版本，以及 Xcode Command Line Tools：

```bash
xcode-select --install
git clone https://github.com/ww1425680101/codex-proxy-launcher.git
cd codex-proxy-launcher
swift test
./Scripts/generate-icon.sh
./Scripts/build-app.sh release
```

构建产物位于：

```text
dist/Codex 代理启动器.app
```

测试：

```bash
swift test
```

## 项目结构

```text
Sources/CodexProxyLauncher/       SwiftUI 应用和仪表盘
Sources/CodexProxyLauncherCore/   启动、代理、流量与 IP 查询核心逻辑
Tests/                            单元测试
Assets/                           应用图标源文件和 .icns
Scripts/                          图标生成与 App 打包脚本
Packaging/                        Info.plist
```

## 许可证与声明

本项目采用 [MIT License](LICENSE) 开源。

本项目是独立的社区工具，与 OpenAI、Codex、Clash Verge 或其维护者不存在隶属或官方合作关系。相关产品名称和商标归各自权利人所有。
