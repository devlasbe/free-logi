import CoreGraphics

private let minimumButtonNumber = 3

// 일반 마우스 버튼(번호 3 이상: 뒤로·앞으로 …)의 otherMouseDown/Up을 active 탭으로 받는다.
// handler가 true를 돌려주면 그 이벤트를 삼킨다(앱에 전달되지 않는다). 손쉬운 사용 권한이 없으면 만들어지지 않는다(nil).
@MainActor
final class ButtonTap {
    // init이 성공하면 항상 있다(콜백에 self를 넘기려고 init 도중에는 비워 둔다).
    private var tap: CFMachPort!
    private var source: CFRunLoopSource!
    fileprivate let handler: (_ buttonNumber: Int, _ isDown: Bool) -> Bool
    // 시스템이 탭을 꺼서 다시 켠 횟수
    private(set) var reenabledCount = 0

    init?(handler: @escaping (_ buttonNumber: Int, _ isDown: Bool) -> Bool) {
        self.handler = handler

        let buttonEvents = [CGEventType.otherMouseDown, CGEventType.otherMouseUp]
        let eventMask = buttonEvents.reduce(CGEventMask(0)) { mask, type in mask | CGEventMask(1) << type.rawValue }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let createdTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: buttonTapCallback,
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

private let buttonTapCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    let buttonTap = Unmanaged<ButtonTap>.fromOpaque(context).takeUnretainedValue()

    // 꺼졌다는 알림에는 쓸 만한 event가 없다. 버튼 번호를 읽기 전에 처리한다.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { buttonTap.reenable() }
        return Unmanaged.passUnretained(event)
    }

    let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
    if buttonNumber < minimumButtonNumber { return Unmanaged.passUnretained(event) }

    let isDown = type == .otherMouseDown
    let shouldSwallow = MainActor.assumeIsolated { buttonTap.handler(buttonNumber, isDown) }
    return shouldSwallow ? nil : Unmanaged.passUnretained(event)
}
