import AppKit

final class NotchHitTestView: NSView {
    /// 可交互区域（屏幕坐标）。设为 .zero 则完全穿透。
    var interactiveRect: NSRect = .zero

    /// Notchikko 区域（视图本地坐标），用于悬浮检测
    var petLocalRect: NSRect = .zero {
        didSet { updateTrackingAreas() }
    }
    /// 鼠标进入 Notchikko 区域的回调
    var onPetHover: (() -> Void)?

    private var petTrackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect != .zero, let window else { return nil }
        let screenPoint = window.convertPoint(toScreen: convert(point, to: nil))
        guard interactiveRect.contains(screenPoint) else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = petTrackingArea { removeTrackingArea(old) }
        guard petLocalRect != .zero else { return }
        petTrackingArea = NSTrackingArea(
            rect: petLocalRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(petTrackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        onPetHover?()
    }
}
