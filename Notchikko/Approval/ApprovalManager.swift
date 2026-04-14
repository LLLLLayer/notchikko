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

        /// AskUserQuestion 的结构化问题数据
        var questions: [Question] = []

        /// 通知类卡片（无 requestId，不阻塞 CLI）
        var isNotification: Bool { requestId.isEmpty }
        /// 是否是可交互的 AskUserQuestion（有 requestId + 有 questions）
        var isAskUser: Bool { !requestId.isEmpty && !questions.isEmpty }

        struct Question {
            let text: String
            let options: [String]      // option labels
        }
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

        let toolInput = hookEvent.toolInput?.values.first.flatMap { value -> String? in
            if case .string(let s) = value { return s }
            return nil
        } ?? ""

        // 解析 AskUserQuestion 的结构化问题
        let questions: [ApprovalRequest.Question] = Self.parseQuestions(from: hookEvent.toolInput)

        // AskUserQuestion 显示问题文本，审批显示 tool input
        let displayInput: String
        if !questions.isEmpty {
            displayInput = questions.map { q in
                var lines = [q.text]
                lines += q.options.map { "  · \($0)" }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n")
        } else {
            displayInput = String(toolInput.prefix(500))
        }

        let request = ApprovalRequest(
            id: requestId.isEmpty ? UUID().uuidString : requestId,
            requestId: requestId,
            source: hookEvent.source ?? "unknown",
            tool: hookEvent.tool ?? "",
            input: displayInput,
            sessionId: hookEvent.sessionId,
            cwdName: session?.cwdName ?? "",
            terminalName: session?.matchedTerminal?.appName ?? "",
            timestamp: Date(),
            questions: questions
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

    /// 始终允许：放行当前请求 + 开 bypassPermissions（会话级）
    func alwaysAllowTool(requestId: String) {
        guard let req = pendingApprovals[requestId] else { return }
        Log("alwaysAllow: sid=\(req.sessionId.prefix(8))", tag: "Approval")
        autoApprovedSessions.insert(req.sessionId)

        // 直接在本次响应里带 bypass=true，hook 输出 setMode: bypassPermissions
        let response: [String: Any] = [
            "request_id": req.requestId,
            "decision": "allow",
            "bypass": true,
        ]
        sendResponse(response, for: req)
        dismiss(requestId: requestId)
        SoundManager.shared.play(for: "nod")
    }

    /// AskUserQuestion: 用户在卡片上选择了选项
    func answerQuestion(requestId: String, questionText: String, answer: String) {
        guard let req = pendingApprovals[requestId] else { return }
        Log("answerQuestion: q=\(questionText.prefix(40)), a=\(answer), reqId=\(requestId.prefix(8))", tag: "Approval")

        let response: [String: Any] = [
            "request_id": req.requestId,
            "answers": [questionText: answer],
        ]
        sendResponse(response, for: req)
        dismiss(requestId: requestId)
        SoundManager.shared.play(for: "nod")
    }

    /// 自动批准：放行所有待审批 + 立即开 bypassPermissions（会话级）
    func autoApproveSession(requestId: String) {
        guard let req = pendingApprovals[requestId] else { return }
        let sessionId = req.sessionId

        Log("autoApproveSession: sid=\(sessionId.prefix(8))", tag: "Approval")
        autoApprovedSessions.insert(sessionId)

        // 放行该 session 的所有待审批请求，第一个带 bypass=true 切模式
        let sessionRequests = pendingApprovals.values.filter {
            $0.sessionId == sessionId && !$0.isNotification
        }
        var bypassSent = false
        for r in sessionRequests {
            var response: [String: Any] = [
                "request_id": r.requestId,
                "decision": "allow",
            ]
            if !bypassSent {
                response["bypass"] = true
                bypassSent = true
            }
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

    /// Session 结束时清理会话级状态
    func cleanupSession(_ sessionId: String) {
        autoApprovedSessions.remove(sessionId)
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

    // MARK: - Question Parsing

    /// 从 toolInput 解析 AskUserQuestion 的结构化问题
    static func parseQuestions(from toolInput: [String: AnyCodableValue]?) -> [ApprovalRequest.Question] {
        guard let toolInput else { return [] }

        // 单问题模式: { question: "...", options: [...] }
        if case .string(let q) = toolInput["question"] {
            var opts: [String] = []
            if case .array(let options) = toolInput["options"] {
                for opt in options {
                    if case .object(let d) = opt, case .string(let label) = d["label"] {
                        opts.append(label)
                    } else if case .string(let label) = opt {
                        opts.append(label)
                    }
                }
            }
            if !opts.isEmpty { return [.init(text: q, options: opts)] }
        }

        // 多问题模式: { questions: [{ question: "...", options: [...] }] }
        guard case .array(let questions) = toolInput["questions"] else { return [] }
        var result: [ApprovalRequest.Question] = []
        for q in questions {
            guard case .object(let dict) = q,
                  case .string(let text) = dict["question"] else { continue }
            var opts: [String] = []
            if case .array(let options) = dict["options"] {
                for opt in options {
                    if case .object(let d) = opt, case .string(let label) = d["label"] {
                        opts.append(label)
                    }
                }
            }
            if !opts.isEmpty { result.append(.init(text: text, options: opts)) }
        }
        return result
    }
}
