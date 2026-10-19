import Foundation

enum HIDPPError: Error, Equatable {
    case timeout
    case sendFailed
    // HID++ 2.0 오류 응답은 두 번째 바이트 자리(feature index)에 0xFF, HID++ 1.0 오류 응답은 0x8F가 온다.
    case errorReply(code: UInt8, isHIDPP10: Bool)
}

// HID++ long 리포트(20바이트): [0x11, deviceIndex, featureIndex, function << 4 | softwareId, 파라미터 16바이트]
// BLE 직결 기기는 long만 있어서 요청은 항상 long으로 보낸다. 수신기·USB는 둘 다 받는다.
@MainActor
final class HIDPPChannel {
    static let shortReportId: UInt8 = 0x10
    static let longReportId: UInt8 = 0x11
    static let longReportLength = 20
    // 채널이 붙은 장치 자신의 인덱스: 직결 기기이거나, 수신기면 수신기 자신. 수신기에 붙은 기기는 슬롯 1~6.
    static let directDeviceIndex: UInt8 = 0xFF
    // 0은 기기가 먼저 보내는 알림의 swId라서 요청에는 쓰지 않는다.
    static let softwareId: UInt8 = 0x0A

    static let headerLength = 4
    private static let getRegisterSubId: UInt8 = 0x81
    private static let hidpp20ErrorMarker: UInt8 = 0xFF
    private static let hidpp10ErrorMarker: UInt8 = 0x8F

    private struct PendingRequest {
        let frame: [UInt8]
        let continuation: CheckedContinuation<[UInt8], any Error>
    }

    // 요청에 맞는 응답이 아닌 모든 HID++ 리포트(버튼 알림, 수신기 알림)가 여기로 온다.
    var onNotification: (([UInt8]) -> Void)?

    private let sendFrame: ([UInt8]) -> Bool
    private let responseTimeout: Duration
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var nextRequestId = 0

    init(responseTimeout: Duration = .seconds(1), sendFrame: @escaping ([UInt8]) -> Bool) {
        self.responseTimeout = responseTimeout
        self.sendFrame = sendFrame
    }

    // 응답의 파라미터 16바이트를 돌려준다. 같은 기기·feature·function·swId인 응답이 올 때까지 기다린다.
    func request(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        params: [UInt8] = []
    ) async throws -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: HIDPPChannel.longReportLength)
        frame[0] = HIDPPChannel.longReportId
        frame[1] = deviceIndex
        frame[2] = featureIndex
        frame[3] = function << 4 | HIDPPChannel.softwareId
        frame.replaceSubrange(HIDPPChannel.headerLength..<(HIDPPChannel.headerLength + params.count), with: params)
        let payload = try await send(frame)
        return payload
    }

    // HID++ 1.0 레지스터 읽기(수신기용): short [0x10, deviceIndex, 0x81, address, 0, 0, 0] → 응답 데이터 3바이트.
    // 요청 헤더 자리(0x81, address)가 2.0의 (feature index, function<<4|swId) 자리와 같아서 같은 매칭을 쓴다.
    func readRegister(deviceIndex: UInt8, address: UInt8) async throws -> [UInt8] {
        let frame: [UInt8] = [HIDPPChannel.shortReportId, deviceIndex, HIDPPChannel.getRegisterSubId, address, 0, 0, 0]
        let data = try await send(frame)
        return data
    }

    private func send(_ frame: [UInt8]) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            let requestId = nextRequestId
            nextRequestId += 1
            pendingRequests[requestId] = PendingRequest(frame: frame, continuation: continuation)

            let isSent = sendFrame(frame)
            if !isSent {
                finish(requestId, with: .failure(HIDPPError.sendFailed))
                return
            }

            Task {
                try? await Task.sleep(for: responseTimeout)
                finish(requestId, with: .failure(HIDPPError.timeout))
            }
        }
    }

    // 장치에서 올라온 input 리포트 하나. 같은 인터페이스의 마우스·키보드 리포트는 버린다.
    func handleReport(_ report: [UInt8]) {
        let isHIDPPReport = report.first == HIDPPChannel.shortReportId || report.first == HIDPPChannel.longReportId
        if !isHIDPPReport { return }

        for (requestId, pending) in pendingRequests {
            guard let result = HIDPPChannel.reply(to: pending.frame, report: report) else { continue }
            finish(requestId, with: result)
            return
        }
        onNotification?(report)
    }

    private func finish(_ requestId: Int, with result: Result<[UInt8], HIDPPError>) {
        guard let pending = pendingRequests.removeValue(forKey: requestId) else { return }
        switch result {
        case .success(let payload): pending.continuation.resume(returning: payload)
        case .failure(let error): pending.continuation.resume(throwing: error)
        }
    }

    // report가 frame 요청의 응답이면 결과를, 아니면 nil을 돌려준다.
    // 오류 응답: [id, dev, 0xFF|0x8F, 요청 feature index, 요청 function<<4|swId, 오류 코드, …]
    private static func reply(to frame: [UInt8], report: [UInt8]) -> Result<[UInt8], HIDPPError>? {
        let minimumLength = headerLength + 2
        if report.count < minimumLength { return nil }
        if report[1] != frame[1] { return nil }

        let marker = report[2]
        let isHIDPP20Error = marker == hidpp20ErrorMarker
        let isHIDPP10Error = marker == hidpp10ErrorMarker
        if isHIDPP20Error || isHIDPP10Error {
            let isErrorForRequest = report[3] == frame[2] && report[4] == frame[3]
            if !isErrorForRequest { return nil }
            return .failure(.errorReply(code: report[5], isHIDPP10: isHIDPP10Error))
        }

        let isReplyForRequest = marker == frame[2] && report[3] == frame[3]
        if !isReplyForRequest { return nil }
        let payload = Array(report[headerLength...])
        return .success(payload)
    }
}
