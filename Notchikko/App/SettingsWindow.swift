import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设置面板主窗口（侧边栏导航）

enum SettingsTab: String, CaseIterable {
    case display, sound, approval, integration, shortcuts, about

    var displayName: String {
        switch self {
        case .display: return String(localized: "settings.display")
        case .sound: return String(localized: "settings.sound")
        case .approval: return String(localized: "settings.approval")
        case .integration: return String(localized: "settings.integration")
        case .shortcuts: return String(localized: "settings.shortcuts")
        case .about: return String(localized: "settings.about")
        }
    }

    var icon: String {
        switch self {
        case .display: return "paintbrush"
        case .sound: return "speaker.wave.2"
        case .approval: return "checkmark.shield"
        case .integration: return "terminal"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

struct SettingsWindowView: View {
    @State private var selectedTab: SettingsTab = .display

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.displayName, systemImage: tab.icon)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
        } detail: {
            Group {
                switch selectedTab {
                case .display:
                    DisplaySettingsView()
                case .sound:
                    SoundSettingsView()
                case .approval:
                    ApprovalSettingsView()
                case .integration:
                    IntegrationSettingsView()
                case .shortcuts:
                    ShortcutsSettingsView()
                case .about:
                    AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .toolbar(.hidden)
        .frame(width: 580, height: 420)
    }
}

// MARK: - 显示

struct DisplaySettingsView: View {
    @State private var themes: [ThemeInfo] = []

    private let controlWidth: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(String(localized: "settings.display"))
                .font(.title2.bold())

            VStack(spacing: 12) {
                settingsRow(String(localized: "settings.pet_size")) {
                    Picker("", selection: scaleBinding) {
                        Text(String(localized: "settings.size_small")).tag(1.0 as CGFloat)
                        Text(String(localized: "settings.size_medium")).tag(1.5 as CGFloat)
                        Text(String(localized: "settings.size_large")).tag(2.0 as CGFloat)
                    }
                    .pickerStyle(.segmented)
                }

                Divider()

                settingsRow(String(localized: "settings.theme")) {
                    Picker("", selection: themeBinding) {
                        ForEach(themes) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                }

                Divider()

                settingsRow(String(localized: "settings.notch_detection")) {
                    Picker("", selection: notchDetectionBinding) {
                        Text(String(localized: "settings.notch_auto")).tag(NotchDetectionMode.auto)
                        Text(String(localized: "settings.notch_force_on")).tag(NotchDetectionMode.forceOn)
                        Text(String(localized: "settings.notch_force_off")).tag(NotchDetectionMode.forceOff)
                    }
                }

                Divider()

                settingsRow(String(localized: "settings.danmaku")) {
                    Toggle("", isOn: danmakuBinding)
                        .toggleStyle(.switch)
                }
            }
            .padding(4)

            Spacer()
        }
        .onAppear { themes = ThemeProvider.shared.availableThemes }
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
            Spacer()
            HStack {
                Spacer()
                content()
            }
            .frame(width: controlWidth)
        }
    }

    private var scaleBinding: Binding<CGFloat> {
        Binding(
            get: { PreferencesStore.shared.preferences.petScale },
            set: { PreferencesStore.shared.preferences.petScale = $0 }
        )
    }

    private var themeBinding: Binding<String> {
        Binding(
            get: { PreferencesStore.shared.preferences.themeId },
            set: { PreferencesStore.shared.preferences.themeId = $0 }
        )
    }

    private var notchDetectionBinding: Binding<NotchDetectionMode> {
        Binding(
            get: { PreferencesStore.shared.preferences.notchDetectionMode },
            set: { PreferencesStore.shared.preferences.notchDetectionMode = $0 }
        )
    }

    private var danmakuBinding: Binding<Bool> {
        Binding(
            get: { PreferencesStore.shared.preferences.danmakuEnabled },
            set: { PreferencesStore.shared.preferences.danmakuEnabled = $0 }
        )
    }
}

// MARK: - 声音

struct SoundSettingsView: View {
    private let controlWidth: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(String(localized: "settings.sound"))
                .font(.title2.bold())

            VStack(spacing: 12) {
                settingsRow(String(localized: "settings.volume")) {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Slider(value: volumeBinding, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                Divider()

                settingsRow(String(localized: "settings.sound_theme")) {
                    Picker("", selection: soundThemeBinding) {
                        ForEach(SoundThemeRegistry.themes) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                }
            }
            .padding(4)

            Spacer()
        }
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
            Spacer()
            HStack {
                Spacer()
                content()
            }
            .frame(width: controlWidth)
        }
    }

    private var volumeBinding: Binding<Float> {
        Binding(
            get: { PreferencesStore.shared.preferences.soundVolume },
            set: { PreferencesStore.shared.preferences.soundVolume = $0 }
        )
    }

    private var soundThemeBinding: Binding<String> {
        Binding(
            get: { PreferencesStore.shared.preferences.soundThemeId },
            set: { PreferencesStore.shared.preferences.soundThemeId = $0 }
        )
    }
}

// MARK: - 审批

struct ApprovalSettingsView: View {
    private let controlWidth: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(String(localized: "settings.approval"))
                .font(.title2.bold())

            VStack(spacing: 12) {
                settingsRow(String(localized: "settings.approval_card")) {
                    Toggle("", isOn: approvalEnabledBinding)
                        .toggleStyle(.switch)
                }

                if PreferencesStore.shared.preferences.approvalCardEnabled {
                    Divider()
                    settingsRow(String(localized: "settings.approval_delay")) {
                        Picker("", selection: hideDelayBinding) {
                            Text(String(localized: "settings.seconds_15")).tag(15.0 as TimeInterval)
                            Text(String(localized: "settings.never_hide")).tag(0.0 as TimeInterval)
                        }
                    }
                }
            }
            .padding(4)

            Spacer()
        }
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
            Spacer()
            HStack {
                Spacer()
                content()
            }
            .frame(width: controlWidth)
        }
    }

    private var approvalEnabledBinding: Binding<Bool> {
        Binding(
            get: { PreferencesStore.shared.preferences.approvalCardEnabled },
            set: { PreferencesStore.shared.preferences.approvalCardEnabled = $0 }
        )
    }

    private var hideDelayBinding: Binding<TimeInterval> {
        Binding(
            get: {
                let v = PreferencesStore.shared.preferences.approvalCardHideDelay
                return v == 0 ? 0 : 15  // 旧值（3/5/10）映射到 15
            },
            set: { PreferencesStore.shared.preferences.approvalCardHideDelay = $0 }
        )
    }
}

// MARK: - 集成

struct IntegrationSettingsView: View {
    @State private var hookInstaller = HookInstaller()
    @State private var hookStatuses: [String: Bool] = [:]
    @State private var ideStatuses: [String: IDEExtensionInstaller.ExtensionStatus] = [:]
    @State private var hooksOutdated: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(String(localized: "settings.integration"))
                    .font(.title2.bold())

                // 升级提示：老版 inline-python .sh 或 .py 丢失时显示
                if hooksOutdated {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "settings.hooks_outdated_title"))
                                .font(.body.bold())
                            Text(String(localized: "settings.hooks_outdated_body"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(String(localized: "settings.hooks_reinstall_all")) {
                            hookInstaller.reinstallAllOutdatedHooks()
                            refreshStatuses()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(.orange.opacity(0.12))
                    .cornerRadius(8)
                }

                // CLI Hooks
                GroupBox("CLI Hooks") {
                    VStack(spacing: 12) {
                        ForEach(HookInstaller.supportedCLIs, id: \.name) { cli in
                            CLIRow(
                                cli: cli,
                                isInstalled: hookStatuses[cli.name] ?? false,
                                onInstall: { installHook(cli) },
                                onUninstall: { uninstallHook(cli) }
                            )
                        }
                    }
                    .padding(4)
                }

                // IDE Extensions
                GroupBox(String(localized: "settings.ide_extensions")) {
                    VStack(spacing: 12) {
                        ForEach(IDEExtensionInstaller.targets) { target in
                            IDEExtensionRow(
                                target: target,
                                status: ideStatuses[target.id] ?? .notInstalled,
                                onInstall: { installExtension(target) },
                                onUninstall: { uninstallExtension(target) }
                            )
                        }
                    }
                    .padding(4)
                }
            }
        }
        .onAppear {
            refreshStatuses()
        }
    }

    private func installHook(_ cli: CLIHookConfig) {
        do {
            try hookInstaller.install(for: cli)
            refreshStatuses()
        } catch {}
    }

    private func uninstallHook(_ cli: CLIHookConfig) {
        do {
            try hookInstaller.uninstall(for: cli)
            refreshStatuses()
        } catch {}
    }

    private func installExtension(_ target: IDEExtensionInstaller.IDETarget) {
        do {
            try IDEExtensionInstaller.install(for: target)
            refreshStatuses()
        } catch {}
    }

    private func uninstallExtension(_ target: IDEExtensionInstaller.IDETarget) {
        do {
            try IDEExtensionInstaller.uninstall(for: target)
            refreshStatuses()
        } catch {}
    }

    private func refreshStatuses() {
        for cli in HookInstaller.supportedCLIs {
            hookStatuses[cli.name] = hookInstaller.isInstalled(for: cli)
        }
        hooksOutdated = hookInstaller.isInstalledHookOutdated
        Task {
            for target in IDEExtensionInstaller.targets {
                let status = await IDEExtensionInstaller.checkStatus(for: target)
                await MainActor.run {
                    ideStatuses[target.id] = status
                }
            }
        }
    }

}

// MARK: - 快捷键

struct ShortcutsSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(String(localized: "settings.shortcuts"))
                    .font(.title2.bold())

                GroupBox(String(localized: "settings.shortcuts.group_approval")) {
                    VStack(spacing: 0) {
                        ShortcutRow(
                            keys: ["⌘", "Y"],
                            label: String(localized: "approval.allow_once")
                        )
                        Divider()
                        ShortcutRow(
                            keys: ["⌘", "⇧", "Y"],
                            label: String(localized: "approval.always_allow")
                        )
                        Divider()
                        ShortcutRow(
                            keys: ["⌘", "N"],
                            label: String(localized: "approval.deny")
                        )
                        Divider()
                        ShortcutRow(
                            keys: ["⌘", "⇧", "N"],
                            label: String(localized: "approval.auto_approve")
                        )
                    }
                    .padding(.vertical, 4)
                }
                Text(String(localized: "settings.shortcuts.approval_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                GroupBox(String(localized: "settings.shortcuts.group_app")) {
                    VStack(spacing: 0) {
                        ShortcutRow(
                            keys: ["⌘", ","],
                            label: String(localized: "settings.shortcuts.app_open_settings")
                        )
                        Divider()
                        ShortcutRow(
                            keys: ["⌘", "Q"],
                            label: String(localized: "settings.shortcuts.app_quit")
                        )
                    }
                    .padding(.vertical, 4)
                }

                GroupBox(String(localized: "settings.shortcuts.group_pet")) {
                    VStack(spacing: 0) {
                        ShortcutRow(
                            keys: [String(localized: "settings.shortcuts.mouse_click")],
                            label: String(localized: "settings.shortcuts.pet_click")
                        )
                        Divider()
                        ShortcutRow(
                            keys: [String(localized: "settings.shortcuts.mouse_right_click")],
                            label: String(localized: "settings.shortcuts.pet_right_click")
                        )
                        Divider()
                        ShortcutRow(
                            keys: [String(localized: "settings.shortcuts.mouse_drag")],
                            label: String(localized: "settings.shortcuts.pet_drag")
                        )
                    }
                    .padding(.vertical, 4)
                }

                Spacer(minLength: 0)
            }
        }
    }
}

private struct ShortcutRow: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack {
            Text(label)
                .font(.body)
            Spacer()
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    KeyCap(text: key)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(.secondary.opacity(0.3), lineWidth: 0.5)
            )
            .cornerRadius(4)
    }
}

// MARK: - 关于

struct AboutSettingsView: View {
    private static let githubURL = URL(string: "https://github.com/yangjie-layer/Notchikko")!

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    var body: some View {
        VStack(alignment: .center, spacing: 18) {
            // 使用 NSApplication.shared.applicationIconImage 以直接拿到 Assets 里的 AppIcon（不依赖图标名称常量）
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)

            VStack(spacing: 4) {
                Text("Notchikko")
                    .font(.title.bold())
                Text("v\(appVersion)\(buildNumber.isEmpty ? "" : " (\(buildNumber))")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            VStack(spacing: 10) {
                Link(destination: Self.githubURL) {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text(verbatim: "github.com/yangjie-layer/Notchikko")
                    }
                    .font(.callout)
                }
                .buttonStyle(.link)

                Button(String(localized: "menu.check_for_updates")) {
                    UpdateManager.shared.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!UpdateManager.shared.canCheckForUpdates)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 8)
    }
}

// MARK: - 子组件

private struct CLIRow: View {
    let cli: CLIHookConfig
    let isInstalled: Bool
    let onInstall: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        HStack {
            Text(cli.icon).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(cli.displayName).font(.body.bold())
                Text(isInstalled ? String(localized: "settings.hook_installed") : String(localized: "settings.hook_not_installed"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isInstalled {
                Button(String(localized: "settings.uninstall_hook")) { onUninstall() }
                    .controlSize(.small)
                Button(String(localized: "settings.reinstall_hook")) { onInstall() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(String(localized: "settings.install_hook")) { onInstall() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .cornerRadius(8)
    }
}

private struct IDEExtensionRow: View {
    let target: IDEExtensionInstaller.IDETarget
    let status: IDEExtensionInstaller.ExtensionStatus
    let onInstall: () -> Void
    let onUninstall: () -> Void

    @State private var showRestartHint = false

    private var statusText: String {
        switch status {
        case .notInstalled: return String(localized: "settings.ext_not_installed")
        case .installed: return String(localized: "settings.ext_installed")
        case .running: return String(localized: "settings.ext_running")
        case .updateAvailable: return String(localized: "settings.ext_update_available")
        }
    }

    var body: some View {
        HStack {
            Text("💻").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).font(.body.bold())
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if showRestartHint {
                    Text(String(localized: "settings.ext_restart_hint"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            switch status {
            case .notInstalled:
                Button(String(localized: "settings.install_hook")) {
                    onInstall()
                    showRestartHint = true
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            case .updateAvailable:
                Button(String(localized: "settings.uninstall_hook")) { onUninstall() }
                    .controlSize(.small)
                Button(String(localized: "settings.ext_update")) {
                    onInstall()
                    showRestartHint = true
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            default:
                Button(String(localized: "settings.uninstall_hook")) { onUninstall() }
                    .controlSize(.small)
                Button(String(localized: "settings.reinstall_hook")) {
                    onInstall()
                    showRestartHint = true
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .cornerRadius(8)
    }
}

private struct ComingSoonRow: View {
    let icon: String
    let name: String

    var body: some View {
        HStack {
            Text(icon).font(.title2)
            Text(name).font(.body.bold())
            Spacer()
            Text(String(localized: "settings.coming_soon"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.15))
        .cornerRadius(8)
    }
}
