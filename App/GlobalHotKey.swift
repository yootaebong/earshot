import Carbon.HIToolbox

/// ⌃⌥R 전역 단축키. Carbon RegisterEventHotKey 라 손쉬운 사용 권한이 필요 없다.
@MainActor
final class GlobalHotKey {
    private static let signature: OSType = 0x4541_5253 // 'EARS'
    private static var handler: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// 등록에 실패하면 nil
    init?(handler: @escaping () -> Void) {
        Self.handler = handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Carbon 콜백은 메인 스레드에서 온다.
        let callback: EventHandlerUPP = { _, _, _ in
            MainActor.assumeIsolated { GlobalHotKey.handler?() }
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &eventHandlerRef) == noErr else { return nil }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}
