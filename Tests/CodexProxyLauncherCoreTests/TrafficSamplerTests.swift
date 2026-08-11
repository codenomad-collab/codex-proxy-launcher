@testable import CodexProxyLauncherCore
import XCTest

final class TrafficSamplerTests: XCTestCase {
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
