import Carbon
import AppKit

/// 全局快捷键（Carbon，不需要辅助功能权限）
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    private func install() {
        guard !installed else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKeyCenter.shared.handlers[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
        installed = true
    }

    func register(id: UInt32, preset: HotKeyPreset, handler: @escaping () -> Void) {
        install()
        unregister(id: id)
        guard preset.keyCode != 0 || preset.modifiers != 0 else { return }
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5854_4B31), id: id)
        if RegisterEventHotKey(preset.keyCode, preset.modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref = ref {
            refs[id] = ref
            handlers[id] = handler
        }
    }

    func unregister(id: UInt32) {
        if let r = refs[id] { UnregisterEventHotKey(r); refs[id] = nil }
        handlers[id] = nil
    }
}
