import AppKit
import Charts
import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: LauncherViewModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.035, green: 0.055, blue: 0.12),
                    Color(red: 0.075, green: 0.06, blue: 0.18),
                    Color(red: 0.025, green: 0.11, blue: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statusStrip
                    actionBar
                    metrics
                    trafficChart
                    proxyIPCard
                    footer
                }
                .padding(24)
                .padding(.top, 28)
            }
        }
        .frame(minWidth: 680, minHeight: 680)
        .preferredColorScheme(.dark)
        .onAppear { viewModel.startMonitoring() }
    }

    private var header: some View {
        HStack(spacing: 15) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 62, height: 62)
                .shadow(color: .cyan.opacity(0.24), radius: 16, y: 5)

            VStack(alignment: .leading, spacing: 4) {
                Text("Codex 代理启动器")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("专属代理 · 流量监控 · 出口网络诊断")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.64))
            }

            Spacer()

            Button {
                Task { await viewModel.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.09), in: Circle())
            .disabled(viewModel.isBusy || viewModel.ipInfoLoading)
            .help("刷新全部状态")
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 10) {
            StatusPill(
                icon: "point.3.connected.trianglepath.dotted",
                title: "Clash \(viewModel.proxy.displayAddress)",
                state: proxyStatus
            )
            StatusPill(
                icon: "terminal",
                title: viewModel.codexRunning ? "Codex 运行中" : "Codex 未运行",
                state: viewModel.codexRunning ? .good : .neutral
            )
            StatusPill(
                icon: viewModel.trafficMetrics.directExternalTCPConnections > 0
                    ? "exclamationmark.shield.fill"
                    : "checkmark.shield.fill",
                title: viewModel.connectionAuditText,
                state: viewModel.trafficMetrics.directExternalTCPConnections > 0
                    ? .bad
                    : (viewModel.trafficMetrics.activeProxyConnections > 0 ? .good : .neutral)
            )
            Spacer(minLength: 0)
        }
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            MetricCard(
                title: "实时下载",
                value: TrafficFormat.rate(viewModel.trafficMetrics.downloadBytesPerSecond),
                icon: "arrow.down",
                color: .cyan
            )
            MetricCard(
                title: "实时上传",
                value: TrafficFormat.rate(viewModel.trafficMetrics.uploadBytesPerSecond),
                icon: "arrow.up",
                color: .green
            )
            MetricCard(
                title: "本次会话",
                value: TrafficFormat.total(
                    downloaded: viewModel.trafficMetrics.sessionDownloadedBytes,
                    uploaded: viewModel.trafficMetrics.sessionUploadedBytes
                ),
                icon: "waveform.path.ecg",
                color: .purple
            )
            MetricCard(
                title: "代理连接",
                value: "\(viewModel.trafficMetrics.activeProxyConnections) 条",
                icon: "link",
                color: .orange
            )
        }
    }

    private var actionBar: some View {
        HStack {
            Text(viewModel.message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(2)
            Spacer(minLength: 16)
            Button {
                Task { await viewModel.launchCodex() }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(viewModel.primaryButtonTitle)
                }
                .frame(minWidth: 190)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .disabled(
                viewModel.isBusy
                    || viewModel.codexApp == nil
                    || viewModel.proxyReachable == false
            )
        }
    }

    private var trafficChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实时网络流量")
                        .font(.headline)
                    Text("Codex 主进程及其全部子进程 · 最近 3 分钟")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                ChartLegend(color: .cyan, title: "下载")
                ChartLegend(color: .green, title: "上传")
            }

            Chart {
                ForEach(viewModel.trafficHistory) { point in
                    AreaMark(
                        x: .value("时间", point.timestamp),
                        y: .value("下载", point.downloadBytesPerSecond)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan.opacity(0.25), .cyan.opacity(0.015)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("下载", point.downloadBytesPerSecond),
                        series: .value("方向", "下载")
                    )
                    .foregroundStyle(.cyan)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("上传", point.uploadBytesPerSecond),
                        series: .value("方向", "上传")
                    )
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: 0...viewModel.chartMaximum)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) {
                            Text(TrafficFormat.rate(bytes))
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
            .frame(height: 158)
        }
        .panelStyle()
    }

    private var proxyIPCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("代理出口 IP", systemImage: "globe.asia.australia.fill")
                    .font(.headline)
                Spacer()
                if viewModel.ipInfoLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("重新查询") {
                        Task { await viewModel.refreshProxyIPInfo() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.cyan)
                }
            }

            if let info = viewModel.proxyIPInfo {
                HStack(alignment: .top, spacing: 16) {
                    Text(info.countryFlag.isEmpty ? "🌐" : info.countryFlag)
                        .font(.system(size: 36))
                        .frame(width: 52, height: 52)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(info.ip)
                            .font(.system(.title2, design: .monospaced, weight: .semibold))
                            .textSelection(.enabled)
                        Text(info.locationSummary.isEmpty ? "位置未知" : info.locationSummary)
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 5) {
                        Text(info.networkSummary.isEmpty ? "网络信息未知" : info.networkSummary)
                            .lineLimit(1)
                        if !info.timezone.isEmpty {
                            Text("\(info.timezone) \(info.timezoneAbbreviation)")
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .font(.caption)
                }

                HStack {
                    Text("经 Clash \(viewModel.proxy.displayAddress) 查询")
                    Spacer()
                    if let date = viewModel.ipInfoUpdatedAt {
                        Text("更新于 \(date.formatted(date: .omitted, time: .standard))")
                    }
                    Text("· IP 位置为数据库估算")
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
            } else if let error = viewModel.ipInfoError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Text("正在通过 Clash 查询代理出口信息…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .panelStyle()
    }

    private var footer: some View {
        HStack {
            Text("流量来自 macOS 进程统计；连接审计覆盖已建立的 TCP 连接。")
            Spacer()
            Text("IP 数据：ipwho.is")
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.32))
    }

    private var proxyStatus: StatusPill.State {
        switch viewModel.proxyReachable {
        case true: return .good
        case false: return .bad
        case nil: return .neutral
        }
    }
}

struct CompactMenuView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Codex 代理启动器").font(.headline)
                    Text(viewModel.connectionAuditText)
                        .font(.caption)
                        .foregroundStyle(connectionColor)
                }
            }

            Divider()

            HStack {
                CompactMetric(
                    title: "下载",
                    value: TrafficFormat.rate(viewModel.trafficMetrics.downloadBytesPerSecond),
                    color: .cyan
                )
                Spacer()
                CompactMetric(
                    title: "上传",
                    value: TrafficFormat.rate(viewModel.trafficMetrics.uploadBytesPerSecond),
                    color: .green
                )
                Spacer()
                CompactMetric(
                    title: "代理连接",
                    value: "\(viewModel.trafficMetrics.activeProxyConnections)",
                    color: .orange
                )
            }

            if let info = viewModel.proxyIPInfo {
                HStack {
                    Text(info.countryFlag.isEmpty ? "🌐" : info.countryFlag)
                    Text(info.ip).font(.system(.callout, design: .monospaced))
                    Spacer()
                    Text(info.city.isEmpty ? info.country : info.city)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(viewModel.primaryButtonTitle) {
                Task { await viewModel.launchCodex() }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(
                viewModel.isBusy
                    || viewModel.codexApp == nil
                    || viewModel.proxyReachable == false
            )

            HStack {
                Button("打开仪表盘") {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 330)
        .onAppear { viewModel.startMonitoring() }
    }

    private var connectionColor: Color {
        if viewModel.trafficMetrics.directExternalTCPConnections > 0 { return .red }
        if viewModel.trafficMetrics.activeProxyConnections > 0 { return .green }
        return .secondary
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct CompactMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}

private struct StatusPill: View {
    enum State {
        case good
        case bad
        case neutral

        var color: Color {
            switch self {
            case .good: return .green
            case .bad: return .red
            case .neutral: return .white.opacity(0.45)
            }
        }
    }

    let icon: String
    let title: String
    let state: State

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(state.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(state.color.opacity(0.1), in: Capsule())
            .overlay { Capsule().stroke(state.color.opacity(0.15), lineWidth: 1) }
    }
}

private struct ChartLegend: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(title).font(.caption2).foregroundStyle(.white.opacity(0.5))
        }
    }
}

private enum TrafficFormat {
    static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(clamping: value))
    }

    static func rate(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0 KB/s" }
        let bounded = min(value, Double(Int64.max))
        return "\(bytes(UInt64(bounded)))/s"
    }

    static func total(downloaded: UInt64, uploaded: UInt64) -> String {
        "↓ \(bytes(downloaded))  ↑ \(bytes(uploaded))"
    }
}

private extension View {
    func panelStyle() -> some View {
        padding(17)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }
    }
}
