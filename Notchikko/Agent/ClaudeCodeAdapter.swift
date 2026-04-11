import Foundation

final class ClaudeCodeAdapter: AgentBridge {
    let agentName = "Claude Code"
    private let socketServer = SocketServer()
    private var continuation: AsyncStream<AgentEvent>.Continuation?

    lazy var eventStream: AsyncStream<AgentEvent> = {
        AsyncStream { [weak self] continuation in
            self?.continuation = continuation
            self?.socketServer.onEvent = { hookEvent in
                let agentEvent = Self.convert(hookEvent)
                continuation.yield(agentEvent)
            }
        }
    }()

    func start() async throws {
        socketServer.start()
    }

    func stop() async {
        socketServer.stop()
        continuation?.finish()
    }

    private static func convert(_ hook: HookEvent) -> AgentEvent {
        switch hook.event {
        case "SessionStart":
            return .sessionStart(sessionId: hook.sessionId, cwd: hook.cwd)
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
