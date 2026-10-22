import Foundation

// 인식 모드가 divert하는 컨트롤 하나. wasDiverted는 인식 모드에 들어가기 전 상태다.
private struct DivertTarget {
    let channel: HIDPPChannel
    let deviceIndex: UInt8
    let featureIndex: UInt8
    let cid: UInt16
    let wasDiverted: Bool
    let wasRawXY: Bool
    let supportsRawXY: Bool
}

// 인식 모드: divertable CID를 모두 divert하고 일반 버튼(3 이상)은 삼키면서, 처음 눌린 버튼 하나를 돌려준다.
// 끝나면(버튼이 눌렸거나 task가 취소되면) divert를 원래 상태로 되돌린 뒤에 돌아온다.
@MainActor
final class ButtonCapture {
    private static let releaseWaitLimit: Duration = .seconds(2)
    private static let releasePollInterval: Duration = .milliseconds(20)

    private let channels: [HIDPPChannel]
    private let log: (String) -> Void
    private var continuation: CheckedContinuation<ButtonID?, Never>?
    private var heldStandardButton: Int?
    // 인식하는 동안 채널의 알림 핸들러를 빼앗는다. 끝나면 원래 핸들러(매핑 엔진 것)를 돌려놓는다.
    private var previousHandlers: [ObjectIdentifier: (([UInt8]) -> Void)?] = [:]

    init(channels: [HIDPPChannel], log: @escaping (String) -> Void = { _ in }) {
        self.channels = channels
        self.log = log
    }

    // 취소되면 nil.
    func capture(onReady: @MainActor () -> Void = {}) async -> ButtonID? {
        let targets = await divertableTargets()
        for target in targets { await setDiverted(true, rawXY: false, on: target) }
        listenForDivertedButtons(of: targets)

        // 손쉬운 사용 권한이 없으면 탭이 없다. 그때는 HID++ 버튼만 인식된다.
        let tap = ButtonTap { [weak self] buttonNumber, isDown in
            self?.handleStandardButton(buttonNumber, isDown: isDown) ?? true
        }
        if tap == nil { log("일반 버튼 탭을 만들지 못했다(손쉬운 사용 권한 없음) — HID++ 버튼만 인식한다") }

        let tapState = tap == nil ? "없음" : "있음"
        log("ready: divert \(targets.count)개, 일반 버튼 탭 \(tapState)")
        let button: ButtonID? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                if !Task.isCancelled { onReady() }
            }
        } onCancel: {
            Task { @MainActor in self.finish(with: nil) }
        }

        stopListening()
        for target in targets { await setDiverted(target.wasDiverted, rawXY: target.wasRawXY, on: target) }
        await waitForStandardButtonRelease()
        tap?.stop()
        return button
    }

    // 복구용: 모든 divertable CID의 divert를 푼다. 인식 중에 프로세스가 죽어 divert가 남았을 때 쓴다.
    func undivertAll() async {
        let targets = await divertableTargets()
        for target in targets { await setDiverted(false, rawXY: false, on: target) }
    }

    private func divertableTargets() async -> [DivertTarget] {
        var targets: [DivertTarget] = []
        for channel in channels {
            for control in await channel.divertableControls() {
                let reporting = try? await channel.cidReporting(cid: control.cid, featureIndex: control.featureIndex, deviceIndex: control.deviceIndex)
                targets.append(DivertTarget(
                    channel: channel,
                    deviceIndex: control.deviceIndex,
                    featureIndex: control.featureIndex,
                    cid: control.cid,
                    wasDiverted: reporting?.diverted ?? false,
                    wasRawXY: reporting?.rawXY ?? false,
                    supportsRawXY: control.supportsRawXY
                ))
            }
        }
        return targets
    }

    // setCidReporting 응답을 받은 뒤 getCidReporting으로 실제 상태를 다시 읽어 로그에 남긴다.
    private func setDiverted(_ diverted: Bool, rawXY: Bool, on target: DivertTarget) async {
        let name = String(format: "cid 0x%04X (index 0x%02X)", target.cid, target.deviceIndex)
        do {
            let rawXYSetting: Bool? = target.supportsRawXY ? rawXY : nil
            try await target.channel.setDiverted(diverted, rawXY: rawXYSetting, cid: target.cid, featureIndex: target.featureIndex, deviceIndex: target.deviceIndex)
            let actual = try await target.channel.isDiverted(cid: target.cid, featureIndex: target.featureIndex, deviceIndex: target.deviceIndex)
            log("setCidReporting \(name) diverted=\(diverted) → 응답 받음, getCidReporting diverted=\(actual)")
        } catch {
            log("setCidReporting \(name) diverted=\(diverted) 실패: \(error)")
        }
    }

    // 알림 핸들러는 채널당 하나라서 원래 것을 기억해 뒀다가 stopListening에서 돌려놓는다.
    private func listenForDivertedButtons(of targets: [DivertTarget]) {
        for channel in channels {
            previousHandlers[ObjectIdentifier(channel)] = channel.onNotification
            let channelTargets = targets.filter { $0.channel === channel }
            channel.onNotification = { [weak self] report in
                self?.handleNotification(report, targets: channelTargets)
            }
        }
    }

    private func stopListening() {
        for channel in channels {
            let previousHandler = previousHandlers[ObjectIdentifier(channel)] ?? nil
            channel.onNotification = previousHandler
        }
        previousHandlers = [:]
    }

    private func handleNotification(_ report: [UInt8], targets: [DivertTarget]) {
        for target in targets {
            let pressed = HIDPPChannel.divertedButtons(in: report, deviceIndex: target.deviceIndex, featureIndex: target.featureIndex)
            guard let pressed else { continue }
            if let cid = pressed.first { finish(with: .hidpp(cid)) }
            return
        }
    }

    private func handleStandardButton(_ buttonNumber: Int, isDown: Bool) -> Bool {
        if isDown && continuation != nil {
            heldStandardButton = buttonNumber
            finish(with: .standard(buttonNumber))
        }
        if !isDown && buttonNumber == heldStandardButton { heldStandardButton = nil }
        return true
    }

    private func finish(with button: ButtonID?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: button)
    }

    // 눌린 일반 버튼의 up까지 삼켜야 앱에 up만 따로 가지 않는다. up이 안 와도 영원히 기다리지 않는다.
    private func waitForStandardButtonRelease() async {
        let pollCount = Int(ButtonCapture.releaseWaitLimit / ButtonCapture.releasePollInterval)
        for _ in 0..<pollCount {
            if heldStandardButton == nil { return }
            try? await Task.sleep(for: ButtonCapture.releasePollInterval)
        }
    }
}
