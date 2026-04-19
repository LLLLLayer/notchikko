import AppKit
import SwiftUI

/// 首次启动 / 从"关于"页打开的 CLI Hook 引导视图。
/// 托管在 `HookOnboardingCoordinator` 的 NSPanel 里。
struct HookOnboardingView: View {
    let onClose: () -> Void
    let onInstall: (CLIHookConfig) -> Void
    let onInstallAll: () -> Void
    let items: [CLIItem]

    struct CLIItem: Identifiable {
        let cli: CLIHookConfig
        let status: Status
        var id: String { cli.name }

        enum Status { case notDetected, notInstalled, installed }
    }

    @State private var iconHover = false

    private var detectedMissing: [CLIItem] {
        items.filter { $0.status == .notInstalled }
    }

    private var allSet: Bool {
        !items.isEmpty && detectedMissing.isEmpty &&
            items.contains(where: { $0.status == .installed })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4).padding(.horizontal, 28)
            list
            footer
        }
        .frame(width: 440)
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(iconHover ? 0.3 : 0.18),
                        radius: iconHover ? 10 : 6, y: iconHover ? 4 : 2)
                .offset(y: iconHover ? -2 : 0)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: iconHover)
                .onHover { iconHover = $0 }

            VStack(spacing: 4) {
                Text(String(localized: allSet ? "onboarding.all_done_title" : "onboarding.title"))
                    .font(.title2.bold())
                Text(String(localized: allSet ? "onboarding.all_done_subtitle" : "onboarding.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    // MARK: - CLI list

    private var list: some View {
        VStack(spacing: 8) {
            ForEach(items) { item in
                cliRow(item)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private func cliRow(_ item: CLIItem) -> some View {
        HStack(spacing: 12) {
            Text(item.cli.icon)
                .font(.title2)
                .frame(width: 32, height: 32)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .opacity(item.status == .notDetected ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.cli.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(item.status == .notDetected ? .secondary : .primary)
                Text(statusText(item.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            statusTrailing(item)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.quaternary.opacity(0.25))
        )
    }

    @ViewBuilder
    private func statusTrailing(_ item: CLIItem) -> some View {
        switch item.status {
        case .installed:
            Label(String(localized: "onboarding.status.installed"), systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .font(.title3)
                .accessibilityLabel(String(localized: "onboarding.status.installed"))
        case .notInstalled:
            Button(String(localized: "onboarding.status.install")) {
                onInstall(item.cli)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        case .notDetected:
            Text(statusText(item.status))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private func statusText(_ status: CLIItem.Status) -> String {
        switch status {
        case .installed: return String(localized: "onboarding.status.installed")
        case .notInstalled: return String(localized: "onboarding.subtitle.row_ready")
        case .notDetected: return String(localized: "onboarding.status.not_detected")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(String(localized: "onboarding.later")) {
                onClose()
            }
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)

            Button(String(localized: "onboarding.install_all")) {
                onInstallAll()
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(detectedMissing.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.quaternary.opacity(0.15))
    }
}
