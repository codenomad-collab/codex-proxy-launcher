@testable import CodexProxyLauncherCore
import XCTest

final class TrafficSamplerTests: XCTestCase {
    private func processTable(count: Int) -> String {
        (100..<(100 + count)).map { "\($0) \($0 == 100 ? 1 : 100)" }.joined(separator: "\n")
    }

    private func selectedPIDs(_ arguments: [String]) -> [Int32] {
        arguments.indices.filter { arguments[$0] == "-p" }.compactMap { Int32(arguments[$0 + 1]) }
    }

    private func csv(_ pids: [Int32]) -> String {
        ",bytes_in,bytes_out,\n" + pids.map { "Worker.\($0),1000,2000," }.joined(separator: "\n")
    }

    func testLargeProcessTreesAreFullySampledWithinSystemPIDLimit() {
        for count in [20, 21, 41] {
            var batches: [[Int32]] = []
            let snapshot = TrafficSampler.collect(rootPIDs: [100], proxy: ProxySettings()) { executable, arguments in
                switch executable {
                case "/bin/ps":
                    return .init(output: self.processTable(count: count), exitStatus: 0)
                case "/usr/bin/nettop":
                    let pids = self.selectedPIDs(arguments)
                    batches.append(pids)
                    // Match the real system's failure, rather than accepting
                    // an arbitrarily long fixture invocation.
                    if pids.count > 20 { return .init(output: "PID limit is 20", exitStatus: 64) }
                    return .init(output: self.csv(pids), exitStatus: 0)
                case "/usr/sbin/lsof": return .init(output: "", exitStatus: 1)
                default: XCTFail("Unexpected command: \(executable)"); return .init(output: "", exitStatus: nil)
                }
            }
            XCTAssertNil(snapshot.samplingError)
            XCTAssertEqual(snapshot.counters.count, count)
            XCTAssertEqual(Set(batches.flatMap { $0 }), Set((100..<(100 + count)).map(Int32.init)))
            XCTAssertEqual(batches.flatMap { $0 }.count, count, "No duplicated or omitted PID")
            XCTAssertTrue(batches.allSatisfy { !$0.isEmpty && $0.count <= 20 })
        }
    }

    func testFailedBatchRejectsPartialCountersButKeepsConnectionAudit() {
        var calls = 0
        let snapshot = TrafficSampler.collect(rootPIDs: [100], proxy: ProxySettings()) { executable, arguments in
            if executable == "/bin/ps" { return .init(output: self.processTable(count: 21), exitStatus: 0) }
            if executable == "/usr/bin/nettop" {
                calls += 1
                return calls == 1
                    ? .init(output: self.csv(self.selectedPIDs(arguments)), exitStatus: 0)
                    : .init(output: "PID limit exceeded", exitStatus: 64)
            }
            return .init(output: "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nCodex 100 me 1u IPv4 x 0t0 TCP 127.0.0.1:5000->127.0.0.1:7890 (ESTABLISHED)", exitStatus: 0)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(snapshot.counters.isEmpty)
        XCTAssertTrue(snapshot.samplingError?.contains("64") == true)
        XCTAssertEqual(snapshot.activeProxyConnections, 1)
    }

    func testFailedProcessDiscoveryDoesNotPretendToBeAnIdleSample() {
        var commands: [String] = []
        let snapshot = TrafficSampler.collect(rootPIDs: [100], proxy: ProxySettings()) { executable, _ in
            commands.append(executable)
            return .init(output: "permission denied", exitStatus: 1)
        }
        XCTAssertEqual(commands, ["/bin/ps"])
        XCTAssertNotNil(snapshot.samplingError)
    }

    func testUnrecognizedSuccessfulOutputIsReportedAsFailure() {
        let snapshot = TrafficSampler.collect(rootPIDs: [100], proxy: ProxySettings()) { executable, _ in
            if executable == "/bin/ps" { return .init(output: self.processTable(count: 1), exitStatus: 0) }
            return .init(output: "unexpected output", exitStatus: 0)
        }
        XCTAssertNotNil(snapshot.samplingError)
        XCTAssertTrue(snapshot.counters.isEmpty)
    }

    func testHeaderOnlyIsAValidIdleSample() {
        let snapshot = TrafficSampler.collect(rootPIDs: [100], proxy: ProxySettings()) { executable, _ in
            if executable == "/bin/ps" { return .init(output: self.processTable(count: 1), exitStatus: 0) }
            return .init(output: ",bytes_in,bytes_out,\n", exitStatus: 0)
        }
        XCTAssertNil(snapshot.samplingError)
        XCTAssertTrue(snapshot.counters.isEmpty)
    }

    func testNettopRowsOutsideSelectedProcessTreeAreNotCounted() {
        let snapshot = TrafficSampler.collect(rootPIDs: [100], proxy: ProxySettings()) { executable, _ in
            if executable == "/bin/ps" { return .init(output: self.processTable(count: 1), exitStatus: 0) }
            return .init(output: self.csv([100, 999]), exitStatus: 0)
        }
        XCTAssertEqual(Set(snapshot.counters.keys), [100])
    }

    func testFailedSamplePreservesTotalsAndLastGoodBaselineUntilRecovery() {
        var accumulator = TrafficAccumulator()
        let start = Date(timeIntervalSince1970: 1000)
        func sample(_ offset: Double, bytes: UInt64, error: String? = nil) -> RawTrafficSnapshot {
            RawTrafficSnapshot(timestamp: start.addingTimeInterval(offset),
                               counters: [7: .init(pid: 7, bytesIn: bytes, bytesOut: bytes)],
                               activeProxyConnections: 2, directExternalTCPConnections: 0, samplingError: error)
        }
        _ = accumulator.ingest(sample(0, bytes: 100))
        _ = accumulator.ingest(sample(1, bytes: 200))
        let failed = accumulator.ingest(sample(2, bytes: 9999, error: "nettop failed"))
        XCTAssertEqual(failed.sessionDownloadedBytes, 100)
        XCTAssertEqual(failed.samplingError, "nettop failed")
        let recovered = accumulator.ingest(sample(6, bytes: 1200))
        XCTAssertNil(recovered.samplingError)
        XCTAssertEqual(recovered.sessionDownloadedBytes, 1100)
        XCTAssertEqual(recovered.downloadBytesPerSecond, 200, accuracy: 0.001)
        XCTAssertEqual(recovered.uploadBytesPerSecond, 200, accuracy: 0.001)
    }

    func testDescendantPIDsIncludesWholeProcessTree() {
        let table = """
          10     1
          11    10
          12    11
          20     1
          21    20
        """

        XCTAssertEqual(
            TrafficSampler.descendantPIDs(processTable: table, roots: [10]),
            Set([10, 11, 12])
        )
    }

    func testParsesNettopCSV() {
        let csv = """
        ,bytes_in,bytes_out,
        Codex (Service).73835,567171,266715,
        codex.73898,502500,3024999,
        """

        let counters = TrafficSampler.parseNettopCSV(csv)

        XCTAssertEqual(counters[73835], ProcessTrafficCounter(
            pid: 73835,
            bytesIn: 567_171,
            bytesOut: 266_715
        ))
        XCTAssertEqual(counters[73898]?.bytesOut, 3_024_999)
    }

    func testCountsProxyAndExternalTCPConnections() {
        let output = """
        COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        Codex 101 me 21u IPv4 0x0 0t0 TCP 127.0.0.1:50001->127.0.0.1:7890 (ESTABLISHED)
        Codex 101 me 22u IPv4 0x0 0t0 TCP 192.168.1.2:50002->192.168.1.10:8080 (ESTABLISHED)
        Codex 101 me 23u IPv4 0x0 0t0 TCP 192.168.1.2:50003->1.1.1.1:443 (ESTABLISHED)
        """

        let counts = TrafficSampler.parseConnectionCounts(
            output,
            proxy: ProxySettings(host: "127.0.0.1", port: 7890)
        )

        XCTAssertEqual(counts.proxy, 1)
        XCTAssertEqual(counts.directExternal, 1)
    }

    func testAccumulatorUsesDeltasAndSessionTotals() {
        var accumulator = TrafficAccumulator()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = accumulator.ingest(RawTrafficSnapshot(
            timestamp: start,
            counters: [7: ProcessTrafficCounter(pid: 7, bytesIn: 100, bytesOut: 200)],
            activeProxyConnections: 1,
            directExternalTCPConnections: 0
        ))

        let metrics = accumulator.ingest(RawTrafficSnapshot(
            timestamp: start.addingTimeInterval(2),
            counters: [7: ProcessTrafficCounter(pid: 7, bytesIn: 1_100, bytesOut: 600)],
            activeProxyConnections: 2,
            directExternalTCPConnections: 1
        ))

        XCTAssertEqual(metrics.downloadBytesPerSecond, 500)
        XCTAssertEqual(metrics.uploadBytesPerSecond, 200)
        XCTAssertEqual(metrics.sessionDownloadedBytes, 1_000)
        XCTAssertEqual(metrics.sessionUploadedBytes, 400)
        XCTAssertEqual(metrics.activeProxyConnections, 2)
        XCTAssertEqual(metrics.directExternalTCPConnections, 1)
        XCTAssertEqual(metrics.observedProcessCount, 1)
    }
}
