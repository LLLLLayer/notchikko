import Foundation

final class ClaudeCodeAdapter: AgentBridge {
    let socketServerRef = SocketServer()
    private var continuation: AsyncStream<AgentEvent>.Continuation?

    private var knownSessions: Set<String> = []

    /// 终端 PID 更新回调
    var onTerminalPidUpdate: ((String, Int) -> Void)?
    /// 终端 tty 更新回调
    var onTerminalTtyUpdate: ((String, String) -> Void)?
    /// permission_mode 更新回调
    var onPermissionModeUpdate: ((String, String) -> Void)?

    lazy var eventStream: AsyncStream<AgentEvent> = {
        AsyncStream { [weak self] continuation in
            self?.continuation = continuation
            self?.socketServerRef.onEvent = { hookEvent in
                guard let self else { return }
                // 首次见到的 session，自动补发一个 sessionStart（带 cwd/source）
                if !self.knownSessions.contains(hookEvent.sessionId) {
                    self.knownSessions.insert(hookEvent.sessionId)
                    if hookEvent.event != "SessionStart" {
                        let syntheticStart = AgentEvent.sessionStart(
                            sessionId: hookEvent.sessionId,
                            cwd: hookEvent.cwd,
                            source: hookEvent.source ?? "claude-code",
                            terminalPid: hookEvent.terminalPid
                        )
                        continuation.yield(syntheticStart)
                    }
                }
                if let agentEvent = Self.convert(hookEvent) {
                    continuation.yield(agentEvent)
                }

                // 每个事件都可能携带 terminalPid/tty/permissionMode，通知更新
                let sid = hookEvent.sessionId
                let tPid = hookEvent.terminalPid
                let tTty = hookEvent.terminalTty
                let pMode = hookEvent.permissionMode
                if tPid != nil || tTty != nil || pMode != nil {
                    let pidCb = self.onTerminalPidUpdate
                    let ttyCb = self.onTerminalTtyUpdate
                    let modeCb = self.onPermissionModeUpdate
                    DispatchQueue.main.async {
                        if let tPid { pidCb?(sid, tPid) }
                        if let tTty { ttyCb?(sid, tTty) }
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
            return .sessionStart(sessionId: hook.sessionId, cwd: hook.cwd, source: hook.source ?? "claude-code", terminalPid: hook.terminalPid)
        case "SessionEnd":
            return .sessionEnd(sessionId: hook.sessionId)
        case "UserPromptSubmit":
            return .prompt(sessionId: hook.sessionId, text: hook.prompt)
        case "PreToolUse":
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
            return .stop(sessionId: hook.sessionId)
        case "StopFailure":
            return .error(sessionId: hook.sessionId, message: "Task failed")
        case "SubagentStart", "SubagentStop":
            return nil  // Subagent 生命周期不影响主状态
        case "Notification":
            return .notification(sessionId: hook.sessionId, message: "")
        case "Elicitation", "PermissionRequest":
            // AskUserQuestion / 权限请求 → 等待用户操作
            return .notification(sessionId: hook.sessionId, message: hook.event)
        case "WorktreeCreate":
            return .prompt(sessionId: hook.sessionId, text: nil)
        default:
            return .notification(sessionId: hook.sessionId, message: hook.event)
        }
    }
}
