import AppKit
import ApplicationServices
import IOKit.hid

enum Permission: CaseIterable {
    case inputMonitoring
    case accessibility

    var title: String {
        switch self {
        case .inputMonitoring: return String(localized: "입력 모니터링")
        case .accessibility: return String(localized: "손쉬운 사용")
        }
    }

    var reason: String {
        switch self {
        case .inputMonitoring: return String(localized: "마우스 버튼 입력을 읽는 데 필요합니다")
        case .accessibility: return String(localized: "버튼의 원래 동작을 막고 키 입력을 보내는 데 필요합니다")
        }
    }

    private var settingsAnchor: String {
        switch self {
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .accessibility: return "Privacy_Accessibility"
        }
    }

    var settingsURL: URL {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)"
        return URL(string: urlString)!
    }

    var isGranted: Bool {
        switch self {
        case .inputMonitoring: return Permission.hasInputMonitoring()
        case .accessibility: return Permission.hasAccessibility()
        }
    }

    func statusLine(granted: Bool) -> String {
        let status = granted ? String(localized: "허용") : String(localized: "미허용")
        return "\(title): \(status)"
    }

    // 시스템 설정 목록에 앱 행을 만들려면 요청 함수를 불러야 한다. 확인 함수는 행을 만들지 않는다.
    // 입력 모니터링 요청은 사용자가 답할 때까지 스레드를 막으므로 메인 스레드에서 부르지 않는다.
    func request() {
        switch self {
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .accessibility:
            // kAXTrustedCheckOptionPrompt 상수의 실제 값. Swift 6에서 전역 var를 직접 읽을 수 없다.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    @MainActor
    func requestAndOpenSettings() {
        Task.detached {
            request()
            await MainActor.run { openSettings() }
        }
    }

    func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    private static func hasInputMonitoring() -> Bool {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        return access == kIOHIDAccessTypeGranted
    }

    // AXIsProcessTrusted는 설정에서 앱 행을 지워도 true를 돌려준다(OpenLogi #674).
    // 그래서 값이 true일 때만 실제 active 탭을 만들어 보고, 만들어져야 허용으로 본다.
    private static func hasAccessibility() -> Bool {
        let isTrusted = AXIsProcessTrusted()
        if !isTrusted { return false }
        return canCreateActiveTap()
    }

    // kCGEventNull은 아무도 보내지 않는 이벤트라 이 탭이 실제 입력을 건드리지 않는다.
    private static func canCreateActiveTap() -> Bool {
        let nullEventMask = CGEventMask(1) << CGEventType.null.rawValue
        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: nullEventMask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        guard let tap else { return false }
        CFMachPortInvalidate(tap)
        return true
    }
}
