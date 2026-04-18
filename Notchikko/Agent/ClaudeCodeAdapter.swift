import Foundation

final class ClaudeCodeAdapter: AgentBridge {
    let socketServerRef = SocketServer()
    private var continuation: AsyncStream<AgentEvent>.Continuation?

    private var knownSessions: Set<String> = []
    /// 每个 session 的 subagent 嵌套深度（>0 时抑制工具/状态事件）
    private var subagentDepth: [String: Int] = [:]
    /// 保护 knownSessions / subagentDepth 的并发访问（onEvent 在并发队列上调用）
    private let stateLock = NSLock()

    /// 指定 session 是否正在运行 subagent（depth > 0）
    func isInSubagent(sessionId: String) -> Bool {
        stateLock.lock()
        let depth = subagentDepth[sessionId] ?? 0
        stateLock.unlock()
        return depth > 0
    }

    /// Subagent 深度 >0 时仍需放行的事件类型
    private static let subagentPassthroughEvents: Set<String> = ["Elicitation", "AskUserQuestion"]

    /// 终端 PID 更新回调
    var onTerminalPidUpdate: ((String, Int) -> Void)?
    /// 终端 tty 更新回调
    var onTerminalTtyUpdate: ((String, String) -> Void)?
    /// PID 链更新回调（VS Code 终端定位）
    var onPidChainUpdate: ((String, [Int]) -> Void)?
    /// permission_mode 更新回调
    var onPermissionModeUpdate: ((String, String) -> Void)?

    lazy var eventStream: AsyncStream<AgentEvent> = {
        AsyncStream { [weak self] continuation in
            self?.continuation = continuation
            self?.socketServerRef.onEvent = { hookEvent in
                guard let self else { return }
                let sid = hookEvent.sessionId

                // 单次加锁：session 注册 + subagent 深度追踪
                self.stateLock.lock()
                let isNewSession = self.knownSessions.insert(sid).inserted
                var shouldEmitEvent = true
                switch hookEvent.event {
                case "SubagentStart":
                    self.subagentDepth[sid, default: 0] += 1
                    shouldEmitEvent = false
                case "SubagentStop":
                    self.subagentDepth[sid] = max((self.subagentDepth[sid] ?? 1) - 1, 0)
                    shouldEmitEvent = false
                default:
                    let depth = self.subagentDepth[sid] ?? 0
                    if depth > 0, !Self.subagentPassthroughEvents.contains(hookEvent.event) {
                        shouldEmitEvent = false
                    }
                }
                if hookEvent.event == "SessionEnd" {
                    self.subagentDepth.removeValue(forKey: sid)
                }
                self.stateLock.unlock()

                if isNewSession && hookEvent.event != "SessionStart" {
                    continuation.yield(.sessionStart(
                        sessionId: sid, cwd: hookEvent.cwd,
                        source: hookEvent.source ?? "claude-code",
                        terminalPid: hookEvent.terminalPid, pidChain: hookEvent.pidChain
                    ))
                }

                if shouldEmitEvent {
                    if let agentEvent = Self.convert(hookEvent) {
                        continuation.yield(agentEvent)
                    }
                }

                // 每个事件都可能携带 terminalPid/tty/permissionMode，通知更新
                let tPid = hookEvent.terminalPid
                let tTty = hookEvent.terminalTty
                let pMode = hookEvent.permissionMode
                let pChain = hookEvent.pidChain
                if tPid != nil || tTty != nil || pMode != nil || pChain != nil {
                    let pidCb = self.onTerminalPidUpdate
                    let ttyCb = self.onTerminalTtyUpdate
                    let chainCb = self.onPidChainUpdate
                    let modeCb = self.onPermissionModeUpdate
                    DispatchQueue.main.async {
                        if let tPid { pidCb?(sid, tPid) }
                        if let tTty { ttyCb?(sid, tTty) }
                        if let pChain, !pChain.isEmpty { chainCb?(sid, pChain) }
                        if let pMode { modeCb?(sid, pMode) }
                    }
                }
            }
        }
    }()

    func start() async throws {
        socketServerRef.start()
    }

    func stop() async {
        socketServerRef.stop()
        continuation?.finish()
    }

    private static func convert(_ hook: HookEvent) -> AgentEvent? {
        switch hook.event {
        case "SessionStart":
            return .sessionStart(sessionId: hook.sessionId, cwd: hook.cwd, source: hook.source ?? "claude-code", terminalPid: hook.terminalPid, pidChain: hook.pidChain)
        case "SessionEnd":
            return .sessionEnd(sessionId: hook.sessionId)
        case "UserPromptSubmit":
            return .prompt(sessionId: hook.sessionId, text: hook.prompt)
        case "PreToolUse":
            // AskUserQuestion 可能只走 PreToolUse（不走 PermissionRequest）
            // 此时弹非阻塞通知卡提醒用户回终端操作
            if hook.tool == "AskUserQuestion" {
                let detail = Self.extractAskUserDetail(from: hook.toolInput)
                return .notification(sessionId: hook.sessionId, message: "AskUserQuestion", detail: detail)
            }
            return .toolUse(sessionId: hook.sessionId, tool: hook.tool ?? "", phase: .pre)
        case "PostToolUse":
            let success = hook.status != "error"
            return .toolUse(sessionId: hook.sessionId, tool: hook.tool ?? "", phase: .post(success: success))
        case "PostToolUseFailure":
            return .toolUse(sessionId: hook.sessionId, tool: hook.tool ?? "", phase: .post(success: false))
        case "PreCompact":
            return .compact(sessionId: hook.sessionId)
        case "PostCompact":
            return .prompt(sessionId: hook.sessionId, text: nil)
        case "Stop":
            return .stop(sessionId: hook.sessionId, usage: hook.usage)
        case "StopFailure":
            return .error(sessionId: hook.sessionId, message: "Task failed")
        // SubagentStart/SubagentStop 已在 onEvent 闭包中处理（深度追踪），不会到达这里
        case "Notification":
            return .notification(sessionId: hook.sessionId, message: "")
        case "Elicitation":
            let detail = Self.extractElicitationDetail(from: hook.toolInput)
            return .notification(sessionId: hook.sessionId, message: hook.event, detail: detail)
        case "PermissionRequest":
            let detail = Self.extractPermissionDetail(from: hook)
            // AskUserQuestion 走 .notification（它的"问答"语义和审批不同）
            if hook.tool == "AskUserQuestion" {
                return .notification(sessionId: hook.sessionId, message: "AskUserQuestion", detail: detail)
            }
            // 此处只处理非阻塞的 PermissionRequest——阻塞式直通 onApprovalRequest，不走这条路径
            return .permissionRequest(sessionId: hook.sessionId, tool: hook.tool ?? "", detail: detail)
        case "AskUserQuestion":
            let detail = Self.extractAskUserDetail(from: hook.toolInput)
            return .notification(sessionId: hook.sessionId, message: hook.event, detail: detail)
        case "WorktreeCreate":
            return .prompt(sessionId: hook.sessionId, text: nil)
        default:
            Log("Unknown hook event: \(hook.event)", tag: "Adapter")
            return nil  // 忽略未知事件，避免产生垃圾通知卡片
        }
    }

    /// 从 PermissionRequest 中提取工具名和输入预览
    private static func extractPermissionDetail(from hook: HookEvent) -> String {
        // AskUserQuestion 可能以 PermissionRequest 到达，用专用解析
        if hook.tool == "AskUserQuestion" {
            let detail = extractAskUserDetail(from: hook.toolInput)
            if !detail.isEmpty { return detail }
        }

        var lines: [String] = []
        if let tool = hook.tool, !tool.isEmpty {
            lines.append("Tool: \(tool)")
        }
        if let toolInput = hook.toolInput {
            for key in ["command", "file_path", "path", "content", "description"] {
                if case .string(let val) = toolInput[key], !val.isEmpty {
                    let display = val.count > 200 ? String(val.prefix(200)) + "…" : val
                    lines.append(display)
                    break
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 从 Elicitation 中提取提示信息
    private static func extractElicitationDetail(from toolInput: [String: AnyCodableValue]?) -> String {
        guard let toolInput else { return "" }
        // message / description / question 字段
        for key in ["message", "description", "question"] {
            if case .string(let val) = toolInput[key], !val.isEmpty {
                return val.count > 300 ? String(val.prefix(300)) + "…" : val
            }
        }
        return ""
    }

    /// 从 AskUserQuestion 的 tool_input 中提取问题文本和选项
    private static func extractAskUserDetail(from toolInput: [String: AnyCodableValue]?) -> String {
        guard let toolInput else { return "" }

        // tool_input.question (简单文本问题)
        if case .string(let q) = toolInput["question"] {
            return q
        }

        // tool_input.questions (结构化问题列表)
        guard case .array(let questions) = toolInput["questions"] else { return "" }

        var lines: [String] = []
        for q in questions {
            guard case .object(let dict) = q else { continue }
            // 问题文本
            if case .string(let text) = dict["question"] {
                lines.append(text)
            }
            // 选项列表
            if case .array(let options) = dict["options"] {
                for opt in options {
                    if case .object(let optDict) = opt,
                       case .string(let label) = optDict["label"] {
                        lines.append("  · \(label)")
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
