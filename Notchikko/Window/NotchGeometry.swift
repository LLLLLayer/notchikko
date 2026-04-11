import AppKit

struct NotchGeometry {
    let notchSize: CGSize
    let notchCenter: CGPoint
    let panelFrame: NSRect
    let hasPhysicalNotch: Bool

    init(screen: NSScreen) {
        hasPhysicalNotch = screen.safeAreaInsets.top > 0

        if hasPhysicalNotch {
            let leftPadding = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightPadding = screen.auxiliaryTopRightArea?.width ?? 0
            let notchWidth = screen.frame.width - leftPadding - rightPadding + 4
            let notchHeight = screen.safeAreaInsets.top
            notchSize = CGSize(width: notchWidth, height: notchHeight)
        } else {
            // 没有 Notch：用屏幕顶部菜单栏高度，宽度给一个合理值
            let menuBarHeight = screen.frame.height - screen.visibleFrame.height
                - (screen.visibleFrame.origin.y - screen.frame.origin.y)
            notchSize = CGSize(width: 200, height: max(menuBarHeight, 25))
        }

        let screenFrame = screen.frame
        notchCenter = CGPoint(
            x: screenFrame.midX,
            y: screenFrame.maxY - notchSize.height / 2
        )

        // Panel 宽度 = notch 宽度（有 notch）或固定宽度（无 notch）
        let panelWidth = notchSize.width
        let panelHeight = notchSize.height + 150

        // 关键：Panel 顶部始终对齐屏幕物理顶部
        // 有 Notch → 上半身藏在 Notch 硬件挖孔里
        // 无 Notch → 上半身超出屏幕顶部被裁剪
        panelFrame = NSRect(
            x: screenFrame.midX - panelWidth / 2,
            y: screenFrame.maxY - panelHeight,
            width: panelWidth,
            height: panelHeight
        )

    }
}
