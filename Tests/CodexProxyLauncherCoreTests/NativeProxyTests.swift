import Foundation
import JavaScriptCore
import XCTest
@testable import CodexProxyLauncherCore

final class NativeProxyTests: XCTestCase {
    func testPACRoutesOnlyOpenAIDomainsAndNeverResolvesNamesLocally() throws {
        let script = try NativeProxyPolicy.javaScript(proxy: ProxySettings())
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("function dnsDomainIs(host, suffix) { return host.slice(-suffix.length) === suffix; }")
        context.evaluateScript(script)
        for host in ["chatgpt.com", "api.openai.com", "CHATGPT.COM.", "a.oaistatic.com"] {
            XCTAssertEqual(context.objectForKeyedSubscript("FindProxyForURL").call(withArguments: ["https://" + host, host]).toString(), "PROXY 127.0.0.1:7890")
        }
        for host in ["example.com", "chatgpt.com.evil.test", "notopenai.com", "192.168.1.1", "localhost"] {
            XCTAssertEqual(context.objectForKeyedSubscript("FindProxyForURL").call(withArguments: ["https://" + host, host]).toString(), "DIRECT")
        }
        XCTAssertFalse(script.contains("dnsResolve"))
        XCTAssertFalse(script.contains("PROXY 127.0.0.1:7890; DIRECT"))
    }

    func testRejectsRemoteProxyToPreventUnexpectedExposure() {
        XCTAssertThrowsError(try NativeProxyPolicy.javaScript(proxy: ProxySettings(host: "192.0.2.1", port: 7890)))
        XCTAssertThrowsError(try NativeProxyPolicy.javaScript(proxy: ProxySettings(port: 0)))
    }

    func testDoesNotOverrideExistingManualOrAutomaticProxy() {
        let url = URL(string: "http://127.0.0.1:1234/test.pac")!
        for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"] {
            XCTAssertThrowsError(try SystemProxyStore.installingPAC(url, into: [key: 1]))
        }
    }

    func testRestoresAbsentKeysAndKeepsUnrelatedChanges() throws {
        let url = URL(string: "http://127.0.0.1:1234/test.pac")!
        let original: [String: Any] = ["HTTPEnable": 0, "ExceptionsList": ["*.local"]]
        var current = try SystemProxyStore.installingPAC(url, into: original)
        current["SOCKSEnable"] = 1
        let restored = try SystemProxyStore.restoring(original, current: current, ownedURL: url)
        XCTAssertNil(restored["ProxyAutoConfigURLString"])
        XCTAssertNil(restored["ProxyAutoConfigEnable"])
        XCTAssertEqual(restored["SOCKSEnable"] as? Int, 1)
        XCTAssertEqual(restored["ExceptionsList"] as? [String], ["*.local"])
    }

    func testNeverRestoresOverAnotherProgramsPAC() {
        let owned = URL(string: "http://127.0.0.1:1234/ours.pac")!
        let current: [String: Any] = ["ProxyAutoConfigURLString": "https://example.com/admin.pac", "ProxyAutoConfigEnable": 1]
        XCTAssertThrowsError(try SystemProxyStore.restoring([:], current: current, ownedURL: owned))
    }

    func testRestoresDisabledButStoredPriorPACURL() throws {
        let owned = URL(string: "http://127.0.0.1:1234/ours.pac")!
        let original: [String: Any] = ["ProxyAutoConfigURLString": "https://example.com/old.pac", "ProxyAutoConfigEnable": 0]
        let installed = try SystemProxyStore.installingPAC(owned, into: original)
        let restored = try SystemProxyStore.restoring(original, current: installed, ownedURL: owned)
        XCTAssertEqual(restored["ProxyAutoConfigURLString"] as? String, "https://example.com/old.pac")
        XCTAssertEqual(restored["ProxyAutoConfigEnable"] as? Int, 0)
    }

    func testPACServerBindsLoopbackAndServesOnlyItsRandomPath() async throws {
        let server = try LoopbackPACServer(proxy: ProxySettings())
        let url = try await server.start()
        defer { server.stop() }
        XCTAssertEqual(url.host, "127.0.0.1")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("FindProxyForURL"))
        let (_, missing) = try await session.data(from: url.deletingLastPathComponent().appendingPathComponent("nope"))
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)
    }

    func testSnapshotRoundTripPreservesValues() throws {
        let snapshot = try NetworkProxySnapshot(serviceID: "test", serviceName: "Wi-Fi", dictionary: ["HTTPEnable": 0, "ExceptionsList": ["*.local"]])
        let decoded = try JSONDecoder().decode(NetworkProxySnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.dictionary["ExceptionsList"] as? [String], ["*.local"])
    }

    func testPACControlRequiresSeparateBearerAndDoesNotExposeItInScript() async throws {
        let server = try LoopbackPACServer(proxy: ProxySettings())
        server.controlHandler = { action, authorization in action == "stop" && authorization == "Bearer unit-test-only" }
        let url = try await server.start()
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: url)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("unit-test-only"))
        var request = URLRequest(url: URL(string: url.absoluteString + "/stop")!)
        request.httpMethod = "POST"
        let (_, denied) = try await session.data(for: request)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 403)
        request.setValue("Bearer unit-test-only", forHTTPHeaderField: "Authorization")
        let (_, accepted) = try await session.data(for: request)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 204)
    }

    func testAdminCommandQuotingKeepsMetacharactersLiteral() {
        XCTAssertEqual(NativeProxyClient.shellQuote("/tmp/a'b $HOME`id`"), "'/tmp/a'\\''b $HOME`id`'")
    }
}
