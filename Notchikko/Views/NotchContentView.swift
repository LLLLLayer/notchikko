import SwiftUI

struct NotchContentView: View {
    let notchHeight: CGFloat
    var sessionManager: SessionManager
    var approvalManager: ApprovalManager?
    var petSize: CGFloat = 80

    var body: some View {
        ZStack(alignment: .top) {
            // 宠物居中贴在 panel 顶部，上半身自然藏在 notch 里
            NotchikkoRepresentable(svgName: sessionManager.currentState.svgName)
                .frame(width: petSize, height: petSize)

            // 审批卡片（浮层，不影响宠物位置）
            if let manager = approvalManager,
               manager.hasPendingApproval,
               manager.isCardVisible,
               let request = manager.pendingApproval {
                ApprovalCardView(
                    request: request,
                    onApprove: { manager.approve() },
                    onDeny: { manager.deny() }
                )
                .frame(maxWidth: 240)
                // 卡片在宠物右侧，从 notch 下沿开始
                .offset(x: petSize / 2 + 16, y: notchHeight + 4)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topLeading)))
                .animation(.spring(duration: 0.3), value: manager.isCardVisible)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct NotchikkoRepresentable: NSViewRepresentable {
    let svgName: String

    func makeNSView(context: Context) -> NotchikkoView {
        let view = NotchikkoView(frame: .zero)
        view.loadSVG(named: svgName)
        return view
    }

    func updateNSView(_ nsView: NotchikkoView, context: Context) {
        nsView.loadSVG(named: svgName)
    }
}
