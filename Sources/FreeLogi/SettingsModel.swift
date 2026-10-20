import Carbon.HIToolbox
import Foundation

// 매핑 표의 한 줄. keys가 nil이면 버튼만 인식한 줄(키를 기다리는 중이라 아직 저장되지 않았다).
struct MappingRow: Identifiable {
    let button: ButtonID
    let keys: KeyCombo?
    var gesture: GestureDirectionEnum? = nil

    var id: BindingID { BindingID(button: button, gesture: gesture) }
}

private extension KeyCombo {
    // 수식키 없는 Esc. 인식·녹화 중에는 취소로 쓴다(그래서 Esc 단독은 매핑할 수 없다).
    var isPlainEscape: Bool {
        keyCode == UInt16(kVK_Escape) && modifiers == 0
    }
}

// 설정 창의 상태와 동작. 창이 열려 있는 동안만 산다.
// 프로필 목록에서 고른 프로필이 곧 활성 프로필이다(메뉴바에서 바꿔도 같은 값을 본다).
@MainActor
final class SettingsModel: ObservableObject {
    private static let newProfilePrefix = String(localized: "프로필")

    @Published private(set) var state: ProfileStoreState
    @Published private(set) var pendingAction: BindingID?
    @Published private(set) var recordingAction: BindingID?
    var pendingButton: ButtonID? { pendingAction?.button }
    var recordingButton: ButtonID? { recordingAction?.button }
    @Published private(set) var launchesAtLogin = LoginItem.isEnabled
    @Published var isCapturing = false
    @Published private(set) var isCaptureReady = false
    @Published private(set) var grantedPermissions: [Permission: Bool] = [:]

    var screen: MainScreenEnum {
        MainScreenEnum.select(granted: grantedPermissions)
    }

    func updatePermissions(_ granted: [Permission: Bool]) {
        grantedPermissions = granted
        if screen == .permissions { close() }
    }

    private let store: ProfileStore
    private let captureButton: @MainActor (@escaping @MainActor () -> Void) async -> ButtonID?
    private let onChange: () -> Void
    private let supportsRawXY: (ButtonID) -> Bool
    private let recorder = KeyRecorder()
    private var captureTask: Task<Void, Never>?

    // captureButton은 준비되면 콜백을 부르고 눌린 버튼 하나를 돌려준다(취소되면 nil). onChange는 저장한 뒤 엔진·메뉴가 따라가게 한다.
    init(
        store: ProfileStore,
        captureButton: @escaping @MainActor (@escaping @MainActor () -> Void) async -> ButtonID?,
        supportsRawXY: @escaping (ButtonID) -> Bool = { _ in false },
        onChange: @escaping () -> Void
    ) {
        self.store = store
        self.state = store.state
        self.captureButton = captureButton
        self.onChange = onChange
        self.supportsRawXY = supportsRawXY
    }

    var activeProfile: Profile {
        state.profiles.first { $0.id == state.activeID } ?? state.profiles[0]
    }

    var rows: [MappingRow] {
        var rows = activeProfile.bindings.map { MappingRow(button: $0.button, keys: $0.keys, gesture: $0.gesture) }
        if let pendingAction {
            rows.append(MappingRow(button: pendingAction.button, keys: nil, gesture: pendingAction.gesture))
        }
        return rows
    }

    func buttonName(for button: ButtonID) -> String {
        activeProfile.buttonName(for: button)
    }

    func renameButton(_ button: ButtonID, to name: String) {
        save { try store.renameButton(profileID: state.activeID, button: button, name: name) }
    }

    func availableGestures(for button: ButtonID) -> [GestureDirectionEnum?] {
        guard case .hidpp = button, supportsRawXY(button) else { return [nil] }
        let directions = GestureDirectionEnum.allCases.map { Optional($0) }
        return [nil] + directions
    }

    func canSelect(_ gesture: GestureDirectionEnum?, for action: BindingID) -> Bool {
        if action.gesture == gesture { return true }
        let target = BindingID(button: action.button, gesture: gesture)
        let isTaken = rows.contains { $0.id == target }
        let isAvailable = availableGestures(for: action.button).contains(gesture)
        return isAvailable && !isTaken
    }

    func changeGesture(_ gesture: GestureDirectionEnum?, for action: BindingID) {
        if !canSelect(gesture, for: action) || action.gesture == gesture { return }
        if pendingAction == action {
            beginRecording(action.button, gesture: gesture)
            return
        }
        if recordingAction == action { cancelRecording() }
        save { try store.changeGesture(profileID: state.activeID, action: action, to: gesture) }
    }

    // 창을 닫을 때 부른다. 인식·녹화를 멈춘다.
    func close() {
        cancelCapture()
        cancelRecording()
    }

    // 메뉴바에서 활성 프로필이 바뀐 뒤 부른다.
    func reload() {
        cancelCapture()
        cancelRecording()
        state = store.state
    }

    // MARK: - 프로필

    func select(profileID: UUID) {
        if profileID == state.activeID { return }
        cancelCapture()
        cancelRecording()
        save { try store.setActive(id: profileID) }
    }

    func addProfile() {
        let name = "\(SettingsModel.newProfilePrefix) \(state.profiles.count + 1)"
        cancelRecording()
        save {
            let profile = try store.add(name: name)
            try store.setActive(id: profile.id)
        }
    }

    // 빈 이름은 무시한다.
    func rename(to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName == activeProfile.name { return }
        save { try store.rename(id: state.activeID, name: trimmedName) }
    }

    // 마지막 프로필은 지울 수 없다(store가 거부한다).
    func removeActiveProfile() {
        cancelRecording()
        save { try store.remove(id: state.activeID) }
    }

    // MARK: - 버튼 인식

    func startCapture() {
        if captureTask != nil { return }
        cancelRecording()
        isCaptureReady = false
        isCapturing = true
        cancelCaptureOnEscape()
        captureTask = Task {
            let button = await captureButton { [weak self] in
                guard let self, self.isCapturing, !Task.isCancelled else { return }
                self.isCaptureReady = true
            }
            isCaptureReady = false
            isCapturing = false
            captureTask = nil
            recorder.stop()
            if let button, !Task.isCancelled {
                let actions = availableGestures(for: button).map { BindingID(button: button, gesture: $0) }
                let nextAction = actions.first { action in
                    !activeProfile.bindings.contains { $0.id == action }
                }
                beginRecording(button, gesture: nextAction?.gesture)
            }
        }
    }

    // 인식 중 Esc는 취소다. 다른 키는 삼킨다(그 키가 창에 들어가지 않게).
    private func cancelCaptureOnEscape() {
        recorder.start { [weak self] combo in
            MainActor.assumeIsolated {
                if combo.isPlainEscape {
                    self?.cancelCapture()
                } else {
                    self?.cancelCaptureOnEscape()
                }
            }
        }
    }

    // 인식 모드가 divert를 되돌릴 때까지 captureTask는 남는다(그 사이 다시 시작하지 않는다).
    func cancelCapture() {
        captureTask?.cancel()
        isCaptureReady = false
        isCapturing = false
    }

    // MARK: - 키 녹화

    // 같은 버튼·동작이면 그 줄의 키를 다시 녹화하고, 아니면 키를 기다리는 새 줄을 만든다.
    func beginRecording(_ button: ButtonID, gesture: GestureDirectionEnum? = nil) {
        cancelRecording()
        let action = BindingID(button: button, gesture: gesture)
        if !availableGestures(for: button).contains(gesture) { return }
        let isMapped = activeProfile.bindings.contains { $0.id == action }
        pendingAction = isMapped ? nil : action
        recordingAction = action
        recorder.start { [weak self] combo in
            MainActor.assumeIsolated { self?.record(combo) }
        }
    }

    func record(_ combo: KeyCombo) {
        guard let action = recordingAction else { return }
        if combo.isPlainEscape {
            cancelRecording()
            return
        }

        recorder.stop()
        recordingAction = nil
        pendingAction = nil
        save { try store.setBinding(profileID: state.activeID, button: action.button, keys: combo, gesture: action.gesture) }
    }

    func cancelRecording() {
        recorder.stop()
        recordingAction = nil
        pendingAction = nil
    }

    func removeBinding(_ button: ButtonID, gesture: GestureDirectionEnum? = nil) {
        let action = BindingID(button: button, gesture: gesture)
        if action == pendingAction {
            cancelRecording()
            return
        }
        if recordingAction == action { cancelRecording() }
        save { try store.removeBinding(profileID: state.activeID, button: button, gesture: gesture) }
    }

    func setScrollReversal(vertical: Bool, horizontal: Bool) {
        save { try store.setScrollReversal(vertical: vertical, horizontal: horizontal) }
    }

    // MARK: - 로그인 시 실행

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled: enabled)
        } catch {
            printToStandardError("로그인 시 실행을 바꾸지 못했다: \(error)")
        }
        launchesAtLogin = LoginItem.isEnabled
    }

    // MARK: - 디버그

    // FREELOGI_DEBUG_ADD_BUTTON_KEY: "버튼 추가" → 인식 → 키 지정을 창을 누르지 않고 같은 동작으로 돌리고 표를 로그로 남긴다.
    func runAddButtonFlow(recordingKeyCode keyCode: UInt16) async {
        startCapture()
        await captureTask?.value
        if recordingButton != nil { record(KeyCombo(keyCode: keyCode, modifiers: 0)) }

        let rowTexts = rows.map { row in "\(buttonName(for: row.button))=\(row.keys?.displayString ?? "-")" }
        printToStandardError("flow: rows=\(rowTexts.joined(separator: ","))")
    }

    // MARK: - 저장

    // 저장하고 화면 상태를 store에서 다시 읽은 뒤 알린다. 저장이 실패해도 화면은 store 상태를 따른다.
    private func save(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            printToStandardError("프로필을 저장하지 못했다: \(error)")
        }
        state = store.state
        onChange()
    }
}
