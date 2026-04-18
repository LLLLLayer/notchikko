import Foundation

/// Hook 脚本发来的原始 JSON（所有 CLI 共用同一格式）
struct HookEvent: Decodable {
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    let tool: String?
    let toolInput: [String: AnyCodableValue]?
    let source: String?
    let requestId: String?
    let prompt: String?          // v0.3: 用户 prompt 文本
    let terminalPid: Int?        // v0.3: 终端进程 PID（hook 进程树检测）
    let terminalTty: String?     // v0.3: 终端 tty 路径（用于 iTerm2 tab 定位）
    let permissionMode: String?  // "default" / "bypassPermissions" 等
    let pidChain: [Int]?         // v0.4: hook→终端的 PID 链（VS Code 终端定位）
    let usage: TokenUsage?       // Stop 事件携带的 token 用量

    struct TokenUsage: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheRead: Int
        let cacheCreation: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheRead = "cache_read"
            case cacheCreation = "cache_creation"
        }

        var totalTokens: Int { inputTokens + outputTokens }

        /// 估算成本（USD），基于 Claude Sonnet 4 定价
        var estimatedCostUSD: Double {
            let inputCost = Double(inputTokens) * 3.0 / 1_000_000
            let outputCost = Double(outputTokens) * 15.0 / 1_000_000
            let cacheCost = Double(cacheRead) * 0.30 / 1_000_000
            return inputCost + outputCost + cacheCost
        }
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd, event, status, tool, source, prompt, usage
        case toolInput = "tool_input"
        case requestId = "request_id"
        case terminalPid = "terminal_pid"
        case terminalTty = "terminal_tty"
        case permissionMode = "permission_mode"
        case pidChain = "pid_chain"
    }
}

/// JSON 中任意值的包装（支持嵌套数组和对象）
enum AnyCodableValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { self = .string(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode([AnyCodableValue].self) { self = .array(v) }
        else if let v = try? container.decode([String: AnyCodableValue].self) { self = .object(v) }
        else { self = .null }
    }

    /// 提取字符串值
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// 统一事件模型（多 Agent 通用）
enum AgentEvent {
    case sessionStart(sessionId: String, cwd: String, source: String, terminalPid: Int?, pidChain: [Int]?)
    case sessionEnd(sessionId: String)
    case prompt(sessionId: String, text: String?)
    case toolUse(sessionId: String, tool: String, phase: ToolPhase)
    /// 信息性通知（Elicitation、Notification、AskUserQuestion 等）。
    /// 注意：阻塞式 PermissionRequest 不走这里，走 `SocketServer.onApprovalRequest` 直通；
    /// 非阻塞 PermissionRequest 走下面的 .permissionRequest case。
    case notification(sessionId: String, message: String, detail: String = "")
    /// 非阻塞 PermissionRequest（hook 没生成 request_id：approvalCard 关 / bypass / 非审批工具）。
    case permissionRequest(sessionId: String, tool: String, detail: String)
    case compact(sessionId: String)
    case stop(sessionId: String, usage: HookEvent.TokenUsage?)
    case error(sessionId: String, message: String)
}

extension AgentEvent {
    var sessionId: String {
        switch self {
        case .sessionStart(let sid, _, _, _, _): sid
        case .sessionEnd(let sid): sid
        case .prompt(let sid, _): sid
        case .toolUse(let sid, _, _): sid
        case .notification(let sid, _, _): sid
        case .permissionRequest(let sid, _, _): sid
        case .compact(let sid): sid
        case .stop(let sid, _): sid
        case .error(let sid, _): sid
        }
    }
}

enum ToolPhase {
    case pre
    case post(success: Bool)
}
