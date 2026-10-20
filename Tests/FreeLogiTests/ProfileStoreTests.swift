import XCTest
@testable import FreeLogi

final class ProfileStoreTests: XCTestCase {
    private var tmpURL: URL!

    override func setUp() {
        super.setUp()
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("profiles.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpURL.deletingLastPathComponent())
        super.tearDown()
    }

    func testScrollReversalPersistsAcrossProfiles() throws {
        let store = try ProfileStore(fileURL: tmpURL)
        XCTAssertFalse(store.state.reverseVerticalScroll)
        XCTAssertFalse(store.state.reverseHorizontalScroll)
        for (vertical, horizontal) in [(true, false), (false, true), (true, true), (false, false)] {
            try store.setScrollReversal(vertical: vertical, horizontal: horizontal)
            let profile = try store.add(name: "다른 프로필")
            try store.setActive(id: profile.id)
            let reloaded = try ProfileStore(fileURL: tmpURL)
            XCTAssertEqual(reloaded.state, store.state)
            XCTAssertEqual(reloaded.state.reverseVerticalScroll, vertical)
            XCTAssertEqual(reloaded.state.reverseHorizontalScroll, horizontal)
        }
    }

    func testSmoothScrollingPersistsAcrossProfiles() throws {
        let store = try ProfileStore(fileURL: tmpURL)
        XCTAssertFalse(store.state.smoothScrolling)
        for enabled in [true, false] {
            try store.setSmoothScrolling(enabled)
            let profile = try store.add(name: "다른 프로필")
            try store.setActive(id: profile.id)
            let reloaded = try ProfileStore(fileURL: tmpURL)
            XCTAssertEqual(reloaded.state.smoothScrolling, enabled)
            XCTAssertEqual(reloaded.state, store.state)
        }
    }

    // 저장 후 재로드 동일성 검증
    func testRoundTrip() throws {
        let store = try ProfileStore(fileURL: tmpURL)
        let p2 = try store.add(name: "작업용")

        // standard + hidpp 바인딩 모두 추가
        try store.setBinding(profileID: store.state.profiles[0].id,
                             button: .standard(3),
                             keys: KeyCombo(keyCode: 1, modifiers: 256))
        try store.setBinding(profileID: p2.id,
                             button: .hidpp(0x0050),
                             keys: KeyCombo(keyCode: 2, modifiers: 512))
        try store.setActive(id: p2.id)

        let store2 = try ProfileStore(fileURL: tmpURL)
        XCTAssertEqual(store.state.profiles, store2.state.profiles)
        XCTAssertEqual(store.state.activeID, store2.state.activeID)
    }

    // 파일 없으면 기본 프로필 '기본' 한 개, 활성
    func testMissingFileDefaultsToBasicProfile() throws {
        let store = try ProfileStore(fileURL: tmpURL)
        XCTAssertEqual(store.state.profiles.count, 1)
        XCTAssertEqual(store.state.profiles[0].name, "기본")
        XCTAssertEqual(store.state.activeID, store.state.profiles[0].id)
    }

    // 마지막 프로필 삭제 거부
    func testRemoveLastProfileRefused() throws {
        let store = try ProfileStore(fileURL: tmpURL)
        XCTAssertThrowsError(try store.remove(id: store.state.profiles[0].id))
    }

    // 활성 프로필 삭제 시 active가 남은 첫 번째로 이동
    func testRemoveActiveMovesToFirst() throws {
        let store = try ProfileStore(fileURL: tmpURL)
        let p2 = try store.add(name: "두 번째")
        try store.setActive(id: p2.id)

        try store.remove(id: p2.id)

        XCTAssertEqual(store.state.activeID, store.state.profiles[0].id)
    }

    func testLegacyJSONWithoutGestureDecodesAsClick() throws {
        let json = #"{"profiles":[{"id":"00000000-0000-0000-0000-000000000001","name":"기본","bindings":[{"button":{"hidpp":{"_0":83}},"keys":{"keyCode":80,"modifiers":0}}]}],"activeID":"00000000-0000-0000-0000-000000000001"}"#
        let state = try JSONDecoder().decode(ProfileStoreState.self, from: Data(json.utf8))
        XCTAssertEqual(state.profiles[0].bindings, [ButtonBinding(button: .hidpp(83), keys: KeyCombo(keyCode: 80, modifiers: 0))])
        XCTAssertNil(state.profiles[0].bindings[0].gesture)
        XCTAssertFalse(state.reverseVerticalScroll)
        XCTAssertFalse(state.reverseHorizontalScroll)
        XCTAssertFalse(state.smoothScrolling)
    }

    func testDirectionsCoexistAndUpdateOrRemoveIndependently() throws {
        let store = try ProfileStore(fileURL: tmpURL)
        let profileID = store.state.activeID
        let button = ButtonID.hidpp(0x0053)
        let click = KeyCombo(keyCode: 80, modifiers: 0)
        let direction = KeyCombo(keyCode: 79, modifiers: 0)
        try store.setBinding(profileID: profileID, button: button, keys: click)
        for gesture in GestureDirectionEnum.allCases {
            try store.setBinding(profileID: profileID, button: button, keys: direction, gesture: gesture)
        }
        try store.setBinding(profileID: profileID, button: button, keys: click, gesture: .up)
        XCTAssertEqual(store.activeProfile?.bindings.count, 5)
        let reloaded = try ProfileStore(fileURL: tmpURL)
        XCTAssertEqual(reloaded.state, store.state)
        try store.removeBinding(profileID: profileID, button: button, gesture: .left)
        try store.removeBinding(profileID: profileID, button: button)
        XCTAssertEqual(store.activeProfile?.bindings.map(\.gesture), [.up, .down, .right])
    }
    func testButtonNumbersReuseSmallestGapAndStayWithinProfile() throws {
        let store = try ProfileStore(fileURL: tmpURL)
        let profileID = store.state.activeID
        let keys = KeyCombo(keyCode: 80, modifiers: 0)
        try store.setBinding(profileID: profileID, button: .standard(9), keys: keys)
        try store.setBinding(profileID: profileID, button: .hidpp(0x0053), keys: keys)
        try store.setBinding(profileID: profileID, button: .standard(4), keys: keys)
        XCTAssertEqual(store.activeProfile?.buttonName(for: .standard(9)), "버튼 1")
        XCTAssertEqual(store.activeProfile?.buttonName(for: .hidpp(0x0053)), "버튼 2")
        XCTAssertEqual(store.activeProfile?.buttonName(for: .standard(4)), "버튼 3")

        try store.removeBinding(profileID: profileID, button: .hidpp(0x0053))
        try store.setBinding(profileID: profileID, button: .standard(5), keys: keys)
        XCTAssertEqual(store.activeProfile?.buttonName(for: .standard(5)), "버튼 2")
        let other = try store.add(name: "다른 프로필")
        try store.setBinding(profileID: other.id, button: .standard(9), keys: keys)
        XCTAssertEqual(store.state.profiles[1].buttonName(for: .standard(9)), "버튼 1")
    }

    func testRenamedButtonPersistsAcrossDirectionsAndLastRemovalClearsName() throws {
        let store = try ProfileStore(fileURL: tmpURL)
        let profileID = store.state.activeID
        let button = ButtonID.hidpp(0x0053)
        let keys = KeyCombo(keyCode: 80, modifiers: 0)
        try store.setBinding(profileID: profileID, button: button, keys: keys)
        try store.setBinding(profileID: profileID, button: button, keys: keys, gesture: .up)
        try store.renameButton(profileID: profileID, button: button, name: "  탐색  ")
        try store.renameButton(profileID: profileID, button: button, name: "  \n  ")
        let reloaded = try ProfileStore(fileURL: tmpURL)
        XCTAssertEqual(reloaded.activeProfile?.buttonNames, [button: "탐색"])
        XCTAssertEqual(reloaded.state, store.state)

        try store.removeBinding(profileID: profileID, button: button)
        XCTAssertEqual(store.activeProfile?.buttonNames[button], "탐색")
        try store.removeBinding(profileID: profileID, button: button, gesture: .up)
        XCTAssertTrue(try XCTUnwrap(store.activeProfile).buttonNames.isEmpty)
        try store.setBinding(profileID: profileID, button: button, keys: keys)
        XCTAssertEqual(store.activeProfile?.buttonName(for: button), "버튼 1")
    }

    func testLegacyButtonNamesFollowBindingOrderAndShareDirections() throws {
        let json = #"""
        {"id":"00000000-0000-0000-0000-000000000001","name":"기본","bindings":[
        {"button":{"hidpp":{"_0":83}},"keys":{"keyCode":80,"modifiers":0},"gesture":"up"},
        {"button":{"standard":{"_0":9}},"keys":{"keyCode":80,"modifiers":0}},
        {"button":{"hidpp":{"_0":83}},"keys":{"keyCode":79,"modifiers":0}}]}
        """#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.buttonNames, [.hidpp(83): "버튼 1", .standard(9): "버튼 2"])
        let encoded = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: encoded), profile)
    }

}
