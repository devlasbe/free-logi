import CoreGraphics

// KeyCombo를 키 이벤트로 보낸다. 버튼 down에 press, up에 release를 부르면 버튼을 누르는 동안 키도 눌려 있다.
enum KeyInjector {
    static func press(_ combo: KeyCombo) {
        post(combo, isDown: true)
    }

    static func release(_ combo: KeyCombo) {
        post(combo, isDown: false)
    }

    private static func post(_ combo: KeyCombo, isDown: Bool) {
        let keyCode = CGKeyCode(combo.keyCode)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown)
        event?.flags = CGEventFlags(rawValue: combo.modifiers & KeyCombo.modifierMask).union(hardwareFlags(keyCode))
        event?.post(tap: .cghidEventTap)
    }

    // 실제 키보드가 붙이는 플래그. 없으면 ⌃↑(Mission Control) 같은 시스템 단축키가 키로 인식되지 않는다.
    static func hardwareFlags(_ keyCode: CGKeyCode) -> CGEventFlags {
        switch keyCode {
        case 123...126: return [.maskSecondaryFn, .maskNumericPad] // ← → ↓ ↑
        case 114...122, 96...101, 103, 105, 106, 107, 109, 111, 64, 79, 80, 90: return .maskSecondaryFn // F키·Home·End·PgUp·PgDn·⌦
        default: return []
        }
    }
}
