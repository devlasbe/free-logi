import SwiftUI

private let sidebarWidth: CGFloat = 180
private let keyColumnWidth: CGFloat = 150
private let ACTION_COLUMN_WIDTH: CGFloat = 64
private let iconColumnWidth: CGFloat = 28
private let contentPadding: CGFloat = 20
private let ACTIVE_BADGE_HORIZONTAL_PADDING: CGFloat = 8
private let ACTIVE_BADGE_VERTICAL_PADDING: CGFloat = 4

// 왼쪽 프로필 목록, 오른쪽 선택한 프로필의 매핑 표, 아래 앱 전체 설정.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var draftName = ""
    @State private var isConfirmingDelete = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: sidebarWidth)
                Divider()
                detail
            }
            Divider()
            footer
        }
        .frame(width: MAIN_WINDOW_SIZE.width, height: MAIN_WINDOW_SIZE.height)
        .overlay {
            if model.isCapturing { CapturePrompt(isReady: model.isCaptureReady, cancel: model.cancelCapture) }
        }
        .onAppear { draftName = model.activeProfile.name }
        .onChange(of: model.activeProfile.id) { _ in draftName = model.activeProfile.name }
    }

    private var selectedProfile: Binding<UUID?> {
        Binding(
            get: { model.state.activeID },
            set: { profileID in
                if let profileID { model.select(profileID: profileID) }
            }
        )
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { model.launchesAtLogin },
            set: { enabled in model.setLaunchesAtLogin(enabled) }
        )
    }

    // MARK: - 프로필 목록

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(model.state.profiles, selection: selectedProfile) { profile in
                HStack {
                    Text(profile.name)
                    Spacer()
                    if profile.id == model.state.activeID {
                        Image(systemName: "checkmark")
                            .accessibilityLabel("사용 중")
                    }
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 4) {
                Button { model.addProfile() } label: { Image(systemName: "plus") }
                    .help("프로필 추가")
                Button { isConfirmingDelete = true } label: { Image(systemName: "minus") }
                    .help("프로필 삭제")
                    .disabled(model.state.profiles.count < 2)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .confirmationDialog(
            "‘\(model.activeProfile.name)’ 프로필을 삭제할까요?",
            isPresented: $isConfirmingDelete
        ) {
            Button("삭제", role: .destructive) { model.removeActiveProfile() }
        } message: {
            Text("이 프로필의 매핑도 함께 지워집니다.")
        }
    }

    // MARK: - 매핑 표

    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("이름").foregroundStyle(.secondary)
                TextField("프로필 이름", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit { commitName() }
                    .onChange(of: isNameFocused) { isFocused in
                        if !isFocused { commitName() }
                    }
                // 목록에서 고른 프로필이 곧 활성 프로필이다.
                Text("사용 중")
                    .font(.caption)
                    .padding(.horizontal, ACTIVE_BADGE_HORIZONTAL_PADDING)
                    .padding(.vertical, ACTIVE_BADGE_VERTICAL_PADDING)
                    .background(.quaternary, in: Capsule())
                    .fixedSize()
            }

            mappingTable

            HStack {
                Spacer()
                Button("버튼 추가") { model.startCapture() }
            }
        }
        .padding(contentPadding)
    }

    private func commitName() {
        model.rename(to: draftName)
        draftName = model.activeProfile.name
    }

    private var mappingTable: some View {
        Table(model.rows) {
            TableColumn("버튼") { row in
                ButtonNameField(
                    name: model.buttonName(for: row.button),
                    rawValue: row.button.rawValueText,
                    rename: { name in model.renameButton(row.button, to: name) }
                )
                .id(ButtonNameFieldID(profileID: model.activeProfile.id, action: row.id))
                .disabled(model.recordingAction != nil)
            }
            TableColumn("동작") { row in
                gesturePicker(for: row)
            }
            .width(ACTION_COLUMN_WIDTH)
            TableColumn("키") { row in
                keyButton(for: row)
            }
            .width(keyColumnWidth)
            TableColumn("") { row in
                removeButton(for: row)
            }
            .width(iconColumnWidth)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .overlay {
            if model.rows.isEmpty { emptyState }
        }
    }

    private func gesturePicker(for row: MappingRow) -> some View {
        let selection = Binding<GestureDirectionEnum?>(
            get: { row.gesture },
            set: { gesture in model.changeGesture(gesture, for: row.id) }
        )
        return Picker("동작", selection: selection) {
            ForEach(model.availableGestures(for: row.button), id: \.self) { gesture in
                Text(gesture?.displayName ?? String(localized: "클릭"))
                    .tag(gesture)
                    .disabled(!model.canSelect(gesture, for: row.id))
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .disabled(model.availableGestures(for: row.button).count == 1)
    }

    private func keyButton(for row: MappingRow) -> some View {
        let isRecording = model.recordingAction == row.id
        let label = isRecording ? String(localized: "키를 누르세요 (Esc 취소)") : (row.keys?.displayString ?? "")
        return Button { model.beginRecording(row.button, gesture: row.gesture) } label: {
            Text(label)
                .frame(maxWidth: .infinity)
                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func removeButton(for row: MappingRow) -> some View {
        Button { model.removeBinding(row.button, gesture: row.gesture) } label: {
            Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("매핑 삭제")
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("매핑한 버튼이 없습니다")
            Text("‘버튼 추가’를 누르고 마우스 버튼을 누르세요")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 앱 전체 설정

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                Toggle("세로 스크롤 반전", isOn: Binding(
                    get: { model.state.reverseVerticalScroll },
                    set: { enabled in
                        model.setScrollReversal(vertical: enabled, horizontal: model.state.reverseHorizontalScroll)
                    }
                ))
                Toggle("가로 스크롤 반전", isOn: Binding(
                    get: { model.state.reverseHorizontalScroll },
                    set: { enabled in
                        model.setScrollReversal(vertical: model.state.reverseVerticalScroll, horizontal: enabled)
                    }
                ))
                Toggle("부드러운 스크롤", isOn: Binding(
                    get: { model.state.smoothScrolling },
                    set: { model.setSmoothScrolling($0) }
                ))
                Spacer()
            }
            .toggleStyle(.checkbox)
            Toggle("로그인 시 실행", isOn: loginBinding)
                .toggleStyle(.checkbox)
        }
        .padding(.horizontal, contentPadding)
        .padding(.vertical, 10)
    }
}

// "버튼 추가"를 누르면 창 위에 뜨는 안내. 취소는 Esc(모델이 처리)나 버튼.
// 시트(.sheet)로 띄우면 떠 있는 동안 NSApp.terminate가 무시돼 앱을 끝낼 수 없다.
struct CapturePrompt: View {
    private static let dimOpacity = 0.25
    private static let cornerRadius: CGFloat = 12
    private static let shadowRadius: CGFloat = 12

    let isReady: Bool
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(CapturePrompt.dimOpacity)

            VStack(spacing: 12) {
                HStack {
                    if !isReady { ProgressView().controlSize(.small) }
                    Text(isReady ? String(localized: "마우스 버튼을 누르세요") : String(localized: "준비 중…"))
                        .font(.headline)
                }
                Text(isReady ? String(localized: "매핑할 버튼을 한 번 누르면 인식됩니다") : String(localized: "잠시만 기다려 주세요"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("취소 (Esc)", action: cancel)
                    .padding(.top, 8)
            }
            .padding(28)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: CapturePrompt.cornerRadius))
            .shadow(radius: CapturePrompt.shadowRadius)
        }
    }
}

// 확정 전 입력은 행에 둔다. 저장하면 같은 버튼의 방향 행에도 반영한다.
private struct ButtonNameField: View {
    let name: String
    let rawValue: String
    let rename: (String) -> Void
    @State private var draftName = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("버튼 이름", text: $draftName)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { commitName() }
                .onChange(of: isFocused) { focused in
                    if !focused { commitName() }
                }
            Text(rawValue)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .onAppear { draftName = name }
        .onChange(of: name) { newName in draftName = newName }
    }

    private func commitName() {
        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        rename(trimmedName)
        draftName = trimmedName.isEmpty ? name : trimmedName
    }
}

private struct ButtonNameFieldID: Hashable {
    let profileID: UUID
    let action: BindingID
}
