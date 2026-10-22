import AppKit

// 활성 프로필의 매핑대로 동작한다.
// - 일반 버튼(standard): 매핑이 있을 때만 ButtonTap을 켜서 삼키고 키를 보낸다.
// - HID++ 버튼(hidpp): 매핑된 CID만 divert하고, divertedButtonsEvent 알림에서 눌림·뗌을 키 down·up으로 보낸다.
// - rawXY 지원 CID에 방향 매핑이 있으면 이동량을 누적하고, 뗄 때 클릭 또는 방향 키를 down+up으로 보낸다.
// - 매핑이 없는 버튼은 건드리지 않는다. divert는 매핑에 맞춰 걸고 푼다(이전 실행이 남긴 divert도 푼다).
// - 기기가 연결되거나(HIDPPManager) 잠자기에서 깨면 divert를 다시 건다. 끝낼 때(stop) 모두 푼다.
@MainActor
final class MappingEngine {
    private static let connectAttemptCount = 5
    // HID++ 1.0 수신기 알림의 sub ID. 수신기에 붙은 기기가 연결·재연결되면 온다.
    private static let receiverConnectionSubId: UInt8 = 0x41

    private struct PressedKey: Hashable {
        let channelId: ObjectIdentifier
        let deviceIndex: UInt8
    }

    private let log: (String) -> Void
    private let press: (KeyCombo) -> Void
    private let release: (KeyCombo) -> Void
    private let connectRetryDelay: Duration

    private var bindings: [ButtonID: KeyCombo] = [:]
    private var gestureBindings: [BindingID: KeyCombo] = [:]
    // 지금 눌려 있는 버튼이 누를 때 보낸 키. 뗄 때 같은 키를 뗀다(그 사이 매핑이 바뀌어도).
    private var heldKeys: [ButtonID: KeyCombo] = [:]
    private var tap: ButtonTap?
    private var scrollTap: ScrollTap?
    private var manager: HIDPPManager?
    private var wakeObserver: NSObjectProtocol?
    private var isStopped = false
    // divert 작업은 한 줄로 세운다. 같은 채널에 요청이 섞이지 않게 한다.
    private var syncChain: Task<Void, Never>?
    private var controlsByChannel: [ObjectIdentifier: [HIDPPDivertControl]] = [:]
    private var pressedCids: [PressedKey: Set<UInt16>] = [:]
    private var gestures: [PressedKey: [UInt16: GestureAccumulator]] = [:]
    var onControlsChanged: (() -> Void)?

    // 인식 모드(ButtonCapture)가 같은 채널을 쓴다.
    private(set) var channels: [HIDPPChannel] = []

    init(
        log: @escaping (String) -> Void = { _ in },
        connectRetryDelay: Duration = .seconds(1),
        press: @escaping (KeyCombo) -> Void = KeyInjector.press,
        release: @escaping (KeyCombo) -> Void = KeyInjector.release
    ) {
        self.log = log
        self.connectRetryDelay = connectRetryDelay
        self.press = press
        self.release = release
    }

    // MARK: - 시작·끝

    // 연결된 기기를 열고, 이후 연결·분리와 잠자기 해제를 지켜본다.
    func start() {
        let manager = HIDPPManager()
        manager.onNodeAdded = { [weak self] node in
            self?.log("기기 연결: \(node.name)")
            self?.addChannel(node.channel)
        }
        manager.onNodeRemoved = { [weak self] node in
            self?.log("기기 분리: \(node.name)")
            self?.removeChannel(node.channel)
        }
        self.manager = manager
        for node in manager.nodes { addChannel(node.channel) }
        observeWake()
    }

    func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    // 모든 divert를 풀고 키를 떼고 탭을 내린다. 끝나면 이 엔진은 더 일하지 않는다.
    func stop() async {
        isStopped = true
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        await waitUntilIdle()

        bindings = [:]
        gestureBindings = [:]
        releaseHeldKeys()
        tap?.stop()
        tap = nil
        scrollTap?.stop()
        scrollTap = nil
        for channel in channels {
            let controls = controlsByChannel[ObjectIdentifier(channel)] ?? []
            await applyDiverts(on: channel, controls: controls)
        }
        manager?.close()
        manager = nil
    }

    // 지금까지 세워 둔 divert 작업이 끝날 때까지 기다린다.
    func waitUntilIdle() async {
        await syncChain?.value
    }

    // MARK: - 매핑

    // 활성 프로필(없으면 매핑 없음)을 반영한다. 프로필을 바꾸거나 매핑을 고칠 때마다 부른다.
    func apply(_ profile: Profile?) {
        let profileBindings = profile?.bindings ?? []
        let clickBindings = profileBindings.filter { $0.gesture == nil }
        let pairs = clickBindings.map { ($0.button, $0.keys) }
        bindings = Dictionary(pairs, uniquingKeysWith: { _, last in last })
        let directions = profileBindings.filter { $0.gesture != nil }
        let directionPairs = directions.map { ($0.id, $0.keys) }
        gestureBindings = Dictionary(directionPairs, uniquingKeysWith: { _, last in last })
        releaseHeldKeys()
        updateTap()
        syncAllChannels()
    }

    func applyScrollReversal(vertical: Bool, horizontal: Bool, smooth: Bool = false) {
        if isStopped { return }
        if !vertical && !horizontal && !smooth {
            scrollTap?.stop()
            scrollTap = nil
            return
        }
        if scrollTap == nil {
            scrollTap = ScrollTap()
            if scrollTap == nil { log("스크롤 탭을 만들지 못했다(손쉬운 사용 권한 없음)") }
        }
        scrollTap?.reverseVertical = vertical
        scrollTap?.reverseHorizontal = horizontal
        scrollTap?.smoothScrolling = smooth
    }

    // 주기적으로 부른다. 탭이 시스템에 의해 꺼졌으면 다시 켠다.
    func reenableTapIfNeeded() {
        tap?.reenableIfDisabled()
        scrollTap?.reenableIfDisabled()
    }

    // 매핑된 버튼이면 true(원래 동작을 삼킨다). down에 키를 누르고 up에 뗀다.
    // up은 우리가 down을 삼킨 버튼만 삼킨다(down을 통과시킨 버튼의 up만 삼키면 앱에 up만 따로 간다).
    @discardableResult
    func handleButton(_ button: ButtonID, isDown: Bool) -> Bool {
        if isDown {
            guard let combo = bindings[button] else { return false }
            if heldKeys[button] == nil {
                heldKeys[button] = combo
                press(combo)
            }
            return true
        }

        guard let combo = heldKeys.removeValue(forKey: button) else { return false }
        release(combo)
        return true
    }

    private func releaseHeldKeys() {
        gestures = [:]
        for combo in heldKeys.values { release(combo) }
        heldKeys = [:]
    }

    // 일반 버튼 매핑이 있을 때만 탭을 둔다. 손쉬운 사용 권한이 없으면 만들어지지 않는다.
    private func updateTap() {
        let needsTap = bindings.keys.contains { button in
            if case .standard = button { return true }
            return false
        }
        if !needsTap {
            tap?.stop()
            tap = nil
            return
        }
        if tap != nil { return }

        tap = ButtonTap { [weak self] buttonNumber, isDown in
            self?.handleButton(.standard(buttonNumber), isDown: isDown) ?? false
        }
        if tap == nil { log("일반 버튼 탭을 만들지 못했다(손쉬운 사용 권한 없음) — 일반 버튼 매핑은 동작하지 않는다") }
    }

    // MARK: - 기기

    func addChannel(_ channel: HIDPPChannel) {
        let isKnown = channels.contains { $0 === channel }
        if isKnown { return }
        channels.append(channel)
        channel.onNotification = { [weak self, weak channel] report in
            guard let channel else { return }
            self?.handleNotification(report, from: channel)
        }
        syncAfterConnect(channel, attemptsLeft: MappingEngine.connectAttemptCount)
    }

    func removeChannel(_ channel: HIDPPChannel) {
        let channelId = ObjectIdentifier(channel)
        channels.removeAll { $0 === channel }
        channel.onNotification = nil
        controlsByChannel[channelId] = nil
        onControlsChanged?()

        // 눌린 채로 분리된 버튼의 키가 눌린 채 남지 않게 뗀다.
        for key in pressedCids.keys where key.channelId == channelId {
            gestures[key] = nil
            updatePressed([], for: key)
            pressedCids[key] = nil
        }
    }

    func supportsRawXY(_ button: ButtonID) -> Bool {
        guard case .hidpp(let cid) = button else { return false }
        let supportsRawXY = controlsByChannel.values.contains { controls in
            controls.contains { $0.cid == cid && $0.supportsRawXY }
        }
        return supportsRawXY
    }

    private func hasGestureBindings(_ cid: UInt16) -> Bool {
        let hasDirections = gestureBindings.keys.contains { $0.button == .hidpp(cid) }
        return hasDirections
    }

    private func didWake() {
        log("잠자기 해제 — divert를 다시 건다")
        syncAllChannels()
    }

    // MARK: - divert

    private func scheduleSync(_ work: @escaping @MainActor () async -> Void) {
        if isStopped { return }
        let previous = syncChain
        syncChain = Task {
            await previous?.value
            await work()
        }
    }

    private func syncAllChannels() {
        scheduleSync { [self] in
            for channel in channels { _ = await syncDiverts(of: channel) }
        }
    }

    // 기기가 막 연결되면 바로는 응답하지 않을 수 있어, 컨트롤을 못 찾으면 몇 번 다시 해 본다.
    // ponytail: 수신기에 페어링된 기기가 없으면 끝까지 못 찾고 connectAttemptCount번 헛돈다. 기기별 연결 알림(0x41)이 오면 그때 다시 한다.
    private func syncAfterConnect(_ channel: HIDPPChannel, attemptsLeft: Int) {
        scheduleSync { [self] in
            let foundControls = await syncDiverts(of: channel)
            if foundControls || attemptsLeft <= 1 { return }

            Task {
                try? await Task.sleep(for: connectRetryDelay)
                let isStillConnected = channels.contains { $0 === channel }
                if isStillConnected { syncAfterConnect(channel, attemptsLeft: attemptsLeft - 1) }
            }
        }
    }

    // 채널의 divert를 매핑에 맞춘다. divert할 수 있는 컨트롤을 하나라도 찾았으면 true.
    private func syncDiverts(of channel: HIDPPChannel) async -> Bool {
        let controls = await channel.divertableControls()
        let isStillConnected = channels.contains { $0 === channel }
        if !isStillConnected { return false }

        controlsByChannel[ObjectIdentifier(channel)] = controls
        onControlsChanged?()
        await applyDiverts(on: channel, controls: controls)
        return !controls.isEmpty
    }

    // 매핑된 CID는 divert하고 나머지는 푼다. 실제 상태를 읽어 다른 것만 바꾼다. 한 번 실패하면 그 채널은 그만둔다(응답 없는 기기에서 1초씩 기다리지 않게).
    private func applyDiverts(on channel: HIDPPChannel, controls: [HIDPPDivertControl]) async {
        for control in controls {
            let needsRawXY = control.supportsRawXY && hasGestureBindings(control.cid)
            let shouldDivert = bindings[.hidpp(control.cid)] != nil || needsRawXY
            let name = String(format: "cid 0x%04X (index 0x%02X)", control.cid, control.deviceIndex)
            do {
                let reporting = try await channel.cidReporting(cid: control.cid, featureIndex: control.featureIndex, deviceIndex: control.deviceIndex)
                let rawXYMatches = !control.supportsRawXY || reporting.rawXY == needsRawXY
                if reporting.diverted == shouldDivert && rawXYMatches { continue }

                let rawXY: Bool? = control.supportsRawXY ? needsRawXY : nil
                try await channel.setDiverted(shouldDivert, rawXY: rawXY, cid: control.cid, featureIndex: control.featureIndex, deviceIndex: control.deviceIndex)
                let actual = try await channel.isDiverted(cid: control.cid, featureIndex: control.featureIndex, deviceIndex: control.deviceIndex)
                log("setCidReporting \(name) diverted=\(shouldDivert) → 응답 받음, getCidReporting diverted=\(actual)")
            } catch {
                log("divert 맞추기 실패 \(name): \(error)")
                return
            }
        }
    }

    // MARK: - 알림

    private func handleNotification(_ report: [UInt8], from channel: HIDPPChannel) {
        let isShortReport = report.first == HIDPPChannel.shortReportId
        if isShortReport && report.count > 2 && report[2] == MappingEngine.receiverConnectionSubId {
            log("수신기 연결 알림 — divert를 다시 건다")
            syncAfterConnect(channel, attemptsLeft: MappingEngine.connectAttemptCount)
            return
        }

        let channelId = ObjectIdentifier(channel)
        for control in controlsByChannel[channelId] ?? [] {
            let key = PressedKey(channelId: channelId, deviceIndex: control.deviceIndex)
            if let movement = HIDPPChannel.divertedRawMouseXY(in: report, deviceIndex: control.deviceIndex, featureIndex: control.featureIndex) {
                // rawXY에는 CID가 없다. 여러 제스처 버튼이 겹치면 출처를 가릴 수 없어 이동을 버린다.
                if let activeGestures = gestures[key], activeGestures.count == 1,
                   let cid = activeGestures.keys.first {
                    gestures[key]?[cid]?.add(dx: movement.dx, dy: movement.dy)
                }
                return
            }
            let pressed = HIDPPChannel.divertedButtons(in: report, deviceIndex: control.deviceIndex, featureIndex: control.featureIndex)
            guard let pressed else { continue }
            updatePressed(Set(pressed), for: key)
            return
        }
    }

    // divertedButtonsEvent는 지금 눌려 있는 CID 전체다. 이전과 비교해 새로 눌린 것은 down, 사라진 것은 up으로 본다.
    private func updatePressed(_ cids: Set<UInt16>, for key: PressedKey) {
        let previous = pressedCids[key] ?? []
        pressedCids[key] = cids

        for cid in cids.subtracting(previous).sorted() {
            let control = controlsByChannel[key.channelId]?.first { $0.deviceIndex == key.deviceIndex && $0.cid == cid }
            if control?.supportsRawXY == true && hasGestureBindings(cid) {
                gestures[key, default: [:]][cid] = GestureAccumulator()
            } else {
                handleButton(.hidpp(cid), isDown: true)
            }
        }
        for cid in previous.subtracting(cids).sorted() {
            if let gesture = gestures[key]?.removeValue(forKey: cid) {
                let action = BindingID(button: .hidpp(cid), gesture: gesture.direction)
                let combo = gesture.direction == nil ? bindings[action.button] : gestureBindings[action]
                if let combo {
                    press(combo)
                    release(combo)
                }
            } else {
                handleButton(.hidpp(cid), isDown: false)
            }
        }
    }
}
