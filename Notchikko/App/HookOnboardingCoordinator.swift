import AppKit
import SwiftUI

/// 托管首次启动 / "关于"页手动触发的 CLI Hook 引导面板。
/// 自动/手动都经过 `present()`；NSPanel 里装一个 SwiftUI 视图。
@MainActor
final class HookOnboardingCoordinator {
    static let shared = HookOnboardingCoordinator()

    private let installer = HookInstaller()
    private var panel: NSPanel?

    private init() {}

    /// 首次启动调用：仅当之前未展示过 且 检测到未安装的 CLI 时弹面板。
    func promptIfNeeded() {
        guard !PreferencesStore.shared.preferences.hasShownHookPrompt else { return }
        let items = buildItems()
        let hasPending = items.contains(where: { $0.status == .notInstalled })
        guard hasPending else {
            PreferencesStore.shared.preferences.hasShownHookPrompt = true
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.present()
        }
    }

    /// 从"关于"页手动打开，忽略 `hasShownHookPrompt`。
    func presentManually() {
        present()
    }

    // MARK: - Private

    private func present() {
        // 已经打开就聚焦
        if let existing = panel, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        rebuildContent(in: panel)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    private func rebuildContent(in panel: NSPanel) {
        let items = buildItems()
        let view = HookOnboardingView(
            onClose: { [weak self] in
                self?.dismiss()
            },
            onInstall: { [weak self] cli in
                self?.install(cli: cli)
            },
            onInstallAll: { [weak self] in
                self?.installAll()
            },
            items: items
        )
        panel.contentView = NSHostingView(rootView: view)
    }

    private func dismiss() {
        PreferencesStore.shared.preferences.hasShownHookPrompt = true
        panel?.close()
        panel = nil
    }

    private func install(cli: CLIHookConfig) {
        do {
            try installer.install(for: cli)
            Log("Installed hook for \(cli.displayName)", tag: "Onboarding")
        } catch {
            Log("Failed to install hook for \(cli.displayName): \(error)", tag: "Onboarding")
        }
        refresh()
    }

    private func installAll() {
        let items = buildItems()
        for item in items where item.status == .notInstalled {
            do {
                try installer.install(for: item.cli)
                Log("Auto-installed hook for \(item.cli.displayName)", tag: "Onboarding")
            } catch {
                Log("Failed to install hook for \(item.cli.displayName): \(error)", tag: "Onboarding")
            }
        }
        refresh()
    }

    private func refresh() {
        guard let panel else { return }
        rebuildContent(in: panel)
    }

    private func buildItems() -> [HookOnboardingView.CLIItem] {
        HookInstaller.supportedCLIs.filter { !$0.hidden }.map { cli in
            let settingsURL = URL(fileURLWithPath: NSString(string: cli.settingsPath).expandingTildeInPath)
            let cliExists = FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path)
            let status: HookOnboardingView.CLIItem.Status
            if !cliExists {
                status = .notDetected
            } else if installer.isInstalled(for: cli) {
                status = .installed
            } else {
                status = .notInstalled
            }
            return HookOnboardingView.CLIItem(cli: cli, status: status)
        }
    }
}
