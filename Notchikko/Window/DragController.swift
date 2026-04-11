import AppKit

final class DragController {
    private var localMonitor: Any?
    private var globalMonitor: Any?

    private weak var panel: NotchPanel?
    private var homeFrame: NSRect = .zero
    private var isDragging = false
    private var dragOffset: CGPoint = .zero

    var onDragStart: (() -> Void)?
    /// 松手回调，参数为鼠标所在屏幕（可能与起始屏幕不同）
    var onDragEnd: ((NSScreen?) -> Void)?
    var onRightClick: ((NSPoint) -> Void)?

    func setup(panel: NotchPanel, homeFrame: NSRect) {
        self.panel = panel
        self.homeFrame = homeFrame

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

            dragOffset = CGPoint(
                x: mouseScreen.x - panel.frame.origin.x,
                y: mouseScreen.y - panel.frame.origin.y
            )
            isDragging = true
            onDragStart?()

        case .leftMouseDragged:
            guard isDragging else { return }
            let mouseScreen = NSEvent.mouseLocation
            let newOrigin = CGPoint(
                x: mouseScreen.x - dragOffset.x,
                y: mouseScreen.y - dragOffset.y
            )
            panel.setFrameOrigin(newOrigin)

        case .leftMouseUp:
            guard isDragging else { return }
            isDragging = false
            let mouseLocation = NSEvent.mouseLocation
            let targetScreen = screenContaining(mouseLocation)
            onDragEnd?(targetScreen)

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
        let petSize: CGFloat = 60
        return NSRect(
            x: panelFrame.midX - petSize / 2,
            y: panelFrame.maxY - petSize - 5,
            width: petSize,
            height: petSize
        )
    }

    /// 飞回目标位置
    func animateToFrame(_ frame: NSRect) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        })
    }
}
