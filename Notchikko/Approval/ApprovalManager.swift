import Foundation

@MainActor @Observable
final class ApprovalManager {
    private(set) var pendingApproval: ApprovalRequest?
    private(set) var isCardVisible: Bool = false

    private var hideTimer: Task<Void, Never>?
    private weak var socketServer: SocketServer?

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
        let toolInput = hookEvent.toolInput?.values.first.flatMap { value -> String? in
            if case .string(let s) = value { return s }
            return nil
        } ?? ""

        let request = ApprovalRequest(
            requestId: hookEvent.requestId ?? "",
            source: hookEvent.source ?? "unknown",
            tool: hookEvent.tool ?? "",
            input: String(toolInput.prefix(80)),
            sessionId: hookEvent.sessionId,
            timestamp: Date()
        )

        pendingApproval = request
        isCardVisible = true
        startHideTimer()
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

    // MARK: - Private

    private func dismiss() {
        hideTimer?.cancel()
        pendingApproval = nil
        isCardVisible = false
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
