import XCTest
@testable import FreeLogi

@MainActor
final class HIDPPChannelTests: XCTestCase {
    private static let batteryFeatureIndex: UInt8 = 0x09
    private static let requestHeaderByte: UInt8 = 0x1A // function 1, swId 0x0A

    private var sentFrames: [[UInt8]] = []

    private func makeChannel(timeout: Duration = .seconds(5), isSent: Bool = true) -> HIDPPChannel {
        HIDPPChannel(responseTimeout: timeout) { frame in
            self.sentFrames.append(frame)
            return isSent
        }
    }

    // request가 프레임을 보낼 때까지 양보한다.
    private func waitForSentFrame() async {
        for _ in 0..<100 {
            if !sentFrames.isEmpty { return }
            await Task.yield()
        }
    }

    private func report(
        id: UInt8 = 0x11,
        deviceIndex: UInt8 = 0xFF,
        marker: UInt8 = HIDPPChannelTests.batteryFeatureIndex,
        header: UInt8 = HIDPPChannelTests.requestHeaderByte,
        data: [UInt8] = []
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes[0] = id
        bytes[1] = deviceIndex
        bytes[2] = marker
        bytes[3] = header
        bytes.replaceSubrange(4..<(4 + data.count), with: data)
        return bytes
    }

    func testRequestSendsLongFrameAndReturnsMatchingReplyPayload() async throws {
        let channel = makeChannel()
        let pending = Task {
            try await channel.request(deviceIndex: 0xFF, featureIndex: HIDPPChannelTests.batteryFeatureIndex, function: 1, params: [7])
        }
        await waitForSentFrame()

        var expectedFrame = [UInt8](repeating: 0, count: 20)
        expectedFrame.replaceSubrange(0..<5, with: [0x11, 0xFF, 0x09, 0x1A, 7])
        XCTAssertEqual(sentFrames, [expectedFrame])

        channel.handleReport(report(data: [4, 5, 6]))
        let payload = try await pending.value
        XCTAssertEqual(Array(payload.prefix(3)), [4, 5, 6])
        XCTAssertEqual(payload.count, 16)
    }

    func testHIDPP20ErrorReplyThrowsErrorCode() async {
        let channel = makeChannel()
        let pending = Task {
            try await channel.request(deviceIndex: 0xFF, featureIndex: HIDPPChannelTests.batteryFeatureIndex, function: 1)
        }
        await waitForSentFrame()

        let errorReport = report(marker: 0xFF, header: HIDPPChannelTests.batteryFeatureIndex, data: [HIDPPChannelTests.requestHeaderByte, 0x02])
        channel.handleReport(errorReport)

        do {
            _ = try await pending.value
            XCTFail("오류 응답이면 던져야 한다")
        } catch {
            XCTAssertEqual(error as? HIDPPError, .errorReply(code: 0x02, isHIDPP10: false))
        }
    }

    func testHIDPP10ErrorReplyIsMarkedAsHIDPP10() async {
        let channel = makeChannel()
        let pending = Task {
            try await channel.request(deviceIndex: 3, featureIndex: HIDPPChannelTests.batteryFeatureIndex, function: 1)
        }
        await waitForSentFrame()

        let errorReport = report(deviceIndex: 3, marker: 0x8F, header: HIDPPChannelTests.batteryFeatureIndex, data: [HIDPPChannelTests.requestHeaderByte, 0x09])
        channel.handleReport(errorReport)

        do {
            _ = try await pending.value
            XCTFail("오류 응답이면 던져야 한다")
        } catch {
            XCTAssertEqual(error as? HIDPPError, .errorReply(code: 0x09, isHIDPP10: true))
        }
    }

    func testNoReplyTimesOut() async {
        let channel = makeChannel(timeout: .milliseconds(50))
        do {
            _ = try await channel.request(deviceIndex: 0xFF, featureIndex: 0, function: 0)
            XCTFail("응답이 없으면 던져야 한다")
        } catch {
            XCTAssertEqual(error as? HIDPPError, .timeout)
        }
    }

    func testSendFailureThrows() async {
        let channel = makeChannel(isSent: false)
        do {
            _ = try await channel.request(deviceIndex: 0xFF, featureIndex: 0, function: 0)
            XCTFail("보내기에 실패하면 던져야 한다")
        } catch {
            XCTAssertEqual(error as? HIDPPError, .sendFailed)
        }
    }

    func testReportsThatAreNotTheReplyGoToNotificationHandler() async throws {
        let channel = makeChannel()
        var notifications: [[UInt8]] = []
        channel.onNotification = { notifications.append($0) }

        let pending = Task {
            try await channel.request(deviceIndex: 0xFF, featureIndex: HIDPPChannelTests.batteryFeatureIndex, function: 1)
        }
        await waitForSentFrame()

        let deviceNotification = report(header: 0x10) // swId 0 = 기기가 먼저 보낸 알림
        let otherDeviceReply = report(deviceIndex: 2)
        let mouseMovement = report(id: 0x02)
        channel.handleReport(deviceNotification)
        channel.handleReport(otherDeviceReply)
        channel.handleReport(mouseMovement)
        XCTAssertEqual(notifications, [deviceNotification, otherDeviceReply])

        channel.handleReport(report(data: [1]))
        _ = try await pending.value
        XCTAssertEqual(notifications.count, 2)
    }

    func testReadRegisterMatchesHIDPP10Reply() async throws {
        let channel = makeChannel()
        let pending = Task { try await channel.readRegister(deviceIndex: 0xFF, address: 0x02) }
        await waitForSentFrame()
        XCTAssertEqual(sentFrames, [[0x10, 0xFF, 0x81, 0x02, 0, 0, 0]])

        channel.handleReport([0x10, 0xFF, 0x81, 0x02, 0x00, 0x03, 0x00])
        let data = try await pending.value
        XCTAssertEqual(data, [0x00, 0x03, 0x00])
    }

    func testPingReplyGivesProtocolVersion() async throws {
        let channel = makeChannel()
        let pending = Task { try await channel.protocolVersion(deviceIndex: 0xFF) }
        await waitForSentFrame()

        channel.handleReport(report(marker: 0, header: 0x1A, data: [4, 5, 0xA5]))
        let version = try await pending.value
        XCTAssertEqual(version.major, 4)
        XCTAssertEqual(version.minor, 5)
    }

    func testHIDPP10InvalidSubIdOnPingMeansProtocolOnePointZero() async throws {
        let channel = makeChannel()
        let pending = Task { try await channel.protocolVersion(deviceIndex: 0xFF) }
        await waitForSentFrame()

        channel.handleReport(report(marker: 0x8F, header: 0, data: [0x1A, 0x01]))
        let version = try await pending.value
        XCTAssertEqual(version.major, 1)
        XCTAssertEqual(version.minor, 0)
    }

    // 실기기(M585/M590 BLE) --dump 값
    func testControlParsesCidTaskIdAndFlags() {
        let middleButton = HIDPPControl(payload: [0x00, 0x52, 0x00, 0x3A, 0x71, 0x03, 0x01, 0x01, 0x01])
        XCTAssertEqual(middleButton.cid, 0x0052)
        XCTAssertEqual(middleButton.taskId, 0x003A)
        XCTAssertEqual(middleButton.flags, 0x0171)
        XCTAssertTrue(middleButton.isDivertable)
        XCTAssertTrue(middleButton.isPersistentlyDivertable)

        let leftButton = HIDPPControl(payload: [0x00, 0x50, 0x00, 0x38, 0x11, 0x01, 0x01, 0x01, 0x00])
        XCTAssertEqual(leftButton.flags, 0x0011)
        XCTAssertFalse(leftButton.isDivertable)

        let dpiButton = HIDPPControl(payload: [0x00, 0xD7, 0x00, 0xB4, 0xA0, 0x08, 0x00, 0x00, 0x03])
        XCTAssertEqual(dpiButton.flags, 0x03A0)
        XCTAssertTrue(dpiButton.isDivertable)
        XCTAssertFalse(dpiButton.isPersistentlyDivertable)
    }

    func testSetDivertedSendsCidAndValidBitThenFinishesOnReply() async throws {
        let channel = makeChannel()
        let pending = Task { try await channel.setDiverted(true, cid: 0x0053, featureIndex: 0x09, deviceIndex: 0xFF) }
        await waitForSentFrame()

        // function 3, swId 0x0A → 0x3A. flags 0x03 = divert 값(bit0) + 바꾼다(bit1)
        var expectedFrame = [UInt8](repeating: 0, count: 20)
        expectedFrame.replaceSubrange(0..<7, with: [0x11, 0xFF, 0x09, 0x3A, 0x00, 0x53, 0x03])
        XCTAssertEqual(sentFrames, [expectedFrame])

        channel.handleReport(report(header: 0x3A, data: [0x00, 0x53, 0x03]))
        try await pending.value
    }

    func testSetDivertedFalseKeepsValidBitOnly() async throws {
        let channel = makeChannel()
        let pending = Task { try await channel.setDiverted(false, cid: 0x00D7, featureIndex: 0x09, deviceIndex: 0xFF) }
        await waitForSentFrame()
        XCTAssertEqual(Array(sentFrames[0].prefix(7)), [0x11, 0xFF, 0x09, 0x3A, 0x00, 0xD7, 0x02])

        channel.handleReport(report(header: 0x3A))
        try await pending.value
    }

    func testIsDivertedReadsFlagsBitZero() async throws {
        let channel = makeChannel()
        let pending = Task { try await channel.isDiverted(cid: 0x0053, featureIndex: 0x09, deviceIndex: 0xFF) }
        await waitForSentFrame()
        XCTAssertEqual(Array(sentFrames[0].prefix(6)), [0x11, 0xFF, 0x09, 0x2A, 0x00, 0x53])

        channel.handleReport(report(header: 0x2A, data: [0x00, 0x53, 0x01]))
        let isDiverted = try await pending.value
        XCTAssertTrue(isDiverted)
    }

    func testDivertedButtonsEventListsPressedCidsWithoutEmptySlots() {
        let pressedTwo: [UInt8] = [0x11, 0xFF, 0x09, 0x00, 0x00, 0x53, 0x00, 0x56, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 8)
        let pressed = HIDPPChannel.divertedButtons(in: pressedTwo, deviceIndex: 0xFF, featureIndex: 0x09)
        XCTAssertEqual(pressed, [0x0053, 0x0056])

        let releasedAll = report(marker: 0x09, header: 0x00)
        XCTAssertEqual(HIDPPChannel.divertedButtons(in: releasedAll, deviceIndex: 0xFF, featureIndex: 0x09), [])
    }

    func testDivertedButtonsEventIgnoresOtherReports() {
        let event = report(marker: 0x09, header: 0x00, data: [0x00, 0x53])
        XCTAssertNil(HIDPPChannel.divertedButtons(in: event, deviceIndex: 0x01, featureIndex: 0x09))
        XCTAssertNil(HIDPPChannel.divertedButtons(in: event, deviceIndex: 0xFF, featureIndex: 0x0A))

        let rawXYEvent = report(marker: 0x09, header: 0x10, data: [0x00, 0x53]) // event 1
        XCTAssertNil(HIDPPChannel.divertedButtons(in: rawXYEvent, deviceIndex: 0xFF, featureIndex: 0x09))

        let shortReport: [UInt8] = [0x10, 0xFF, 0x09, 0x00, 0x00, 0x53, 0x00]
        XCTAssertNil(HIDPPChannel.divertedButtons(in: shortReport, deviceIndex: 0xFF, featureIndex: 0x09))
    }

    func testRawXYReportingFlagBytes() async throws {
        let channel = makeChannel()
        let cases: [(Bool, Bool, UInt8)] = [(true, true, 0x33), (true, false, 0x23), (false, false, 0x22)]
        for (diverted, rawXY, expectedFlags) in cases {
            sentFrames = []
            let pending = Task {
                try await channel.setDiverted(diverted, rawXY: rawXY, cid: 0x0053, featureIndex: 0x09, deviceIndex: 0xFF)
            }
            await waitForSentFrame()
            var expectedFrame = [UInt8](repeating: 0, count: 20)
            expectedFrame.replaceSubrange(0..<7, with: [0x11, 0xFF, 0x09, 0x3A, 0, 0x53, expectedFlags])
            XCTAssertEqual(sentFrames, [expectedFrame], "영구 divert·forceRawXY 비트는 바꾸지 않는다")
            channel.handleReport(report(header: 0x3A))
            try await pending.value
        }
    }

    func testReportingReadsDivertedAndRawXYIndependently() async throws {
        let channel = makeChannel()
        let pending = Task { try await channel.cidReporting(cid: 0x0053, featureIndex: 0x09, deviceIndex: 0xFF) }
        await waitForSentFrame()
        channel.handleReport(report(header: 0x2A, data: [0, 0x53, 0x11]))
        let reporting = try await pending.value
        XCTAssertEqual(reporting, HIDPPReporting(diverted: true, rawXY: true))
    }

    func testRawXYEventParsesSignedBigEndianAndFiltersHeaders() throws {
        let event = report(header: 0x10, data: [0x80, 0, 0x7F, 0xFF])
        let movement = try XCTUnwrap(HIDPPChannel.divertedRawMouseXY(in: event, deviceIndex: 0xFF, featureIndex: 0x09))
        XCTAssertEqual(movement.dx, Int16.min)
        XCTAssertEqual(movement.dy, Int16.max)
        let negativeY = report(header: 0x10, data: [0, 1, 0xFF, 0xFE])
        XCTAssertEqual(HIDPPChannel.divertedRawMouseXY(in: negativeY, deviceIndex: 0xFF, featureIndex: 0x09)?.dy, -2)
        XCTAssertNil(HIDPPChannel.divertedRawMouseXY(in: event, deviceIndex: 1, featureIndex: 0x09))
        XCTAssertNil(HIDPPChannel.divertedRawMouseXY(in: event, deviceIndex: 0xFF, featureIndex: 0x08))
        for header: UInt8 in [0x00, 0x11, 0x1A] {
            let otherEvent = report(header: header)
            XCTAssertNil(HIDPPChannel.divertedRawMouseXY(in: otherEvent, deviceIndex: 0xFF, featureIndex: 0x09))
        }
        for length in 0..<8 {
            XCTAssertNil(HIDPPChannel.divertedRawMouseXY(in: Array(event.prefix(length)), deviceIndex: 0xFF, featureIndex: 0x09))
        }
        let otherReport = report(id: 0x02, header: 0x10)
        XCTAssertNil(HIDPPChannel.divertedRawMouseXY(in: otherReport, deviceIndex: 0xFF, featureIndex: 0x09))
    }
}
