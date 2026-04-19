import SwiftUI

struct ApprovalCardView: View {
    let request: ApprovalManager.ApprovalRequest
    /// 自动隐藏倒计时秒数；> 0 时卡片底边显示进度条。
    var hideDelay: Double = 0
    let onDeny: () -> Void
    let onApprove: () -> Void
    let onAlwaysAllow: () -> Void
    let onAutoApprove: () -> Void
    /// AskUserQuestion: 用户选了某个选项 (questionText, optionLabel)
    var onAnswer: ((String, String) -> Void)? = nil
    var onJump: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var isPulsing = false
    @State private var cardScale: CGFloat = 0.88
    @State private var shownAt: Date = .init()

    private static let tailHeight: CGFloat = 8
    private static let tailWidth: CGFloat = 16
    private static let cardCornerRadius: CGFloat = 12
    private static let cardBackground = Color(nsColor: NSColor(white: 0.11, alpha: 0.94))
    /// 统一弹簧动画节拍
    static let bubbleSpring: Animation = .spring(response: 0.35, dampingFraction: 0.82)

    private var agentMeta: (icon: String, displayName: String) {
        CLIHookConfig.metadata(for: request.source)
    }

    /// 工具类别颜色：通知=蓝，Bash=绿，Edit/Write=蓝，Read/Grep=紫，其他=橙
    private var categoryColor: Color {
        if request.isNotification || request.isAskUser {
            return .blue
        }
        return Self.toolColor(for: request.tool)
    }

    private static func toolColor(for tool: String) -> Color {
        ToolColors.color(for: tool)
    }

    private var bubbleShape: BubbleShape {
        BubbleShape(cornerRadius: Self.cardCornerRadius,
                    tailWidth: Self.tailWidth,
                    tailHeight: Self.tailHeight)
    }

    /// Subagent 用 amber 左边条，主 session 用工具类别色
    private var accentBarColor: Color {
        request.isSubagent ? Color(red: 0.96, green: 0.62, blue: 0.08) : categoryColor
    }

    var body: some View {
        VStack(spacing: 0) {
            // 气泡尾巴留白区域
            Color.clear.frame(height: Self.tailHeight)

            // 卡片主体
            HStack(spacing: 0) {
                // 左侧彩色边条 + 发光（subagent 显示 amber 以示区分）
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentBarColor)
                    .frame(width: request.isSubagent ? 4.5 : 3.5)
                    .padding(.vertical, 10)
                    .shadow(color: accentBarColor.opacity(0.5), radius: 8)
                    .opacity(isPulsing ? 0.65 : 1.0)

                VStack(alignment: .leading, spacing: 8) {
                    headerRow
                    toolRow
                    if !request.input.isEmpty && !request.isAskUser {
                        contentPreview
                    }
                    // AskUserQuestion: 显示问题文本
                    if request.isAskUser, let q = request.questions.first {
                        Text(q.text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    actionRow
                }
                .padding(.leading, 10)
                .padding(.trailing, 12)
                .padding(.vertical, 10)
            }
            .overlay(alignment: .bottom) {
                if hideDelay > 0 {
                    countdownBar
                        .allowsHitTesting(false)
                }
            }
        }
        .background(bubbleShape.fill(Self.cardBackground))
        .clipShape(bubbleShape)
        .overlay(bubbleShape.stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .scaleEffect(cardScale)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .onAppear {
            shownAt = Date()
            withAnimation(Self.bubbleSpring) {
                cardScale = 1.0
            }
            guard !request.isNotification else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    // MARK: - VoiceOver 汇总
    private var accessibilitySummary: String {
        let scope = request.isSubagent ? "Subagent " : ""
        let toolPart = request.tool.isEmpty ? "" : " · \(request.tool)"
        let cwd = request.cwdName.isEmpty ? "Session" : request.cwdName
        return "\(scope)\(agentMeta.displayName)\(toolPart) · \(cwd)"
    }

    // MARK: - 倒计时进度条

    private var countdownBar: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: false)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(shownAt)
            let remaining = max(0, 1 - elapsed / hideDelay)
            GeometryReader { geo in
                Rectangle()
                    .fill(categoryColor.opacity(0.55))
                    .frame(width: geo.size.width * CGFloat(remaining), height: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 2)
        }
    }

    // MARK: - 标题行

    private var headerRow: some View {
        HStack(spacing: 5) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            Text(agentMeta.icon)
                .font(.system(size: 12))
            Text(request.cwdName.isEmpty ? "Session" : request.cwdName)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)

            Spacer()

            if let onJump {
                Button(action: onJump) {
                    HStack(spacing: 3) {
                        if request.isNotification {
                            Text(String(localized: "approval.respond_in_terminal"))
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        Image(systemName: "terminal")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "approval.jump_to_terminal"))
            }
        }
    }

    // MARK: - 工具行

    private var toolRow: some View {
        HStack(spacing: 5) {
            ToolPill(name: request.tool, color: categoryColor)
            if request.isSubagent {
                Text("Subagent")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(red: 1.0, green: 0.75, blue: 0.35))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.96, green: 0.62, blue: 0.08).opacity(0.18))
                    .clipShape(Capsule())
            }
            if !request.terminalName.isEmpty {
                Text("·")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                Text(request.terminalName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    // MARK: - 内容预览

    private var contentPreview: some View {
        // 阻塞期间禁用文本选择，避免与飞入手势冲突；通知卡可选
        ScrollView(.vertical, showsIndicators: false) {
            Group {
                if request.isNotification {
                    Text(request.input)
                        .textSelection(.enabled)
                } else {
                    Text(request.input)
                        .textSelection(.disabled)
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 80)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 操作行

    @ViewBuilder
    private var actionRow: some View {
        if request.isAskUser {
            askUserActionRow
        } else if !request.isNotification {
            HStack(spacing: 5) {
                // Deny: 紧凑图标按钮
                Button(action: onDeny) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.55))
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityLabel(String(localized: "approval.deny"))
                .accessibilityHint("Command N")

                Spacer()

                // 按钮层级：Allow Once 主操作（primary），Always Allow 次要（light），Auto Approve 警告色（amber）
                CardButton(
                    label: String(localized: "approval.allow_once"),
                    icon: "checkmark",
                    style: .primary,
                    action: onApprove
                )
                .accessibilityHint("Command Y")
                CardButton(
                    label: String(localized: "approval.always_allow"),
                    icon: "checkmark.circle",
                    style: .light,
                    action: onAlwaysAllow
                )
                .accessibilityHint("Shift Command Y")
                CardButton(
                    label: String(localized: "approval.auto_approve"),
                    icon: "bolt.fill",
                    style: .amber,
                    action: onAutoApprove
                )
                .accessibilityHint("Shift Command N · Auto approve all tools in this session")
            }
        }
    }

    // MARK: - AskUserQuestion 选项

    @ViewBuilder
    private var askUserActionRow: some View {
        if let question = request.questions.first {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        onAnswer?(question.text, option)
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.primary.opacity(0.5))
                                .frame(width: 14, height: 14)
                                .background(Color.primary.opacity(0.1))
                                .clipShape(Circle())
                            Text(option)
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(2)
                            Spacer()
                        }
                        .foregroundColor(.primary.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 气泡形状（圆角矩形 + 顶部三角尾巴）

private struct BubbleShape: Shape {
    let cornerRadius: CGFloat
    let tailWidth: CGFloat
    let tailHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let cr = min(cornerRadius, min(rect.width, max(rect.height - tailHeight, 0)) / 2)
        let bodyTop = rect.minY + tailHeight
        let tailCenterX = rect.midX
        let halfTail = min(tailWidth, rect.width - 2 * cr) / 2

        var p = Path()

        p.move(to: CGPoint(x: rect.minX, y: bodyTop + cr))
        p.addArc(center: CGPoint(x: rect.minX + cr, y: bodyTop + cr),
                 radius: cr,
                 startAngle: .degrees(180),
                 endAngle: .degrees(270),
                 clockwise: false)
        p.addLine(to: CGPoint(x: tailCenterX - halfTail, y: bodyTop))
        p.addLine(to: CGPoint(x: tailCenterX, y: rect.minY))
        p.addLine(to: CGPoint(x: tailCenterX + halfTail, y: bodyTop))
        p.addLine(to: CGPoint(x: rect.maxX - cr, y: bodyTop))
        p.addArc(center: CGPoint(x: rect.maxX - cr, y: bodyTop + cr),
                 radius: cr,
                 startAngle: .degrees(270),
                 endAngle: .degrees(0),
                 clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cr))
        p.addArc(center: CGPoint(x: rect.maxX - cr, y: rect.maxY - cr),
                 radius: cr,
                 startAngle: .degrees(0),
                 endAngle: .degrees(90),
                 clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + cr, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + cr, y: rect.maxY - cr),
                 radius: cr,
                 startAngle: .degrees(90),
                 endAngle: .degrees(180),
                 clockwise: false)

        p.closeSubpath()
        return p
    }
}

// MARK: - 工具名胶囊（工具类别图标 + 颜色）

private struct ToolPill: View {
    let name: String
    let color: Color

    private var iconName: String {
        switch name {
        case "Bash": return "terminal"
        case "Edit": return "pencil"
        case "Write": return "doc.text"
        case "Read": return "eye"
        case "Grep", "Glob": return "magnifyingglass"
        case "NotebookEdit": return "note.text"
        case "AskUserQuestion", "Elicitation": return "questionmark.circle"
        case "PermissionRequest": return "lock.shield"
        default: return "wrench"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .font(.system(size: 8.5, weight: .semibold))
            Text(name)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - 按钮（label + icon）

private struct CardButton: View {
    let label: String
    let icon: String
    let style: ButtonVariant
    let action: () -> Void

    enum ButtonVariant {
        case light       // 次要：始终允许
        case primary     // 主操作：允许一次
        case amber       // 警告：自动批准（高风险）
    }

    private var bgColor: Color {
        switch style {
        case .light: .primary.opacity(0.15)
        case .primary: .accentColor
        case .amber: Color(red: 0.96, green: 0.62, blue: 0.08)
        }
    }

    private var fgColor: Color {
        switch style {
        case .light: .primary.opacity(0.85)
        case .primary: .white
        case .amber: .white
        }
    }

    private var fontWeight: Font.Weight {
        style == .light ? .medium : .semibold
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: fontWeight))
                Text(label)
                    .font(.system(size: 10.5, weight: fontWeight))
                    .fixedSize()
            }
            .foregroundColor(fgColor)
            .padding(.horizontal, 9)
            .frame(height: 28)
        }
        .buttonStyle(.plain)
        .background(bgColor)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel(label)
    }
}
