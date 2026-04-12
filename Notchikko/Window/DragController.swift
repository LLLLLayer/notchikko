import AppKit

final class DragController {
    private var localMonitor: Any?
    private var globalMonitor: Any?

    private weak var panel: NotchPanel?
    private var homeFrame: NSRect = .zero
    private var notchHeight: CGFloat = 0
    private var petSize: CGFloat = 80
    private var isDragging = false
    private var dragOffset: CGPoint = .zero

    // 单击 vs 拖拽区分
    private var mouseDownPoint: NSPoint = .zero
    private var mouseDownInPet = false
    private static let dragThreshold: CGFloat = 5.0

    var onDragStart: (() -> Void)?
    /// 松手回调，参数为鼠标所在屏幕（可能与起始屏幕不同）
    var onDragEnd: ((NSScreen?) -> Void)?
    var onRightClick: ((NSPoint) -> Void)?
    /// 单击回调（非拖拽的点击）
    var onClick: (() -> Void)?

    deinit {
        teardown()
    }

    func setup(panel: NotchPanel, homeFrame: NSRect, notchHeight: CGFloat = 0, petSize: CGFloat = 80) {
        self.panel = panel
        self.homeFrame = homeFrame
        self.notchHeight = notchHeight
        self.petSize = petSize

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]
        ) { [weak self] event in
            self?.handleEvent(event)
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .rightMouseDown]
        ) { [weak self] event in
            self?.handleEvent(event)
        }
    }

    func updateHomeFrame(_ frame: NSRect) {
        homeFrame = frame
    }

    func teardown() {
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        localMonitor = nil
        globalMonitor = nil
        isDragging = false
        mouseDownInPet = false
    }

    private func handleEvent(_ event: NSEvent) {
        guard let panel else { return }

        switch event.type {
        case .rightMouseDown:
            let mouseScreen = NSEvent.mouseLocation
            let petRect = petScreenRect(panel: panel)
            guard petRect.contains(mouseScreen) else { return }
            onRightClick?(mouseScreen)

        case .leftMouseDown:
            let mouseScreen = NSEvent.mouseLocation
            let petRect = petScreenRect(panel: panel)
            guard petRect.contains(mouseScreen) else { return }

            mouseDownPoint = mouseScreen
            mouseDownInPet = true
            isDragging = false

            dragOffset = CGPoint(
                x: mouseScreen.x - panel.frame.origin.x,
                y: mouseScreen.y - panel.frame.origin.y
            )

        case .leftMouseDragged:
            guard mouseDownInPet else { return }
            let mouseScreen = NSEvent.mouseLocation

            if !isDragging {
                // 检查是否超过拖拽阈值
                let dx = mouseScreen.x - mouseDownPoint.x
                let dy = mouseScreen.y - mouseDownPoint.y
                let distance = sqrt(dx * dx + dy * dy)
                guard distance >= Self.dragThreshold else { return }

                // 进入拖拽模式
                isDragging = true
                onDragStart?()
            }

            let newOrigin = CGPoint(
                x: mouseScreen.x - dragOffset.x,
                y: mouseScreen.y - dragOffset.y
            )
            panel.setFrameOrigin(newOrigin)

        case .leftMouseUp:
            guard mouseDownInPet else { return }
            mouseDownInPet = false

            if isDragging {
                isDragging = false
                let mouseLocation = NSEvent.mouseLocation
                let targetScreen = screenContaining(mouseLocation)
                onDragEnd?(targetScreen)
            } else {
                // 没有拖拽 → 单击
                onClick?()
            }

        default:
            break
        }
    }

    /// 找到鼠标所在的屏幕
    private func screenContaining(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func petScreenRect(panel: NotchPanel) -> NSRect {
        let panelFrame = panel.frame
        // 宠物贴在 panel 顶部，上半身藏在 notch 里
        // 热区比实际宠物大一圈（上下左右各扩 20px），更容易点到
        let padding: CGFloat = 20
        let visibleTop = panelFrame.maxY - notchHeight
        return NSRect(
            x: panelFrame.midX - petSize / 2 - padding,
            y: visibleTop - petSize - padding,
            width: petSize + padding * 2,
            height: petSize + padding * 2
        )
    }

    /// 飞回目标位置，动画完成后执行回调
    func animateToFrame(_ frame: NSRect, completion: (() -> Void)? = nil) {
        guard let panel else { completion?(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: {
            panel.setFrame(frame, display: false)
            completion?()
        })
    }
}
