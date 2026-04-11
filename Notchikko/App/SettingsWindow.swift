import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设置面板主窗口（侧边栏导航）

enum SettingsTab: String, CaseIterable {
    case general = "通用"
    case display = "显示"
    case sound = "声音"
    case cli = "CLI 集成"

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
                Label(tab.rawValue, systemImage: tab.icon)
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
            Text("通用")
                .font(.title2.bold())

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("审批卡片隐藏延时")
                        Spacer()
                        Picker("", selection: hideDelayBinding) {
                            Text("3 秒").tag(3.0 as TimeInterval)
                            Text("5 秒").tag(5.0 as TimeInterval)
                            Text("10 秒").tag(10.0 as TimeInterval)
                            Text("永不隐藏").tag(0.0 as TimeInterval)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("显示")
                .font(.title2.bold())

            GroupBox {
                HStack {
                    Text("宠物大小")
                    Spacer()
                    Picker("", selection: scaleBinding) {
                        Text("小 (0.6x)").tag(0.6 as CGFloat)
                        Text("中 (1.0x)").tag(1.0 as CGFloat)
                        Text("大 (1.5x)").tag(1.5 as CGFloat)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
                .padding(4)
            }

            Spacer()
        }
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
}

// MARK: - 声音

struct SoundSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("声音")
                .font(.title2.bold())

            // 总开关 + 音量
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("音量")
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
            GroupBox("音效自定义") {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("CLI 集成")
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

            Spacer()
        }
        .onAppear { refreshStatuses() }
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
                Text(isInstalled ? "Hook 状态: ✅ 已安装" : "Hook 状态: ❌ 未安装")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isInstalled {
                Button("重新安装") { onReinstall() }
                    .controlSize(.small)
            } else {
                Button("一键安装 Hook") { onInstall() }
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
            Text("Coming Soon")
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
                Text("自定义").font(.caption).foregroundStyle(.blue)
            } else {
                Text("默认").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("选择文件...") { pickFile() }
                .controlSize(.small)
            if hasCustom {
                Button("恢复默认") { resetToDefault() }
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
