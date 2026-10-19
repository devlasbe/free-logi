// 키 이벤트 관찰자. 사용: swift scripts/observe-keys.swift [초, 기본 5]
// 세션 탭 끝(listen-only)에서 keyDown/keyUp을 `down|up keyCode=<n> mods=<cmd,shift,opt,ctrl,fn,caps|-> t=<ms>`로 출력한다.
// 준비되면 `ready`를 먼저 출력한다. 앞 앱·화면 잠금과 상관없이 시스템에 들어간 이벤트를 본다(입력 모니터링 권한 필요).
import CoreGraphics
import Foundation

let observeSeconds = CommandLine.arguments.dropFirst().first.flatMap { Double($0) } ?? 5
let flagNames: [(CGEventFlags, String)] = [
    (.maskCommand, "cmd"), (.maskShift, "shift"), (.maskAlternate, "opt"),
    (.maskControl, "ctrl"), (.maskSecondaryFn, "fn"), (.maskAlphaShift, "caps"),
]

setvbuf(stdout, nil, _IOLBF, 0)
let startTime = DispatchTime.now().uptimeNanoseconds

let keyEvents = CGEventMask(1) << CGEventType.keyDown.rawValue | CGEventMask(1) << CGEventType.keyUp.rawValue
let observer = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .tailAppendEventTap,
    options: .listenOnly,
    eventsOfInterest: keyEvents,
    callback: { _, type, event, _ in
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let names = flagNames.filter { entry in event.flags.contains(entry.0) }.map { entry in entry.1 }
        let mods = names.isEmpty ? "-" : names.joined(separator: ",")
        let elapsedMilliseconds = (DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000
        let direction = type == .keyDown ? "down" : "up"
        print("\(direction) keyCode=\(keyCode) mods=\(mods) t=\(elapsedMilliseconds)")
        return Unmanaged.passUnretained(event)
    },
    userInfo: nil
)
guard let observer else {
    print("관찰 탭을 만들지 못했다(입력 모니터링 권한 필요)")
    exit(1)
}
let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, observer, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)

print("ready")
CFRunLoopRunInMode(.defaultMode, observeSeconds, false)
