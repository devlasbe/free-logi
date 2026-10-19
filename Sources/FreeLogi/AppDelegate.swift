import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let permissionPollInterval: TimeInterval = 2
    // 디버그: 이 경로의 profiles.json을 쓴다(사용자 프로필을 건드리지 않고 확인할 때).
    private static let profilesPathVariable = "FREELOGI_PROFILES_PATH"
    // 디버그: 이 값(keyCode)을 두고 시작하면 설정 창을 열고 "버튼 추가" 흐름을 UI 없이 돌린다.
    private static let debugAddButtonKeyVariable = "FREELOGI_DEBUG_ADD_BUTTON_KEY"
    // 끝난 프로세스를 기다린 뒤 1초 쉬고 새로 연다(막 끝난 앱 바로 뒤에 open -n 하면 안 뜬다).
    private static let relaunchScript = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /bin/sleep 1; shift; exec /usr/bin/open -n \"$@\""

    private static let reopenWindowArgument = "--show-window"

    private var statusItem: NSStatusItem?
    private var grantedPermissions: [Permission: Bool] = [:]
    private var store: ProfileStore?
    private var engine: MappingEngine?
    private var captureTask: Task<ButtonID?, Never>?
    private var restartTask: Task<Void, Never>?
    private var settingsWindow: SettingsWindowController?
    private var signalSources: [DispatchSourceSignal] = []
    private var isTerminating = false

    func makeMenu(granted: [Permission: Bool], profileState: ProfileStoreState? = nil) -> NSMenu {
        let menu = NSMenu()

        if let profileState {
            for profile in profileState.profiles {
                let profileItem = NSMenuItem(title: profile.name, action: #selector(selectProfile(_:)), keyEquivalent: "")
                profileItem.target = self
                profileItem.representedObject = profile.id
                profileItem.state = profile.id == profileState.activeID ? .on : .off
                menu.addItem(profileItem)
            }
            menu.addItem(.separator())
        }

        for permission in Permission.allCases {
            let isGranted = granted[permission] ?? false
            let statusItem = NSMenuItem(title: permission.statusLine(granted: isGranted), action: nil, keyEquivalent: "")
            menu.addItem(statusItem)
            if isGranted { continue }

            let reasonItem = NSMenuItem(title: permission.reason, action: nil, keyEquivalent: "")
            reasonItem.indentationLevel = 1
            menu.addItem(reasonItem)

            let settingsItem = NSMenuItem(
                title: String(localized: "\(permission.title) 설정 열기"),
                action: #selector(openPermissionSettings(_:)),
                keyEquivalent: ""
            )
            settingsItem.target = self
            settingsItem.representedObject = permission
            settingsItem.indentationLevel = 1
            menu.addItem(settingsItem)
        }

        menu.addItem(.separator())

        // 프로필을 못 읽었으면(store 없음) 설정 창을 열 수 없다.
        let settingsAction = profileState == nil ? nil : #selector(openSettings)
        let appSettingsItem = NSMenuItem(title: String(localized: "설정…"), action: settingsAction, keyEquivalent: ",")
        appSettingsItem.target = self
        menu.addItem(appSettingsItem)

        let aboutItem = NSMenuItem(title: String(localized: "FreeLogi 정보"), action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: String(localized: "종료"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        menu.addItem(quitItem)
        return menu
    }

    @objc private func openPermissionSettings(_ sender: NSMenuItem) {
        guard let permission = sender.representedObject as? Permission else { return }
        permission.requestAndOpenSettings()
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let profileID = sender.representedObject as? UUID else { return }
        do {
            try store?.setActive(id: profileID)
        } catch {
            printToStandardError("프로필을 저장하지 못했다: \(error)")
        }
        profilesDidChange()
        settingsWindow?.model.reload()
    }

    @objc private func openAbout() {
        let repositoryURL = "https://github.com/devlasbe/free-logi"
        let credits = NSAttributedString(string: repositoryURL, attributes: [.link: repositoryURL])
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func openSettings() {
        if let settingsWindow {
            settingsWindow.show()
            return
        }
        guard let store else { return }

        let model = SettingsModel(
            store: store,
            captureButton: { [weak self] onReady in await self?.captureButton(onReady: onReady) },
            supportsRawXY: { [weak self] button in self?.engine?.supportsRawXY(button) ?? false },
            onChange: { [weak self] in self?.profilesDidChange() }
        )
        let windowController = SettingsWindowController(model: model, granted: grantedPermissions)
        windowController.onClose = { [weak self] in self?.settingsWindow = nil }
        settingsWindow = windowController
        windowController.show()
    }

    // 엔진이 하던 divert 작업이 끝난 뒤에 인식 모드로 들어간다(같은 채널에 요청이 섞이지 않게).
    private func captureButton(onReady: @escaping @MainActor () -> Void) async -> ButtonID? {
        guard let engine, captureTask == nil, restartTask == nil, !isTerminating else { return nil }
        let task = Task {
            await engine.waitUntilIdle()
            guard !Task.isCancelled else { return nil as ButtonID? }
            let capture = ButtonCapture(channels: engine.channels, log: printToStandardError)
            return await capture.capture(onReady: onReady)
        }
        captureTask = task
        let button = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        captureTask = nil
        return button
    }

    // 활성 프로필이나 매핑이 바뀌면 엔진과 메뉴가 따라간다.
    private func profilesDidChange() {
        if restartTask == nil { engine?.apply(store?.activeProfile) }
        rebuildMenu()
    }

    private func rebuildMenu() {
        statusItem?.menu = makeMenu(granted: grantedPermissions, profileState: store?.state)
    }

    // 권한 상태가 바뀐 때만 메뉴를 다시 만든다. 미허용 → 허용으로 바뀐 것이 있으면 거기에 맞게 다시 시작한다.
    private func refreshPermissions() {
        let currentPermissions = Dictionary(
            uniqueKeysWithValues: Permission.allCases.map { ($0, $0.isGranted) }
        )
        if currentPermissions == grantedPermissions { return }

        let newlyGranted = AppDelegate.newlyGranted(previous: grantedPermissions, current: currentPermissions)
        grantedPermissions = currentPermissions
        settingsWindow?.model.updatePermissions(currentPermissions)
        rebuildMenu()
        if !newlyGranted.isEmpty { handlePermissionsGranted(newlyGranted) }
    }

    // 처음 읽은 값(previous가 비어 있음)은 기준일 뿐이라 "새로 허용"으로 보지 않는다. 그래야 다시 실행한 뒤 또 다시 실행하지 않는다.
    static func newlyGranted(previous: [Permission: Bool], current: [Permission: Bool]) -> [Permission] {
        if previous.isEmpty { return [] }
        return Permission.allCases.filter { permission in
            previous[permission] != true && current[permission] == true
        }
    }

    // macOS는 입력 모니터링을 새로 받아도 실행 중인 프로세스에는 반영하지 않는다(OpenLogi 문서) → 앱을 다시 실행한다.
    // 손쉬운 사용은 엔진을 다시 띄우면 일반 버튼 탭이 만들어진다.
    // 다시 시작하는 쪽은 14에서 사람이 권한을 줘서 확인한다. 같은 길을 SIGUSR1(손쉬운 사용)·SIGUSR2(입력 모니터링)로 불러 볼 수 있다.
    func handlePermissionsGranted(_ permissions: [Permission]) {
        let titles = permissions.map(\.title).joined(separator: ", ")
        printToStandardError("권한 허용 감지: \(titles)")
        if permissions.contains(.inputMonitoring) {
            relaunch()
        } else {
            restartEngine()
        }
    }

    private func restartEngine() {
        guard let oldEngine = engine, restartTask == nil, !isTerminating else { return }
        settingsWindow?.model.cancelCapture()
        captureTask?.cancel()
        restartTask = Task {
            _ = await captureTask?.value
            await oldEngine.stop()
            engine = nil
            restartTask = nil
            startEngine()
        }
    }

    // 이 프로세스가 끝나길 기다렸다가 같은 앱을 새로 여는 셸을 띄우고, 정상 종료한다(divert를 풀고).
    private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AppDelegate.relaunchScript, "freelogi-relaunch", String(getpid()), Bundle.main.bundleURL.path]
        if let profilesPath = ProcessInfo.processInfo.environment[AppDelegate.profilesPathVariable] {
            process.arguments?.append(contentsOf: ["--env", "\(AppDelegate.profilesPathVariable)=\(profilesPath)"])
        }
        process.arguments?.append(contentsOf: ["--args", AppDelegate.reopenWindowArgument])
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            printToStandardError("다시 실행하지 못했다: \(error)")
            return
        }
        printToStandardError("relaunch: 끝난 뒤 다시 연다")
        AppDelegate.terminateFromRunLoop()
    }

    // terminate는 끝내기를 미루는 동안 중첩 이벤트 루프를 도는데, 메인 큐 블록 안에서 부르면 그 루프가
    // 메인 큐를 못 비워 Task가 영영 안 돈다. run loop 블록으로 넘겨 메인 큐 밖에서 부른다.
    private static func terminateFromRunLoop() {
        RunLoop.main.perform {
            MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "computermouse",
            accessibilityDescription: "FreeLogi"
        )
        self.statusItem = statusItem
        openStore()
        refreshPermissions()

        let timer = Timer(timeInterval: AppDelegate.permissionPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPermissions()
                self?.engine?.reenableTapIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)

        startEngine()
        handleSignals()
        let launchValue = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        let launchedAtLogin = LoginItem.isLoginItemLaunch(launchValue)
        if !launchedAtLogin || CommandLine.arguments.contains(AppDelegate.reopenWindowArgument) {
            openSettings()
        }
        runDebugAddButtonFlowIfRequested()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func runDebugAddButtonFlowIfRequested() {
        let variable = ProcessInfo.processInfo.environment[AppDelegate.debugAddButtonKeyVariable]
        guard let keyCode = variable.flatMap({ UInt16($0) }) else { return }

        openSettings()
        Task { await settingsWindow?.model.runAddButtonFlow(recordingKeyCode: keyCode) }
    }

    private func openStore() {
        let pathOverride = ProcessInfo.processInfo.environment[AppDelegate.profilesPathVariable]
        let profilesURL = pathOverride.map { URL(fileURLWithPath: $0) } ?? ProfileStore.defaultURL
        do {
            store = try ProfileStore(fileURL: profilesURL)
        } catch {
            printToStandardError("프로필을 읽지 못해 매핑을 켜지 않는다: \(error)")
        }
    }

    private func startEngine() {
        guard let store, !isTerminating else { return }

        let engine = MappingEngine(log: printToStandardError)
        engine.onControlsChanged = { [weak self] in self?.settingsWindow?.model.objectWillChange.send() }
        self.engine = engine
        engine.apply(store.activeProfile)
        engine.start()
        printToStandardError("engine: ready (프로필 \(store.fileURL.path))")
    }

    // SIGINT·SIGTERM은 일반 종료와 같은 길로 끝낸다(divert를 풀고). SIGHUP은 profiles.json을 다시 읽어 반영한다(디버그).
    // SIGUSR1·SIGUSR2는 권한을 새로 받은 것처럼 handlePermissionsGranted를 부른다(디버그).
    private func handleSignals() {
        let terminate: () -> Void = { AppDelegate.terminateFromRunLoop() }
        let actions: [(Int32, () -> Void)] = [
            (SIGINT, terminate),
            (SIGTERM, terminate),
            (SIGHUP, { [weak self] in self?.reloadProfiles() }),
            (SIGUSR1, { [weak self] in self?.handlePermissionsGranted([.accessibility]) }),
            (SIGUSR2, { [weak self] in self?.handlePermissionsGranted([.inputMonitoring]) }),
        ]
        for (signalNumber, action) in actions {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler(handler: action)
            source.resume()
            signalSources.append(source)
        }
    }

    private func reloadProfiles() {
        guard let fileURL = store?.fileURL else { return }
        do {
            let reloaded = try ProfileStore(fileURL: fileURL)
            settingsWindow?.close()
            store = reloaded
            profilesDidChange()
            printToStandardError("engine: 프로필 다시 읽음")
        } catch {
            printToStandardError("프로필을 다시 읽지 못했다: \(error)")
        }
    }

    // 끝내기 전에 divert를 푼다. 푸는 데 HID++ 응답을 기다려야 해서 끝내기를 미룬다.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        guard engine != nil else { return .terminateNow }

        isTerminating = true
        settingsWindow?.model.close()
        captureTask?.cancel()
        Task {
            _ = await captureTask?.value
            await restartTask?.value
            await engine?.stop()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
