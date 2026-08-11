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

    let proxy = ProxySettings()
    private let launcher = CodexLauncher()
    private var trafficAccumulator = TrafficAccumulator()
    private var monitoredRoots: Set<Int32> = []
    private var monitoringTask: Task<Void, Never>?

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
        await sampleTraffic()
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
