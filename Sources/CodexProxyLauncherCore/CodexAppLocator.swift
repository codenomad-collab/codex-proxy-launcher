import AppKit
import Foundation

public struct LocatedCodexApp: Equatable, Sendable {
    public let url: URL
    public let bundleIdentifier: String
    public let displayName: String
    public let version: String?

    public init(
        url: URL,
        bundleIdentifier: String,
        displayName: String,
        version: String?
    ) {
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.version = version
    }
}

public enum CodexAppLocator {
    public static let bundleIdentifier = "com.openai.codex"

    public static func locate() -> LocatedCodexApp? {
        var candidates: [URL] = []

        if let registeredURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) {
            candidates.append(registeredURL)
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
        ])

        var seenPaths = Set<String>()
        for candidate in candidates where seenPaths.insert(candidate.path).inserted {
            if let app = inspect(candidate) {
                return app
            }
        }
        return nil
    }

    public static func inspect(_ appURL: URL) -> LocatedCodexApp? {
        guard FileManager.default.fileExists(atPath: appURL.path),
              let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == bundleIdentifier else {
            return nil
        }

        let info = bundle.infoDictionary ?? [:]
        let displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let version = info["CFBundleShortVersionString"] as? String

        return LocatedCodexApp(
            url: appURL,
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            version: version
        )
    }
}
