import Foundation

@MainActor @Observable
final class ApprovalManager {
    private(set) var pendingApproval: ApprovalRequest?
    private(set) var isCardVisible: Bool = false

    private var hideTimer: Task<Void, Never>?
    private var staleTimer: Task<Void, Never>?
    private weak var socketServer: SocketServer?

    /// 已设为"全部允许"的 session（session 维度，不持久化）
    private var autoApprovedSessions: Set<String> = []

    struct ApprovalRequest {
        let requestId: String
        let source: String
        let tool: String
        let input: String
        let sessionId: String
        let timestamp: Date
    }

    init(socketServer: SocketServer) {
        self.socketServer = socketServer
    }

    // MARK: - 请求处理

    func handleApprovalRequest(from hookEvent: HookEvent) {
        // 如果该 session 已设为"全部允许"，直接放行
        if autoApprovedSessions.contains(hookEvent.sessionId) {
            let requestId = hookEvent.requestId ?? ""
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
            requestId: hookEvent.requestId ?? "",
            source: hookEvent.source ?? "unknown",
            tool: hookEvent.tool ?? "",
            input: String(toolInput.prefix(500)),
            sessionId: hookEvent.sessionId,
            timestamp: Date()
        )

        pendingApproval = request
        isCardVisible = true
        startHideTimer()
        startStaleTimer()
    }

    // MARK: - 审批操作

    func approve() {
        guard let req = pendingApproval else { return }
        let response: [String: Any] = [
            "request_id": req.requestId,
            "decision": "allow",
        ]
        sendResponse(response)
        dismiss()
        SoundManager.shared.play(for: "nod")
    }

    /// 允许当前 session 的所有后续请求（session 维度，不持久化）
    func approveAllForSession() {
        guard let req = pendingApproval else { return }
        autoApprovedSessions.insert(req.sessionId)
        approve()  // 同时放行当前请求
    }

    func deny() {
        guard let req = pendingApproval else { return }
        let response: [String: Any] = [
            "request_id": req.requestId,
            "decision": "deny",
            "reason": "Denied by Notchikko",
        ]
        sendResponse(response)
        dismiss()
        SoundManager.shared.play(for: "shake")
    }

    // MARK: - 卡片显示控制

    func onMouseEnter() {
        guard pendingApproval != nil else { return }
        isCardVisible = true
        hideTimer?.cancel()
    }

    func onMouseExit() {
        guard pendingApproval != nil else { return }
        startHideTimer()
    }

    var hasPendingApproval: Bool {
        pendingApproval != nil
    }

    /// 当收到同一 session 的后续事件时，说明审批已在 CLI 侧完成，清理卡片
    func onSessionEvent(sessionId: String) {
        guard let pending = pendingApproval,
              pending.sessionId == sessionId else { return }
        dismiss()
    }

    // MARK: - Private

    private func dismiss() {
        hideTimer?.cancel()
        staleTimer?.cancel()
        pendingApproval = nil
        isCardVisible = false
    }

    /// Hook 脚本有 300s 超时，超时后 hook 侧自动放行。
    /// App 侧也需要在同样时间后清理审批状态，避免卡片常驻。
    private func startStaleTimer() {
        staleTimer?.cancel()
        staleTimer = Task {
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private func startHideTimer() {
        hideTimer?.cancel()
        let delay = PreferencesStore.shared.preferences.approvalCardHideDelay
        guard delay > 0 else { return }  // 0 = 永不隐藏
        hideTimer = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            isCardVisible = false
        }
    }

    private func sendResponse(_ dict: [String: Any]) {
        guard let req = pendingApproval,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        socketServer?.respond(requestId: req.requestId, json: data)
    }
}
