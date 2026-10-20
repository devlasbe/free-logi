import CoreGraphics
import Foundation

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

// 시각과 출력만 주입한다. 소수 픽셀은 다음 틱으로 넘겨 총 이동량을 보존한다.
struct ScrollDecay {
    static let timeConstant: TimeInterval = 0.055
    private var remaining = SIMD2<Double>.zero
    private var fraction = SIMD2<Double>.zero
    private var lastTime: TimeInterval?

    var isActive: Bool { remaining != .zero || fraction != .zero }

    mutating func add(vertical: Int64, horizontal: Int64, at time: TimeInterval) {
        if !isActive { lastTime = time }
        remaining += SIMD2(Double(vertical), Double(horizontal))
    }

    mutating func finish(post: (Int32, Int32) -> Void) {
        let total = remaining + fraction
        let vertical = Int32(clamping: Int64(total[0].rounded()))
        let horizontal = Int32(clamping: Int64(total[1].rounded()))
        if vertical != 0 || horizontal != 0 { post(vertical, horizontal) }
        self = ScrollDecay()
    }

    mutating func tick(at time: TimeInterval, post: (Int32, Int32) -> Void) {
        guard let lastTime else { return }
        let elapsed = max(0, time - lastTime)
        self.lastTime = time
        let ratio = 1 - exp(-elapsed / Self.timeConstant)
        var pixels = SIMD2<Int32>.zero
        for axis in 0..<2 {
            let distance = remaining[axis] * ratio
            remaining[axis] -= distance
            fraction[axis] += distance
            if abs(remaining[axis]) < 0.5 {
                fraction[axis] += remaining[axis]
                remaining[axis] = 0
                pixels[axis] = Int32(clamping: Int64(fraction[axis].rounded()))
            } else {
                pixels[axis] = Int32(clamping: Int64(fraction[axis]))
            }
            fraction[axis] -= Double(pixels[axis])
            if remaining[axis] == 0 && abs(fraction[axis]) < 0.5 { fraction[axis] = 0 }
        }
        if pixels != .zero { post(pixels[0], pixels[1]) }
        if !isActive { self.lastTime = nil }
    }
}

let smoothScrollMarker: Int64 = 0x467265654C6F6769

func makeSmoothScrollEvent(vertical: Int32, horizontal: Int32, flags: CGEventFlags) -> CGEvent? {
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                        wheel1: vertical, wheel2: horizontal, wheel3: 0)
    event?.flags = flags
    event?.setIntegerValueField(.eventSourceUserData, value: smoothScrollMarker)
    return event
}

// 토글이 켜진 동안만 산다. active 탭·재활성화는 ButtonTap과 같은 경로다.
@MainActor
final class ScrollTap {
    // init이 성공하면 항상 있다(콜백에 self를 넘기려고 init 도중에는 비워 둔다).
    private var tap: CFMachPort!
    private var source: CFRunLoopSource!
    var reverseVertical = false
    var reverseHorizontal = false
    var smoothScrolling = false {
        didSet {
            if !smoothScrolling { stopSmoothing() }
        }
    }
    private static let tickInterval: TimeInterval = 1.0 / 120
    private var decay = ScrollDecay()
    private var timer: Timer?
    private var flags: CGEventFlags = []
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

    fileprivate func smooth(vertical: Int64, horizontal: Int64, flags: CGEventFlags) -> Bool {
        guard smoothScrolling else { return false }

        // 수식키가 바뀌면 앞 입력을 그때의 flags로 마저 보낸다.
        if decay.isActive && self.flags != flags {
            decay.finish(post: post)
        }
        self.flags = flags
        decay.add(vertical: vertical, horizontal: horizontal,
                  at: ProcessInfo.processInfo.systemUptime)
        if decay.isActive && timer == nil {
            let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        return true
    }

    private func post(vertical: Int32, horizontal: Int32) {
        let event = makeSmoothScrollEvent(vertical: vertical, horizontal: horizontal, flags: flags)
        event?.post(tap: .cgSessionEventTap)
    }

    private func tick() {
        decay.tick(at: ProcessInfo.processInfo.systemUptime, post: post)
        if !decay.isActive { stopSmoothing() }
    }

    private func stopSmoothing() {
        timer?.invalidate()
        timer = nil
        decay = ScrollDecay()
    }

    // 탭은 stop을 부를 때까지 산다(콜백이 self를 retain 없이 들고 있다).
    func stop() {
        stopSmoothing()
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

    if event.getIntegerValueField(.eventSourceUserData) == smoothScrollMarker {
        return Unmanaged.passUnretained(event)
    }
    let (vertical, horizontal) = MainActor.assumeIsolated {
        (scrollTap.reverseVertical, scrollTap.reverseHorizontal)
    }
    reverseScroll(event, vertical: vertical, horizontal: horizontal)
    if event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0 ||
        event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 {
        return Unmanaged.passUnretained(event)
    }
    let verticalDelta = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
    let horizontalDelta = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
    let flags = event.flags
    let swallowed = MainActor.assumeIsolated {
        scrollTap.smooth(vertical: verticalDelta, horizontal: horizontalDelta, flags: flags)
    }
    if swallowed { return nil }
    return Unmanaged.passUnretained(event)
}
