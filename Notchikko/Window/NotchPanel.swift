import AppKit

final class NotchPanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .mainMenu + 3
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 临时禁用 frame 约束（拖拽飞回动画期间）
    var disableFrameConstraint = false

    // 有 Notch: 让系统约束（Panel 顶部对齐 Notch 底边）
    // 无 Notch / 动画中: 不约束，允许超出屏幕顶部
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if disableFrameConstraint { return frameRect }
        if let screen, screen.safeAreaInsets.top > 0 {
            return super.constrainFrameRect(frameRect, to: screen)
        }
        return frameRect
    }
}
