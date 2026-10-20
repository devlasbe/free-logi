// scroll-check.sh의 합성 스크롤·세션 관찰 helper. 사용: scroll-events observe | post <phase> <momentum>
import CoreGraphics
import Foundation

let marker: Int64 = 470047
let fields: [CGEventField] = [
    .scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1,
    .scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2,
]
let arguments = Array(CommandLine.arguments.dropFirst())
setvbuf(stdout, nil, _IOLBF, 0)

if arguments.first == "post", arguments.count == 3,
   let phase = Int64(arguments[1]), let momentum = Int64(arguments[2]) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) else { exit(1) }
    let values: [Int64] = [3, 30, 196608, -5, -50, -327680]
    for (field, value) in zip(fields, values) { event.setIntegerValueField(field, value: value) }
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    event.setIntegerValueField(.eventSourceUserData, value: marker)
    event.post(tap: .cghidEventTap)
    // post 직후 바로 끝나면 이벤트가 가끔 버려진다(30번 중 3번, 2026-10-20).
    usleep(100_000)
} else if arguments == ["observe"] {
    let observer = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .tailAppendEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask(1) << CGEventType.scrollWheel.rawValue,
        callback: { _, type, event, _ in
            if type == .scrollWheel && event.getIntegerValueField(.eventSourceUserData) == marker {
                let values = fields.map { String(event.getIntegerValueField($0)) }
                print(values.joined(separator: " "))
            }
            return Unmanaged.passUnretained(event)
        },
        userInfo: nil
    )
    guard let observer else {
        print("관찰 탭을 만들지 못했다(입력 모니터링 권한 필요)")
        exit(1)
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, observer, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    print("ready")
    CFRunLoopRunInMode(.defaultMode, 2, false)
} else {
    print("사용: scroll-events observe | post <phase> <momentum>")
    exit(1)
}
