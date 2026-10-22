import AppKit

// 디버그: 권한 상태를 출력하고 끝낸다. 셸에서 실행하면 터미널의 권한을 물려받는다.
if CommandLine.arguments.contains("--permissions") {
    for permission in Permission.allCases {
        print(permission.statusLine(granted: permission.isGranted))
    }
    exit(0)
}

// 디버그: 연결된 로지텍 기기의 HID++ 프로토콜 버전과 컨트롤 목록을 출력하고 끝낸다.
if CommandLine.arguments.contains("--dump") {
    Task {
        await dumpHIDPP()
        exit(0)
    }
    RunLoop.main.run()
}

// 디버그: 입력 모니터링 상태와, 그 상태로 HID++ 장치가 열리는지 출력하고 끝낸다.
if CommandLine.arguments.contains("--hid-access") {
    Task {
        await checkHIDAccess()
        exit(0)
    }
    RunLoop.main.run()
}

// 디버그: 인식 모드로 눌린 버튼 하나를 출력하고 끝낸다. `--capture 10`이면 10초(기본 10초)까지 기다린다.
if let captureIndex = CommandLine.arguments.firstIndex(of: "--capture") {
    let secondsArgument = CommandLine.arguments.dropFirst(captureIndex + 1).first
    let timeoutSeconds = secondsArgument.flatMap { Int($0) } ?? 10
    Task {
        let exitCode = await runCapture(timeoutSeconds: timeoutSeconds)
        exit(exitCode)
    }
    RunLoop.main.run()
}

// 디버그: 모든 divertable 버튼의 divert를 풀고 끝낸다(인식 중 프로세스가 죽어 divert가 남았을 때).
if CommandLine.arguments.contains("--undivert") {
    Task {
        await runUndivert()
        exit(0)
    }
    RunLoop.main.run()
}

// 디버그: 키 하나를 보내고 끝낸다. `--inject 80 0x120000 [누르는 시간 ms]`
if let injectIndex = CommandLine.arguments.firstIndex(of: "--inject") {
    let injectArguments = Array(CommandLine.arguments.dropFirst(injectIndex + 1))
    exit(runInject(arguments: injectArguments))
}

// 디버그: 설정 창·버튼 인식 시트·메뉴를 PNG로 그려 폴더에 저장하고 끝낸다. `--snapshot <폴더>`
if let snapshotIndex = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let outputDirectory = CommandLine.arguments.dropFirst(snapshotIndex + 1).first ?? "snapshot"
    exit(runSnapshot(outputDirectory: outputDirectory))
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
