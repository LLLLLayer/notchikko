import AppKit

final class NotchHitTestView: NSView {
    /// 可交互区域（屏幕坐标）。设为 .zero 则完全穿透。
    var interactiveRect: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect != .zero, let window else { return nil }
        let screenPoint = window.convertPoint(toScreen: convert(point, to: nil))
        guard interactiveRect.contains(screenPoint) else { return nil }
        return super.hitTest(point)
    }
}
