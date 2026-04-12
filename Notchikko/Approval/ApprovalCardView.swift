import SwiftUI

struct ApprovalCardView: View {
    let request: ApprovalManager.ApprovalRequest
    let onDeny: () -> Void
    let onApprove: () -> Void
    let onApproveAll: () -> Void    // 当前 session 全部自动放行
    var onJump: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题行：Agent · Tool + 跳转按钮
            HStack(spacing: 6) {
                Text(CLIHookConfig.metadata(for: request.source).icon)
                    .font(.system(size: 14))
                Text(CLIHookConfig.metadata(for: request.source).displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(request.tool)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()

                // 右上角跳转按钮
                if let onJump {
                    Button(action: onJump) {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "approval.jump_to_terminal"))
                }
            }

            // 操作内容预览（多行展示）
            if !request.input.isEmpty {
                Text(request.input)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.7))
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // 按钮行
            HStack(spacing: 6) {
                ApprovalButton(
                    title: String(localized: "approval.deny"),
                    style: .secondary,
                    shortcut: "n",
                    action: onDeny
                )

                Spacer()

                ApprovalButton(
                    title: String(localized: "approval.allow_once"),
                    style: .primary,
                    shortcut: "y",
                    action: onApprove
                )

                ApprovalButton(
                    title: String(localized: "approval.allow_all"),
                    style: .danger,
                    action: onApproveAll
                )
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}

// MARK: - 按钮组件

private enum ButtonStyle {
    case secondary, primary, danger
}

private struct ApprovalButton: View {
    let title: String
    let style: ButtonStyle
    var shortcut: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: style == .secondary ? .medium : .semibold))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 10)
                .frame(height: 26)
        }
        .buttonStyle(.plain)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .ifLet(shortcut) { view, key in
            view.keyboardShortcut(KeyEquivalent(Character(key)), modifiers: .command)
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .secondary: .primary
        case .primary: .white
        case .danger: .white
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .secondary: Color.primary.opacity(0.08)
        case .primary: .accentColor
        case .danger: .red
        }
    }
}

private extension View {
    @ViewBuilder
    func ifLet<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}
