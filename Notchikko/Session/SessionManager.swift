import Foundation

@MainActor @Observable
final class SessionManager {
    private(set) var currentState: NotchikkoState = .sleeping
    private(set) var sessions: [String: SessionInfo] = [:]

    private var idleTimer: Task<Void, Never>?
    private var sleepTimer: Task<Void, Never>?
    private var returnTimer: Task<Void, Never>?

    struct SessionInfo {
        let id: String
        let cwd: String
        var lastEvent: Date
        var phase: SessionPhase
    }

    enum SessionPhase {
        case waitingForInput
        case processing
        case runningTool(String)
        case compacting
        case ended
    }

    func handleEvent(_ event: AgentEvent) {
        resetTimers()

        switch event {
        case .sessionStart(let sid, let cwd):
            sessions[sid] = SessionInfo(id: sid, cwd: cwd, lastEvent: Date(), phase: .waitingForInput)
            transition(to: .idle)

        case .prompt(let sid):
            sessions[sid]?.phase = .processing
            sessions[sid]?.lastEvent = Date()
            transition(to: .thinking)

        case .toolUse(let sid, let tool, let phase):
            switch phase {
            case .pre:
                sessions[sid]?.phase = .runningTool(tool)
                sessions[sid]?.lastEvent = Date()
                transition(to: stateForTool(tool))
            case .post(let success):
                sessions[sid]?.lastEvent = Date()
                if !success {
                    transition(to: .error)
                    scheduleReturn(to: .idle, delay: 5.0)
                }
            }

        case .stop(let sid):
            sessions[sid]?.phase = .waitingForInput
            sessions[sid]?.lastEvent = Date()
            transition(to: .happy)
            scheduleReturn(to: .idle, delay: 3.0)

        case .error(let sid, _):
            sessions[sid]?.lastEvent = Date()
            transition(to: .error)
            scheduleReturn(to: .idle, delay: 5.0)

        case .compact(let sid):
            sessions[sid]?.phase = .compacting
            sessions[sid]?.lastEvent = Date()
            transition(to: .sweeping)

        case .sessionEnd(let sid):
            sessions.removeValue(forKey: sid)
            if sessions.isEmpty {
                transition(to: .sleeping)
            }

        case .notification:
            break
        }
    }

    private func stateForTool(_ tool: String) -> NotchikkoState {
        switch tool {
        case "Read", "Grep", "Glob":
            return .reading
        case "Edit", "Write", "NotebookEdit":
            return .typing
        case "Bash":
            return .building
        default:
            return .typing
        }
    }

    /// 直接设置状态（拖拽等外部控制用）
    func overrideState(_ state: NotchikkoState) {
        currentState = state
    }

    private func transition(to newState: NotchikkoState) {
        guard newState.priority >= currentState.priority
            || currentState == .idle
            || currentState == .sleeping else {
            return
        }
        currentState = newState
    }

    private func resetTimers() {
        idleTimer?.cancel()
        sleepTimer?.cancel()

        idleTimer = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            transition(to: .idle)
        }

        sleepTimer = Task {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            transition(to: .sleeping)
        }
    }

    private func scheduleReturn(to state: NotchikkoState, delay: TimeInterval) {
        returnTimer?.cancel()
        returnTimer = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            currentState = state
        }
    }
}
