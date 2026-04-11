import Foundation

final class ClaudeCodeAdapter: AgentBridge {
    let agentName = "Claude Code"
    let agentIcon = "🤖"
    let socketServerRef = SocketServer()
    private var continuation: AsyncStream<AgentEvent>.Continuation?

    private var knownSessions: Set<String> = []

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
                            source: hookEvent.source ?? "claude-code"
                        )
                        continuation.yield(syntheticStart)
                    }
                }
                let agentEvent = Self.convert(hookEvent)
                continuation.yield(agentEvent)
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

    private static func convert(_ hook: HookEvent) -> AgentEvent {
        switch hook.event {
        case "SessionStart":
            return .sessionStart(sessionId: hook.sessionId, cwd: hook.cwd, source: hook.source ?? "claude-code")
        case "SessionEnd":
            return .sessionEnd(sessionId: hook.sessionId)
        case "UserPromptSubmit":
            return .prompt(sessionId: hook.sessionId)
        case "PreToolUse":
            return .toolUse(sessionId: hook.sessionId, tool: hook.tool ?? "", phase: .pre)
        case "PostToolUse":
            let success = hook.status != "error"
            return .toolUse(sessionId: hook.sessionId, tool: hook.tool ?? "", phase: .post(success: success))
        case "PreCompact":
            return .compact(sessionId: hook.sessionId)
        case "Stop":
            return .stop(sessionId: hook.sessionId)
        case "StopFailure":
            return .error(sessionId: hook.sessionId, message: "Task failed")
        case "Notification":
            return .notification(sessionId: hook.sessionId, message: "")
        default:
            return .prompt(sessionId: hook.sessionId)
        }
    }
}
