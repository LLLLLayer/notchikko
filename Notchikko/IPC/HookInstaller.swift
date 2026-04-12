import Foundation

/// 支持的 CLI 配置
struct CLIHookConfig {
    let name: String            // 内部标识: "claude-code", "codex"
    let displayName: String     // 显示名称: "Claude Code", "OpenAI Codex"
    let icon: String            // emoji
    let settingsPath: String    // 配置文件路径 (~ 会被展开)
    let hookEvents: [String]    // 需要注册的事件
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
            settingsPath: "~/.codex/config.json",
            hookEvents: [
                "UserPromptSubmit", "SessionStart", "SessionEnd",
                "PreToolUse", "PostToolUse",
                "Stop",
            ]
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
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        // 检查是否至少有一个事件注册了 notchikko hook（兼容嵌套和扁平格式）
        for event in cli.hookEvents {
            if let entries = hooks[event] as? [[String: Any]] {
                let json = (try? JSONSerialization.data(withJSONObject: entries)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if json.contains("notchikko") { return true }
            }
        }
        return false
    }

    // MARK: - 安装

    func install(for cli: CLIHookConfig) throws {
        // 1. 确保 hook 脚本存在
        try installHookScript()

        // 2. 读取或创建 CLI 配置文件
        let settingsURL = expandPath(cli.settingsPath)
        var json: [String: Any] = [:]

        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        // 3. 合并 hook 配置（不破坏已有）
        var hooks = json["hooks"] as? [String: Any] ?? [:]

        // Claude Code 嵌套格式: { "hooks": [{ "type": "command", "command": "..." }] }
        let hookEntry: [String: Any] = [
            "hooks": [
                [
                    "type": "command",
                    "command": "\(hookScriptPath) \(cli.name)",
                ] as [String: Any]
            ]
        ]

        for event in cli.hookEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            // 检查是否已存在 notchikko hook（兼容嵌套和扁平格式）
            let alreadyExists = entries.contains { entry in
                let json = (try? JSONSerialization.data(withJSONObject: entry)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return json.contains("notchikko")
            }
            if !alreadyExists {
                entries.append(hookEntry)
            }
            hooks[event] = entries
        }

        json["hooks"] = hooks

        // 4. 写回配置文件
        let dir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)

        // 5. 更新 preferences
        Task { @MainActor in
            PreferencesStore.shared.preferences.installedHooks[cli.name] = true
            PreferencesStore.shared.save()
        }
    }

    // MARK: - 卸载

    func uninstall(for cli: CLIHookConfig) throws {
        let settingsURL = expandPath(cli.settingsPath)
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

        Task { @MainActor in
            PreferencesStore.shared.preferences.installedHooks[cli.name] = false
            PreferencesStore.shared.save()
        }
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
