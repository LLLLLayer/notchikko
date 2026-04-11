import Foundation

/// Agent 通信协议，新 Agent 只需实现此协议
protocol AgentBridge: AnyObject {
    var agentName: String { get }
    var agentIcon: String { get }
    func start() async throws
    func stop() async
    var eventStream: AsyncStream<AgentEvent> { get }
}
