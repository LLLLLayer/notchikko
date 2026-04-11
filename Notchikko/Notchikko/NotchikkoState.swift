import Foundation

enum NotchikkoState: String, CaseIterable {
    case sleeping
    case idle
    case thinking
    case reading
    case typing
    case building
    case sweeping
    case happy
    case error
    case dragging
    case approving

    var svgName: String {
        switch self {
        case .sleeping: "clawd-sleeping"
        case .idle: "clawd-idle"
        case .thinking: "clawd-prompt"
        case .reading: "clawd-tool-edit"
        case .typing: "clawd-tool-edit"
        case .building: "clawd-tool-bash"
        case .sweeping: "clawd-compact"
        case .happy: "clawd-stop"
        case .error: "clawd-error"
        case .dragging: "clawd-drag"
        case .approving: "clawd-idle"  // TODO: clawd-approving
        }
    }

    var revealAmount: CGFloat {
        switch self {
        case .sleeping: 0.05
        case .idle: 0.30
        case .thinking: 0.40
        case .reading: 0.40
        case .typing: 0.50
        case .building: 0.50
        case .sweeping: 0.45
        case .happy: 0.60
        case .error: 0.50
        case .dragging: 1.0
        case .approving: 0.80
        }
    }

    /// 音效映射 key（与 SoundManager.defaultSoundMap 对应）
    var soundKey: String { rawValue }

    var priority: Int {
        switch self {
        case .dragging: 100
        case .approving: 95
        case .error: 90
        case .happy: 80
        case .building: 70
        case .typing: 60
        case .reading: 55
        case .sweeping: 53
        case .thinking: 50
        case .idle: 20
        case .sleeping: 10
        }
    }
}
