import AppKit
import Carbon.HIToolbox
import XCTest
@testable import FreeLogi

@MainActor
final class SettingsModelTests: XCTestCase {
    private static let f19 = KeyCombo(keyCode: 80, modifiers: 0)
    private static let escape = KeyCombo(keyCode: 53, modifiers: 0)

    private var directoryURL: URL!
    private var changeCount = 0
    private var models: [SettingsModel] = []

    private var profilesURL: URL { directoryURL.appendingPathComponent("profiles.json") }

    override func setUp() {
        super.setUp()
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        changeCount = 0
    }

    // 녹화 중인 채 끝난 모델의 키 감시가 다음 테스트의 키를 삼키지 않게 닫는다(앱에서는 창을 닫을 때 close()가 한다).
    override func tearDown() {
        models.forEach { $0.close() }
        models = []
        try? FileManager.default.removeItem(at: directoryURL)
        super.tearDown()
    }

    private func makeModel(
        capture: @escaping @MainActor (@escaping @MainActor () -> Void) async -> ButtonID? = { _ in nil },
        supportsRawXY: @escaping (ButtonID) -> Bool = { _ in false }
    ) throws -> SettingsModel {
        let store = try ProfileStore(fileURL: profilesURL)
        let model = SettingsModel(store: store, captureButton: capture, supportsRawXY: supportsRawXY, onChange: { [self] in changeCount += 1 })
        models.append(model)
        return model
    }

    private func savedProfile() throws -> Profile {
        let store = try ProfileStore(fileURL: profilesURL)
        return try XCTUnwrap(store.activeProfile)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("조건이 2초 안에 참이 되지 않았다")
    }

    // 인식된 버튼은 키를 기다리는 줄로 보이고, 키를 받아야 저장된다.
    func testRecordedKeyTurnsPendingRowIntoSavedBinding() throws {
        let model = try makeModel()

        model.beginRecording(.standard(3))
        XCTAssertEqual(model.rows.map(\.button), [.standard(3)])
        XCTAssertNil(model.rows[0].keys)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profilesURL.path), "키를 받기 전에는 저장하지 않는다")

        model.record(SettingsModelTests.f19)

        XCTAssertEqual(model.rows.map(\.keys), [SettingsModelTests.f19])
        XCTAssertNil(model.recordingButton)
        XCTAssertEqual(try savedProfile().bindings, [ButtonBinding(button: .standard(3), keys: SettingsModelTests.f19)])
        XCTAssertEqual(changeCount, 1)
    }

    func testEscapeCancelsRecordingButModifiedEscapeIsRecorded() throws {
        let model = try makeModel()

        model.beginRecording(.hidpp(0x0053))
        model.record(SettingsModelTests.escape)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.recordingButton)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profilesURL.path))

        let commandEscape = KeyCombo(keyCode: 53, modifiers: CGEventFlags.maskCommand.rawValue)
        model.beginRecording(.hidpp(0x0053))
        model.record(commandEscape)
        XCTAssertEqual(try savedProfile().bindings.map(\.keys), [commandEscape])
    }

    func testRecordingMappedButtonReplacesItsKeyInPlace() throws {
        let model = try makeModel()
        model.beginRecording(.hidpp(0x0053))
        model.record(SettingsModelTests.f19)

        model.beginRecording(.hidpp(0x0053))
        XCTAssertEqual(model.rows.count, 1, "이미 있는 버튼은 줄을 더하지 않는다")
        let replacement = KeyCombo(keyCode: 81, modifiers: 0)
        model.record(replacement)

        XCTAssertEqual(try savedProfile().bindings, [ButtonBinding(button: .hidpp(0x0053), keys: replacement)])
    }

    func testRemoveBindingDeletesSavedRowAndDropsPendingRow() throws {
        let model = try makeModel()
        model.beginRecording(.standard(3))
        model.record(SettingsModelTests.f19)

        model.beginRecording(.hidpp(0x0053))
        model.removeBinding(.hidpp(0x0053))
        XCTAssertEqual(model.rows.map(\.button), [.standard(3)], "저장 전 줄은 지우면 사라질 뿐이다")
        XCTAssertNil(model.recordingButton)

        model.removeBinding(.standard(3))
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(try savedProfile().bindings.isEmpty)
    }

    func testCaptureBecomesReadyOnlyAfterSignalAndResetsOnCompletion() async throws {
        var onReady: (@MainActor () -> Void)?
        var result: CheckedContinuation<ButtonID?, Never>?
        let model = try makeModel(capture: { ready in
            onReady = ready
            return await withCheckedContinuation { result = $0 }
        })

        XCTAssertFalse(model.isCaptureReady)
        model.startCapture()
        XCTAssertTrue(model.isCapturing)
        XCTAssertFalse(model.isCaptureReady)
        try await waitUntil { result != nil }
        XCTAssertFalse(model.isCaptureReady)

        onReady?()
        XCTAssertTrue(model.isCaptureReady)
        result?.resume(returning: .standard(3))
        try await waitUntil { !model.isCapturing }

        XCTAssertFalse(model.isCaptureReady)
        XCTAssertEqual(model.recordingButton, .standard(3))
    }

    func testCancellingCaptureResetsReadinessAndIgnoresLateSignal() async throws {
        for signalBeforeCancel in [false, true] {
            var onReady: (@MainActor () -> Void)?
            var result: CheckedContinuation<ButtonID?, Never>?
            let model = try makeModel(capture: { ready in
                onReady = ready
                return await withCheckedContinuation { result = $0 }
            })
            model.startCapture()
            try await waitUntil { result != nil }
            if signalBeforeCancel { onReady?() }
            XCTAssertEqual(model.isCaptureReady, signalBeforeCancel)

            model.cancelCapture()
            XCTAssertFalse(model.isCapturing)
            XCTAssertFalse(model.isCaptureReady)
            onReady?()
            XCTAssertFalse(model.isCaptureReady)

            result?.resume(returning: .standard(3))
            await Task.yield()
            XCTAssertFalse(model.isCaptureReady)
            XCTAssertNil(model.recordingButton)
        }
    }

    func testCapturedButtonStartsRecording() async throws {
        let model = try makeModel(capture: { _ in .hidpp(0x0053) })

        model.startCapture()
        XCTAssertTrue(model.isCapturing)
        try await waitUntil { !model.isCapturing }

        XCTAssertEqual(model.recordingButton, .hidpp(0x0053))
        XCTAssertEqual(model.rows.map { model.buttonName(for: $0.button) }, ["버튼 1"])
    }

    func testCancelledCaptureEndsWithoutRecording() async throws {
        var captureEnded = false
        let model = try makeModel(capture: { _ in
            try? await Task.sleep(for: .seconds(10))
            captureEnded = true
            return nil
        })

        model.startCapture()
        XCTAssertTrue(model.isCapturing)
        model.cancelCapture()
        XCTAssertFalse(model.isCapturing)
        try await waitUntil { captureEnded }

        XCTAssertNil(model.recordingButton)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testClosingDuringCaptureDiscardsLateResultAndReleasesModel() async throws {
        let store = try ProfileStore(fileURL: profilesURL)
        weak var weakModel: SettingsModel?
        var captureEnded = false
        var model: SettingsModel? = SettingsModel(store: store, captureButton: { _ in
            try? await Task.sleep(for: .seconds(10))
            captureEnded = true
            return .standard(3)
        }, onChange: { XCTFail("닫힌 창의 인식 결과를 저장하면 안 된다") })
        weakModel = model
        model?.startCapture()
        await Task.yield()

        model?.close()
        model = nil
        try await waitUntil { captureEnded && weakModel == nil }

        XCTAssertFalse(FileManager.default.fileExists(atPath: profilesURL.path))
    }

    private func sendKeyDown(_ keyCode: Int) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: UInt16(keyCode)
        )!
        NSApplication.shared.sendEvent(event)
    }

    // 인식 중 Esc는 취소, 다른 키는 삼킬 뿐 취소하지 않는다(그 뒤에도 Esc가 먹는다).
    func testEscapeCancelsCaptureButOtherKeysDoNot() async throws {
        var captureEnded = false
        let model = try makeModel(capture: { _ in
            try? await Task.sleep(for: .seconds(10))
            captureEnded = true
            return nil
        })
        model.startCapture()

        sendKeyDown(kVK_ANSI_A)
        XCTAssertTrue(model.isCapturing)
        sendKeyDown(kVK_Escape)
        XCTAssertFalse(model.isCapturing)
        try await waitUntil { captureEnded }

        XCTAssertNil(model.recordingButton)
    }

    func testAddingAndSelectingProfilesChangesActiveOneAndNotifies() throws {
        let model = try makeModel()
        let firstID = model.state.activeID

        model.addProfile()
        XCTAssertEqual(model.activeProfile.name, "프로필 2")
        XCTAssertNotEqual(model.state.activeID, firstID)
        XCTAssertEqual(try ProfileStore(fileURL: profilesURL).state.activeID, model.state.activeID, "활성 프로필도 저장된다")

        model.select(profileID: firstID)
        XCTAssertEqual(model.activeProfile.name, "기본")
        XCTAssertEqual(changeCount, 2)
    }

    func testRenameTrimsAndIgnoresEmptyName() throws {
        let model = try makeModel()

        model.rename(to: "   ")
        XCTAssertEqual(model.activeProfile.name, "기본")
        XCTAssertEqual(changeCount, 0)

        model.rename(to: "  게임  ")
        XCTAssertEqual(model.activeProfile.name, "게임")
        XCTAssertEqual(try savedProfile().name, "게임")
    }

    func testRemovingActiveProfileMovesToFirstAndLastProfileStays() throws {
        let model = try makeModel()
        let firstID = model.state.activeID
        model.addProfile()

        model.removeActiveProfile()
        XCTAssertEqual(model.state.profiles.count, 1)
        XCTAssertEqual(model.state.activeID, firstID)

        model.removeActiveProfile()
        XCTAssertEqual(model.state.profiles.count, 1, "마지막 프로필은 남는다")
    }

    // 창을 닫으면 SwiftUI 뷰(와 그것이 쥔 모델)가 해제된다. 모델은 SwiftUI 뷰만 쥐고 있어서 모델이 사라지면 뷰도 사라진 것이다.
    // 빈 NSWindow 껍데기는 AppKit이 닫은 뒤에도 붙들고 있어서(일반 NSWindow도 그렇다) 확인하지 않는다.
    func testClosingWindowReleasesControllerAndModel() throws {
        let store = try ProfileStore(fileURL: profilesURL)
        weak var weakController: SettingsWindowController?
        weak var weakModel: SettingsModel?
        var didClose = false

        // AppKit이 창을 열고 닫으며 autorelease한 것을 풀 안에서 비운다.
        autoreleasepool {
            let model = SettingsModel(store: store, captureButton: { _ in nil }, onChange: {})
            var controller: SettingsWindowController? = SettingsWindowController(model: model)
            weakController = controller
            weakModel = model
            controller?.onClose = {
                didClose = true
                controller = nil
            }
            controller?.window.orderBack(nil)
            controller?.close()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertTrue(didClose)
        XCTAssertNil(weakController)
        XCTAssertNil(weakModel)
    }

    func testRawButtonValues() {
        XCTAssertEqual(ButtonID.standard(3).rawValueText, "btn 3")
        XCTAssertEqual(ButtonID.hidpp(0x00D7).rawValueText, "cid 0x00D7")
        XCTAssertEqual(ButtonID.hidpp(0x00C3).rawValueText, "cid 0x00C3")
        XCTAssertEqual(ButtonID.hidpp(0x0123).rawValueText, "cid 0x0123")
    }

    func testOnlyRawXYControlsOfferDirections() throws {
        let model = try makeModel(supportsRawXY: { $0 == .hidpp(0x0053) })
        XCTAssertEqual(model.availableGestures(for: .hidpp(0x0053)), [nil, .up, .down, .left, .right])
        XCTAssertEqual(model.availableGestures(for: .hidpp(0x00D7)), [nil], "이름이 제스처여도 지원 플래그가 없으면 클릭만")
        XCTAssertEqual(model.availableGestures(for: .standard(3)), [nil])
        model.beginRecording(.hidpp(0x00D7), gesture: .up)
        XCTAssertNil(model.recordingAction)
    }

    func testGestureRowsHaveDistinctIdentityAndCanBeEditedIndependently() throws {
        let button = ButtonID.hidpp(0x0053)
        let model = try makeModel(supportsRawXY: { $0 == button })
        model.beginRecording(button)
        model.record(SettingsModelTests.f19)
        model.beginRecording(button, gesture: .up)
        model.record(SettingsModelTests.f19)
        XCTAssertEqual(Set(model.rows.map(\.id)).count, 2)
        XCTAssertFalse(model.canSelect(nil, for: BindingID(button: button, gesture: .up)))
        model.changeGesture(.left, for: BindingID(button: button, gesture: .up))
        XCTAssertEqual(try savedProfile().bindings.map(\.gesture), [nil, .left])
        model.beginRecording(button, gesture: .left)
        let replacement = KeyCombo(keyCode: 79, modifiers: 0)
        model.record(replacement)
        XCTAssertEqual(try savedProfile().bindings.map(\.keys), [SettingsModelTests.f19, replacement])
        model.removeBinding(button, gesture: .left)
        XCTAssertEqual(model.rows.map(\.gesture), [nil])
    }

    func testRecapturingButtonAddsNextAvailableActionAndPendingPickerKeepsRecording() async throws {
        let button = ButtonID.hidpp(0x0053)
        let model = try makeModel(capture: { _ in button }, supportsRawXY: { $0 == button })
        model.beginRecording(button)
        model.record(SettingsModelTests.f19)
        model.startCapture()
        try await waitUntil { !model.isCapturing }
        XCTAssertEqual(model.pendingAction, BindingID(button: button, gesture: .up))
        model.changeGesture(.right, for: BindingID(button: button, gesture: .up))
        XCTAssertEqual(model.recordingAction, BindingID(button: button, gesture: .right))
        model.record(SettingsModelTests.f19)
        XCTAssertEqual(try savedProfile().bindings.map(\.gesture), [nil, .right])
    }
    func testPendingNameAndRenamingAreSharedByGestureRows() throws {
        let button = ButtonID.hidpp(0x0053)
        let model = try makeModel(supportsRawXY: { $0 == button })
        model.beginRecording(button)
        XCTAssertEqual(model.buttonName(for: button), "버튼 1")
        model.cancelRecording()
        model.beginRecording(.standard(9))
        XCTAssertEqual(model.buttonName(for: .standard(9)), "버튼 1")
        model.record(SettingsModelTests.f19)
        model.beginRecording(button)
        XCTAssertEqual(model.buttonName(for: button), "버튼 2")
        model.record(SettingsModelTests.f19)
        model.beginRecording(button, gesture: .up)
        model.record(SettingsModelTests.f19)
        model.renameButton(button, to: "탐색")
        XCTAssertEqual(model.rows.map { model.buttonName(for: $0.button) }, ["버튼 1", "탐색", "탐색"])
        XCTAssertEqual(try savedProfile().buttonNames[button], "탐색")
        model.reload()
        XCTAssertEqual(model.buttonName(for: button), "탐색")
    }

}
