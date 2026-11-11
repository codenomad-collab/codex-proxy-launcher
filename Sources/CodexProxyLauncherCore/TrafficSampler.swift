import Foundation

public struct ProcessTrafficCounter: Equatable, Sendable {
    public let pid: Int32
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(pid: Int32, bytesIn: UInt64, bytesOut: UInt64) {
        self.pid = pid
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public struct RawTrafficSnapshot: Equatable, Sendable {
    public let timestamp: Date
    public let counters: [Int32: ProcessTrafficCounter]
    public let activeProxyConnections: Int
    public let directExternalTCPConnections: Int
    public let samplingError: String?

    public init(
        timestamp: Date = Date(),
        counters: [Int32: ProcessTrafficCounter],
        activeProxyConnections: Int,
        directExternalTCPConnections: Int,
        samplingError: String? = nil
    ) {
        self.timestamp = timestamp
        self.counters = counters
        self.activeProxyConnections = activeProxyConnections
        self.directExternalTCPConnections = directExternalTCPConnections
        self.samplingError = samplingError
    }
}

public struct TrafficMetrics: Equatable, Sendable {
    public let downloadBytesPerSecond: Double
    public let uploadBytesPerSecond: Double
    public let sessionDownloadedBytes: UInt64
    public let sessionUploadedBytes: UInt64
    public let activeProxyConnections: Int
    public let directExternalTCPConnections: Int
    public let observedProcessCount: Int
    public let samplingError: String?

    public static let zero = TrafficMetrics(
        downloadBytesPerSecond: 0,
        uploadBytesPerSecond: 0,
        sessionDownloadedBytes: 0,
        sessionUploadedBytes: 0,
        activeProxyConnections: 0,
        directExternalTCPConnections: 0,
        observedProcessCount: 0,
        samplingError: nil
    )
}

public struct TrafficAccumulator: Sendable {
    private var previousCounters: [Int32: ProcessTrafficCounter] = [:]
    private var previousTimestamp: Date?
    private var downloadedBytes: UInt64 = 0
    private var uploadedBytes: UInt64 = 0

    public init() {}

    public mutating func reset() {
        previousCounters = [:]
        previousTimestamp = nil
        downloadedBytes = 0
        uploadedBytes = 0
    }

    public mutating func ingest(_ snapshot: RawTrafficSnapshot) -> TrafficMetrics {
        let interval = max(
            snapshot.timestamp.timeIntervalSince(previousTimestamp ?? snapshot.timestamp),
            0.001
        )
        var incomingDelta: UInt64 = 0
        var outgoingDelta: UInt64 = 0

        if snapshot.samplingError == nil, previousTimestamp != nil {
            for (pid, current) in snapshot.counters {
                guard let previous = previousCounters[pid] else { continue }
                if current.bytesIn >= previous.bytesIn {
                    incomingDelta += current.bytesIn - previous.bytesIn
                }
                if current.bytesOut >= previous.bytesOut {
                    outgoingDelta += current.bytesOut - previous.bytesOut
                }
            }
        }

        downloadedBytes += incomingDelta
        uploadedBytes += outgoingDelta
        // A failed sample must not replace the last good baseline. Recovery
        // includes traffic across the gap and uses the full elapsed interval.
        if snapshot.samplingError == nil {
            previousCounters = snapshot.counters
            previousTimestamp = snapshot.timestamp
        }

        return TrafficMetrics(
            downloadBytesPerSecond: Double(incomingDelta) / interval,
            uploadBytesPerSecond: Double(outgoingDelta) / interval,
            sessionDownloadedBytes: downloadedBytes,
            sessionUploadedBytes: uploadedBytes,
            activeProxyConnections: snapshot.activeProxyConnections,
            directExternalTCPConnections: snapshot.directExternalTCPConnections,
            observedProcessCount: snapshot.samplingError == nil ? snapshot.counters.count : 0,
            samplingError: snapshot.samplingError
        )
    }
}

public enum TrafficSampler {
    struct CommandResult {
        let output: String
        let exitStatus: Int32?

        var succeeded: Bool { exitStatus == 0 }
        var failureDescription: String {
            exitStatus.map { "退出码 \($0)" } ?? "无法执行"
        }
    }

    public static func sample(
        rootPIDs: [Int32],
        proxy: ProxySettings
    ) async -> RawTrafficSnapshot {
        await Task.detached(priority: .utility) {
            Self.collect(rootPIDs: rootPIDs, proxy: proxy, run: Self.runCommand)
        }.value
    }

    /// The command seam exercises the production orchestration, including
    /// nettop's system limit and command failures, without invoking live apps.
    static func collect(
        rootPIDs: [Int32],
        proxy: ProxySettings,
        run: (String, [String]) -> CommandResult
    ) -> RawTrafficSnapshot {
        guard !rootPIDs.isEmpty else {
            return RawTrafficSnapshot(
                counters: [:],
                activeProxyConnections: 0,
                directExternalTCPConnections: 0
            )
        }

        let processTableOutput = run("/bin/ps", ["-axo", "pid=,ppid="])
        guard processTableOutput.succeeded else {
            return RawTrafficSnapshot(
                counters: [:], activeProxyConnections: 0, directExternalTCPConnections: 0,
                samplingError: "无法读取进程列表（ps：\(processTableOutput.failureDescription)）"
            )
        }
        let pids = Self.descendantPIDs(
            processTable: processTableOutput.output,
            roots: Set(rootPIDs)
        )
        guard !pids.isEmpty else {
            return RawTrafficSnapshot(
                counters: [:],
                activeProxyConnections: 0,
                directExternalTCPConnections: 0
            )
        }

        var counters: [Int32: ProcessTrafficCounter] = [:]
        var samplingError: String?
        let sortedPIDs = pids.sorted()
        // macOS nettop exits with status 64 if more than 20 PIDs are
        // selected. Every batch must succeed; partial totals are invalid.
        for start in stride(from: 0, to: sortedPIDs.count, by: 20) {
            let batch = sortedPIDs[start..<min(start + 20, sortedPIDs.count)]
            var arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
            for pid in batch { arguments.append(contentsOf: ["-p", String(pid)]) }
            let result = run("/usr/bin/nettop", arguments)
            guard result.succeeded else {
                samplingError = "流量采集失败（nettop：\(result.failureDescription)）"
                break
            }
            guard result.output.split(whereSeparator: \.isNewline).contains(where: {
                $0.hasPrefix(",bytes_in,bytes_out")
            }) else {
                samplingError = "流量采集失败：无法识别 nettop 输出"
                break
            }
            for (pid, counter) in Self.parseNettopCSV(result.output) where batch.contains(pid) {
                counters[pid] = counter
            }
        }
        if samplingError != nil { counters.removeAll() }

        let lsofOutput = run("/usr/sbin/lsof", [
            "-nP",
            "-a",
            "-p", sortedPIDs.map { String($0) }.joined(separator: ","),
            "-iTCP",
            "-sTCP:ESTABLISHED"
        ])
        let connectionCounts = Self.parseConnectionCounts(
            lsofOutput.output,
            proxy: proxy
        )

        return RawTrafficSnapshot(
            counters: counters,
            activeProxyConnections: connectionCounts.proxy,
            directExternalTCPConnections: connectionCounts.directExternal,
            samplingError: samplingError
        )
    }

    static func descendantPIDs(
        processTable: String,
        roots: Set<Int32>
    ) -> Set<Int32> {
        var parentByPID: [Int32: Int32] = [:]
        for line in processTable.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2,
                  let pid = Int32(fields[0]),
                  let parentPID = Int32(fields[1]) else {
                continue
            }
            parentByPID[pid] = parentPID
        }

        var result = roots
        var changed = true
        while changed {
            changed = false
            for (pid, parentPID) in parentByPID where result.contains(parentPID) {
                if result.insert(pid).inserted {
                    changed = true
                }
            }
        }
        return result
    }

    static func parseNettopCSV(_ output: String) -> [Int32: ProcessTrafficCounter] {
        var counters: [Int32: ProcessTrafficCounter] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let label = String(fields[0])
            guard !label.isEmpty,
                  let separator = label.lastIndex(of: "."),
                  let pid = Int32(label[label.index(after: separator)...]),
                  let bytesIn = UInt64(fields[1]),
                  let bytesOut = UInt64(fields[2]) else {
                continue
            }
            counters[pid] = ProcessTrafficCounter(
                pid: pid,
                bytesIn: bytesIn,
                bytesOut: bytesOut
            )
        }
        return counters
    }

    static func parseConnectionCounts(
        _ output: String,
        proxy: ProxySettings
    ) -> (proxy: Int, directExternal: Int) {
        var proxyCount = 0
        var directExternalCount = 0
        let proxySuffixes = [
            "\(proxy.host):\(proxy.port)",
            "[\(proxy.host)]:\(proxy.port)"
        ]

        for line in output.split(whereSeparator: \.isNewline).dropFirst() {
            let text = String(line)
            guard let arrow = text.range(of: "->") else { continue }
            let remoteWithState = text[arrow.upperBound...]
            let remote = remoteWithState
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? ""

            if proxySuffixes.contains(where: { remote.hasSuffix($0) }) {
                proxyCount += 1
            } else if !isLocalEndpoint(remote) {
                directExternalCount += 1
            }
        }
        return (proxyCount, directExternalCount)
    }

    private static func isLocalEndpoint(_ endpoint: String) -> Bool {
        let lowercased = endpoint.lowercased()
        if lowercased.hasPrefix("127.")
            || lowercased.hasPrefix("[::1]")
            || lowercased.hasPrefix("localhost:")
            || lowercased.contains(".local:")
            || lowercased.hasPrefix("10.")
            || lowercased.hasPrefix("192.168.")
            || lowercased.hasPrefix("169.254.") {
            return true
        }

        if lowercased.hasPrefix("172."),
           let secondOctet = lowercased
            .split(separator: ".")
            .dropFirst()
            .first
            .flatMap({ Int($0) }),
           (16...31).contains(secondOctet) {
            return true
        }
        return false
    }

    private static func runCommand(
        executable: String,
        arguments: [String]
    ) -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return CommandResult(output: "", exitStatus: nil)
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            output: String(data: data, encoding: .utf8) ?? "",
            exitStatus: process.terminationStatus
        )
    }
}
