import AppKit
import XCTest
@testable import FreeLogi

// 0x1B04가 있는 가짜 마우스. 요청에는 바로 응답하고 divert 상태를 기억한다.
@MainActor
private final class FakeMouse {
    static let featureIndex: UInt8 = 0x09
    private static let reprogControlsFeature: UInt16 = 0x1B04
    private static let leftButtonCid: UInt16 = 0x0050
    private static let notDivertableFlags: UInt8 = 0x11
    private static let divertableFlags: UInt8 = 0x71

    let divertableCids: [UInt16]
    var isConnected = true
    var diverted: Set<UInt16> = []
    var rawXY: Set<UInt16> = []
    var supportsRawXY = true
    private(set) var channel: HIDPPChannel!

    init(divertableCids: [UInt16]) {
        self.divertableCids = divertableCids
        channel = HIDPPChannel(responseTimeout: .milliseconds(200)) { [unowned self] frame in
            self.receive(frame)
        }
    }

    // 기기를 껐다 켠 것처럼 임시 divert가 풀린다.
    func powerCycle() {
        diverted = []
        rawXY = []
    }

    // divertedButtonsEvent: 지금 눌려 있는 CID 전체(최대 4개)
    func sendPressedButtons(_ cids: [UInt16]) {
        var report = [UInt8](repeating: 0, count: HIDPPChannel.longReportLength)
        report[0] = HIDPPChannel.longReportId
        report[1] = HIDPPChannel.directDeviceIndex
        report[2] = FakeMouse.featureIndex
        for (slot, cid) in cids.enumerated() {
            report[4 + slot * 2] = UInt8(cid >> 8)
            report[5 + slot * 2] = UInt8(cid & 0xFF)
        }
        channel.handleReport(report)
    }

    func sendMovement(dx: Int16, dy: Int16, deviceIndex: UInt8 = 0xFF) {
        let dxBits = UInt16(bitPattern: dx)
        let dyBits = UInt16(bitPattern: dy)
        let report: [UInt8] = [0x11, deviceIndex, FakeMouse.featureIndex, 0x10,
                               UInt8(dxBits >> 8), UInt8(dxBits & 0xFF), UInt8(dyBits >> 8), UInt8(dyBits & 0xFF)]
            + [UInt8](repeating: 0, count: 12)
        channel.handleReport(report)
    }

    private func receive(_ frame: [UInt8]) -> Bool {
        if !isConnected { return false }

        let featureIndex = frame[2]
        let function = frame[3] >> 4
        let params = Array(frame[HIDPPChannel.headerLength...])
        let payload = payloadForRequest(featureIndex: featureIndex, function: function, params: params)

        var report = [UInt8](repeating: 0, count: HIDPPChannel.longReportLength)
        report[0] = HIDPPChannel.longReportId
        report[1] = frame[1]
        report[2] = featureIndex
        report[3] = frame[3]
        report.replaceSubrange(HIDPPChannel.headerLength..<(HIDPPChannel.headerLength + payload.count), with: payload)
        channel.handleReport(report)
        return true
    }

    private func payloadForRequest(featureIndex: UInt8, function: UInt8, params: [UInt8]) -> [UInt8] {
        let allCids = [FakeMouse.leftButtonCid] + divertableCids
        if featureIndex == 0 {
            if function == 1 { return [4, 5, params[2]] }
            let requestedFeature = UInt16(params[0]) << 8 | UInt16(params[1])
            let index = requestedFeature == FakeMouse.reprogControlsFeature ? FakeMouse.featureIndex : 0
            return [index]
        }

        switch function {
        case 0:
            return [UInt8(allCids.count)]
        case 1:
            let cid = allCids[Int(params[0])]
            let flags = cid == FakeMouse.leftButtonCid ? FakeMouse.notDivertableFlags : FakeMouse.divertableFlags
            return [UInt8(cid >> 8), UInt8(cid & 0xFF), 0, 0, flags, 0, 0, 0, supportsRawXY ? 0x01 : 0]
        case 2:
            let cid = UInt16(params[0]) << 8 | UInt16(params[1])
            let flags: UInt8 = (diverted.contains(cid) ? 1 : 0) | (rawXY.contains(cid) ? 0x10 : 0)
            return [params[0], params[1], flags]
        default:
            let cid = UInt16(params[0]) << 8 | UInt16(params[1])
            let shouldDivert = params[2] & 0x01 != 0
            if shouldDivert { diverted.insert(cid) } else { diverted.remove(cid) }
            if params[2] & 0x20 != 0 {
                if params[2] & 0x10 != 0 { rawXY.insert(cid) } else { rawXY.remove(cid) }
            }
            return Array(params.prefix(3))
        }
    }
}

@MainActor
final class MappingEngineTests: XCTestCase {
    private static let tiltLeft: UInt16 = 0x005B
    private static let back: UInt16 = 0x0053
    private static let middle: UInt16 = 0x0052
    private static let f19 = KeyCombo(keyCode: 80, modifiers: 0)
    private static let f18 = KeyCombo(keyCode: 79, modifiers: 0)

    private var keyEvents: [String] = []

    private func makeEngine(retryDelay: Duration = .milliseconds(10)) -> MappingEngine {
        MappingEngine(
            connectRetryDelay: retryDelay,
            press: { self.keyEvents.append("down \($0.keyCode)") },
            release: { self.keyEvents.append("up \($0.keyCode)") }
        )
    }

    private func makeMouse() -> FakeMouse {
        FakeMouse(divertableCids: [MappingEngineTests.middle, MappingEngineTests.back, MappingEngineTests.tiltLeft])
    }

    private func profile(_ bindings: [ButtonID: KeyCombo]) -> Profile {
        let list = bindings.map { ButtonBinding(button: $0.key, keys: $0.value) }
        return Profile(id: UUID(), name: "test", bindings: list)
    }

    // 재시도·알림처럼 엔진 밖에서 일어나는 일이 끝나길 기다린다.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testDivertsOnlyMappedCids() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        engine.apply(profile([.hidpp(MappingEngineTests.tiltLeft): MappingEngineTests.f19]))
        engine.addChannel(mouse.channel)
        await engine.waitUntilIdle()

        XCTAssertEqual(mouse.diverted, [MappingEngineTests.tiltLeft])
        await engine.stop()
    }

    func testLeftoverDivertFromPreviousRunIsReleased() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        mouse.diverted = [MappingEngineTests.back]
        engine.apply(profile([.hidpp(MappingEngineTests.tiltLeft): MappingEngineTests.f19]))
        engine.addChannel(mouse.channel)
        await engine.waitUntilIdle()

        XCTAssertEqual(mouse.diverted, [MappingEngineTests.tiltLeft])
        await engine.stop()
    }

    func testNotificationPressesAndReleasesMappedKey() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        engine.apply(profile([.hidpp(MappingEngineTests.tiltLeft): MappingEngineTests.f19]))
        engine.addChannel(mouse.channel)
        await engine.waitUntilIdle()

        mouse.sendPressedButtons([MappingEngineTests.tiltLeft])
        XCTAssertEqual(keyEvents, ["down 80"])
        mouse.sendPressedButtons([MappingEngineTests.tiltLeft])
        XCTAssertEqual(keyEvents, ["down 80"], "같은 상태 알림은 다시 누르지 않는다")
        mouse.sendPressedButtons([])
        XCTAssertEqual(keyEvents, ["down 80", "up 80"])

        keyEvents = []
        mouse.sendPressedButtons([MappingEngineTests.middle])
        mouse.sendPressedButtons([MappingEngineTests.middle, MappingEngineTests.tiltLeft])
        mouse.sendPressedButtons([])
        XCTAssertEqual(keyEvents, ["down 80", "up 80"], "매핑 없는 버튼은 키를 보내지 않는다")
        await engine.stop()
    }

    func testProfileChangeUpdatesDivertList() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        engine.addChannel(mouse.channel)
        engine.apply(profile([.hidpp(MappingEngineTests.tiltLeft): MappingEngineTests.f19]))
        await engine.waitUntilIdle()
        XCTAssertEqual(mouse.diverted, [MappingEngineTests.tiltLeft])

        engine.apply(profile([.hidpp(MappingEngineTests.back): MappingEngineTests.f18]))
        await engine.waitUntilIdle()
        XCTAssertEqual(mouse.diverted, [MappingEngineTests.back])

        engine.apply(nil)
        await engine.waitUntilIdle()
        XCTAssertEqual(mouse.diverted, [])
        await engine.stop()
    }

    func testProfileChangeReleasesHeldKey() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        engine.addChannel(mouse.channel)
        engine.apply(profile([.hidpp(MappingEngineTests.tiltLeft): MappingEngineTests.f19]))
        await engine.waitUntilIdle()

        mouse.sendPressedButtons([MappingEngineTests.tiltLeft])
        engine.apply(nil)
        mouse.sendPressedButtons([])
        XCTAssertEqual(keyEvents, ["down 80", "up 80"], "눌린 채 프로필이 바뀌면 그때 떼고, 버튼을 뗄 때 또 떼지 않는다")
        await engine.stop()
    }

    func testReconnectedDeviceIsDivertedAgainAndRemovedDeviceReleasesKeys() async {
        let engine = makeEngine()
        let firstConnection = makeMouse()
        engine.apply(profile([.hidpp(MappingEngineTests.tiltLeft): MappingEngineTests.f19]))
        engine.addChannel(firstConnection.channel)
        await engine.waitUntilIdle()
        XCTAssertEqual(firstConnection.diverted, [MappingEngineTests.tiltLeft])

        firstConnection.sendPressedButtons([MappingEngineTests.tiltLeft])
        engine.removeChannel(firstConnection.channel)
        XCTAssertEqual(keyEvents, ["down 80", "up 80"], "눌린 채 분리되면 키를 뗀다")
        firstConnection.sendPressedButtons([MappingEngineTests.tiltLeft])
        XCTAssertEqual(keyEvents.count, 2, "분리된 채널의 알림은 무시한다")

        let secondConnection = makeMouse()
        engine.addChannel(secondConnection.channel)
        await engine.waitUntilIdle()
        XCTAssertEqual(secondConnection.diverted, [MappingEngineTests.tiltLeft])
        XCTAssertEqual(engine.channels.count, 1)
        await engine.stop()
    }

    func testRetriesUntilNewlyConnectedDeviceAnswers() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        mouse.isConnected = false
        engine.apply(profile([.hidpp(MappingEngineTests.tiltLeft): MappingEngineTests.f19]))
        engine.addChannel(mouse.channel)
        await engine.waitUntilIdle()
        XCTAssertEqual(mouse.diverted, [])

        mouse.isConnected = true
        await waitUntil { mouse.diverted == [MappingEngineTests.tiltLeft] }
        XCTAssertEqual(mouse.diverted, [MappingEngineTests.tiltLeft])
        await engine.stop()
    }

    func testReceiverConnectionNotificationDivertsAgain() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        engine.apply(profile([.hidpp(MappingEngineTests.tiltLeft): MappingEngineTests.f19]))
        engine.addChannel(mouse.channel)
        await engine.waitUntilIdle()

        mouse.powerCycle()
        mouse.channel.handleReport([0x10, 0x01, 0x41, 0x04, 0x00, 0x00, 0x00])
        await waitUntil { mouse.diverted == [MappingEngineTests.tiltLeft] }
        XCTAssertEqual(mouse.diverted, [MappingEngineTests.tiltLeft])
        await engine.stop()
    }

    func testWakeDivertsAgainAfterDeviceReset() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        engine.apply(profile([.hidpp(MappingEngineTests.tiltLeft): MappingEngineTests.f19]))
        engine.addChannel(mouse.channel)
        engine.observeWake()
        await engine.waitUntilIdle()
        XCTAssertEqual(mouse.diverted, [MappingEngineTests.tiltLeft])

        mouse.powerCycle()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await waitUntil { mouse.diverted == [MappingEngineTests.tiltLeft] }
        XCTAssertEqual(mouse.diverted, [MappingEngineTests.tiltLeft])
        await engine.stop()
    }

    func testStopReleasesEveryDivertAndStopsWorking() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        engine.apply(profile([
            .hidpp(MappingEngineTests.tiltLeft): MappingEngineTests.f19,
            .hidpp(MappingEngineTests.back): MappingEngineTests.f18,
        ]))
        engine.addChannel(mouse.channel)
        await engine.waitUntilIdle()
        XCTAssertEqual(mouse.diverted, [MappingEngineTests.tiltLeft, MappingEngineTests.back])

        await engine.stop()
        XCTAssertEqual(mouse.diverted, [])

        engine.apply(profile([.hidpp(MappingEngineTests.middle): MappingEngineTests.f19]))
        await engine.waitUntilIdle()
        XCTAssertEqual(mouse.diverted, [], "멈춘 뒤에는 다시 divert하지 않는다")
    }

    func testStandardButtonIsSwallowedOnlyWhenMapped() async {
        let engine = makeEngine()
        engine.apply(profile([.standard(9): MappingEngineTests.f19]))

        XCTAssertTrue(engine.handleButton(.standard(9), isDown: true))
        XCTAssertTrue(engine.handleButton(.standard(9), isDown: false))
        XCTAssertEqual(keyEvents, ["down 80", "up 80"])

        XCTAssertFalse(engine.handleButton(.standard(8), isDown: true))
        XCTAssertFalse(engine.handleButton(.standard(8), isDown: false))
        XCTAssertFalse(engine.handleButton(.standard(9), isDown: false), "down을 통과시킨 버튼의 up은 삼키지 않는다")
        XCTAssertEqual(keyEvents.count, 2)
        await engine.stop()
    }

    func testButtonUpOfSwallowedDownIsSwallowedEvenAfterMappingRemoved() async {
        let engine = makeEngine()
        engine.apply(profile([.standard(9): MappingEngineTests.f19]))
        XCTAssertTrue(engine.handleButton(.standard(9), isDown: true))

        engine.apply(nil)
        XCTAssertEqual(keyEvents, ["down 80", "up 80"])
        XCTAssertFalse(engine.handleButton(.standard(9), isDown: false), "프로필이 바뀌면서 이미 뗐으므로 up은 통과")
        await engine.stop()
    }

    func testCaptureGivesNotificationHandlerBackToEngine() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        engine.apply(profile([.hidpp(MappingEngineTests.tiltLeft): MappingEngineTests.f19]))
        engine.addChannel(mouse.channel)
        await engine.waitUntilIdle()

        var isCaptureReady = false
        let capture = ButtonCapture(channels: engine.channels) { message in
            if message.hasPrefix("ready") { isCaptureReady = true }
        }
        let captureTask = Task { await capture.capture() }
        await waitUntil { isCaptureReady }
        XCTAssertEqual(mouse.diverted.count, 3, "인식 모드는 divert 가능한 것을 모두 divert한다")

        mouse.sendPressedButtons([MappingEngineTests.back])
        let button = await captureTask.value
        XCTAssertEqual(button, .hidpp(MappingEngineTests.back))
        XCTAssertEqual(mouse.diverted, [MappingEngineTests.tiltLeft], "인식이 끝나면 매핑된 것만 divert 상태로 돌아간다")
        XCTAssertEqual(keyEvents, [], "인식 중 눌림은 키로 나가지 않는다")

        mouse.sendPressedButtons([MappingEngineTests.tiltLeft])
        XCTAssertEqual(keyEvents, ["down 80"], "인식이 끝난 뒤 엔진의 핸들러가 다시 일한다")
        await engine.stop()
    }

    private func gestureProfile() -> Profile {
        let button = ButtonID.hidpp(MappingEngineTests.back)
        let click = ButtonBinding(button: button, keys: MappingEngineTests.f19)
        let directions = GestureDirectionEnum.allCases.map { direction in
            ButtonBinding(button: button, keys: MappingEngineTests.f18, gesture: direction)
        }
        return Profile(id: UUID(), name: "gesture", bindings: [click] + directions)
    }

    func testGestureAccumulatesAndSendsClickOrEachDirectionOnlyOnRelease() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        engine.apply(gestureProfile())
        engine.addChannel(mouse.channel)
        await engine.waitUntilIdle()
        XCTAssertEqual(mouse.rawXY, [MappingEngineTests.back])
        XCTAssertTrue(engine.supportsRawXY(.hidpp(MappingEngineTests.back)))
        XCTAssertFalse(engine.supportsRawXY(.standard(3)))

        let samples: [(Int16, Int16, UInt16)] = [(20, 20, 80), (30, 2, 79), (-30, 2, 79), (2, -30, 79), (2, 30, 79)]
        for (dx, dy, expectedKey) in samples {
            keyEvents = []
            mouse.sendMovement(dx: 200, dy: 0) // 눌리기 전 이동은 버린다.
            mouse.sendPressedButtons([MappingEngineTests.back])
            mouse.sendMovement(dx: dx, dy: dy)
            mouse.sendPressedButtons([MappingEngineTests.back]) // 반복 상태가 누적을 초기화하지 않는다.
            mouse.sendMovement(dx: dx, dy: dy)
            XCTAssertEqual(keyEvents, [])
            mouse.sendPressedButtons([])
            XCTAssertEqual(keyEvents, ["down \(expectedKey)", "up \(expectedKey)"])
            mouse.sendPressedButtons([])
            XCTAssertEqual(keyEvents.count, 2)
        }
        await engine.stop()
        XCTAssertEqual(mouse.rawXY, [])
        XCTAssertEqual(mouse.diverted, [])
    }

    func testUnboundDirectionDoesNotFallBackToClickAndOtherDeviceMotionIsIgnored() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        let button = ButtonID.hidpp(MappingEngineTests.back)
        engine.apply(Profile(id: UUID(), name: "test", bindings: [
            ButtonBinding(button: button, keys: MappingEngineTests.f19),
            ButtonBinding(button: button, keys: MappingEngineTests.f18, gesture: .up),
        ]))
        engine.addChannel(mouse.channel)
        await engine.waitUntilIdle()
        mouse.sendPressedButtons([MappingEngineTests.back])
        mouse.sendMovement(dx: 100, dy: 0)
        mouse.sendPressedButtons([])
        XCTAssertEqual(keyEvents, [], "미지정 방향은 클릭을 보내지 않는다")

        mouse.sendPressedButtons([MappingEngineTests.back])
        mouse.sendMovement(dx: 0, dy: -100, deviceIndex: 1)
        mouse.sendPressedButtons([])
        XCTAssertEqual(keyEvents, ["down 80", "up 80"])
        await engine.stop()
    }

    func testUnsupportedControlKeepsClickHoldAndIgnoresDirections() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        mouse.supportsRawXY = false
        engine.apply(gestureProfile())
        engine.addChannel(mouse.channel)
        await engine.waitUntilIdle()
        XCTAssertFalse(engine.supportsRawXY(.hidpp(MappingEngineTests.back)))
        XCTAssertEqual(mouse.rawXY, [])
        mouse.sendPressedButtons([MappingEngineTests.back])
        XCTAssertEqual(keyEvents, ["down 80"])
        mouse.sendMovement(dx: 100, dy: 0)
        mouse.sendPressedButtons([])
        XCTAssertEqual(keyEvents, ["down 80", "up 80"])
        await engine.stop()
    }

    func testChangingToClickOnlyClearsRawXYWhileKeepingDivert() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        engine.apply(gestureProfile())
        engine.addChannel(mouse.channel)
        await engine.waitUntilIdle()
        mouse.sendPressedButtons([MappingEngineTests.back])
        mouse.sendMovement(dx: 100, dy: 0)
        engine.apply(profile([.hidpp(MappingEngineTests.back): MappingEngineTests.f19]))
        await engine.waitUntilIdle()
        XCTAssertEqual(mouse.rawXY, [])
        XCTAssertEqual(mouse.diverted, [MappingEngineTests.back])
        mouse.sendPressedButtons([])
        XCTAssertEqual(keyEvents, [], "프로필 변경으로 취소된 제스처는 보내지 않는다")
        mouse.sendPressedButtons([MappingEngineTests.back])
        XCTAssertEqual(keyEvents, ["down 80"])
        await engine.stop()
    }

    func testDisconnectCancelsGestureWithoutSendingKey() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        engine.apply(gestureProfile())
        engine.addChannel(mouse.channel)
        await engine.waitUntilIdle()
        mouse.sendPressedButtons([MappingEngineTests.back])
        mouse.sendMovement(dx: 100, dy: 0)
        engine.removeChannel(mouse.channel)
        XCTAssertEqual(keyEvents, [])
        await engine.stop()
    }

    func testCaptureRestoresRawXYAndUndivertClearsIt() async {
        let engine = makeEngine()
        let mouse = makeMouse()
        engine.apply(gestureProfile())
        engine.addChannel(mouse.channel)
        await engine.waitUntilIdle()
        var isReady = false
        let capture = ButtonCapture(channels: engine.channels) { message in
            if message.hasPrefix("ready") { isReady = true }
        }
        let captureTask = Task { await capture.capture() }
        await waitUntil { isReady }
        XCTAssertEqual(mouse.rawXY, [])
        mouse.sendPressedButtons([MappingEngineTests.back])
        let captured = await captureTask.value
        XCTAssertEqual(captured, .hidpp(MappingEngineTests.back))
        XCTAssertEqual(mouse.rawXY, [MappingEngineTests.back])
        await capture.undivertAll()
        XCTAssertEqual(mouse.rawXY, [])
        XCTAssertEqual(mouse.diverted, [])
        await engine.stop()
    }
}
