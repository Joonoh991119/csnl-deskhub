import AppKit
import Carbon.HIToolbox

/// 전역 단축키 (Carbon RegisterEventHotKey — 접근성 권한 없이 동작). 설정 예: "ctrl+opt+d", "cmd+shift+space"
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    nonisolated(unsafe) private static var action: (() -> Void)?
    let label: String

    init?(_ spec: String, action: @escaping () -> Void) {
        guard let (code, mods, label) = HotKey.parse(spec) else { return nil }
        self.label = label
        HotKey.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &type, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4453_4B48), id: 1)   // 'DSKH'
        guard RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref) == noErr else {
            NSLog("DeskHub: 단축키 %@ 등록 실패 (다른 앱이 쓰는 중일 수 있음)", spec)
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    static func parse(_ spec: String) -> (UInt32, UInt32, String)? {
        var mods: UInt32 = 0, label = "", key: UInt32?
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control": mods |= UInt32(controlKey); label += "⌃"
            case "opt", "option", "alt": mods |= UInt32(optionKey); label += "⌥"
            case "shift": mods |= UInt32(shiftKey); label += "⇧"
            case "cmd", "command": mods |= UInt32(cmdKey); label += "⌘"
            default:
                key = keyCodes[part]
                label += part == "space" ? "Space" : part.uppercased()
            }
        }
        guard let key, mods != 0 else { return nil }
        return (key, mods, label)
    }

    private static let keyCodes: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C), "d": UInt32(kVK_ANSI_D), "e": UInt32(kVK_ANSI_E),
        "f": UInt32(kVK_ANSI_F), "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H), "i": UInt32(kVK_ANSI_I), "j": UInt32(kVK_ANSI_J),
        "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L), "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O),
        "p": UInt32(kVK_ANSI_P), "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R), "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T),
        "u": UInt32(kVK_ANSI_U), "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X), "y": UInt32(kVK_ANSI_Y),
        "z": UInt32(kVK_ANSI_Z), "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
        "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5), "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
        "9": UInt32(kVK_ANSI_9), "space": UInt32(kVK_Space), "`": UInt32(kVK_ANSI_Grave),
    ]
}
