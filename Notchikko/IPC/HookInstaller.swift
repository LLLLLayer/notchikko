import Foundation

/// 支持的 CLI 配置
struct CLIHookConfig {
    let name: String            // 内部标识: "claude-code", "codex", "trae-cli"
    let displayName: String     // 显示名称: "Claude Code", "OpenAI Codex", "Trae CLI"
    let icon: String            // emoji
    let settingsPath: String    // 配置文件路径 (~ 会被展开)
    let hookEvents: [String]    // 需要注册的事件
    let matcher: String         // JSON 写入时的 matcher 值：Claude Code 用 glob "*"；Codex 用正则 ".*"
    let configFormat: ConfigFormat // 配置文件格式
    let hidden: Bool            // true = 不在 Settings / Onboarding / 批量更新里曝光（保留元数据用）

    enum ConfigFormat {
        case json   // Claude Code, Codex
        case yaml   // Trae CLI (Coco)
    }

    init(name: String, displayName: String, icon: String, settingsPath: String,
         hookEvents: [String], matcher: String = "*", configFormat: ConfigFormat = .json,
         hidden: Bool = false) {
        self.name = name
        self.displayName = displayName
        self.icon = icon
        self.settingsPath = settingsPath
        self.hookEvents = hookEvents
        self.matcher = matcher
        self.configFormat = configFormat
        self.hidden = hidden
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
                "UserPromptSubmit", "SessionStart",
                "PreToolUse", "PostToolUse",
                "Stop",
            ],
            // Codex matcher 是正则，glob "*" 不是合法量词；用 ".*" 做"匹配任意工具"
            matcher: ".*"
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
            ],
            // 暂未完成端到端验证——先从 UI / Onboarding / 批量更新里隐藏，代码保留以便后续放出
            hidden: true
        ),
        CLIHookConfig(
            name: "trae-cli",
            displayName: "Trae CLI",
            icon: "🦎",
            settingsPath: "~/.trae/traecli.yaml",
            hookEvents: [
                "session_start", "session_end",
                "user_prompt_submit",
                "pre_tool_use", "post_tool_use", "post_tool_use_failure",
                "pre_compact", "post_compact",
                "stop",
                "subagent_start", "subagent_stop",
                "notification", "permission_request",
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

    /// 已安装的 hook 是否需要升级。
    ///
    /// 检测逻辑：读两个文件首部的 `# notchikko-hook-version: N` 戳，与 bundle 里的版本比对。
    /// 任意文件缺失 / 缺戳 / 版本不一致 → outdated。覆盖：
    /// - 老版 inline Python（无戳）
    /// - .py 缺失（升级中断）
    /// - .sh 与 .py 版本不同步（只更新了一个）
    /// - 用户降级 app 但 hook 没回退
    /// - 用户手工乱改文件
    ///
    /// 返回 true → Settings 应提示用户重装 hook。
    var isInstalledHookOutdated: Bool {
        let shPath = hookDir.appendingPathComponent("notchikko-hook.sh").path
        let pyPath = hookDir.appendingPathComponent("notchikko-hook.py").path
        guard FileManager.default.fileExists(atPath: shPath) else {
            return false  // 全新用户，未装 hook — 不是"需要升级"
        }
        guard FileManager.default.fileExists(atPath: pyPath) else { return true }

        let installedSh = Self.readHookVersion(atPath: shPath)
        let installedPy = Self.readHookVersion(atPath: pyPath)
        let bundledSh = Self.bundleHookVersion(name: "notchikko-hook", ext: "sh")
        let bundledPy = Self.bundleHookVersion(name: "notchikko-hook", ext: "py")
        return installedSh != bundledSh || installedPy != bundledPy
    }

    /// 从 hook 文件首 5 行里抽取 `# notchikko-hook-version: N` 的 N。找不到返回 nil（视为旧版）。
    private static func readHookVersion(atPath path: String) -> Int? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parseHookVersion(content)
    }

    private static func bundleHookVersion(name: String, ext: String) -> Int? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseHookVersion(content)
    }

    private static func parseHookVersion(_ content: String) -> Int? {
        for line in content.split(separator: "\n").prefix(5) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            if let range = trimmed.range(of: "notchikko-hook-version:") {
                let tail = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                return Int(tail)
            }
        }
        return nil
    }

    /// 批量重装所有当前已安装的 CLI hooks（Settings 的 "Update All" 按钮用）
    func reinstallAllOutdatedHooks() {
        for cli in Self.supportedCLIs where !cli.hidden && isInstalled(for: cli) {
            do {
                try install(for: cli)
                Log("Reinstalled hook for \(cli.displayName)", tag: "HookInstaller")
            } catch {
                Log("Failed to reinstall hook for \(cli.displayName): \(error)",
                    tag: "HookInstaller", level: .error)
            }
        }
    }

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
        // Claude Code 的 matcher 是 glob（"*"），Codex 是正则（".*"）——由 cli.matcher 决定
        let defaultHookEntry: [String: Any] = [
            "matcher": cli.matcher,
            "hooks": [
                [
                    "type": "command",
                    "command": "\(hookScriptPath) \(cli.name)",
                ] as [String: Any]
            ]
        ]

        // PermissionRequest 需要长超时（阻塞等用户操作）
        let permissionHookEntry: [String: Any] = [
            "matcher": cli.matcher,
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

        let matchers = cli.hookEvents.map { "      - event: \($0)" }.joined(separator: "\n")

        if content.contains("\nhooks:") || content.hasPrefix("hooks:") {
            // ---- 文件已有 hooks: 字段 → 找到该列表末尾，把新条目插进去 ----
            let entry = [
                "    # Notchikko hook — visual pet indicator",
                "    - type: command",
                "      command: '\(hookScriptPath) \(cli.name)'",
                "      matchers:",
            ].joined(separator: "\n") + "\n" + matchers

            var lines = content.components(separatedBy: "\n")

            // 找到 "hooks:" 行
            guard let hooksIdx = lines.firstIndex(where: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed == "hooks:" || trimmed.hasPrefix("hooks:")
            }) else {
                // 不应该走到这里，但保底追加完整块
                content.append("\nhooks:\n" + entry + "\n")
                try content.write(to: settingsURL, atomically: true, encoding: .utf8)
                return
            }

            // 从 hooks: 的下一行开始，找到第一个非空 & 缩进 <= hooks: 本身的行 —— 即下一个顶级 key
            let hooksIndent = lines[hooksIdx].prefix(while: { $0 == " " || $0 == "\t" }).count
            var insertAt = lines.count // 默认：列表延伸到文件末尾
            for i in (hooksIdx + 1)..<lines.count {
                let line = lines[i]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                if indent <= hooksIndent {
                    insertAt = i
                    break
                }
            }

            // 在 insertAt 处插入新条目
            lines.insert(entry, at: insertAt)
            content = lines.joined(separator: "\n")
        } else {
            // ---- 文件没有 hooks: 字段 → 追加完整块 ----
            let hookBlock = [
                "",
                "hooks:",
                "    # Notchikko hook — visual pet indicator",
                "    - type: command",
                "      command: '\(hookScriptPath) \(cli.name)'",
                "      matchers:",
            ].joined(separator: "\n") + "\n" + matchers
            content.append(hookBlock)
        }

        // 确保文件以换行符结尾
        if !content.hasSuffix("\n") { content.append("\n") }
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
                // 安装时写的是 Claude Code 嵌套格式：顶层 entry = { matcher, hooks: [{ command: "...notchikko..." }] }
                // notchikko 字符串在内层 hooks[].command 里，顶层没有 "command" 字段。
                // 和 isInstalled 对齐：把整条 entry 序列化后搜子串，匹配任意嵌套深度。
                entries.removeAll { entry in
                    let jsonStr = (try? JSONSerialization.data(withJSONObject: entry))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    return jsonStr.contains("notchikko")
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

        // 找到包含 "notchikko" 的 hook 条目块并完整移除。
        // 每个条目以 "- type: command" 开头（缩进 4 格），
        // 其上可能有一行 # 注释，其下的续行缩进更深。
        var lines = content.components(separatedBy: "\n")
        var indicesToRemove = IndexSet()

        for (i, line) in lines.enumerated() {
            guard line.contains("notchikko") else { continue }

            // 向上找到这个条目的起始行 ("- type:")
            var blockStart = i
            for j in stride(from: i - 1, through: 0, by: -1) {
                let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if trimmed.hasPrefix("- type:") {
                    blockStart = j
                    break
                }
                if trimmed.hasPrefix("#") {
                    // 可能是此条目的注释，继续向上看
                    blockStart = j
                    continue
                }
                break
            }
            // 也移除 blockStart 上方紧邻的 Notchikko 注释行
            if blockStart > 0 {
                let above = lines[blockStart - 1].trimmingCharacters(in: .whitespaces)
                if above.hasPrefix("#") && above.contains("Notchikko") {
                    blockStart -= 1
                }
            }

            // 向下找到条目结束：从 "- type:" 行的缩进开始，后续缩进更深的行都属于此条目
            let anchorLine = lines[min(blockStart, lines.count - 1)]
            let anchorIndent = anchorLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            var blockEnd = blockStart
            for j in (blockStart + 1)..<lines.count {
                let l = lines[j]
                if l.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let indent = l.prefix(while: { $0 == " " || $0 == "\t" }).count
                if indent <= anchorIndent { break }
                blockEnd = j
            }

            for idx in blockStart...blockEnd {
                indicesToRemove.insert(idx)
            }
        }

        // 从后往前删除
        for i in indicesToRemove.reversed() {
            lines.remove(at: i)
        }

        content = lines.joined(separator: "\n")
        if !content.hasSuffix("\n") && !content.isEmpty { content.append("\n") }
        try content.write(to: settingsURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Private

    private func installHookScript() throws {
        try FileManager.default.createDirectory(at: hookDir, withIntermediateDirectories: true)

        // 从 v2 开始分成两个文件：.sh 是薄 wrapper，.py 是 Python 主体
        // (避免"bash 里塞 inline python + f-string 引号打架"的历史坑)
        try copyBundleResource(name: "notchikko-hook", ext: "sh",
                               to: hookDir.appendingPathComponent("notchikko-hook.sh"),
                               executable: true)
        try copyBundleResource(name: "notchikko-hook", ext: "py",
                               to: hookDir.appendingPathComponent("notchikko-hook.py"),
                               executable: false)
    }

    private func copyBundleResource(name: String, ext: String, to dest: URL, executable: Bool) throws {
        guard let bundleURL = Bundle.main.url(forResource: name, withExtension: ext) else {
            throw HookError.scriptNotFound
        }
        // 总是覆盖（确保最新版本）
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: bundleURL, to: dest)

        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: dest.path
            )
        }
    }

    private func expandPath(_ path: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    enum HookError: Error {
        case scriptNotFound
    }
}
