import Carbon
import XCTest
@testable import FreeLogi

final class MainWindowTests: XCTestCase {
    func testScreenRequiresBothPermissions() {
        XCTAssertEqual(MainScreenEnum.select(granted: [:]), .permissions)
        for inputGranted in [false, true] {
            for accessibilityGranted in [false, true] {
                let granted: [Permission: Bool] = [
                    .inputMonitoring: inputGranted,
                    .accessibility: accessibilityGranted,
                ]
                let expected: MainScreenEnum = inputGranted && accessibilityGranted ? .mapping : .permissions
                XCTAssertEqual(MainScreenEnum.select(granted: granted), expected)
            }
        }
    }

    func testLoginItemLaunchUsesAppleEventEnumValue() {
        XCTAssertTrue(LoginItem.isLoginItemLaunch(OSType(keyAELaunchedAsLogInItem)))
        XCTAssertFalse(LoginItem.isLoginItemLaunch(nil))
        XCTAssertFalse(LoginItem.isLoginItemLaunch(0))
        XCTAssertFalse(LoginItem.isLoginItemLaunch(OSType(kAEOpenApplication)))
    }

    @MainActor
    func testPermissionUpdatesSwitchScreenAndCancelRecordingOnRevocation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ProfileStore(fileURL: directory.appendingPathComponent("profiles.json"))
        let model = SettingsModel(store: store, captureButton: { _ in nil }, onChange: {})
        defer { model.close() }

        XCTAssertEqual(model.screen, .permissions)
        model.updatePermissions([.inputMonitoring: true, .accessibility: true])
        XCTAssertEqual(model.screen, .mapping)
        model.beginRecording(.standard(3))
        model.updatePermissions([.inputMonitoring: true, .accessibility: false])
        XCTAssertEqual(model.screen, .permissions)
        XCTAssertNil(model.recordingButton)
    }
}
