import SwiftUI

struct ApprovalCardView: View {
    let request: ApprovalManager.ApprovalRequest
    let onApprove: () -> Void
    let onDeny: () -> Void
    var onBypass: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题行
            HStack(spacing: 6) {
                Text(iconFor(request.source))
                    .font(.system(size: 14))
                Text("\(displayName(request.source))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(request.tool)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            // 操作内容
            Text(request.input)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.7))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // 按钮行
            HStack(spacing: 8) {
                Spacer()

                Button(action: onDeny) {
                    Text(String(localized: "approval.deny"))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 56, height: 26)
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .keyboardShortcut("n", modifiers: .command)

                Button(action: onApprove) {
                    Text(String(localized: "approval.allow"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 26)
                }
                .buttonStyle(.plain)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .keyboardShortcut("y", modifiers: .command)

                if let onBypass {
                    Button(action: onBypass) {
                        Text("Bypass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                            .frame(height: 26)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.plain)
                    .background(Color.red.opacity(0.1))
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

    private func iconFor(_ source: String) -> String {
        switch source {
        case "claude-code": return "🤖"
        case "codex": return "📦"
        default: return "🔧"
        }
    }

    private func displayName(_ source: String) -> String {
        switch source {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        default: return source
        }
    }
}
