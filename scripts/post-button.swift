// 합성 일반 버튼 클릭. 사용: swift scripts/post-button.swift [버튼 번호, 기본 3]
// 현재 커서 위치에 otherMouseDown/Up을 post하고, 세션 탭 끝(listen-only)에서 이벤트가 몇 개 보였는지 출력한다.
// FreeLogi의 active 탭이 삼키면 `seen=0`, 아무도 안 삼키면 `seen=2`(앱에 실제 클릭이 간다).
import CoreGraphics
import Foundation

let buttonNumber = CommandLine.arguments.dropFirst().first.flatMap { Int64($0) } ?? 3
let observeSeconds = 0.5

var seenCount = 0
let observer = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .tailAppendEventTap,
    options: .listenOnly,
    eventsOfInterest: CGEventMask(1) << CGEventType.otherMouseDown.rawValue | CGEventMask(1) << CGEventType.otherMouseUp.rawValue,
    callback: { _, _, event, _ in
        seenCount += 1
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

let cursor = CGEvent(source: nil)?.location ?? .zero
for type in [CGEventType.otherMouseDown, CGEventType.otherMouseUp] {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cursor, mouseButton: .center)
    event?.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
    event?.post(tap: .cghidEventTap)
}
CFRunLoopRunInMode(.defaultMode, observeSeconds, false)
print("posted button=\(buttonNumber) seen=\(seenCount)")
