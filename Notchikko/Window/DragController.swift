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
    /// 撸猫开始：鼠标在宠物热区内频繁移动达阈值
    var onPetStart: (() -> Void)?
    /// 撸猫结束：鼠标停止移动 / 离开热区 / 被 drag 抢断
    var onPetEnd: (() -> Void)?
    /// 撸猫中每次 x 方向反转（一次来回 = 2 次反转）；用于 combo 递增
    var onPetCombo: (() -> Void)?

    // 撸猫检测：滑动窗内的路径长度采样
    private var petSamples: [(t: TimeInterval, p: NSPoint)] = []
    private var isPetting = false
    private var petEndTimer: Timer?
    private var lastPetSampleTime: TimeInterval = 0
    private var lastHapticTime: TimeInterval = 0
    /// 持久化的 x 方向（跨样本），用于 combo 每次反转触发一次
    private var lastPetMoveDir: CGFloat = 0
    private static let petSampleInterval: TimeInterval = 0.016    // 60Hz 节流
    private static let petWindow: TimeInterval = 0.7              // 滑动窗 700ms
    private static let petPathEnterThreshold: CGFloat = 160       // 冷启动：窗内累计 >= 160pt
    private static let petPathMaintainThreshold: CGFloat = 100    // 持续中：>= 100pt 就保持
    private static let petReversalsRequired: Int = 2              // 冷启动要求 2 次反转 ≈ 1 个完整来回
    private static let petIdleTimeout: TimeInterval = 0.9         // 900ms 无移动 → 结束
    private static let hapticInterval: TimeInterval = 0.08        // 撸动期间每 80ms 触发一次触觉

    deinit {
        teardown()
    }

    func setup(panel: NotchPanel, homeFrame: NSRect, notchHeight: CGFloat = 0, petSize: CGFloat = 80) {
        self.panel = panel
        self.homeFrame = homeFrame
        self.notchHeight = notchHeight
        self.petSize = petSize

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .mouseMoved]
        ) { [weak self] event in
            self?.handleEvent(event)
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .rightMouseDown, .mouseMoved]
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

        // 隐身态（panel.ignoresMouseEvents=true）下全部交互短路。
        // Why: NSEvent 全局 monitor 不受 ignoresMouseEvents 影响，仍会把鼠标位置 / 点击事件喂进来，
        // 如果不显式短路，撸猫检测 / 右键 / 点击跳转仍会生效——和"屏蔽交互"的承诺不符。
        if panel.ignoresMouseEvents {
            endPettingIfActive()
            return
        }

        // .mouseMoved 不参与拖拽判定，单独走撸猫检测
        if event.type == .mouseMoved {
            handlePettingSample(panel: panel)
            return
        }

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

                // 进入拖拽模式（撸猫被抢断）
                endPettingIfActive()
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

    // MARK: - 撸猫检测

    /// 节流采样鼠标位置；维护 500ms 滑动窗内的累计路径长度，超阈值进入撸猫态
    private func handlePettingSample(panel: NotchPanel) {
        // 拖拽优先：不能同时撸 + 拖
        if isDragging { return }

        let now = CACurrentMediaTime()
        // 60Hz 节流，避免高频事件烧 CPU
        guard now - lastPetSampleTime >= Self.petSampleInterval else { return }
        lastPetSampleTime = now

        let mouseScreen = NSEvent.mouseLocation
        let petRect = petScreenRect(panel: panel)

        // 离开热区 → 立即结束撸猫
        guard petRect.contains(mouseScreen) else {
            endPettingIfActive()
            return
        }

        // 当前样本相对上一个样本的 x 方向反转检测（持久化跨样本，不依赖窗口）
        let didFlipThisSample: Bool
        if let prev = petSamples.last {
            let dx = mouseScreen.x - prev.p.x
            if abs(dx) > 0.5 {
                let newDir: CGFloat = dx > 0 ? 1 : -1
                didFlipThisSample = (lastPetMoveDir != 0 && newDir != lastPetMoveDir)
                lastPetMoveDir = newDir
            } else {
                didFlipThisSample = false
            }
        } else {
            didFlipThisSample = false
        }

        // 追加采样，淘汰窗口外的旧样本
        petSamples.append((t: now, p: mouseScreen))
        let cutoff = now - Self.petWindow
        while let first = petSamples.first, first.t < cutoff {
            petSamples.removeFirst()
        }

        // 累计窗口内总路径 + 窗口内反转数（仅用于冷启动门控）
        var totalPath: CGFloat = 0
        var windowReversals = 0
        var prevDirX: CGFloat = 0
        for i in 1..<petSamples.count {
            let dx = petSamples[i].p.x - petSamples[i - 1].p.x
            let dy = petSamples[i].p.y - petSamples[i - 1].p.y
            totalPath += sqrt(dx * dx + dy * dy)
            let dir: CGFloat = dx > 0.5 ? 1 : (dx < -0.5 ? -1 : 0)
            if dir != 0 {
                if prevDirX != 0 && dir != prevDirX { windowReversals += 1 }
                prevDirX = dir
            }
        }

        let threshold = isPetting ? Self.petPathMaintainThreshold : Self.petPathEnterThreshold
        let hasEnoughReversals = isPetting || windowReversals >= Self.petReversalsRequired

        if totalPath >= threshold && hasEnoughReversals {
            if !isPetting {
                isPetting = true
                onPetStart?()
            }
            // 每次 x 方向反转 → combo +1（per-sample，不依赖窗口衰减）
            if didFlipThisSample {
                onPetCombo?()
            }
            // NSEvent 事件上下文里直接 fire haptic（LSUIElement app 后台无法从 Timer 触发）
            // 双重脉冲叠加，触感更厚重
            if now - lastHapticTime >= Self.hapticInterval {
                lastHapticTime = now
                let performer = NSHapticFeedbackManager.defaultPerformer
                performer.perform(.levelChange, performanceTime: .now)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    performer.perform(.levelChange, performanceTime: .now)
                }
            }
            // 滚动结束计时
            schedulePetEndTimer()
        }
    }

    /// 600ms 内无新移动样本 → 结束撸猫
    private func schedulePetEndTimer() {
        petEndTimer?.invalidate()
        petEndTimer = Timer.scheduledTimer(withTimeInterval: Self.petIdleTimeout, repeats: false) { [weak self] _ in
            self?.endPettingIfActive()
        }
    }

    private func endPettingIfActive() {
        petEndTimer?.invalidate()
        petEndTimer = nil
        petSamples.removeAll()
        lastPetMoveDir = 0
        guard isPetting else { return }
        isPetting = false
        onPetEnd?()
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
        // 动画期间禁用 frame 约束，避免刘海屏上被系统推到刘海下方
        panel.disableFrameConstraint = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak panel] in
            // 动画已将 frame 设到正确位置，不再重复 setFrame
            // 否则 constrainFrameRect 会把超出刘海安全区的 panel 推下来
            panel?.disableFrameConstraint = false
            completion?()
        })
    }
}
