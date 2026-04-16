import Carbon

/// 全局审批热键管理器。使用 Carbon RegisterEventHotKey，无需 Accessibility 权限。
/// 仅在有阻塞式审批卡片时激活，避免占用 Cmd+Y/N 等常用快捷键。
@MainActor
final class HotkeyManager {
    enum Action: UInt32 {
        case allowOnce   = 1   // Cmd+Y
        case alwaysAllow = 2   // Cmd+Shift+Y
        case deny        = 3   // Cmd+N
        case autoApprove = 4   // Cmd+Shift+N
    }

    var onAction: ((Action) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandlerRef: EventHandlerRef?
    private(set) var isActive = false

    /// C 回调无法捕获 self，用静态属性传递
    private nonisolated(unsafe) static var instance: HotkeyManager?
    /// 四字签名 "NTCH"
    private static let signature: OSType = 0x4E544348

    func activate() {
        guard !isActive else { return }
        HotkeyManager.instance = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let paramStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard paramStatus == noErr,
                      hotKeyID.signature == HotkeyManager.signature,
                      let action = Action(rawValue: hotKeyID.id) else {
                    return OSStatus(eventNotHandledErr)
                }
                Task { @MainActor in
                    HotkeyManager.instance?.onAction?(action)
                }
                return noErr
            },
            1, &eventType, nil, &eventHandlerRef
        )
        guard status == noErr else {
            Log("Failed to install hotkey handler: \(status)", tag: "Hotkey")
            return
        }

        // Cmd+Y → Allow Once
        registerHotKey(id: .allowOnce, keyCode: UInt32(kVK_ANSI_Y),
                       modifiers: UInt32(cmdKey))
        // Cmd+Shift+Y → Always Allow (this tool)
        registerHotKey(id: .alwaysAllow, keyCode: UInt32(kVK_ANSI_Y),
                       modifiers: UInt32(cmdKey | shiftKey))
        // Cmd+N → Deny
        registerHotKey(id: .deny, keyCode: UInt32(kVK_ANSI_N),
                       modifiers: UInt32(cmdKey))
        // Cmd+Shift+N → Auto Approve (session)
        registerHotKey(id: .autoApprove, keyCode: UInt32(kVK_ANSI_N),
                       modifiers: UInt32(cmdKey | shiftKey))

        isActive = true
        Log("Hotkeys activated (4 keys registered)", tag: "Hotkey")
    }

    func deactivate() {
        guard isActive else { return }
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs.removeAll()

        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }

        HotkeyManager.instance = nil
        isActive = false
        Log("Hotkeys deactivated", tag: "Hotkey")
    }

    private func registerHotKey(id: Action, keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRefs.append(ref)
        } else {
            Log("Failed to register hotkey \(id): \(status)", tag: "Hotkey")
        }
    }
}
