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
    case petting

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
        case .petting: 0.70
        }
    }

    /// 音效映射 key（与 SoundManager.defaultSoundMap 对应）
    var soundKey: String { rawValue }

    var priority: Int {
        switch self {
        case .dragging: 100
        case .approving: 95
        case .petting: 92
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

    /// 资源缺失时的视觉兜底（用于过渡期、用户主题尚未提供该状态资源时）
    var fallbackState: NotchikkoState? {
        switch self {
        case .petting: return .happy
        default: return nil
        }
    }
}
