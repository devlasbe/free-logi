import Foundation

// 프로필 저장/로드 관리
final class ProfileStore {
    private(set) var state: ProfileStoreState
    let fileURL: URL

    // 기본 저장 경로
    static let defaultURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("FreeLogi/profiles.json")
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()

    init(fileURL: URL = ProfileStore.defaultURL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            state = try ProfileStore.decoder.decode(ProfileStoreState.self, from: data)
        } else {
            // 파일 없으면 기본 프로필 생성
            let profile = Profile(id: UUID(), name: String(localized: "기본"), bindings: [])
            state = ProfileStoreState(profiles: [profile], activeID: profile.id)
        }
    }

    // MARK: - 저장

    private func save() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try ProfileStore.encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - 읽기

    var activeProfile: Profile? {
        state.profiles.first { $0.id == state.activeID }
    }

    // MARK: - 쓰기

    @discardableResult
    func add(name: String) throws -> Profile {
        let profile = Profile(id: UUID(), name: name, bindings: [])
        state.profiles.append(profile)
        try save()
        return profile
    }

    func rename(id: UUID, name: String) throws {
        guard let i = state.profiles.firstIndex(where: { $0.id == id }) else { return }
        state.profiles[i].name = name
        try save()
    }

    enum StoreError: Error { case lastProfile }

    func remove(id: UUID) throws {
        guard state.profiles.count > 1 else { throw StoreError.lastProfile }
        state.profiles.removeAll { $0.id == id }
        // 활성 프로필이 삭제되면 첫 번째로 교체
        if state.activeID == id {
            state.activeID = state.profiles[0].id
        }
        try save()
    }

    func setScrollReversal(vertical: Bool, horizontal: Bool) throws {
        state.reverseVerticalScroll = vertical
        state.reverseHorizontalScroll = horizontal
        try save()
    }

    func setSmoothScrolling(_ enabled: Bool) throws {
        state.smoothScrolling = enabled
        try save()
    }

    func setActive(id: UUID) throws {
        state.activeID = id
        try save()
    }

    func setBinding(profileID: UUID, button: ButtonID, keys: KeyCombo, gesture: GestureDirectionEnum? = nil) throws {
        guard let i = state.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        if let j = state.profiles[i].bindings.firstIndex(where: { $0.button == button && $0.gesture == gesture }) {
            state.profiles[i].bindings[j].keys = keys
        } else {
            state.profiles[i].bindings.append(ButtonBinding(button: button, keys: keys, gesture: gesture))
        }
        if state.profiles[i].buttonNames[button] == nil {
            state.profiles[i].buttonNames[button] = state.profiles[i].nextButtonName
        }
        try save()
    }

    // 빈 이름은 무시한다.
    func renameButton(profileID: UUID, button: ButtonID, name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let i = state.profiles.firstIndex(where: { $0.id == profileID }),
              state.profiles[i].bindings.contains(where: { $0.button == button })
        else { return }
        state.profiles[i].buttonNames[button] = trimmedName
        try save()
    }

    func changeGesture(profileID: UUID, action: BindingID, to gesture: GestureDirectionEnum?) throws {
        guard let profileIndex = state.profiles.firstIndex(where: { $0.id == profileID }),
              let bindingIndex = state.profiles[profileIndex].bindings.firstIndex(where: { $0.id == action })
        else { return }
        let target = BindingID(button: action.button, gesture: gesture)
        if state.profiles[profileIndex].bindings.contains(where: { $0.id == target }) { return }
        state.profiles[profileIndex].bindings[bindingIndex].gesture = gesture
        try save()
    }

    func removeBinding(profileID: UUID, button: ButtonID, gesture: GestureDirectionEnum? = nil) throws {
        guard let i = state.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        state.profiles[i].bindings.removeAll { $0.button == button && $0.gesture == gesture }
        if !state.profiles[i].bindings.contains(where: { $0.button == button }) {
            state.profiles[i].buttonNames.removeValue(forKey: button)
        }
        try save()
    }
}
