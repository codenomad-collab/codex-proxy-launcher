import SwiftUI

@main
struct CodexProxyLauncherApp: App {
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
