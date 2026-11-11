import AppKit
import CodexProxyLauncherCore
import SwiftUI

@main
struct CodexProxyLauncherApp: App {
    @NSApplicationDelegateAdaptor(LauncherAppDelegate.self) private var delegate
    @StateObject private var viewModel = LauncherViewModel()

    var body: some Scene {
        WindowGroup("Codex 代理启动器", id: "main") {
            DashboardView(viewModel: viewModel)
        }
        .defaultSize(width: 760, height: 760)

        MenuBarExtra {
            CompactMenuView(viewModel: viewModel)
        } label: {
            Image(systemName: viewModel.menuBarSymbol)
                .accessibilityLabel("Codex 代理启动器")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            do {
                try await NativeProxyClient.shared.stop()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                let alert = NSAlert()
                alert.messageText = "原系统代理尚未恢复"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "保留启动器")
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
