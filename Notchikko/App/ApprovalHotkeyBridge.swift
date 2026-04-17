import Foundation

/// HotkeyManager ↔ ApprovalManager 的桥接层。
/// 封装"有阻塞式审批卡片时激活 Carbon 热键 / 无时停用"的逻辑，
/// 以及 Cmd+Y/Cmd+N 等热键到 ApprovalManager.approve/deny 等动作的路由。
@MainActor
final class ApprovalHotkeyBridge {
    private let approvalManager: ApprovalManager
    private let hotkeyManager = HotkeyManager()

    init(approvalManager: ApprovalManager) {
        self.approvalManager = approvalManager
        hotkeyManager.onAction = { [weak self] action in
            self?.handle(action)
        }
    }

    /// ApprovalManager 状态变化后调用：有阻塞式审批 → 激活，否则停用。
    /// 避免全局占用 Cmd+Y/N，只在需要时抢焦点。
    func refresh() {
        if approvalManager.hasPendingBlockingApproval {
            hotkeyManager.activate()
        } else {
            hotkeyManager.deactivate()
        }
    }

    /// applicationWillTerminate 调用
    func deactivate() {
        hotkeyManager.deactivate()
    }

    private func handle(_ action: HotkeyManager.Action) {
        guard let target = approvalManager.mostRecentBlockingApproval else { return }
        Log("Hotkey: \(action), target=\(target.id.prefix(8))", tag: "HotkeyBridge")
        switch action {
        case .allowOnce:   approvalManager.approve(requestId: target.id)
        case .alwaysAllow: approvalManager.alwaysAllowTool(requestId: target.id)
        case .deny:        approvalManager.deny(requestId: target.id)
        case .autoApprove: approvalManager.autoApproveSession(requestId: target.id)
        }
        refresh()
    }
}
