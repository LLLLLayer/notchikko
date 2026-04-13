import SwiftUI

struct ApprovalCardView: View {
    let request: ApprovalManager.ApprovalRequest
    let onDeny: () -> Void
    let onApprove: () -> Void
    let onAlwaysAllow: () -> Void
    let onAutoApprove: () -> Void
    /// AskUserQuestion: 用户选了某个选项 (questionText, optionLabel)
    var onAnswer: ((String, String) -> Void)? = nil
    var onJump: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    private var agentMeta: (icon: String, displayName: String) {
        CLIHookConfig.metadata(for: request.source)
    }

    /// 左侧边条颜色：通知=蓝，审批=橙
    private var accentBarColor: Color {
        request.isNotification ? .blue : .orange
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左侧彩色边条
            RoundedRectangle(cornerRadius: 2)
                .fill(accentBarColor)
                .frame(width: 3.5)
                .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 8) {
                headerRow
                toolRow
                if !request.input.isEmpty && !request.isAskUser {
                    contentPreview
                }
                // AskUserQuestion: 显示问题文本（不在 contentPreview 里，因为选项在 actionRow）
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
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
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
            }
        }
    }

    // MARK: - 工具行

    private var toolRow: some View {
        HStack(spacing: 5) {
            ToolPill(name: request.tool, isNotification: request.isNotification)
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
        ScrollView(.vertical, showsIndicators: false) {
            Text(request.input)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 80)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 操作行

    @ViewBuilder
    private var actionRow: some View {
        if request.isAskUser {
            // AskUserQuestion: 每个问题的选项作为可点击按钮
            askUserActionRow
        } else if !request.isNotification {
            HStack(spacing: 5) {
                CardButton(
                    label: String(localized: "approval.deny"),
                    icon: "xmark",
                    style: .muted,
                    action: onDeny
                )
                CardButton(
                    label: String(localized: "approval.allow_once"),
                    icon: "checkmark",
                    style: .light,
                    action: onApprove
                )
                CardButton(
                    label: String(localized: "approval.always_allow"),
                    icon: "checkmark.circle",
                    style: .primary,
                    action: onAlwaysAllow
                )
                CardButton(
                    label: String(localized: "approval.auto_approve"),
                    icon: "bolt.fill",
                    style: .destructive,
                    action: onAutoApprove
                )
            }
        }
    }

    // MARK: - AskUserQuestion 选项

    @ViewBuilder
    private var askUserActionRow: some View {
        // 只显示第一个问题的选项（多问题场景罕见，先支持单问题）
        if let question = request.questions.first {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(question.options, id: \.self) { option in
                    Button {
                        onAnswer?(question.text, option)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "circle")
                                .font(.system(size: 8))
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

// MARK: - 工具名胶囊

private struct ToolPill: View {
    let name: String
    let isNotification: Bool

    private var pillColor: Color {
        isNotification ? .blue : .orange
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isNotification ? "questionmark.circle" : "wrench")
                .font(.system(size: 8.5, weight: .semibold))
            Text(name)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundColor(pillColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(pillColor.opacity(0.1))
        .clipShape(Capsule())
    }
}

// MARK: - 按钮

private struct CardButton: View {
    let label: String
    let icon: String
    let style: ButtonStyle
    let action: () -> Void

    enum ButtonStyle {
        case muted       // 拒绝：深灰背景
        case light       // 允许一次：浅色/白色背景
        case primary     // 始终允许：蓝色背景
        case destructive // 自动批准：红色背景
    }

    private var bgColor: Color {
        switch style {
        case .muted: .primary.opacity(0.08)
        case .light: .primary.opacity(0.15)
        case .primary: .accentColor
        case .destructive: .red
        }
    }

    private var fgColor: Color {
        switch style {
        case .muted: .primary.opacity(0.5)
        case .light: .primary.opacity(0.85)
        case .primary: .white
        case .destructive: .white
        }
    }

    private var fontWeight: Font.Weight {
        (style == .primary || style == .destructive) ? .semibold : .medium
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: fontWeight))
                Text(label)
                    .font(.system(size: 10.5, weight: fontWeight))
            }
            .foregroundColor(fgColor)
            .padding(.horizontal, 9)
            .frame(height: 24)
        }
        .buttonStyle(.plain)
        .background(bgColor)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
