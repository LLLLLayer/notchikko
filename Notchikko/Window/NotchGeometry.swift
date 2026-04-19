import AppKit

struct NotchGeometry {
    let notchSize: CGSize
    let notchCenter: CGPoint
    let panelFrame: NSRect
    let hasPhysicalNotch: Bool
    /// panel 内被刘海遮住的高度（模拟刘海时为 0，因为 panel 没有延伸到屏幕外）
    let hiddenNotchHeight: CGFloat

    /// Notchikko 热区下方的 padding（与 DragController.petScreenRect 的 padding 保持一致）
    /// panel 下方空间 = petSize + padding，刚好容纳 drag/hover 热区下边缘
    static let petAreaPadding: CGFloat = 20

    init(screen: NSScreen, notchDetectionMode: NotchDetectionMode = .auto, petSize: CGFloat = 80) {
        switch notchDetectionMode {
        case .auto:
            hasPhysicalNotch = screen.safeAreaInsets.top > 0
        case .forceOn:
            hasPhysicalNotch = true
        case .forceOff:
            hasPhysicalNotch = false
        }

        let screenHasNotch = screen.safeAreaInsets.top > 0

        if hasPhysicalNotch && screenHasNotch {
            // 真实刘海：从屏幕 API 读取尺寸
            let leftPadding = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightPadding = screen.auxiliaryTopRightArea?.width ?? 0
            let notchWidth = screen.frame.width - leftPadding - rightPadding + 4
            let notchHeight = screen.safeAreaInsets.top
            notchSize = CGSize(width: notchWidth, height: notchHeight)
        } else if hasPhysicalNotch && !screenHasNotch {
            // 强制有刘海，但屏幕没有物理刘海：模拟一个合理的刘海尺寸
            notchSize = CGSize(width: 200, height: 32)
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

        // 刘海下方需要容纳的 pet 可视高度（petSize + padding 正好覆盖 drag/hover 热区下边缘）
        let petAreaHeight = petSize + Self.petAreaPadding

        if hasPhysicalNotch {
            // 刘海屏（含强制模拟）：panel 顶部 = 刘海底边，crab 整只挂在刘海正下方、完全可见。
            // 过去设计让上半身藏进挖孔里，但飞回动画会穿过挖孔区看起来"闪一下"，
            // 改成全露出后，归位干净，也不需要任何 hiddenNotchHeight 偏置。
            hiddenNotchHeight = 0
            panelFrame = NSRect(
                x: screenFrame.midX - panelWidth / 2,
                y: screenFrame.maxY - notchSize.height - petAreaHeight,
                width: panelWidth,
                height: petAreaHeight
            )
        } else {
            // 无刘海：panel 顶部贴到屏幕顶部，上半身超出屏幕顶部被裁剪
            let panelHeight = notchSize.height + petAreaHeight
            hiddenNotchHeight = notchSize.height
            panelFrame = NSRect(
                x: screenFrame.midX - panelWidth / 2,
                y: screenFrame.maxY - panelHeight,
                width: panelWidth,
                height: panelHeight
            )
        }
    }
}
