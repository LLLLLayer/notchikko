import Foundation

@MainActor @Observable
final class SessionManager {
    private(set) var currentState: NotchikkoState = .sleeping
    private(set) var sessions: [String: SessionInfo] = [:]

    /// nil = 自动跟踪最新活跃 session
    var pinnedSessionId: String? = nil

    private var idleTimer: Task<Void, Never>?
    private var sleepTimer: Task<Void, Never>?
    private var returnTimer: Task<Void, Never>?

    struct SessionInfo {
        let id: String
        let cwd: String
        let source: String       // CLI 来源: "claude-code", "codex"
        var lastEvent: Date
        var phase: SessionPhase

        var cwdName: String {
            (cwd as NSString).lastPathComponent
        }

        var phaseDisplayName: String {
            switch phase {
            case .waitingForInput: return "idle"
            case .processing: return "thinking"
            case .runningTool(let t): return t.lowercased()
            case .compacting: return "sweeping"
            case .ended: return "ended"
            }
        }
    }

    enum SessionPhase: Equatable {
        case waitingForInput
        case processing
        case runningTool(String)
        case compacting
        case ended
    }

    // MARK: - 当前活跃 session

    /// 当前展示的 session（pinned 优先，否则最新活跃）
    var activeSessionId: String? {
        if let pinned = pinnedSessionId, sessions[pinned] != nil,
           sessions[pinned]?.phase != .ended {
            return pinned
        }
        return sessions.values
            .filter { $0.phase != .ended }
            .max(by: { $0.lastEvent < $1.lastEvent })?.id
    }

    /// 活跃 session 列表（供右键菜单用，按最近活跃排序）
    var activeSessions: [SessionInfo] {
        sessions.values
            .filter { $0.phase != .ended }
            .sorted { $0.lastEvent > $1.lastEvent }
    }

    // MARK: - 绑定切换

    func pinSession(_ sessionId: String?) {
        pinnedSessionId = sessionId
        // 切换绑定后，立即根据目标 session 的 phase 更新状态
        if let sid = activeSessionId, let session = sessions[sid] {
            currentState = stateForPhase(session.phase)
        } else {
            currentState = .sleeping
        }
        resetTimers()
    }

    // MARK: - 事件处理

    func handleEvent(_ event: AgentEvent) {
        print("[SessionManager] handleEvent: \(event), activeSessionId=\(activeSessionId ?? "nil"), currentState=\(currentState)")
        let eventSessionId = sessionIdOf(event)

        // 收到未知 session 的事件时自动创建（应对中途安装 hook 的场景）
        ensureSession(event)

        switch event {
        case .sessionStart(let sid, let cwd, let source):
            sessions[sid] = SessionInfo(
                id: sid, cwd: cwd, source: source,
                lastEvent: Date(), phase: .waitingForInput
            )
            if eventSessionId == activeSessionId || activeSessionId == nil {
                resetTimers()
                transition(to: .idle)
            }

        case .prompt(let sid):
            sessions[sid]?.phase = .processing
            sessions[sid]?.lastEvent = Date()
            if sid == activeSessionId {
                resetTimers()
                transition(to: .thinking)
            }

        case .toolUse(let sid, let tool, let phase):
            switch phase {
            case .pre:
                sessions[sid]?.phase = .runningTool(tool)
                sessions[sid]?.lastEvent = Date()
                if sid == activeSessionId {
                    resetTimers()
                    transition(to: stateForTool(tool))
                }
            case .post(let success):
                sessions[sid]?.lastEvent = Date()
                if sid == activeSessionId && !success {
                    resetTimers()
                    transition(to: .error)
                    scheduleReturn(to: .idle, delay: 5.0)
                }
            }

        case .stop(let sid):
            sessions[sid]?.phase = .waitingForInput
            sessions[sid]?.lastEvent = Date()
            if sid == activeSessionId {
                resetTimers()
                transition(to: .happy)
                scheduleReturn(to: .idle, delay: 3.0)
            }

        case .error(let sid, _):
            sessions[sid]?.lastEvent = Date()
            if sid == activeSessionId {
                resetTimers()
                transition(to: .error)
                scheduleReturn(to: .idle, delay: 5.0)
            }

        case .compact(let sid):
            sessions[sid]?.phase = .compacting
            sessions[sid]?.lastEvent = Date()
            if sid == activeSessionId {
                resetTimers()
                transition(to: .sweeping)
            }

        case .sessionEnd(let sid):
            sessions[sid]?.phase = .ended
            // 如果绑定的 session 结束了，自动解绑
            if pinnedSessionId == sid {
                pinnedSessionId = nil
            }
            // 延迟移除，让菜单有时间看到 ended 状态
            let capturedSid = sid
            Task {
                try? await Task.sleep(for: .seconds(3))
                sessions.removeValue(forKey: capturedSid)
            }
            // 如果还有活跃 session，切换到最新的
            if let nextActive = activeSessionId, let session = sessions[nextActive] {
                currentState = stateForPhase(session.phase)
            } else if activeSessions.isEmpty {
                transition(to: .sleeping)
            }

        case .notification:
            break
        }
    }

    // MARK: - Tool → State 映射

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

    private func stateForPhase(_ phase: SessionPhase) -> NotchikkoState {
        switch phase {
        case .waitingForInput: return .idle
        case .processing: return .thinking
        case .runningTool(let tool): return stateForTool(tool)
        case .compacting: return .sweeping
        case .ended: return .sleeping
        }
    }

    // MARK: - 外部控制

    /// 直接设置状态（拖拽等外部控制用）
    func overrideState(_ state: NotchikkoState) {
        currentState = state
    }

    // MARK: - 内部

    /// 确保 session 存在，不存在则自动创建
    private func ensureSession(_ event: AgentEvent) {
        let sid = sessionIdOf(event)
        if case .sessionEnd = event { return }
        if sessions[sid] != nil { return }

        // 从 sessionStart 中提取 cwd 和 source
        var cwd = ""
        var source = "unknown"
        if case .sessionStart(_, let c, let s) = event {
            cwd = c
            source = s
        }

        sessions[sid] = SessionInfo(
            id: sid, cwd: cwd, source: source,
            lastEvent: Date(), phase: .waitingForInput
        )
        print("[SessionManager] Auto-created session \(sid.prefix(8))")
    }

    private func sessionIdOf(_ event: AgentEvent) -> String {
        switch event {
        case .sessionStart(let sid, _, _): return sid
        case .sessionEnd(let sid): return sid
        case .prompt(let sid): return sid
        case .toolUse(let sid, _, _): return sid
        case .notification(let sid, _): return sid
        case .compact(let sid): return sid
        case .stop(let sid): return sid
        case .error(let sid, _): return sid
        }
    }

    private func transition(to newState: NotchikkoState) {
        guard newState.priority >= currentState.priority
            || currentState == .idle
            || currentState == .sleeping else {
            return
        }
        let oldState = currentState
        currentState = newState
        if oldState != newState {
            SoundManager.shared.play(for: newState.soundKey)
        }
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
