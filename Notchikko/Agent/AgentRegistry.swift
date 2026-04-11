import Foundation

/// 管理多个 AgentBridge 实例，合并事件流
final class AgentRegistry {
    private(set) var adapters: [AgentBridge] = []

    func register(_ adapter: AgentBridge) {
        adapters.append(adapter)
    }

    func startAll() async {
        for adapter in adapters {
            try? await adapter.start()
        }
    }

    func stopAll() async {
        for adapter in adapters {
            await adapter.stop()
        }
    }

    /// 合并所有 adapter 的事件流为一个 AsyncStream
    var mergedEventStream: AsyncStream<AgentEvent> {
        let adapters = self.adapters
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for adapter in adapters {
                        let stream = adapter.eventStream
                        group.addTask {
                            for await event in stream {
                                continuation.yield(event)
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
