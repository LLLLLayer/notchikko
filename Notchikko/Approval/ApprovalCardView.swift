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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题行：关闭按钮 + 项目名 + 跳转按钮
            HStack(spacing: 6) {
                // macOS 风格关闭按钮
                if let onClose {
                    Button(action: onClose) {
                        Circle()
                            .fill(Color.red.opacity(0.8))
                            .frame(width: 12, height: 12)
                            .overlay(
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.9))
                            )
                    }
                    .buttonStyle(.plain)
                }

                Text(request.cwdName.isEmpty ? "Session" : request.cwdName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
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

            // 信息标签：Agent + Terminal + Tool
            HStack(spacing: 6) {
                InfoTag(icon: agentMeta.icon, text: agentMeta.displayName)
                if !request.terminalName.isEmpty {
                    InfoTag(icon: "🖥", text: request.terminalName)
                }
                InfoTag(icon: "⚙", text: request.tool)
                Spacer()
            }

            // 内容预览（可滚动）
            if !request.input.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    Text(request.input)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // 按钮行（仅有 requestId 时显示审批按钮）
            if !request.requestId.isEmpty {
                HStack(spacing: 6) {
                    Button(action: onDeny) {
                        Text(String(localized: "approval.deny"))
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                    }
                    .buttonStyle(.plain)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Spacer()

                    Button(action: onApprove) {
                        Text(String(localized: "approval.allow_once"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                    }
                    .buttonStyle(.plain)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button(action: onApproveAll) {
                        Text(String(localized: "approval.allow_all"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                    }
                    .buttonStyle(.plain)
                    .background(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}

// MARK: - 信息标签

private struct InfoTag: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Text(icon).font(.system(size: 10))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
