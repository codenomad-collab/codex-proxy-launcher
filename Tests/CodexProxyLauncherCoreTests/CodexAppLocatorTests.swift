import Foundation
import XCTest
@testable import CodexProxyLauncherCore

final class CodexAppLocatorTests: XCTestCase {
    func testRejectsNonCodexBundleIdentifier() throws {
        let appURL = try makeFakeApp(bundleIdentifier: "example.not-codex")
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }

        XCTAssertNil(CodexAppLocator.inspect(appURL))
    }

    func testReadsCodexBundleMetadata() throws {
        let appURL = try makeFakeApp(bundleIdentifier: CodexAppLocator.bundleIdentifier)
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }

        let result = try XCTUnwrap(CodexAppLocator.inspect(appURL))
        XCTAssertEqual(result.bundleIdentifier, "com.openai.codex")
        XCTAssertEqual(result.displayName, "Test Codex")
        XCTAssertEqual(result.version, "1.2.3")
    }

    private func makeFakeApp(bundleIdentifier: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = root.appendingPathComponent("Test Codex.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )

        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "Test Codex",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundlePackageType": "APPL"
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return appURL
    }
}
