import Foundation

private let timeoutExitCode: Int32 = 2

// 디버그(--capture [초]): 인식 모드로 버튼 하나를 기다려 stdout에 `standard(3)` / `hidpp(0x0053)`로 출력한다.
// 로그는 stderr. 시간이 지나거나 SIGINT/SIGTERM을 받으면 인식 모드를 끝내 divert를 되돌리고 종료 코드 2로 끝난다.
@MainActor
func runCapture(timeoutSeconds: Int) async -> Int32 {
    let manager = HIDPPManager()
    let capture = ButtonCapture(channels: manager.nodes.map(\.channel), log: printToStandardError)
    let captureTask = Task { await capture.capture() }

    var signalSources: [DispatchSourceSignal] = []
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { captureTask.cancel() }
        source.resume()
        signalSources.append(source)
    }
    let timeoutTask = Task {
        try? await Task.sleep(for: .seconds(timeoutSeconds))
        captureTask.cancel()
    }

    let button = await captureTask.value
    timeoutTask.cancel()
    withExtendedLifetime(signalSources) {}

    switch button {
    case .standard(let buttonNumber):
        print("standard(\(buttonNumber))")
        return 0
    case .hidpp(let cid):
        print(String(format: "hidpp(0x%04X)", cid))
        return 0
    case nil:
        printToStandardError("취소 또는 시간 초과")
        return timeoutExitCode
    }
}

// 디버그(--undivert): 모든 divertable CID의 divert를 푼다.
@MainActor
func runUndivert() async {
    let manager = HIDPPManager()
    let capture = ButtonCapture(channels: manager.nodes.map(\.channel), log: printToStandardError)
    await capture.undivertAll()
}
