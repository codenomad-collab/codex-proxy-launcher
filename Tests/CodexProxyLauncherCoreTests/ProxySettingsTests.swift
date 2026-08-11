import XCTest
@testable import CodexProxyLauncherCore

final class ProxySettingsTests: XCTestCase {
    func testDefaultEnvironmentUsesLocalClashMixedPort() {
        let settings = ProxySettings()

        XCTAssertEqual(settings.httpURL, "http://127.0.0.1:7890")
        XCTAssertEqual(settings.socksURL, "socks5://127.0.0.1:7890")
        XCTAssertEqual(settings.environment["HTTP_PROXY"], settings.httpURL)
        XCTAssertEqual(settings.environment["HTTPS_PROXY"], settings.httpURL)
        XCTAssertEqual(settings.environment["ALL_PROXY"], settings.socksURL)
        XCTAssertEqual(settings.environment["NODE_USE_ENV_PROXY"], "1")
        XCTAssertEqual(settings.environment["ELECTRON_GET_USE_PROXY"], "1")
    }

    func testElectronArgumentsOverrideSystemProxyAndBypassLoopback() {
        let arguments = ProxySettings().electronArguments

        XCTAssertEqual(arguments.first, "--proxy-server=http://127.0.0.1:7890")
        XCTAssertTrue(arguments.contains(where: { $0.contains("localhost") }))
        XCTAssertTrue(arguments.contains(where: { $0.contains("127.0.0.1") }))
        XCTAssertTrue(arguments.contains(where: { $0.contains("[::1]") }))
    }

    func testIPv6HostIsBracketedInURLs() {
        let settings = ProxySettings(host: "::1", port: 7890)

        XCTAssertEqual(settings.httpURL, "http://[::1]:7890")
        XCTAssertEqual(settings.socksURL, "socks5://[::1]:7890")
    }
}
