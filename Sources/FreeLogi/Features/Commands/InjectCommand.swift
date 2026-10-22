import Foundation

private let defaultHoldMilliseconds: UInt32 = 50
private let usage = "사용: --inject <keyCode> <modifiers: CGEventFlags 값(0x 가능)> [누르는 시간 ms, 기본 50]"

private func parseNumber(_ text: String) -> UInt64? {
    guard text.hasPrefix("0x") else { return UInt64(text) }
    return UInt64(text.dropFirst(2), radix: 16)
}

// 디버그(--inject <keyCode> <modifiers> [ms]): KeyCombo를 press → ms 대기 → release로 보내고 끝난다.
func runInject(arguments: [String]) -> Int32 {
    guard arguments.count >= 2,
          let keyCode = UInt16(arguments[0]),
          let modifiers = parseNumber(arguments[1])
    else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return 1
    }
    let holdMilliseconds = arguments.dropFirst(2).first.flatMap { UInt32($0) } ?? defaultHoldMilliseconds

    let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
    KeyInjector.press(combo)
    usleep(holdMilliseconds * 1000)
    KeyInjector.release(combo)
    print("injected \(combo.displayString) hold=\(holdMilliseconds)ms")
    return 0
}
