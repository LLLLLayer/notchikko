import Foundation

@MainActor @Observable
final class ApprovalManager {
    /// 所有待审批请求（requestId → request），每张卡片独立闭环
    private(set) var pendingApprovals: [String: ApprovalRequest] = [:]

    private var hideTimers: [String: Task<Void, Never>] = [:]
    private var staleTimers: [String: Task<Void, Never>] = [:]
    private weak var socketServer: SocketServer?

    /// 已设为"全部允许"的 session（session 维度，不持久化）
    private var autoApprovedSessions: Set<String> = []

    /// 已设为"始终允许"的 tool（session × tool 维度）
    private var autoApprovedTools: [String: Set<String>] = [:]

    /// 卡片移除回调（AppDelegate 注入，用于关闭对应 NSPanel）
    var onCardDismissed: ((String) -> Void)?
    /// 全部移除回调（Allow All / Auto Approve 时）
    var onAllCardsDismissed: (() -> Void)?

    struct ApprovalRequest: Identifiable {
        let id: String             // 同 requestId，用于卡片标识
        let requestId: String
        let source: String
        let tool: String
        let input: String
        let sessionId: String
        let cwdName: String
        let terminalName: String
        let timestamp: Date
        var isVisible: Bool = true

        /// 通知类卡片（无 requestId，不阻塞 CLI）
        var isNotification: Bool { requestId.isEmpty }
    }

    init(socketServer: SocketServer) {
        self.socketServer = socketServer
    }

    // MARK: - 请求处理

    func handleApprovalRequest(from hookEvent: HookEvent, session: SessionManager.SessionInfo?) {
        let requestId = hookEvent.requestId ?? ""
        Log("handleApproval: tool=\(hookEvent.tool ?? "?"), sid=\(hookEvent.sessionId.prefix(8)), reqId=\(requestId.prefix(8))", tag: "Approval")

        // 如果该 session 已设为"全部允许"，直接放行
        if autoApprovedSessions.contains(hookEvent.sessionId) {
            let response: [String: Any] = ["request_id": requestId, "decision": "allow"]
            if let data = try? JSONSerialization.data(withJSONObject: response) {
                socketServer?.respond(requestId: requestId, json: data)
            }
            SoundManager.shared.play(for: "nod")
            return
        }

        // 如果该 tool 已被"始终允许"，直接放行
        let toolName = hookEvent.tool ?? ""
        if let approvedTools = autoApprovedTools[hookEvent.sessionId], approvedTools.contains(toolName) {
            Log("Auto-allowed tool '\(toolName)' for session \(hookEvent.sessionId.prefix(8))", tag: "Approval")
            let response: [String: Any] = ["request_id": requestId, "decision": "allow"]
            if let data = try? JSONSerialization.data(withJSONObject: response) {
                socketServer?.respond(requestId: requestId, json: data)
            }
            SoundManager.shared.play(for: "nod")
            return
        }

        let toolInput = hookEvent.toolInput?.values.first.flatMap { value -> String? in
            if case .string(let s) = value { return s }
            return nil
        } ?? ""

        let request = ApprovalRequest(
            id: requestId.isEmpty ? UUID().uuidString : requestId,
            requestId: requestId,
            source: hookEvent.source ?? "unknown",
            tool: hookEvent.tool ?? "",
            input: String(toolInput.prefix(500)),
            sessionId: hookEvent.sessionId,
            cwdName: session?.cwdName ?? "",
            terminalName: session?.matchedTerminal?.appName ?? "",
            timestamp: Date()
        )

        pendingApprovals[request.id] = request
        startHideTimer(for: request.id)
        if !request.isNotification {
            startStaleTimer(for: request.id)
        }
    }

    /// 添加通知类卡片（Elicitation / AskUserQuestion）
    func addNotification(_ request: ApprovalRequest) {
        Log("addNotification: tool=\(request.tool), sid=\(request.sessionId.prefix(8)), id=\(request.id.prefix(8))", tag: "Approval")
        pendingApprovals[request.id] = request
        startHideTimer(for: request.id)
        // 通知卡片兜底：60s 后自动清理（不阻塞 CLI，无需等 300s）
        let notifId = request.id
        staleTimers[notifId]?.cancel()
        staleTimers[notifId] = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            pendingApprovals.removeValue(forKey: notifId)
            cleanupTimers(for: notifId)
            onCardDismissed?(notifId)
        }
    }

    // MARK: - 审批操作（每个操作都指定 requestId）

    func approve(requestId: String) {
        Log("approve: \(requestId.prefix(8))", tag: "Approval")
        guard let req = pendingApprovals[requestId] else { return }
        let response: [String: Any] = [
            "request_id": req.requestId,
            "decision": "allow",
        ]
        sendResponse(response, for: req)
        dismiss(requestId: requestId)
        SoundManager.shared.play(for: "nod")
    }

    func deny(requestId: String) {
        Log("deny: \(requestId.prefix(8))", tag: "Approval")
        guard let req = pendingApprovals[requestId] else { return }
        let response: [String: Any] = [
            "request_id": req.requestId,
            "decision": "deny",
            "reason": "Denied by Notchikko",
        ]
        sendResponse(response, for: req)
        dismiss(requestId: requestId)
        SoundManager.shared.play(for: "shake")
    }

    /// 始终允许该 tool（session × tool 维度），放行当前请求
    func alwaysAllowTool(requestId: String) {
        guard let req = pendingApprovals[requestId] else { return }
        let sessionId = req.sessionId
        let tool = req.tool

        Log("alwaysAllowTool: tool=\(tool), sid=\(sessionId.prefix(8))", tag: "Approval")
        autoApprovedTools[sessionId, default: []].insert(tool)

        // 放行该 session 所有同类 tool 的待审批请求
        let sameToolRequests = pendingApprovals.values.filter {
            $0.sessionId == sessionId && $0.tool == tool && !$0.isNotification
        }
        for r in sameToolRequests {
            let response: [String: Any] = [
                "request_id": r.requestId,
                "decision": "allow",
            ]
            sendResponse(response, for: r)
            dismiss(requestId: r.id)
        }

        SoundManager.shared.play(for: "nod")
    }

    /// 自动批准：放行所有待审批 + 写 bypass 标记文件，hook 下次 PermissionRequest 时切换 Claude Code 到 bypassPermissions
    func autoApproveSession(requestId: String) {
        guard let req = pendingApprovals[requestId] else { return }
        let sessionId = req.sessionId

        Log("autoApproveSession: sid=\(sessionId.prefix(8))", tag: "Approval")
        autoApprovedSessions.insert(sessionId)

        // 写 bypass 标记文件，hook 脚本检测后输出 setMode: bypassPermissions
        writeBypassFlag(sessionId: sessionId)

        // 放行该 session 的所有待审批请求
        let sessionRequests = pendingApprovals.values.filter {
            $0.sessionId == sessionId && !$0.isNotification
        }
        for r in sessionRequests {
            let response: [String: Any] = [
                "request_id": r.requestId,
                "decision": "allow",
            ]
            sendResponse(response, for: r)
        }

        // 清除该 session 的所有卡片（包括通知卡片）
        let allSessionIds = pendingApprovals.values
            .filter { $0.sessionId == sessionId }
            .map { $0.id }
        for id in allSessionIds {
            cleanupTimers(for: id)
            pendingApprovals.removeValue(forKey: id)
        }

        SoundManager.shared.play(for: "nod")
        onAllCardsDismissed?()
    }

    // MARK: - Bypass Flag

    /// 写 bypass 标记文件供 hook 脚本读取（~/.notchikko/bypass-flags/{sessionId}）
    private func writeBypassFlag(sessionId: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notchikko/bypass-flags")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let flagPath = dir.appendingPathComponent(sessionId).path
        FileManager.default.createFile(atPath: flagPath, contents: Data())
    }

    // MARK: - 卡片显示控制

    func onMouseEnter(requestId: String) {
        guard pendingApprovals[requestId] != nil else { return }
        pendingApprovals[requestId]?.isVisible = true
        hideTimers[requestId]?.cancel()
        hideTimers[requestId] = nil
    }

    func onMouseExit(requestId: String) {
        guard pendingApprovals[requestId] != nil else { return }
        startHideTimer(for: requestId)
    }

    /// Session 结束时清理会话级状态（auto-approve 列表 + bypass flag 文件）
    func cleanupSession(_ sessionId: String) {
        autoApprovedSessions.remove(sessionId)
        autoApprovedTools.removeValue(forKey: sessionId)
        // 清理可能残留的 bypass flag 文件
        let flagDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notchikko/bypass-flags")
        let flagPath = flagDir.appendingPathComponent(sessionId).path
        try? FileManager.default.removeItem(atPath: flagPath)
    }

    /// 当收到同一 session 的后续事件时，说明审批已在 CLI 侧完成，清理该 session 的卡片
    func onSessionEvent(sessionId: String) {
        let toRemove = pendingApprovals.values.filter { $0.sessionId == sessionId }.map { $0.id }
        if !toRemove.isEmpty {
            Log("onSessionEvent: sid=\(sessionId.prefix(8)), clearing \(toRemove.count) card(s)", tag: "Approval")
        }
        for id in toRemove {
            dismiss(requestId: id)
        }
    }

    // MARK: - Private

    /// 关闭指定卡片（关闭按钮 = deny 审批卡，直接关闭通知卡）
    func closeCard(requestId: String) {
        guard let req = pendingApprovals[requestId] else { return }
        if req.isNotification {
            dismiss(requestId: requestId)
        } else {
            deny(requestId: requestId)
        }
    }

    private func dismiss(requestId: String) {
        Log("dismiss: \(requestId.prefix(8)), remaining=\(pendingApprovals.count - 1)", tag: "Approval")
        cleanupTimers(for: requestId)
        pendingApprovals.removeValue(forKey: requestId)
        onCardDismissed?(requestId)
    }

    private func cleanupTimers(for requestId: String) {
        hideTimers[requestId]?.cancel()
        hideTimers.removeValue(forKey: requestId)
        staleTimers[requestId]?.cancel()
        staleTimers.removeValue(forKey: requestId)
    }

    /// Hook 脚本有 300s 超时，超时后 hook 侧自动放行。
    /// App 侧也需要在同样时间后清理审批状态，避免卡片常驻。
    private func startStaleTimer(for requestId: String) {
        staleTimers[requestId]?.cancel()
        staleTimers[requestId] = Task {
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            // 超时：hook 侧已自动放行并关闭连接，app 侧也关闭对应 fd 防止泄漏
            if let req = pendingApprovals[requestId], !req.requestId.isEmpty {
                socketServer?.closePending(requestId: req.requestId)
            }
            pendingApprovals.removeValue(forKey: requestId)
            cleanupTimers(for: requestId)
            onCardDismissed?(requestId)
        }
    }

    private func startHideTimer(for requestId: String) {
        hideTimers[requestId]?.cancel()
        let delay = PreferencesStore.shared.preferences.approvalCardHideDelay
        guard delay > 0 else { return }
        hideTimers[requestId] = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            pendingApprovals[requestId]?.isVisible = false
        }
    }

    private func sendResponse(_ dict: [String: Any], for req: ApprovalRequest) {
        guard !req.requestId.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        socketServer?.respond(requestId: req.requestId, json: data)
    }
}
