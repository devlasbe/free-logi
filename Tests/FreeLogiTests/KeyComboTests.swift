import AppKit
import Carbon.HIToolbox
import XCTest
@testable import FreeLogi

@MainActor
final class KeyComboTests: XCTestCase {
    private func makeKeyDown(keyCode: Int, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: UInt16(keyCode)
        )!
    }

    func testDisplayStringUsesMenuModifierOrder() {
        let commandShift = KeyCombo.modifierMask & (CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
        XCTAssertEqual(KeyCombo(keyCode: UInt16(kVK_ANSI_4), modifiers: commandShift).displayString, "⇧⌘4")
        XCTAssertEqual(KeyCombo(keyCode: UInt16(kVK_ANSI_4), modifiers: KeyCombo.modifierMask).displayString, "⌃⌥⇧⌘4")
        XCTAssertEqual(KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: 0).displayString, "A")
        XCTAssertEqual(KeyCombo(keyCode: UInt16(kVK_F19), modifiers: 0).displayString, "F19")
        XCTAssertEqual(KeyCombo(keyCode: UInt16(kVK_LeftArrow), modifiers: 0).displayString, "←")
        XCTAssertEqual(KeyCombo(keyCode: UInt16(kVK_Space), modifiers: 0).displayString, "Space")
        XCTAssertEqual(KeyCombo(keyCode: 200, modifiers: 0).displayString, "#200")
    }

    func testDisplayStringIgnoresNonModifierFlags() {
        let capsLockAndFunction = CGEventFlags.maskAlphaShift.rawValue | CGEventFlags.maskSecondaryFn.rawValue
        XCTAssertEqual(KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: capsLockAndFunction).displayString, "A")
    }

    func testNSEventModifierBitsMatchCGEventFlags() {
        let pairs: [(NSEvent.ModifierFlags, CGEventFlags)] = [
            (.command, .maskCommand), (.shift, .maskShift), (.option, .maskAlternate), (.control, .maskControl),
        ]
        for (nsFlag, cgFlag) in pairs {
            XCTAssertEqual(UInt64(nsFlag.rawValue), cgFlag.rawValue)
        }
    }

    func testRecordedEventKeepsOnlyFourModifiers() {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .capsLock, .function, .numericPad]
        let combo = KeyCombo(event: makeKeyDown(keyCode: kVK_ANSI_4, flags: flags))

        XCTAssertEqual(combo.keyCode, UInt16(kVK_ANSI_4))
        XCTAssertEqual(combo.modifiers, CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
        XCTAssertEqual(combo.displayString, "⇧⌘4")
    }

    func testRecorderReturnsOnlyFirstKeyDown() {
        let recorder = KeyRecorder()
        var recorded: [KeyCombo] = []
        recorder.start { combo in recorded.append(combo) }

        let event = makeKeyDown(keyCode: kVK_ANSI_4, flags: [.command, .shift])
        NSApplication.shared.sendEvent(event)
        NSApplication.shared.sendEvent(event)

        XCTAssertEqual(recorded.map(\.displayString), ["⇧⌘4"])
    }
}
