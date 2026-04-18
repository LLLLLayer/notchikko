import SwiftUI

/// 弹幕层：工具名从右向左飘过宠物背后，工具类别彩色标签，渐入渐出
struct DanmakuView: View {
    var sessionManager: SessionManager

    @State private var items: [DanmakuItem] = []
    @State private var lastToolEventId = 0
    @State private var lastSessionEventId = 0
    @State private var lastPettingEventId = 0

    private static func toolColor(for tool: String) -> Color {
        ToolColors.color(for: tool)
    }

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

            // ~30% 概率附带一条上下文信息（更暗的灰色风格）
            if Double.random(in: 0...1) < 0.3, let info = randomContextInfo() {
                let delay = Double.random(in: 0.3...0.8)
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    spawnItem(text: info, isContext: true)
                }
            }
        }
        .onChange(of: sessionManager.danmakuSessionEvent.id) { _, newId in
            guard newId != lastSessionEventId else { return }
            lastSessionEventId = newId
            spawnItem(text: sessionManager.danmakuSessionEvent.name, isContext: true)
        }
        .onChange(of: sessionManager.danmakuPettingEvent.id) { _, newId in
            guard newId != lastPettingEventId else { return }
            lastPettingEventId = newId
            let combo = sessionManager.danmakuPettingEvent.combo
            spawnItem(text: "×\(combo)", isCombo: true, comboLevel: combo)
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

        // 工具弹幕：类别色文字 / 上下文弹幕：暗灰文字 / combo：亮粉高饱和
        let textColor: Color = item.isCombo
            ? item.color
            : item.isContext
                ? Color.white.opacity(0.4)
                : item.color.opacity(0.85)

        let resolved = context.resolve(
            Text(item.text)
                .font(.system(size: item.fontSize, weight: .medium, design: .monospaced))
                .foregroundColor(textColor)
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

        // 工具弹幕：类别色底 / 上下文弹幕：微弱白底 / combo：无底只留文字，凸显飘字感
        let bgColor: Color = item.isCombo
            ? Color.clear
            : item.isContext
                ? Color.white.opacity(0.08)
                : item.color.opacity(0.2)

        let path = pixelRoundedRect(rect: rect, px: px)
        ctx.fill(path, with: .color(bgColor))
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
        if let terminal = session.matchedTerminal?.appName {
            candidates.append(terminal)
        }
        return candidates.randomElement()
    }

    // MARK: - 弹幕生成

    private func spawnItem(text: String, isContext: Bool = false,
                           isCombo: Bool = false, comboLevel: Int = 0) {
        // combo 随等级放大字号、变更色彩，制造"连击感"
        let fontSize: CGFloat
        let color: Color
        let duration: Double
        if isCombo {
            fontSize = min(10 + CGFloat(comboLevel) * 1.5, 22)
            color = Self.comboColor(level: comboLevel)
            duration = 1.2  // combo 飘得快，避免堆积
        } else {
            fontSize = isContext ? 8.5 : 9.5
            color = isContext ? .white : Self.toolColor(for: text)
            duration = Double.random(in: 3.0...5.0)
        }
        let charWidth = fontSize * 0.65
        let textWidth = charWidth * CGFloat(text.count)
        let padH: CGFloat = 1.0 * 3 * 2
        let bubbleWidth = textWidth + padH + 2

        // combo 固定顶部中央附近；其他弹幕 4 档抖动
        let yRatio: CGFloat
        if isCombo {
            yRatio = CGFloat.random(in: 0.15...0.35)
        } else {
            let slots: [CGFloat] = [0.12, 0.32, 0.52, 0.72]
            let baseY = slots.randomElement()!
            let jitter = CGFloat.random(in: -0.05...0.05)
            yRatio = min(max(baseY + jitter, 0.08), 0.80)
        }

        let item = DanmakuItem(
            text: text,
            startTime: Date.now.timeIntervalSinceReferenceDate,
            duration: duration,
            yRatio: yRatio,
            fontSize: fontSize,
            bubbleWidth: bubbleWidth,
            startOffset: isCombo ? 0 : CGFloat.random(in: 0...20),
            color: color,
            isContext: isContext,
            isCombo: isCombo
        )
        items.append(item)
    }

    /// Combo 色阶：1-2 粉 → 3-5 橙 → 6-7 金 → 8+ 红
    private static func comboColor(level: Int) -> Color {
        switch level {
        case ...2: return Color(red: 1.00, green: 0.45, blue: 0.65)  // 粉
        case 3...5: return Color(red: 1.00, green: 0.60, blue: 0.20) // 橙
        case 6...7: return Color(red: 1.00, green: 0.85, blue: 0.20) // 金
        default:    return Color(red: 1.00, green: 0.30, blue: 0.30) // 红（MAX）
        }
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
    let color: Color
    let isContext: Bool
    let isCombo: Bool
}
