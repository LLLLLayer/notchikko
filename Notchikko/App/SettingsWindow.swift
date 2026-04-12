import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设置面板主窗口（侧边栏导航）

enum SettingsTab: String, CaseIterable {
    case general, display, sound, cli

    var displayName: String {
        switch self {
        case .general: return String(localized: "settings.general")
        case .display: return String(localized: "settings.display")
        case .sound: return String(localized: "settings.sound")
        case .cli: return String(localized: "settings.cli")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .display: return "textformat.size"
        case .sound: return "speaker.wave.2"
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
                case .display:
                    DisplaySettingsView()
                case .sound:
                    SoundSettingsView()
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

// MARK: - 通用

struct GeneralSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(String(localized: "settings.general"))
                .font(.title2.bold())

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(String(localized: "settings.approval_delay"))
                        Spacer()
                        Picker("", selection: hideDelayBinding) {
                            Text(String(localized: "settings.seconds_3")).tag(3.0 as TimeInterval)
                            Text(String(localized: "settings.seconds_5")).tag(5.0 as TimeInterval)
                            Text(String(localized: "settings.seconds_10")).tag(10.0 as TimeInterval)
                            Text(String(localized: "settings.never_hide")).tag(0.0 as TimeInterval)
                        }
                        .frame(width: 140)
                    }
                }
                .padding(4)
            }

            Spacer()
        }
    }

    private var hideDelayBinding: Binding<TimeInterval> {
        Binding(
            get: { PreferencesStore.shared.preferences.approvalCardHideDelay },
            set: {
                PreferencesStore.shared.preferences.approvalCardHideDelay = $0
                PreferencesStore.shared.save()
            }
        )
    }
}

// MARK: - 显示

struct DisplaySettingsView: View {
    @State private var themes: [ThemeInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(String(localized: "settings.display"))
                .font(.title2.bold())

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(String(localized: "settings.pet_size"))
                        Spacer()
                        Picker("", selection: scaleBinding) {
                            Text(String(localized: "settings.size_small")).tag(0.6 as CGFloat)
                            Text(String(localized: "settings.size_medium")).tag(1.0 as CGFloat)
                            Text(String(localized: "settings.size_large")).tag(1.5 as CGFloat)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }

                    Divider()

                    // 主题选择
                    HStack {
                        Text(String(localized: "settings.theme"))
                        Spacer()
                        Picker("", selection: themeBinding) {
                            ForEach(themes) { theme in
                                Text(theme.name).tag(theme.id)
                            }
                        }
                        .frame(width: 160)
                    }

                    // 导入主题
                    HStack {
                        Spacer()
                        Button(String(localized: "settings.import_theme")) {
                            importTheme()
                        }
                        .controlSize(.small)
                    }
                }
                .padding(4)
            }

            Spacer()
        }
        .onAppear { themes = ThemeProvider.shared.availableThemes }
    }

    private var scaleBinding: Binding<CGFloat> {
        Binding(
            get: { PreferencesStore.shared.preferences.petScale },
            set: {
                PreferencesStore.shared.preferences.petScale = $0
                PreferencesStore.shared.save()
            }
        )
    }

    private var themeBinding: Binding<String> {
        Binding(
            get: { PreferencesStore.shared.preferences.themeId },
            set: {
                PreferencesStore.shared.preferences.themeId = $0
                PreferencesStore.shared.save()
            }
        )
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = String(localized: "settings.import_theme_msg")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let themeId = try ThemeProvider.shared.importTheme(from: url)
            PreferencesStore.shared.preferences.themeId = themeId
            PreferencesStore.shared.save()
            themes = ThemeProvider.shared.availableThemes
        } catch {}
    }
}

// MARK: - 声音

struct SoundSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(String(localized: "settings.sound"))
                .font(.title2.bold())

            // 总开关 + 音量
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(String(localized: "settings.volume"))
                        Spacer()
                        Picker("", selection: volumeBinding) {
                            ForEach(SoundVolume.allCases, id: \.self) { vol in
                                Text(vol.displayName).tag(vol)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                }
                .padding(4)
            }

            // 各状态音效自定义
            GroupBox(String(localized: "settings.sound_custom")) {
                VStack(spacing: 0) {
                    ForEach(Array(SoundManager.soundableStates.enumerated()), id: \.element) { index, state in
                        if index > 0 { Divider() }
                        SoundCustomRow(stateName: state)
                            .padding(.vertical, 6)
                    }
                }
                .padding(4)
            }

            Spacer()
        }
    }

    private var volumeBinding: Binding<SoundVolume> {
        Binding(
            get: { PreferencesStore.shared.preferences.soundVolume },
            set: {
                PreferencesStore.shared.preferences.soundVolume = $0
                PreferencesStore.shared.save()
            }
        )
    }
}

// MARK: - CLI 集成

struct CLISettingsView: View {
    @State private var hookInstaller = HookInstaller()
    @State private var hookStatuses: [String: Bool] = [:]
    @State private var isBypassOn: Bool = false

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
                        onReinstall: { installHook(cli) }
                    )
                }

                ComingSoonRow(icon: "🔮", name: "Cursor")
                ComingSoonRow(icon: "💎", name: "Gemini CLI")
            }

            // Bypass Permissions
            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.shield")
                                .foregroundStyle(.red)
                            Text(String(localized: "settings.bypass_permissions"))
                                .font(.body.bold())
                        }
                        Text(isBypassOn
                             ? String(localized: "settings.bypass_on_desc")
                             : String(localized: "settings.bypass_off_desc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isBypassOn ? String(localized: "settings.disable") : String(localized: "settings.enable")) {
                        toggleBypass()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isBypassOn ? .gray : .red)
                    .controlSize(.small)
                }
                .padding(4)
            }

            Spacer()
        }
        .onAppear {
            refreshStatuses()
            isBypassOn = readBypassStatus()
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

    private func refreshStatuses() {
        for cli in HookInstaller.supportedCLIs {
            hookStatuses[cli.name] = hookInstaller.isInstalled(for: cli)
        }
    }

    private func readBypassStatus() -> Bool {
        let path = NSString(string: "~/.claude/settings.json").expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["skipDangerousModePermissionPrompt"] as? Bool ?? false
    }

    private func toggleBypass() {
        let path = NSString(string: "~/.claude/settings.json").expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        var json: [String: Any] = [:]

        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let newValue = !(json["skipDangerousModePermissionPrompt"] as? Bool ?? false)
        json["skipDangerousModePermissionPrompt"] = newValue

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }

        isBypassOn = newValue
    }
}

// MARK: - 子组件

private struct CLIRow: View {
    let cli: CLIHookConfig
    let isInstalled: Bool
    let onInstall: () -> Void
    let onReinstall: () -> Void

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
                Button(String(localized: "settings.reinstall")) { onReinstall() }
                    .controlSize(.small)
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

private struct SoundCustomRow: View {
    let stateName: String
    @State private var hasCustom: Bool = false

    var body: some View {
        HStack {
            Text(stateName)
                .frame(width: 80, alignment: .leading)
            if hasCustom {
                Text(String(localized: "settings.custom")).font(.caption).foregroundStyle(.blue)
            } else {
                Text(String(localized: "settings.default")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "settings.pick_file")) { pickFile() }
                .controlSize(.small)
            if hasCustom {
                Button(String(localized: "settings.reset_default")) { resetToDefault() }
                    .controlSize(.small)
            }
        }
        .onAppear {
            hasCustom = PreferencesStore.shared.preferences.customSounds[stateName] != nil
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let fileName = try SoundManager.shared.importCustomSound(from: url, for: stateName)
            PreferencesStore.shared.preferences.customSounds[stateName] = fileName
            PreferencesStore.shared.save()
            hasCustom = true
        } catch {}
    }

    private func resetToDefault() {
        SoundManager.shared.removeCustomSound(for: stateName)
        PreferencesStore.shared.preferences.customSounds.removeValue(forKey: stateName)
        PreferencesStore.shared.save()
        hasCustom = false
    }
}
