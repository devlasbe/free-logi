import Foundation

// 0x1B04 getCidInfo 한 줄. 응답 파라미터: cid(2) tid(2) flags(1) position(1) group(1) groupMask(1) flagsHigh(1)
struct HIDPPControl: Equatable {
    private static let divertableFlag: UInt16 = 1 << 5
    private static let persistentlyDivertableFlag: UInt16 = 1 << 6
    private static let rawXYFlag: UInt16 = 1 << 8

    let cid: UInt16
    let taskId: UInt16
    let flags: UInt16

    var isDivertable: Bool { flags & HIDPPControl.divertableFlag != 0 }
    var isPersistentlyDivertable: Bool { flags & HIDPPControl.persistentlyDivertableFlag != 0 }
    var supportsRawXY: Bool { flags & HIDPPControl.rawXYFlag != 0 }

    init(payload: [UInt8]) {
        let flagsLow = UInt16(payload[4])
        let flagsHigh = UInt16(payload[8])
        self.cid = UInt16(payload[0]) << 8 | UInt16(payload[1])
        self.taskId = UInt16(payload[2]) << 8 | UInt16(payload[3])
        self.flags = flagsHigh << 8 | flagsLow
    }
}

// divert할 수 있는 컨트롤 하나가 어느 기기(deviceIndex)의 0x1B04(featureIndex)에 있는지.
struct HIDPPDivertControl: Equatable {
    let deviceIndex: UInt8
    let featureIndex: UInt8
    let cid: UInt16
    var supportsRawXY = false
}

struct HIDPPReporting: Equatable {
    let diverted: Bool
    let rawXY: Bool
}

enum HIDPPFeatureId {
    static let deviceName: UInt16 = 0x0005
    static let reprogControls: UInt16 = 0x1B04
}

extension HIDPPChannel {
    // 수신기에 붙은 기기는 슬롯 1~6
    static let receiverSlotIndexes: ClosedRange<UInt8> = 1...6

    private static let connectionsRegister: UInt8 = 0x02
    private static let rootFeatureIndex: UInt8 = 0
    private static let pingData: UInt8 = 0xA5
    private static let getCidReportingFunction: UInt8 = 2
    private static let setCidReportingFunction: UInt8 = 3
    private static let divertedButtonsEvent: UInt8 = 0
    private static let divertedFlag: UInt8 = 1 << 0
    private static let divertedValidFlag: UInt8 = 1 << 1
    private static let rawXYFlag: UInt8 = 1 << 4
    private static let rawXYValidFlag: UInt8 = 1 << 5
    private static let divertedRawMouseXYEvent: UInt8 = 1
    private static let divertedButtonSlotCount = 4

    // 수신기 Connections 레지스터(0x02)의 두 번째 바이트 = 페어링된 기기 수. 오프라인 기기도 센다.
    func pairedDeviceCount() async throws -> UInt8 {
        let data = try await readRegister(deviceIndex: HIDPPChannel.directDeviceIndex, address: HIDPPChannel.connectionsRegister)
        let pairedCount = data[1]
        return pairedCount
    }

    // Root(index 0) fn1 ping. 응답 파라미터 = [프로토콜 major, minor, pingData].
    // HID++ 1.0 기기는 ping에 InvalidSubId(0x01) 오류로 답한다 → 1.0.
    func protocolVersion(deviceIndex: UInt8) async throws -> (major: UInt8, minor: UInt8) {
        do {
            let payload = try await request(
                deviceIndex: deviceIndex,
                featureIndex: HIDPPChannel.rootFeatureIndex,
                function: 1,
                params: [0, 0, HIDPPChannel.pingData]
            )
            return (payload[0], payload[1])
        } catch HIDPPError.errorReply(code: 0x01, isHIDPP10: true) {
            return (1, 0)
        }
    }

    // Root fn0 getFeature. 응답 파라미터 = [feature index, type, version]. index 0은 "없음"이다.
    func featureIndex(of featureId: UInt16, deviceIndex: UInt8) async throws -> UInt8? {
        let payload = try await request(
            deviceIndex: deviceIndex,
            featureIndex: HIDPPChannel.rootFeatureIndex,
            function: 0,
            params: [UInt8(featureId >> 8), UInt8(featureId & 0xFF)]
        )
        let index = payload[0]
        let isNotFound = index == HIDPPChannel.rootFeatureIndex
        return isNotFound ? nil : index
    }

    // 0x0005 DeviceName: fn0 getCount, fn1 getDeviceName(charIndex) → 이름 조각(최대 16자)
    func deviceName(deviceIndex: UInt8) async throws -> String? {
        guard let index = try await featureIndex(of: HIDPPFeatureId.deviceName, deviceIndex: deviceIndex) else {
            return nil
        }
        let countPayload = try await request(deviceIndex: deviceIndex, featureIndex: index, function: 0)
        let nameLength = Int(countPayload[0])

        var characters: [UInt8] = []
        while characters.count < nameLength {
            let chunk = try await request(
                deviceIndex: deviceIndex,
                featureIndex: index,
                function: 1,
                params: [UInt8(characters.count)]
            )
            characters.append(contentsOf: chunk)
        }
        return String(decoding: characters.prefix(nameLength), as: UTF8.self)
    }

    // 0x1B04 ReprogControlsV4: fn0 getCount, fn1 getCidInfo(i). 기능이 없으면 nil.
    func controls(deviceIndex: UInt8) async throws -> [HIDPPControl]? {
        guard let index = try await featureIndex(of: HIDPPFeatureId.reprogControls, deviceIndex: deviceIndex) else {
            return nil
        }
        let countPayload = try await request(deviceIndex: deviceIndex, featureIndex: index, function: 0)
        let count = Int(countPayload[0])

        var controls: [HIDPPControl] = []
        for controlIndex in 0..<count {
            let payload = try await request(
                deviceIndex: deviceIndex,
                featureIndex: index,
                function: 1,
                params: [UInt8(controlIndex)]
            )
            controls.append(HIDPPControl(payload: payload))
        }
        return controls
    }

    // HID++ 2.0으로 응답하는 기기의 인덱스. 직결이면 [0xFF], 수신기면 응답하는 슬롯.
    func connectedDeviceIndexes() async -> [UInt8] {
        guard let directVersion = try? await protocolVersion(deviceIndex: HIDPPChannel.directDeviceIndex) else {
            return []
        }
        if directVersion.major >= 2 { return [HIDPPChannel.directDeviceIndex] }

        var indexes: [UInt8] = []
        for slot in HIDPPChannel.receiverSlotIndexes {
            guard let version = try? await protocolVersion(deviceIndex: slot) else { continue }
            if version.major >= 2 { indexes.append(slot) }
        }
        return indexes
    }

    // 연결된 기기마다 0x1B04 컨트롤을 읽어 divert할 수 있는 것만 돌려준다. 응답 없는 기기·0x1B04 없는 기기는 건너뛴다.
    func divertableControls() async -> [HIDPPDivertControl] {
        var divertControls: [HIDPPDivertControl] = []
        for deviceIndex in await connectedDeviceIndexes() {
            guard let featureIndex = try? await featureIndex(of: HIDPPFeatureId.reprogControls, deviceIndex: deviceIndex),
                  let controls = try? await controls(deviceIndex: deviceIndex)
            else { continue }

            for control in controls where control.isDivertable {
                divertControls.append(HIDPPDivertControl(
                    deviceIndex: deviceIndex,
                    featureIndex: featureIndex,
                    cid: control.cid,
                    supportsRawXY: control.supportsRawXY
                ))
            }
        }
        return divertControls
    }

    // 0x1B04 fn2 getCidReporting. 응답 파라미터: cid(2) flags(1) remap(2) flags2(1). flags bit0 = 임시 divert.
    func isDiverted(cid: UInt16, featureIndex: UInt8, deviceIndex: UInt8) async throws -> Bool {
        let reporting = try await cidReporting(cid: cid, featureIndex: featureIndex, deviceIndex: deviceIndex)
        return reporting.diverted
    }

    func cidReporting(cid: UInt16, featureIndex: UInt8, deviceIndex: UInt8) async throws -> HIDPPReporting {
        let payload = try await request(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            function: HIDPPChannel.getCidReportingFunction,
            params: [UInt8(cid >> 8), UInt8(cid & 0xFF)]
        )
        let flags = payload[2]
        return HIDPPReporting(
            diverted: flags & HIDPPChannel.divertedFlag != 0,
            rawXY: flags & HIDPPChannel.rawXYFlag != 0
        )
    }

    // 0x1B04 fn3 setCidReporting. 파라미터: cid(2) flags(1) remap(2) flags2(1). flags bit0 = divert 값, bit1 = "bit0을 바꾼다".
    // bit4 = rawXY 값, bit5 = "bit4를 바꾼다". 영구 divert·forceRawXY는 바꾸지 않는다.
    // remap을 0으로 두면 그대로 유지된다. 임시 divert라서 기기를 껐다 켜면 풀린다.
    func setDiverted(_ diverted: Bool, rawXY: Bool? = nil, cid: UInt16, featureIndex: UInt8, deviceIndex: UInt8) async throws {
        var flags = HIDPPChannel.divertedValidFlag
        if diverted { flags |= HIDPPChannel.divertedFlag }
        // nil은 rawXY를 그대로 둔다. 지원하는 컨트롤에서만 이 비트를 바꾼다.
        if let rawXY {
            flags |= HIDPPChannel.rawXYValidFlag
            if rawXY { flags |= HIDPPChannel.rawXYFlag }
        }
        _ = try await request(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            function: HIDPPChannel.setCidReportingFunction,
            params: [UInt8(cid >> 8), UInt8(cid & 0xFF), flags]
        )
    }

    // 0x1B04 event0 divertedButtonsEvent 알림: [0x11, deviceIndex, featureIndex, event0 << 4, cid(2) × 4].
    // 지금 눌려 있는 CID만 돌려준다(빈 자리 0은 뺀다). 다른 리포트면 nil.
    static func divertedButtons(in report: [UInt8], deviceIndex: UInt8, featureIndex: UInt8) -> [UInt16]? {
        let reportLength = headerLength + divertedButtonSlotCount * 2
        let isDivertedButtonsEvent = report.count >= reportLength
            && report[0] == longReportId
            && report[1] == deviceIndex
            && report[2] == featureIndex
            && report[3] == divertedButtonsEvent << 4
        if !isDivertedButtonsEvent { return nil }

        var pressedCids: [UInt16] = []
        for slot in 0..<divertedButtonSlotCount {
            let offset = headerLength + slot * 2
            let cid = UInt16(report[offset]) << 8 | UInt16(report[offset + 1])
            if cid != 0 { pressedCids.append(cid) }
        }
        return pressedCids
    }

    // event1: signed big-endian dx(2), dy(2). CID는 없으므로 같은 기기에서 누른 제스처 버튼에만 쓴다.
    static func divertedRawMouseXY(in report: [UInt8], deviceIndex: UInt8, featureIndex: UInt8) -> (dx: Int16, dy: Int16)? {
        let minimumLength = headerLength + 4
        let isRawXYEvent = report.count >= minimumLength
            && report[0] == longReportId
            && report[1] == deviceIndex
            && report[2] == featureIndex
            && report[3] == divertedRawMouseXYEvent << 4
        if !isRawXYEvent { return nil }
        let dxBits = UInt16(report[4]) << 8 | UInt16(report[5])
        let dyBits = UInt16(report[6]) << 8 | UInt16(report[7])
        return (Int16(bitPattern: dxBits), Int16(bitPattern: dyBits))
    }
}
