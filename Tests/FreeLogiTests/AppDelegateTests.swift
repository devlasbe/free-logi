import AppKit
import XCTest
@testable import FreeLogi

@MainActor
final class AppDelegateTests: XCTestCase {
    private func makeMenu(granted: Bool) -> NSMenu {
        let grantedPermissions = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, granted) })
        return AppDelegate().makeMenu(granted: grantedPermissions)
    }

    func testMenuWithoutPermissionsShowsStatusReasonAndSettingsItem() {
        let menu = makeMenu(granted: false)

        XCTAssertEqual(menu.items.map(\.title), [
            "입력 모니터링: 미허용",
            "마우스 버튼 입력을 읽는 데 필요합니다",
            "입력 모니터링 설정 열기",
            "손쉬운 사용: 미허용",
            "버튼의 원래 동작을 막고 키 입력을 보내는 데 필요합니다",
            "손쉬운 사용 설정 열기",
            "",
            "설정…",
            "FreeLogi 정보",
            "종료",
        ])
        let settingsItems = menu.items.filter { $0.representedObject is Permission }
        XCTAssertEqual(settingsItems.compactMap { $0.representedObject as? Permission }, Permission.allCases)
    }

    func testMenuWithPermissionsShowsStatusAndAppItems() {
        let menu = makeMenu(granted: true)

        XCTAssertEqual(menu.items.map(\.title), ["입력 모니터링: 허용", "손쉬운 사용: 허용", "", "설정…", "FreeLogi 정보", "종료"])
        XCTAssertNotNil(menu.items.first { $0.title == "FreeLogi 정보" }?.action)
        XCTAssertEqual(menu.items.last?.action, #selector(NSApplication.terminate(_:)))
    }

    func testSettingsURLsPointToPrivacyPanes() {
        XCTAssertEqual(
            Permission.inputMonitoring.settingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        )
        XCTAssertEqual(
            Permission.accessibility.settingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func testMenuListsProfilesWithActiveChecked() {
        let first = Profile(id: UUID(), name: "기본", bindings: [])
        let second = Profile(id: UUID(), name: "코딩", bindings: [])
        let state = ProfileStoreState(profiles: [first, second], activeID: second.id)
        let granted = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, true) })

        let menu = AppDelegate().makeMenu(granted: granted, profileState: state)

        XCTAssertEqual(menu.items.prefix(3).map(\.title), ["기본", "코딩", ""])
        XCTAssertEqual(menu.items.prefix(2).map(\.state), [.off, .on])
        XCTAssertEqual(menu.items.prefix(2).compactMap { $0.representedObject as? UUID }, [first.id, second.id])
        XCTAssertNotNil(menu.items.first { $0.title == "설정…" }?.action)
    }

    func testSettingsItemIsDisabledWithoutProfiles() {
        let menu = makeMenu(granted: true)

        XCTAssertNil(menu.items.first { $0.title == "설정…" }?.action)
    }

    func testNewlyGrantedIsOnlyDeniedToGrantedAfterFirstRead() {
        let denied = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, false) })
        let granted = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, true) })
        let onlyAccessibility: [Permission: Bool] = [.inputMonitoring: false, .accessibility: true]

        XCTAssertEqual(AppDelegate.newlyGranted(previous: [:], current: granted), [], "처음 읽은 값은 기준이다")
        XCTAssertEqual(AppDelegate.newlyGranted(previous: denied, current: onlyAccessibility), [.accessibility])
        XCTAssertEqual(AppDelegate.newlyGranted(previous: onlyAccessibility, current: granted), [.inputMonitoring])
        XCTAssertEqual(AppDelegate.newlyGranted(previous: granted, current: denied), [])
    }
}
