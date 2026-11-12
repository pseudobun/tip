import Carbon
import TipCore

/// One global hotkey (zen mode) through Carbon's RegisterEventHotKey: needs no permission.
@MainActor
final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var action: (@MainActor () -> Void)?
    private(set) var spec: String = ""

    func set(_ spec: String, _ action: @escaping @MainActor () -> Void) {
        guard spec != self.spec else { Self.action = action; return }
        clear()
        self.spec = spec
        guard let k = KeySpec.parse(spec), let code = k.keyCode else { return }
        Self.action = action
        var mods: UInt32 = 0
        if k.cmd { mods |= UInt32(cmdKey) }
        if k.alt { mods |= UInt32(optionKey) }
        if k.ctrl { mods |= UInt32(controlKey) }
        if k.shift { mods |= UInt32(shiftKey) }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Hotkey.action?() } }
            return noErr
        }, 1, &type, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x7469_7031), id: 1) // "tip1"
        if RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref) != noErr {
            Log.app.error("zen hotkey \(spec, privacy: .public) is taken")
        }
    }

    func clear() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
        spec = ""
    }
}
