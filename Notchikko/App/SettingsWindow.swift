import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设置面板主窗口（侧边栏导航）

enum SettingsTab: String, CaseIterable {
    case general, cli

    var displayName: String {
        switch self {
        case .general: return String(localized: "settings.general")
        case .cli: return String(localized: "settings.cli")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .cli: return "terminal"
        }
    }
}

struct SettingsWindowView: View {
    @State private var selectedTab: SettingsTab = .general

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
                case .general:
                    GeneralSettingsView()
                case .cli:
                    CLISettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .toolbar(.hidden)
        .frame(width: 580, height: 420)
    }
}

// MARK: - 通用（外观 + 声音 + 审批）

struct GeneralSettingsView: View {
    @State private var themes: [ThemeInfo] = []

    private let controlWidth: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(String(localized: "settings.general"))
                .font(.title2.bold())

            // 外观
            GroupBox(String(localized: "settings.display")) {
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
                }
                .padding(4)
            }

            // 声音
            GroupBox(String(localized: "settings.sound")) {
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
            }

            // 审批
            GroupBox(String(localized: "settings.approval")) {
                VStack(spacing: 12) {
                    settingsRow(String(localized: "settings.approval_card")) {
                        Toggle("", isOn: approvalEnabledBinding)
                            .toggleStyle(.switch)
                    }

                    if PreferencesStore.shared.preferences.approvalCardEnabled {
                        Divider()
                        settingsRow(String(localized: "settings.approval_delay")) {
                            Picker("", selection: hideDelayBinding) {
                                Text(String(localized: "settings.seconds_3")).tag(3.0 as TimeInterval)
                                Text(String(localized: "settings.seconds_5")).tag(5.0 as TimeInterval)
                                Text(String(localized: "settings.seconds_10")).tag(10.0 as TimeInterval)
                                Text(String(localized: "settings.never_hide")).tag(0.0 as TimeInterval)
                            }
                        }
                    }
                }
                .padding(4)
            }

            Spacer()
        }
        .onAppear { themes = ThemeProvider.shared.availableThemes }
    }

    /// 统一的设置行：左边标签 + 右边控件（固定宽度容器右对齐）
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

    private var approvalEnabledBinding: Binding<Bool> {
        Binding(
            get: { PreferencesStore.shared.preferences.approvalCardEnabled },
            set: { PreferencesStore.shared.preferences.approvalCardEnabled = $0 }
        )
    }

    private var hideDelayBinding: Binding<TimeInterval> {
        Binding(
            get: { PreferencesStore.shared.preferences.approvalCardHideDelay },
            set: { PreferencesStore.shared.preferences.approvalCardHideDelay = $0 }
        )
    }
}

// MARK: - CLI 集成

struct CLISettingsView: View {
    @State private var hookInstaller = HookInstaller()
    @State private var hookStatuses: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(String(localized: "settings.cli"))
                .font(.title2.bold())

            VStack(spacing: 12) {
                ForEach(HookInstaller.supportedCLIs, id: \.name) { cli in
                    CLIRow(
                        cli: cli,
                        isInstalled: hookStatuses[cli.name] ?? false,
                        onInstall: { installHook(cli) },
                        onUninstall: { uninstallHook(cli) }
                    )
                }

                ComingSoonRow(icon: "💎", name: "Gemini CLI")
            }

            Spacer()
        }
        .onAppear {
            refreshStatuses()
        }
    }

    private func installHook(_ cli: CLIHookConfig) {
        do {
            try hookInstaller.install(for: cli)
            refreshStatuses()
        } catch {
            // TODO: error alert
        }
    }

    private func uninstallHook(_ cli: CLIHookConfig) {
        do {
            try hookInstaller.uninstall(for: cli)
            refreshStatuses()
        } catch {
            // TODO: error alert
        }
    }

    private func refreshStatuses() {
        for cli in HookInstaller.supportedCLIs {
            hookStatuses[cli.name] = hookInstaller.isInstalled(for: cli)
        }
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
