import SwiftUI

struct ApprovalCardView: View {
    let request: ApprovalManager.ApprovalRequest
    let onDeny: () -> Void
    let onApprove: () -> Void
    let onApproveAll: () -> Void
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
                if !request.input.isEmpty {
                    contentPreview
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
        if !request.isNotification {
            HStack(spacing: 6) {
                CardButton(
                    label: String(localized: "approval.deny"),
                    icon: "xmark",
                    style: .destructive,
                    action: onDeny
                )

                Spacer()

                CardButton(
                    label: String(localized: "approval.allow_once"),
                    icon: "checkmark",
                    style: .primary,
                    action: onApprove
                )
                CardButton(
                    label: String(localized: "approval.allow_all"),
                    icon: "checkmark.circle",
                    style: .secondary,
                    action: onApproveAll
                )
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
        case primary, secondary, destructive
    }

    private var bgColor: Color {
        switch style {
        case .primary: .accentColor
        case .secondary: .primary.opacity(0.07)
        case .destructive: .red.opacity(0.12)
        }
    }

    private var fgColor: Color {
        switch style {
        case .primary: .white
        case .secondary: .primary.opacity(0.7)
        case .destructive: .red
        }
    }

    private var fontWeight: Font.Weight {
        style == .primary ? .semibold : .medium
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
