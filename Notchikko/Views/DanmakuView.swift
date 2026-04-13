import SwiftUI

/// 弹幕层：工具名从右向左飘过宠物背后，透明黑底像素标签，渐入渐出
struct DanmakuView: View {
    var sessionManager: SessionManager

    @State private var items: [DanmakuItem] = []
    @State private var lastToolEventId = 0
    @State private var lastSessionEventId = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                for item in items {
                    let elapsed = now - item.startTime
                    let progress = elapsed / item.duration
                    guard progress >= 0 && progress <= 1 else { continue }

                    // 从右向左，随机起始偏移
                    let totalTravel = size.width + item.bubbleWidth
                    let x = size.width + item.startOffset - totalTravel * progress

                    let y = size.height * item.yRatio

                    // 渐入渐出：前 25% 渐入，后 25% 渐出
                    let opacity: Double
                    if progress < 0.25 {
                        opacity = progress / 0.25
                    } else if progress > 0.75 {
                        opacity = (1.0 - progress) / 0.25
                    } else {
                        opacity = 1.0
                    }

                    drawLabel(
                        context: &context,
                        item: item,
                        at: CGPoint(x: x, y: y),
                        opacity: opacity
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: sessionManager.danmakuToolEvent.id) { _, newId in
            guard newId != lastToolEventId else { return }
            lastToolEventId = newId
            spawnItem(text: sessionManager.danmakuToolEvent.tool)

            // ~30% 概率附带一条上下文信息
            if Double.random(in: 0...1) < 0.3, let info = randomContextInfo() {
                let delay = Double.random(in: 0.3...0.8)
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    spawnItem(text: info)
                }
            }
        }
        .onChange(of: sessionManager.danmakuSessionEvent.id) { _, newId in
            guard newId != lastSessionEventId else { return }
            lastSessionEventId = newId
            spawnItem(text: sessionManager.danmakuSessionEvent.name)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let now = Date.now.timeIntervalSinceReferenceDate
                items.removeAll { now - $0.startTime > $0.duration + 0.5 }
            }
        }
    }

    // MARK: - 绘制

    private func drawLabel(
        context: inout GraphicsContext,
        item: DanmakuItem,
        at point: CGPoint,
        opacity: Double
    ) {
        let px: CGFloat = 1.0
        let padH: CGFloat = px * 3
        let padV: CGFloat = px * 1.5

        let resolved = context.resolve(
            Text(item.text)
                .font(.system(size: item.fontSize, weight: .medium, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.75))
        )
        let textSize = resolved.measure(in: CGSize(width: 200, height: 30))

        let bubbleW = textSize.width + padH * 2
        let bubbleH = textSize.height + padV * 2
        let rect = CGRect(
            x: point.x,
            y: point.y - bubbleH / 2,
            width: bubbleW,
            height: bubbleH
        )

        var ctx = context
        ctx.opacity = opacity

        let path = pixelRoundedRect(rect: rect, px: px)
        ctx.fill(path, with: .color(Color.black.opacity(0.4)))
        ctx.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }

    private func pixelRoundedRect(rect: CGRect, px: CGFloat) -> Path {
        let x = rect.minX, y = rect.minY
        let w = rect.width, h = rect.height
        let c = px

        return Path { p in
            p.move(to: CGPoint(x: x + c, y: y))
            p.addLine(to: CGPoint(x: x + w - c, y: y))
            p.addLine(to: CGPoint(x: x + w, y: y + c))
            p.addLine(to: CGPoint(x: x + w, y: y + h - c))
            p.addLine(to: CGPoint(x: x + w - c, y: y + h))
            p.addLine(to: CGPoint(x: x + c, y: y + h))
            p.addLine(to: CGPoint(x: x, y: y + h - c))
            p.addLine(to: CGPoint(x: x, y: y + c))
            p.closeSubpath()
        }
    }

    // MARK: - 上下文信息

    private func randomContextInfo() -> String? {
        guard let sid = sessionManager.activeSessionId,
              let session = sessionManager.sessions[sid] else { return nil }

        var candidates: [String] = []
        let project = session.cwdName
        if !project.isEmpty { candidates.append(project) }
        let meta = CLIHookConfig.metadata(for: session.source)
        candidates.append(meta.displayName)
        if let terminal = session.matchedTerminal?.appName {
            candidates.append(terminal)
        }
        return candidates.randomElement()
    }

    // MARK: - 弹幕生成

    private func spawnItem(text: String) {
        let fontSize: CGFloat = CGFloat.random(in: 7...9)
        let charWidth = fontSize * 0.65
        let textWidth = charWidth * CGFloat(text.count)
        let padH: CGFloat = 1.0 * 3 * 2
        let bubbleWidth = textWidth + padH + 2

        // y 位置：离散档位 + 小抖动，避免聚集
        // 弹幕区域很矮（petSize * 0.35），yRatio 上限需留出弹幕自身高度
        let slots: [CGFloat] = [0.15, 0.40, 0.65]
        let baseY = slots.randomElement()!
        let jitter = CGFloat.random(in: -0.06...0.06)
        let yRatio = min(max(baseY + jitter, 0.10), 0.75)

        let item = DanmakuItem(
            text: text,
            startTime: Date.now.timeIntervalSinceReferenceDate,
            duration: Double.random(in: 3.0...5.0),
            yRatio: yRatio,
            fontSize: fontSize,
            bubbleWidth: bubbleWidth,
            startOffset: CGFloat.random(in: 0...20)
        )
        items.append(item)
    }
}

// MARK: - 数据模型

private struct DanmakuItem: Identifiable {
    let id = UUID()
    let text: String
    let startTime: TimeInterval
    let duration: Double
    let yRatio: CGFloat
    let fontSize: CGFloat
    let bubbleWidth: CGFloat
    let startOffset: CGFloat
}
