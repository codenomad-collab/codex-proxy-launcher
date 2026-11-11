import AppKit
import CodexProxyLauncherCore
import Foundation

struct TrafficPoint: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
}

@MainActor
final class LauncherViewModel: ObservableObject {
    enum Activity: Equatable {
        case idle
        case checking
        case stoppingCodex
        case launching
    }

    @Published private(set) var proxyReachable: Bool?
    @Published private(set) var codexApp: LocatedCodexApp?
    @Published private(set) var codexRunning = false
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var message = "正在检查本机环境…"
    @Published private(set) var lastLaunchUsedProxy = false
    @Published private(set) var trafficMetrics = TrafficMetrics.zero
    @Published private(set) var trafficHistory: [TrafficPoint] = []
    @Published private(set) var trafficUpdatedAt: Date?
    @Published private(set) var proxyIPInfo: ProxyIPInfo?
    @Published private(set) var ipInfoLoading = false
    @Published private(set) var ipInfoError: String?
    @Published private(set) var ipInfoUpdatedAt: Date?
    @Published private(set) var nativeProbe: NativeNetworkProbe?
    @Published private(set) var explicitNativeProbe: NativeNetworkProbe?
    @Published private(set) var nativeProxyActive = false
    @Published private(set) var nativeProxyBusy = false
    @Published private(set) var nativeProxyMessage = "原生组件网络尚未检测。"

    let proxy = ProxySettings()
    private let launcher = CodexLauncher()
    private var trafficAccumulator = TrafficAccumulator()
    private var monitoredRoots: Set<Int32> = []
    private var monitoringTask: Task<Void, Never>?
    private let nativeProxy = NativeProxyClient.shared

    var isBusy: Bool {
        activity != .idle
    }

    var menuBarSymbol: String {
        if proxyReachable == false || trafficMetrics.directExternalTCPConnections > 0 {
            return "exclamationmark.triangle.fill"
        }
        return codexRunning ? "network.badge.shield.half.filled" : "network"
    }

    var primaryButtonTitle: String {
        codexRunning ? "重启 Codex 并启用代理" : "启动 Codex（使用代理）"
    }

    var chartMaximum: Double {
        max(
            1_024,
            trafficHistory.map {
                max($0.downloadBytesPerSecond, $0.uploadBytesPerSecond)
            }.max() ?? 0
        ) * 1.15
    }

    var connectionAuditText: String {
        guard codexRunning else { return "Codex 未运行" }
        if trafficMetrics.directExternalTCPConnections > 0 {
            return "发现 \(trafficMetrics.directExternalTCPConnections) 条外部 TCP 直连"
        }
        if trafficMetrics.activeProxyConnections > 0 {
            return "已观察连接均指向 Clash"
        }
        return "等待 Codex 建立网络连接"
    }

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            await self.refreshProxyIPInfo()
            if UserDefaults.standard.bool(forKey: "nativeProxyCompatibilityEnabled") || self.nativeProxy.session?.isLive == true {
                await self.enableNativeCompatibility()
            } else {
                await self.refreshNativeNetwork()
            }

            while !Task.isCancelled {
                await self.sampleTraffic()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func refresh() async {
        guard activity == .idle else { return }
        activity = .checking
        message = "正在检查 Clash 与 Codex…"

        async let reachable = ProxyReachability.check(settings: proxy)
        codexApp = CodexAppLocator.locate()
        codexRunning = launcher.isRunning
        proxyReachable = await reachable

        if codexApp == nil {
            message = "没有找到 Bundle ID 为 com.openai.codex 的应用。"
        } else if proxyReachable == false {
            message = "Clash 代理端口不可达，请先启动 Clash Verge。"
        } else if codexRunning {
            message = lastLaunchUsedProxy
                ? "Codex 已由本启动器代理启动。"
                : "Codex 正在运行；如并非由本启动器打开，请重启以注入代理设置。"
        } else {
            message = "环境就绪，可以通过代理启动 Codex。"
        }
        activity = .idle
    }

    func refreshAll() async {
        await refresh()
        await refreshProxyIPInfo()
        await refreshNativeNetwork()
        await sampleTraffic()
    }

    func refreshNativeNetwork() async {
        guard !nativeProxyBusy else { return }
        nativeProxyBusy = true
        defer { nativeProxyBusy = false }
        async let system = NativeNetworkDiagnostics.probe()
        async let explicit = NativeNetworkDiagnostics.probe(proxy: proxy)
        nativeProbe = await system
        explicitNativeProbe = await explicit
        nativeProxyActive = nativeProxy.session?.isLive == true
        updateNativeMessage()
    }

    func enableNativeCompatibility() async {
        guard !nativeProxyBusy else { return }
        nativeProxyBusy = true
        do {
            try await nativeProxy.start(proxy: proxy)
            nativeProxyActive = true
            UserDefaults.standard.set(true, forKey: "nativeProxyCompatibilityEnabled")
            // A fresh URLSession uses the current system PAC, just like native helpers.
            nativeProbe = await NativeNetworkDiagnostics.probe()
            explicitNativeProbe = await NativeNetworkDiagnostics.probe(proxy: proxy)
            updateNativeMessage()
        } catch {
            nativeProxyActive = nativeProxy.session?.isLive == true
            nativeProxyMessage = error.localizedDescription
        }
        nativeProxyBusy = false
    }

    func disableNativeCompatibility() async {
        guard !nativeProxyBusy else { return }
        nativeProxyBusy = true
        do {
            try await nativeProxy.stop()
            nativeProxyActive = false
            UserDefaults.standard.set(false, forKey: "nativeProxyCompatibilityEnabled")
            nativeProxyMessage = "兼容代理已关闭，原系统代理设置已恢复。"
        } catch { nativeProxyMessage = error.localizedDescription }
        nativeProxyBusy = false
    }

    private func updateNativeMessage() {
        if nativeProbe?.reachable == true {
            nativeProxyMessage = "原生联网可达（HTTP \(nativeProbe?.statusCode ?? 0)）；登录与电脑控制需单独验证。"
        } else if explicitNativeProbe?.reachable == true {
            nativeProxyMessage = "Clash 可达，但原生组件网络不通。可开启下方兼容代理。"
        } else {
            nativeProxyMessage = "原生与显式代理请求均未连通，请先检查 Clash 线路。"
        }
    }

    func refreshProxyIPInfo() async {
        guard !ipInfoLoading else { return }
        ipInfoLoading = true
        ipInfoError = nil

        do {
            let info = try await ProxyIPInfoService.fetch(proxy: proxy)
            proxyIPInfo = info
            ipInfoUpdatedAt = Date()
        } catch {
            ipInfoError = error.localizedDescription
        }
        ipInfoLoading = false
    }

    func launchCodex() async {
        guard activity == .idle else { return }
        activity = .checking
        message = "正在验证 Clash 代理端口…"

        let reachable = await ProxyReachability.check(settings: proxy)
        proxyReachable = reachable
        guard reachable else {
            message = "已阻止启动：Clash \(proxy.displayAddress) 不可达。"
            activity = .idle
            return
        }

        guard let app = CodexAppLocator.locate() else {
            codexApp = nil
            message = "已阻止启动：没有找到 Codex。"
            activity = .idle
            return
        }
        codexApp = app

        do {
            if launcher.isRunning {
                activity = .stoppingCodex
                message = "正在正常退出 Codex…"
                try await launcher.terminateRunningApplications()
            }

            activity = .launching
            message = "正在通过 \(proxy.displayAddress) 启动 Codex…"
            try await launcher.launch(app: app, proxy: proxy)
            lastLaunchUsedProxy = true
            codexRunning = true
            resetTrafficSession()
            message = "Codex 已启动，正在监测其进程树与代理连接。"
            await refreshProxyIPInfo()
        } catch {
            lastLaunchUsedProxy = false
            message = error.localizedDescription
        }
        activity = .idle
    }

    private func sampleTraffic() async {
        nativeProxyActive = nativeProxy.session?.isLive == true
        let roots = Set(launcher.runningApplications().map(\.processIdentifier))
        codexRunning = !roots.isEmpty

        if roots != monitoredRoots {
            monitoredRoots = roots
            resetTrafficSession(keepRoots: true)
        }

        guard !roots.isEmpty else {
            trafficMetrics = .zero
            trafficUpdatedAt = Date()
            return
        }

        let snapshot = await TrafficSampler.sample(
            rootPIDs: Array(roots),
            proxy: proxy
        )
        trafficMetrics = trafficAccumulator.ingest(snapshot)
        trafficUpdatedAt = snapshot.timestamp
        trafficHistory.append(TrafficPoint(
            timestamp: snapshot.timestamp,
            downloadBytesPerSecond: trafficMetrics.downloadBytesPerSecond,
            uploadBytesPerSecond: trafficMetrics.uploadBytesPerSecond
        ))
        if trafficHistory.count > 90 {
            trafficHistory.removeFirst(trafficHistory.count - 90)
        }
    }

    private func resetTrafficSession(keepRoots: Bool = false) {
        trafficAccumulator.reset()
        trafficMetrics = .zero
        trafficHistory.removeAll(keepingCapacity: true)
        trafficUpdatedAt = nil
        if !keepRoots {
            monitoredRoots = []
        }
    }
}
