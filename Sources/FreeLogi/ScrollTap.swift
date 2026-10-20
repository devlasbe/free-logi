import CoreGraphics

// phase가 없는 휠 이벤트만 켜진 축의 세 필드를 뒤집는다.
func reverseScroll(_ event: CGEvent, vertical: Bool, horizontal: Bool) {
    let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
    let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
    if scrollPhase != 0 || momentumPhase != 0 { return }

    let axes: [(Bool, [CGEventField])] = [
        (vertical, [.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1]),
        (horizontal, [.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2]),
    ]
    for (enabled, fields) in axes where enabled {
        // DeltaAxis를 쓰면 point·fixed도 바뀌므로 먼저 모두 읽는다.
        let deltas = fields.map { event.getIntegerValueField($0) }
        for (field, delta) in zip(fields, deltas) {
            event.setIntegerValueField(field, value: 0 &- delta)
        }
    }
}

// 토글이 켜진 동안만 산다. active 탭·재활성화는 ButtonTap과 같은 경로다.
@MainActor
final class ScrollTap {
    // init이 성공하면 항상 있다(콜백에 self를 넘기려고 init 도중에는 비워 둔다).
    private var tap: CFMachPort!
    private var source: CFRunLoopSource!
    var reverseVertical = false
    var reverseHorizontal = false
    // 시스템이 탭을 꺼서 다시 켠 횟수
    private(set) var reenabledCount = 0

    init?() {
        let eventMask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        let context = Unmanaged.passUnretained(self).toOpaque()
        let createdTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: scrollTapCallback,
            userInfo: context
        )
        guard let createdTap else { return nil }

        self.tap = createdTap
        self.source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    // 콜백이 오래 걸리면(메인 스레드가 막히면) 시스템이 탭을 끈다. 꺼져 있으면 다시 켠다.
    // 끄면서 보내는 tapDisabledByTimeout 콜백이 안 오는 경우가 있어(macOS 26, 2026-10-18 실측) 주기적으로도 부른다.
    func reenableIfDisabled() {
        if isEnabled { return }
        reenable()
    }

    var isEnabled: Bool { CGEvent.tapIsEnabled(tap: tap) }

    fileprivate func reenable() {
        CGEvent.tapEnable(tap: tap, enable: true)
        reenabledCount += 1
    }

    // 탭은 stop을 부를 때까지 산다(콜백이 self를 retain 없이 들고 있다).
    func stop() {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
    }
}

private let scrollTapCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    let scrollTap = Unmanaged<ScrollTap>.fromOpaque(context).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { scrollTap.reenable() }
        return Unmanaged.passUnretained(event)
    }

    let (vertical, horizontal) = MainActor.assumeIsolated {
        (scrollTap.reverseVertical, scrollTap.reverseHorizontal)
    }
    reverseScroll(event, vertical: vertical, horizontal: horizontal)
    return Unmanaged.passUnretained(event)
}
