import AppKit
import SwiftUI

/// 审批卡片 NSPanel 的全生命周期管理。
/// 每个 approval request 对应一个 NSPanel，叠加显示在 Notchikko 下方，支持:
/// - 入场滑入 + 淡入
/// - hideTimer 触发的滑下隐藏 / hover 恢复
/// - 退场滑出 + 淡出 + 层缩放
/// - Allow-All 批量关闭
///
/// 坐标/几何通过 geometryProvider/currentScreenProvider 懒取，适配窗口重建。
@MainActor
final class ApprovalPanelCoordinator {
    /// 每张卡片的错位偏移量
    private static let cardStackOffset: CGFloat = 8
    /// 最大可叠加卡片数（超过后不再偏移）
    private static let maxStackIndex: CGFloat = 5

    private var approvalPanels: [String: NSPanel] = [:]
    private var cardFinalFrames: [String: NSRect] = [:]

    private let sessionManager: SessionManager
    private let terminalJumper: TerminalJumper
    private weak var approvalManager: ApprovalManager?
    private let geometryProvider: () -> NotchGeometry?
    private let currentScreenProvider: () -> NSScreen?

    init(sessionManager: SessionManager,
         terminalJumper: TerminalJumper,
         approvalManager: ApprovalManager,
         geometryProvider: @escaping () -> NotchGeometry?,
         currentScreenProvider: @escaping () -> NSScreen?) {
        self.sessionManager = sessionManager
        self.terminalJumper = terminalJumper
        self.approvalManager = approvalManager
        self.geometryProvider = geometryProvider
        self.currentScreenProvider = currentScreenProvider
    }

    // MARK: - Public API

    func show(request: ApprovalManager.ApprovalRequest) {
        guard let geo = geometryProvider(),
              let approval = approvalManager,
              let screen = currentScreenProvider() ?? NSScreen.main else { return }

        let reqId = request.id

        let cardView = ApprovalCardView(
            request: request,
            hideDelay: PreferencesStore.shared.preferences.approvalCardHideDelay,
            onDeny:        { approval.deny(requestId: reqId) },
            onApprove:     { approval.approve(requestId: reqId) },
            onAlwaysAllow: { approval.alwaysAllowTool(requestId: reqId) },
            onAutoApprove: { approval.autoApproveSession(requestId: reqId) },
            onAnswer:      { questionText, answer in
                approval.answerQuestion(requestId: reqId, questionText: questionText, answer: answer)
            },
            onJump: { [weak self] in
                guard let self,
                      let session = self.sessionManager.sessions[request.sessionId] else { return }
                self.terminalJumper.jumpToSession(session: session)
            },
            onClose: {
                // 关闭按钮：审批卡 = deny，通知卡 = 直接关闭
                approval.closeCard(requestId: reqId)
            }
        )

        let hostingView = NSHostingView(rootView: cardView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let cardWidth: CGFloat = 340
        let fittingSize = hostingView.fittingSize
        let cardHeight: CGFloat = min(max(fittingSize.height, 60), 240)

        // 气泡尾巴从 Notchikko 底部探出，微量重叠确保视觉连接
        let petSize = 80 * PreferencesStore.shared.preferences.petScale
        let stackIndex = min(CGFloat(approvalPanels.count), Self.maxStackIndex)
        let cardX = screen.frame.midX - cardWidth / 2
        let petBottom = screen.frame.maxY - geo.notchSize.height - petSize
        let overlap: CGFloat = 40
        let finalY = petBottom - cardHeight + overlap - stackIndex * Self.cardStackOffset
        let finalFrame = NSRect(x: cardX, y: finalY, width: cardWidth, height: cardHeight)

        // 初始位置 = 偏上方（靠近 Notchikko），动画做滑动+淡入
        let startY = finalY + cardHeight * 0.4
        let panel = NSPanel(
            contentRect: NSRect(x: cardX, y: startY, width: cardWidth, height: cardHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 层级低于 Notchikko（mainMenu+3），卡片视觉上在 Notchikko 背后
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.hasShadow = false
        panel.alphaValue = 0
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false

        let wrapper = ApprovalTrackingView(frame: panel.contentView?.bounds ?? panel.frame)
        wrapper.autoresizingMask = [.width, .height]
        wrapper.onMouseEnter = { [weak approval] in
            // 滑入/淡入动画由 onCardVisibilityChanged → animateVisibility 驱动
            approval?.onMouseEnter(requestId: reqId)
        }
        wrapper.onMouseExit = { [weak approval] in
            approval?.onMouseExit(requestId: reqId)
        }
        wrapper.addSubview(hostingView)
        panel.contentView = wrapper

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])

        // 启用 layer 以支持退场缩放动画
        wrapper.wantsLayer = true

        panel.orderFrontRegardless()
        approvalPanels[reqId] = panel
        cardFinalFrames[reqId] = finalFrame

        // 滑入 + 淡入（入场缩放由 SwiftUI scaleEffect 处理，避免动画系统冲突）
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1.0
        })
    }

    /// hideTimer/mouseEnter 触发的滑下隐藏 / 滑上恢复
    func animateVisibility(requestId: String, visible: Bool) {
        guard let panel = approvalPanels[requestId],
              let finalFrame = cardFinalFrames[requestId] else { return }
        let targetY = visible ? finalFrame.origin.y : finalFrame.origin.y + finalFrame.height * 0.4
        let targetFrame = NSRect(x: finalFrame.origin.x, y: targetY,
                                 width: finalFrame.width, height: finalFrame.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.25 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = visible ? 1.0 : 0.0
        }
    }

    /// 鼠标悬浮在 Notchikko 上 → 恢复所有隐藏的审批卡片
    func restoreHidden() {
        approvalManager?.restoreAllHiddenCards()
        for (reqId, finalFrame) in cardFinalFrames {
            guard let panel = approvalPanels[reqId] else { continue }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(finalFrame, display: true)
                panel.animator().alphaValue = 1.0
            }
        }
    }

    /// 移除指定 requestId 的审批面板（滑上+淡出+缩放再关闭）
    func remove(requestId: String) {
        guard let panel = approvalPanels.removeValue(forKey: requestId) else { return }
        let finalFrame = cardFinalFrames.removeValue(forKey: requestId)

        let hideY = (finalFrame?.origin.y ?? panel.frame.origin.y) + panel.frame.height * 0.4
        var hiddenFrame = panel.frame
        hiddenFrame.origin.y = hideY

        // 滑出 + 淡出（display:false 避免和 layer 缩放动画冲突）
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(hiddenFrame, display: false)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.close()
        })
        let scaleOut = CABasicAnimation(keyPath: "transform")
        scaleOut.fromValue = CATransform3DIdentity
        scaleOut.toValue = CATransform3DMakeScale(0.88, 0.88, 1.0)
        scaleOut.duration = 0.2
        scaleOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
        panel.contentView?.layer?.add(scaleOut, forKey: "scaleOut")
        panel.contentView?.layer?.transform = CATransform3DMakeScale(0.88, 0.88, 1.0)
    }

    /// 移除所有审批面板（Allow All / Auto Approve 时）
    func removeAll() {
        let keys = Array(approvalPanels.keys)
        for reqId in keys {
            remove(requestId: reqId)
        }
    }
}

// MARK: - 审批卡片鼠标追踪

private final class ApprovalTrackingView: NSView {
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExit?()
    }
}
