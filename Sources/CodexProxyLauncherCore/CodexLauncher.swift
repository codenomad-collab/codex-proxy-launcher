import AppKit
import Foundation

public enum CodexLaunchError: LocalizedError {
    case terminationRejected
    case terminationTimedOut
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .terminationRejected:
            return "Codex 拒绝退出。请先保存正在进行的工作并手动退出 Codex。"
        case .terminationTimedOut:
            return "等待 Codex 退出超时。请手动退出后重试。"
        case .launchFailed(let message):
            return "启动 Codex 失败：\(message)"
        }
    }
}

@MainActor
public final class CodexLauncher {
    public init() {}

    public func runningApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexAppLocator.bundleIdentifier
        )
    }

    public var isRunning: Bool {
        !runningApplications().isEmpty
    }

    public func terminateRunningApplications(timeout: TimeInterval = 8) async throws {
        let running = runningApplications()
        guard !running.isEmpty else { return }

        guard running.allSatisfy({ $0.terminate() }) else {
            throw CodexLaunchError.terminationRejected
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if running.allSatisfy(\.isTerminated) {
                return
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw CodexLaunchError.terminationTimedOut
    }

    @discardableResult
    public func launch(
        app: LocatedCodexApp,
        proxy: ProxySettings
    ) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = true
        configuration.arguments = proxy.electronArguments
        configuration.environment = proxy.environment

        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: app.url,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(
                        throwing: CodexLaunchError.launchFailed(error.localizedDescription)
                    )
                } else if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(
                        throwing: CodexLaunchError.launchFailed("系统没有返回应用实例")
                    )
                }
            }
        }
    }
}
