import Foundation

/// 支持的 CLI 配置
struct CLIHookConfig {
    let name: String            // 内部标识: "claude-code", "codex", "trae-cli"
    let displayName: String     // 显示名称: "Claude Code", "OpenAI Codex", "Trae CLI"
    let icon: String            // emoji
    let settingsPath: String    // 配置文件路径 (~ 会被展开)
    let hookEvents: [String]    // 需要注册的事件
    let configFormat: ConfigFormat // 配置文件格式

    enum ConfigFormat {
        case json   // Claude Code, Codex
        case yaml   // Trae CLI (Coco)
    }

    init(name: String, displayName: String, icon: String, settingsPath: String,
         hookEvents: [String], configFormat: ConfigFormat = .json) {
        self.name = name
        self.displayName = displayName
        self.icon = icon
        self.settingsPath = settingsPath
        self.hookEvents = hookEvents
        self.configFormat = configFormat
    }

    /// 通过 source 名查找 Agent 元数据（icon + displayName）
    static func metadata(for source: String) -> (icon: String, displayName: String) {
        if let cli = HookInstaller.supportedCLIs.first(where: { $0.name == source }) {
            return (cli.icon, cli.displayName)
        }
        return ("🔧", source)
    }
}

final class HookInstaller {

    static let supportedCLIs: [CLIHookConfig] = [
        CLIHookConfig(
            name: "claude-code",
            displayName: "Claude Code",
            icon: "🤖",
            settingsPath: "~/.claude/settings.json",
            hookEvents: [
                "SessionStart", "SessionEnd",
                "UserPromptSubmit",
                "PreToolUse", "PostToolUse", "PostToolUseFailure",
                "PreCompact", "PostCompact",
                "Stop", "StopFailure",
                "SubagentStart", "SubagentStop",
                "Notification", "Elicitation",
                "WorktreeCreate", "PermissionRequest",
            ]
        ),
        CLIHookConfig(
            name: "codex",
            displayName: "OpenAI Codex",
            icon: "📦",
            settingsPath: "~/.codex/hooks.json",
            hookEvents: [
                "UserPromptSubmit", "SessionStart", "SessionEnd",
                "PreToolUse", "PostToolUse",
                "Stop",
            ]
        ),
        CLIHookConfig(
            name: "gemini-cli",
            displayName: "Gemini CLI",
            icon: "💎",
            settingsPath: "~/.gemini/settings.json",
            hookEvents: [
                "SessionStart", "SessionEnd",
                "BeforeAgent", "BeforeTool", "AfterTool", "AfterAgent",
                "Notification", "PreCompress",
            ]
        ),
        CLIHookConfig(
            name: "trae-cli",
            displayName: "Trae CLI",
            icon: "🦎",
            settingsPath: "~/.trae/traecli.yaml",
            hookEvents: [
                "user_prompt_submit",
                "pre_tool_use", "post_tool_use",
                "stop", "subagent_stop",
            ],
            configFormat: .yaml
        ),
    ]

    private let hookScriptName = "notchikko-hook.sh"

    /// Hook 脚本安装目录
    private var hookDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notchikko/hooks")
    }

    /// 已安装的 hook 脚本路径
    private var hookScriptPath: String {
        hookDir.appendingPathComponent(hookScriptName).path
    }

    // MARK: - 检测

    func isInstalled(for cli: CLIHookConfig) -> Bool {
        let settingsURL = expandPath(cli.settingsPath)
        guard let content = try? String(contentsOf: settingsURL, encoding: .utf8) else {
            return false
        }

        switch cli.configFormat {
        case .yaml:
            // YAML: 简单检查文件中是否包含 notchikko
            return content.contains("notchikko")
        case .json:
            guard let data = content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = json["hooks"] as? [String: Any] else {
                return false
            }
            for event in cli.hookEvents {
                if let entries = hooks[event] as? [[String: Any]] {
                    let jsonStr = (try? JSONSerialization.data(withJSONObject: entries)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    if jsonStr.contains("notchikko") { return true }
                }
            }
            return false
        }
    }

    // MARK: - 安装

    func install(for cli: CLIHookConfig) throws {
        // 1. 确保 hook 脚本存在
        try installHookScript()

        let settingsURL = expandPath(cli.settingsPath)
        let dir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        switch cli.configFormat {
        case .yaml:
            try installYAML(for: cli, settingsURL: settingsURL)
        case .json:
            try installJSON(for: cli, settingsURL: settingsURL)
        }

        // 更新 preferences
        Task { @MainActor in
            PreferencesStore.shared.preferences.installedHooks[cli.name] = true
            PreferencesStore.shared.save()
        }
    }

    private func installJSON(for cli: CLIHookConfig, settingsURL: URL) throws {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        // Claude Code 嵌套格式: { "matcher": "*", "hooks": [{ "type": "command", "command": "...", "timeout": N }] }
        let defaultHookEntry: [String: Any] = [
            "matcher": "*",
            "hooks": [
                [
                    "type": "command",
                    "command": "\(hookScriptPath) \(cli.name)",
                ] as [String: Any]
            ]
        ]

        // PermissionRequest 需要长超时（阻塞等用户操作）
        let permissionHookEntry: [String: Any] = [
            "matcher": "*",
            "hooks": [
                [
                    "type": "command",
                    "command": "\(hookScriptPath) \(cli.name)",
                    "timeout": 86400,  // 24h，与 Vibe Island 一致
                ] as [String: Any]
            ]
        ]

        for event in cli.hookEvents {
            let hookEntry = (event == "PermissionRequest") ? permissionHookEntry : defaultHookEntry
            var entries = hooks[event] as? [[String: Any]] ?? []
            let alreadyExists = entries.contains { entry in
                let jsonStr = (try? JSONSerialization.data(withJSONObject: entry)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return jsonStr.contains("notchikko")
            }
            if !alreadyExists {
                entries.append(hookEntry)
            }
            hooks[event] = entries
        }

        json["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    private func installYAML(for cli: CLIHookConfig, settingsURL: URL) throws {
        // 读取现有内容
        var content = (try? String(contentsOf: settingsURL, encoding: .utf8)) ?? ""

        // 已安装则跳过
        if content.contains("notchikko") { return }

        // 生成 Trae CLI YAML hook 配置块
        // Trae CLI 格式: 一个 hook 条目，用 matchers 数组匹配多个事件
        let matchers = cli.hookEvents.map { "      - event: \($0)" }.joined(separator: "\n")
        let hookBlock = """

        # Notchikko hook — visual pet indicator
        hooks:
          - type: command
            command: '\(hookScriptPath) \(cli.name)'
            matchers:
        \(matchers)
        """

        // 如果文件已有 hooks: 字段，需要在其下追加而非新建
        // 简化实现：如果已有 hooks: 开头的行，在其后追加条目
        if content.contains("\nhooks:") || content.hasPrefix("hooks:") {
            // 在已有 hooks 块下追加一个条目
            let appendBlock = """

              # Notchikko hook — visual pet indicator
              - type: command
                command: '\(hookScriptPath) \(cli.name)'
                matchers:
            \(cli.hookEvents.map { "      - event: \($0)" }.joined(separator: "\n"))
            """
            content.append(appendBlock)
        } else {
            content.append(hookBlock)
        }

        try content.write(to: settingsURL, atomically: true, encoding: .utf8)
    }

    // MARK: - 卸载

    func uninstall(for cli: CLIHookConfig) throws {
        let settingsURL = expandPath(cli.settingsPath)

        switch cli.configFormat {
        case .yaml:
            try uninstallYAML(settingsURL: settingsURL)
        case .json:
            try uninstallJSON(settingsURL: settingsURL, cli: cli)
        }

        Task { @MainActor in
            PreferencesStore.shared.preferences.installedHooks[cli.name] = false
            PreferencesStore.shared.save()
        }
    }

    private func uninstallJSON(settingsURL: URL, cli: CLIHookConfig) throws {
        guard let data = try? Data(contentsOf: settingsURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for event in cli.hookEvents {
            if var entries = hooks[event] as? [[String: Any]] {
                entries.removeAll { entry in
                    (entry["command"] as? String)?.contains("notchikko") == true
                }
                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        json["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: settingsURL, options: .atomic)
    }

    private func uninstallYAML(settingsURL: URL) throws {
        guard var content = try? String(contentsOf: settingsURL, encoding: .utf8) else { return }
        guard content.contains("notchikko") else { return }

        // 移除包含 notchikko 的行以及紧邻的注释行
        var lines = content.components(separatedBy: "\n")
        var indicesToRemove = IndexSet()
        for (i, line) in lines.enumerated() {
            if line.contains("notchikko") {
                indicesToRemove.insert(i)
                // 也移除上方的注释行
                if i > 0 && lines[i - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") &&
                   lines[i - 1].contains("Notchikko") {
                    indicesToRemove.insert(i - 1)
                }
            }
        }

        // 从后往前删除
        for i in indicesToRemove.reversed() {
            lines.remove(at: i)
        }

        content = lines.joined(separator: "\n")
        try content.write(to: settingsURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Private

    private func installHookScript() throws {
        guard let bundleURL = Bundle.main.url(forResource: "notchikko-hook", withExtension: "sh") else {
            throw HookError.scriptNotFound
        }

        try FileManager.default.createDirectory(at: hookDir, withIntermediateDirectories: true)
        let dest = hookDir.appendingPathComponent(hookScriptName)

        // 总是覆盖（确保最新版本）
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: bundleURL, to: dest)

        // 设置可执行权限
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: dest.path
        )
    }

    private func expandPath(_ path: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    enum HookError: Error {
        case scriptNotFound
    }
}
