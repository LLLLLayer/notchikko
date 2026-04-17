import AppKit

/// 首次启动检测已安装的 CLI agent，弹窗询问是否一键安装 hooks。
/// 只弹一次（通过 PreferencesStore.hasShownHookPrompt 记录）。
@MainActor
final class HookOnboardingCoordinator {
    private let installer = HookInstaller()

    func promptIfNeeded() {
        guard !PreferencesStore.shared.preferences.hasShownHookPrompt else { return }

        // 检测哪些 CLI 的配置目录存在但未安装 hook
        let uninstalledCLIs = HookInstaller.supportedCLIs.filter { cli in
            let settingsURL = URL(fileURLWithPath: NSString(string: cli.settingsPath).expandingTildeInPath)
            let cliExists = FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path)
            return cliExists && !installer.isInstalled(for: cli)
        }

        guard !uninstalledCLIs.isEmpty else {
            PreferencesStore.shared.preferences.hasShownHookPrompt = true
            return
        }

        // 延迟 1s 弹窗，等窗口就绪
        Task {
            try? await Task.sleep(for: .seconds(1))
            runPrompt(for: uninstalledCLIs)
        }
    }

    private func runPrompt(for clis: [CLIHookConfig]) {
        let names = clis.map { "\($0.icon) \($0.displayName)" }.joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = String(localized: "hook_prompt.title")
        alert.informativeText = String(format: String(localized: "hook_prompt.message"), names)
        alert.addButton(withTitle: String(localized: "hook_prompt.install"))
        alert.addButton(withTitle: String(localized: "hook_prompt.later"))
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            for cli in clis {
                do {
                    try installer.install(for: cli)
                    Log("Auto-installed hook for \(cli.displayName)", tag: "Onboarding")
                } catch {
                    Log("Failed to install hook for \(cli.displayName): \(error)", tag: "Onboarding")
                }
            }
        }

        PreferencesStore.shared.preferences.hasShownHookPrompt = true
    }
}
