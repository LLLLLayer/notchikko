import Foundation

/// JSONL 转录回退。当 hook 不可用时，通过轮询 CLI 转录文件推导 Agent 状态。
/// 回退模式不支持审批（JSONL 只读）和终端跳转（无 PID/tty 信息）。
@MainActor
final class TranscriptPoller {
    /// 推导出的事件回调（注入到 SessionManager.handleEvent）
    var onEvent: ((AgentEvent) -> Void)?
    /// 新 session 发现回调（用于标记 detection = .transcript）
    var onSessionDiscovered: ((String) -> Void)?

    private var isRunning = false
    private var pollTask: Task<Void, Never>?
    /// 文件读取光标（只增量读取新行）
    private var fileOffsets: [String: UInt64] = [:]
    /// 已通过转录发现的 session IDs
    private var knownTranscriptSessions: Set<String> = []

    /// Hook 管理的 session IDs（跳过这些，由 AppDelegate 同步）
    var hookSessionIds: Set<String> = []

    private static let pollInterval: TimeInterval = 5
    /// 只处理近 5 分钟内修改的文件
    private nonisolated static let recentThreshold: TimeInterval = 300

    private nonisolated static var claudeProjectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }
    private nonisolated static var codexSessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Log("TranscriptPoller started", tag: "Transcript")

        pollTask = Task {
            while !Task.isCancelled {
                await scanAndProcess()
                try? await Task.sleep(for: .seconds(Self.pollInterval))
            }
        }
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        Log("TranscriptPoller stopped", tag: "Transcript")
    }

    /// Hook session 注册后，合并对应的 transcript session
    func mergeWithHookSession(_ sessionId: String) {
        knownTranscriptSessions.remove(sessionId)
    }

    // MARK: - 扫描

    private func scanAndProcess() async {
        // 在后台线程扫描文件系统（避免阻塞主线程）
        let results = await Task.detached { Self.scanFiles() }.value

        // 回到 MainActor 处理结果
        for result in results {
            guard !hookSessionIds.contains(result.sessionId) else { continue }
            processJsonlResult(result)
        }

        // 清理不再活跃的文件偏移（超过 recentThreshold 的文件已不再扫描）
        let activeFiles = Set(results.map(\.path))
        for path in fileOffsets.keys where !activeFiles.contains(path) {
            fileOffsets.removeValue(forKey: path)
        }
    }

    /// 后台线程扫描 — 收集需要处理的文件信息
    private nonisolated static func scanFiles() -> [FileResult] {
        var results: [FileResult] = []
        scanClaudeProjects(into: &results)
        scanCodexSessions(into: &results)
        return results
    }

    /// Claude Code 把绝对路径的 `/` 编码成 `-` 当项目目录名（`/Users/a/b` → `-Users-a-b`）。
    /// 尝试还原；若还原后的路径存在则使用，否则保留原名（含 `-` 的真实目录名无法无损还原）。
    private nonisolated static func decodeClaudeProjectDir(_ name: String) -> String {
        guard name.hasPrefix("-") else { return name }
        let candidate = name.replacingOccurrences(of: "-", with: "/")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
            return candidate
        }
        return name
    }

    private nonisolated static func scanClaudeProjects(into results: inout [FileResult]) {
        let dir = claudeProjectsDir
        guard FileManager.default.fileExists(atPath: dir.path) else { return }

        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return }

        for projectDir in projects {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }

            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ) else { continue }

            let decodedCwd = decodeClaudeProjectDir(projectDir.lastPathComponent)
            for file in files where file.pathExtension == "jsonl" {
                guard isRecentlyModified(file) else { continue }
                let sessionId = file.deletingPathExtension().lastPathComponent
                results.append(FileResult(
                    path: file.path, sessionId: sessionId,
                    source: "claude-code", cwd: decodedCwd
                ))
            }
        }
    }

    private nonisolated static func scanCodexSessions(into results: inout [FileResult]) {
        let dir = codexSessionsDir
        guard FileManager.default.fileExists(atPath: dir.path) else { return }

        let cal = Calendar.current
        let today = Date()
        for dayOffset in 0...1 {
            guard let date = cal.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            let y = cal.component(.year, from: date)
            let m = String(format: "%02d", cal.component(.month, from: date))
            let d = String(format: "%02d", cal.component(.day, from: date))
            let dayDir = dir.appendingPathComponent("\(y)/\(m)/\(d)")

            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dayDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" && file.lastPathComponent.hasPrefix("rollout-") {
                guard isRecentlyModified(file) else { continue }
                let sessionId = file.deletingPathExtension().lastPathComponent
                results.append(FileResult(
                    path: file.path, sessionId: sessionId,
                    source: "codex", cwd: ""
                ))
            }
        }
    }

    // MARK: - JSONL 处理（MainActor）

    private func processJsonlResult(_ result: FileResult) {
        let path = result.path

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64 else { return }

        let lastOffset = fileOffsets[path] ?? 0

        // 文件被截断 → 从头读取（下一轮 poll 再处理新内容，避免本轮触发 sessionStart 重放）
        if fileSize < lastOffset {
            Log("Transcript file truncated (was \(lastOffset), now \(fileSize)): \(result.sessionId.prefix(8))", tag: "Transcript")
            fileOffsets[path] = 0
            return
        }

        guard fileSize > lastOffset else { return }

        // 新 session → emit sessionStart
        if !knownTranscriptSessions.contains(result.sessionId) {
            knownTranscriptSessions.insert(result.sessionId)
            onEvent?(.sessionStart(sessionId: result.sessionId, cwd: result.cwd,
                                   source: result.source, terminalPid: nil, pidChain: nil))
            onSessionDiscovered?(result.sessionId)
            Log("Transcript session discovered: \(result.sessionId.prefix(8)), source=\(result.source)", tag: "Transcript")
        }

        // 增量读取全部新增内容，按 chunk 解析避免单次分配过大
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        handle.seek(toFileOffset: lastOffset)

        let chunkSize = 256 * 1024
        var remaining = Int(fileSize - lastOffset)
        var leftover = Data()
        var lastEvent: AgentEvent?

        while remaining > 0 {
            let toRead = min(remaining, chunkSize)
            var chunk = handle.readData(ofLength: toRead)
            remaining -= chunk.count
            if chunk.isEmpty { break }

            if !leftover.isEmpty {
                leftover.append(chunk)
                chunk = leftover
                leftover = Data()
            }

            // 以最后一个换行符为界，未完整的行留到下一 chunk 拼接
            let newline = UInt8(ascii: "\n")
            if let lastNL = chunk.lastIndex(of: newline) {
                let completeRange = chunk.startIndex...lastNL
                let complete = chunk[completeRange]
                let tailStart = chunk.index(after: lastNL)
                if tailStart < chunk.endIndex {
                    leftover = chunk[tailStart..<chunk.endIndex]
                }
                if let text = String(data: complete, encoding: .utf8) {
                    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                        if let event = parseJsonlLine(String(line), sessionId: result.sessionId) {
                            lastEvent = event
                        }
                    }
                }
            } else {
                // 整个 chunk 都没有换行（极罕见的超长单行），继续累积
                leftover = chunk
            }
        }

        // 尾部未闭合的行暂不消费；offset 只前进到已消费行末尾，剩余部分下轮再读
        let consumed = fileSize - UInt64(leftover.count)
        fileOffsets[path] = consumed

        if let event = lastEvent {
            onEvent?(event)
        }
    }

    // MARK: - JSONL 解析

    private func parseJsonlLine(_ line: String, sessionId: String) -> AgentEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let type = json["type"] as? String ?? ""

        switch type {
        case "assistant":
            return parseAssistant(json, sessionId: sessionId)
        case "user":
            return parseUser(json, sessionId: sessionId)
        case "system":
            if (json["subtype"] as? String) == "turn_duration" {
                return .stop(sessionId: sessionId, usage: nil)
            }
            return nil
        default:
            return nil
        }
    }

    /// assistant 消息 → 检查 content blocks 中的 tool_use 或 text
    private func parseAssistant(_ json: [String: Any], sessionId: String) -> AgentEvent? {
        let blocks = contentBlocks(from: json)

        // tool_use block → 工具调用（取最后一个 tool_use）
        for block in blocks.reversed() {
            if (block["type"] as? String) == "tool_use",
               let toolName = block["name"] as? String {
                return .toolUse(sessionId: sessionId, tool: toolName, phase: .pre)
            }
        }

        // 纯文本 → LLM 正在生成
        return .prompt(sessionId: sessionId, text: nil)
    }

    /// user 消息 → 新 prompt（排除 tool_result）
    private func parseUser(_ json: [String: Any], sessionId: String) -> AgentEvent? {
        let blocks = contentBlocks(from: json)

        // 包含 tool_result → 工具结果回传，不是用户 prompt
        for block in blocks {
            if (block["type"] as? String) == "tool_result" {
                return nil
            }
        }

        // 提取 prompt 文本
        var promptText: String?
        if let text = json["content"] as? String {
            promptText = text
        } else {
            for block in blocks {
                if (block["type"] as? String) == "text",
                   let text = block["text"] as? String {
                    promptText = text
                    break
                }
            }
        }

        return .prompt(sessionId: sessionId, text: promptText)
    }

    /// 从 JSON 中提取 content blocks（支持 message.content 和 content 两种格式）
    private func contentBlocks(from json: [String: Any]) -> [[String: Any]] {
        if let message = json["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            return content
        }
        if let content = json["content"] as? [[String: Any]] {
            return content
        }
        return []
    }

    // MARK: - Types

    private struct FileResult: Sendable {
        let path: String
        let sessionId: String
        let source: String
        let cwd: String
    }

    private nonisolated static func isRecentlyModified(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modDate) < recentThreshold
    }
}
