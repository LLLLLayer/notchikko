import AppKit
import SwiftUI

/// 托管首次启动 / "关于"页手动触发的 CLI Hook 引导面板。
/// 自动/手动都经过 `present()`；NSPanel 里装一个 SwiftUI 视图。
@MainActor
final class HookOnboardingCoordinator {
    static let shared = HookOnboardingCoordinator()

    private let installer = HookInstaller()
    private var panel: NSPanel?
    private var closeObserver: NSObjectProtocol?
    /// 刚成功安装、需要在 UI 上短暂高亮的 CLI 名称集合。
    /// 高亮由视图侧的 `.task` 驱动（~1.2s 后淡出），所以这里只负责在下一次 refresh 时传进去。
    private var recentlyInstalled: Set<String> = []

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

        // 标题栏 ⊗ 关闭、"稍后"按钮、Cmd+W 都会触发 willClose —— 统一当作 dismiss
        // 处理，免得下次启动再弹一次。
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePanelClosed()
            }
        }

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
                self?.panel?.close()
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

    private func handlePanelClosed() {
        PreferencesStore.shared.preferences.hasShownHookPrompt = true
        if let token = closeObserver {
            NotificationCenter.default.removeObserver(token)
            closeObserver = nil
        }
        panel = nil
        recentlyInstalled.removeAll()
    }

    private func install(cli: CLIHookConfig) {
        do {
            try installer.install(for: cli)
            Log("Installed hook for \(cli.displayName)", tag: "Onboarding")
            markInstalled([cli.name])
        } catch {
            Log("Failed to install hook for \(cli.displayName): \(error)",
                tag: "Onboarding", level: .error)
            refresh()
            presentInstallError(failures: [(cli, error)])
        }
    }

    private func installAll() {
        let items = buildItems()
        var installed: [String] = []
        var failures: [(CLIHookConfig, Error)] = []
        for item in items where item.status == .notInstalled {
            do {
                try installer.install(for: item.cli)
                Log("Auto-installed hook for \(item.cli.displayName)", tag: "Onboarding")
                installed.append(item.cli.name)
            } catch {
                Log("Failed to install hook for \(item.cli.displayName): \(error)",
                    tag: "Onboarding", level: .error)
                failures.append((item.cli, error))
            }
        }
        markInstalled(installed)
        if !failures.isEmpty {
            presentInstallError(failures: failures)
        }
    }

    private func markInstalled(_ names: [String]) {
        guard !names.isEmpty else {
            refresh()
            return
        }
        recentlyInstalled.formUnion(names)
        refresh()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self else { return }
            self.recentlyInstalled.subtract(names)
            self.refresh()
        }
    }

    private func presentInstallError(failures: [(CLIHookConfig, Error)]) {
        guard !failures.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "onboarding.install_failed.title")
        let lines = failures.map { "• \($0.0.displayName): \($0.1.localizedDescription)" }
            .joined(separator: "\n")
        alert.informativeText = lines + "\n\n" + String(localized: "onboarding.install_failed.hint")
        if let panel {
            alert.beginSheetModal(for: panel) { _ in }
        } else {
            alert.runModal()
        }
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
            return HookOnboardingView.CLIItem(
                cli: cli,
                status: status,
                justInstalled: recentlyInstalled.contains(cli.name)
            )
        }
    }
}
