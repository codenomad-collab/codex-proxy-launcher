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

    public init(
        timestamp: Date = Date(),
        counters: [Int32: ProcessTrafficCounter],
        activeProxyConnections: Int,
        directExternalTCPConnections: Int
    ) {
        self.timestamp = timestamp
        self.counters = counters
        self.activeProxyConnections = activeProxyConnections
        self.directExternalTCPConnections = directExternalTCPConnections
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

    public static let zero = TrafficMetrics(
        downloadBytesPerSecond: 0,
        uploadBytesPerSecond: 0,
        sessionDownloadedBytes: 0,
        sessionUploadedBytes: 0,
        activeProxyConnections: 0,
        directExternalTCPConnections: 0,
        observedProcessCount: 0
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

        if previousTimestamp != nil {
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
        previousCounters = snapshot.counters
        previousTimestamp = snapshot.timestamp

        return TrafficMetrics(
            downloadBytesPerSecond: Double(incomingDelta) / interval,
            uploadBytesPerSecond: Double(outgoingDelta) / interval,
            sessionDownloadedBytes: downloadedBytes,
            sessionUploadedBytes: uploadedBytes,
            activeProxyConnections: snapshot.activeProxyConnections,
            directExternalTCPConnections: snapshot.directExternalTCPConnections,
            observedProcessCount: snapshot.counters.count
        )
    }
}

public enum TrafficSampler {
    public static func sample(
        rootPIDs: [Int32],
        proxy: ProxySettings
    ) async -> RawTrafficSnapshot {
        guard !rootPIDs.isEmpty else {
            return RawTrafficSnapshot(
                counters: [:],
                activeProxyConnections: 0,
                directExternalTCPConnections: 0
            )
        }

        return await Task.detached(priority: .utility) {
            let processTableOutput = Self.runCommand(
                executable: "/bin/ps",
                arguments: ["-axo", "pid=,ppid="]
            )
            let pids = Self.descendantPIDs(
                processTable: processTableOutput,
                roots: Set(rootPIDs)
            )
            guard !pids.isEmpty else {
                return RawTrafficSnapshot(
                    counters: [:],
                    activeProxyConnections: 0,
                    directExternalTCPConnections: 0
                )
            }

            var nettopArguments = [
                "-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"
            ]
            for pid in pids.sorted() {
                nettopArguments.append(contentsOf: ["-p", String(pid)])
            }
            let nettopOutput = Self.runCommand(
                executable: "/usr/bin/nettop",
                arguments: nettopArguments
            )
            let counters = Self.parseNettopCSV(nettopOutput)

            let lsofOutput = Self.runCommand(
                executable: "/usr/sbin/lsof",
                arguments: [
                    "-nP",
                    "-a",
                    "-p", pids.sorted().map { String($0) }.joined(separator: ","),
                    "-iTCP",
                    "-sTCP:ESTABLISHED"
                ]
            )
            let connectionCounts = Self.parseConnectionCounts(
                lsofOutput,
                proxy: proxy
            )

            return RawTrafficSnapshot(
                counters: counters,
                activeProxyConnections: connectionCounts.proxy,
                directExternalTCPConnections: connectionCounts.directExternal
            )
        }.value
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
    ) -> String {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ""
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
