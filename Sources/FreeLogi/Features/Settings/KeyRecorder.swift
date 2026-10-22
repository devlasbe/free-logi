import AppKit
import Carbon

extension KeyCombo {
    // 저장·주입하는 수식키. fn은 방향키·F키에 OS가 붙이는 플래그라 녹화 때 구분할 수 없어 뺀다.
    static let modifierFlags: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
    static let modifierMask = modifierFlags.rawValue

    // NSEvent와 CGEventFlags는 수식키 비트 위치가 같다(KeyComboTests가 확인한다).
    init(event: NSEvent) {
        let flags = UInt64(event.modifierFlags.rawValue)
        self.init(keyCode: event.keyCode, modifiers: flags & KeyCombo.modifierMask)
    }
}

// 설정 창(08)이 쓴다. start 뒤 첫 keyDown 하나를 KeyCombo로 돌려주고 스스로 멈춘다. 그 키는 앱·메뉴로 가지 않는다.
// 녹화 중에는 시스템 단축키(⌃↑ Mission Control 등)를 꺼 둔다. 켜 두면 Dock이 먼저 가져가 녹화할 수 없다.
@MainActor
final class KeyRecorder {
    private var monitor: Any?
    private var hotKeyMode: UnsafeMutableRawPointer?

    func start(onRecord: @escaping (KeyCombo) -> Void) {
        stop()
        hotKeyMode = PushSymbolicHotKeyMode(OptionBits(kHIHotKeyModeAllDisabled))
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let combo = KeyCombo(event: event)
            MainActor.assumeIsolated { self?.stop() }
            onRecord(combo)
            return nil
        }
    }

    func stop() {
        if let hotKeyMode {
            PopSymbolicHotKeyMode(hotKeyMode)
            self.hotKeyMode = nil
        }
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
