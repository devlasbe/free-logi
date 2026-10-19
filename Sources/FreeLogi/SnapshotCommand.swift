import AppKit
import ServiceManagement
import SwiftUI

private let renderSettleSeconds = 0.5
private let snapshotScale = 2
private let menuWidth: CGFloat = 260
private let menuCornerRadius: CGFloat = 8
private let menuBackdropPadding: CGFloat = 24
private let menuIndentWidth: CGFloat = 12
private let menuCheckColumnWidth: CGFloat = 16

// 디버그(--snapshot <폴더>): 화면이 잠겨 있어도 설정 창·버튼 인식 시트·메뉴를 PNG로 그려 저장한다.
// 샘플 프로필은 임시 폴더에 만든다(사용자 프로필은 건드리지 않는다). 메뉴는 NSMenu 항목을 읽어 그린 것이지 OS가 그린 메뉴가 아니다.
@MainActor
func runSnapshot(outputDirectory: String) -> Int32 {
    NSApplication.shared.setActivationPolicy(.accessory)
    // SwiftPM 바이너리에는 번들 아이콘이 없으므로 저장소의 원본을 쓴다.
    if Bundle.main.bundleIdentifier == nil {
        let repositoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let iconURL = repositoryURL.appendingPathComponent("design/icon/AppIcon.icon/Assets/FreeLogi.png")
        if let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
    let directoryURL = URL(fileURLWithPath: outputDirectory)
    do {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let store = try makeSampleStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        var captureReady: (@MainActor () -> Void)?
        let model = SettingsModel(store: store, captureButton: { onReady in
            captureReady = onReady
            try? await Task.sleep(for: .seconds(60))
            return nil
        }, onChange: {})

        let windowController = SettingsWindowController(model: model)
        try writeImage(of: windowController.window, to: directoryURL.appendingPathComponent("settings.png"))

        // "버튼 추가"를 누른 뒤 준비 중·준비 완료 안내를 각각 그린다.
        model.startCapture()
        try writeImage(of: windowController.window, to: directoryURL.appendingPathComponent("capture-preparing.png"))
        captureReady?()
        try writeImage(of: windowController.window, to: directoryURL.appendingPathComponent("capture.png"))
        model.cancelCapture()

        model.updatePermissions([:])
        try writeImage(of: windowController.window, to: directoryURL.appendingPathComponent("permissions.png"))
        model.updatePermissions([.inputMonitoring: true])
        try writeImage(of: windowController.window, to: directoryURL.appendingPathComponent("permissions-partial.png"))

        windowController.close()

        let allGranted = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, true) })
        let delegate = AppDelegate()
        let menu = delegate.makeMenu(granted: allGranted, profileState: store.state)
        let menuView = NSHostingView(rootView: MenuPreview(items: menu.items))
        try writeImage(of: menuView, to: directoryURL.appendingPathComponent("menu.png"))

        print("login item: enabled=\(LoginItem.isEnabled) status=\(SMAppService.mainApp.status)")
        return 0
    } catch {
        printToStandardError("snapshot 실패: \(error)")
        return 1
    }
}

private func makeSampleStore() throws -> ProfileStore {
    let sampleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("freelogi-snapshot-\(UUID().uuidString)/profiles.json")
    let store = try ProfileStore(fileURL: sampleURL)
    let basicID = store.state.profiles[0].id

    let samples: [(ButtonID, UInt16, UInt64)] = [
        (.hidpp(0x0052), 126, CGEventFlags.maskControl.rawValue),
        (.hidpp(0x0053), 33, CGEventFlags.maskCommand.rawValue),
        (.hidpp(0x0056), 30, CGEventFlags.maskCommand.rawValue),
        (.hidpp(0x005B), 123, CGEventFlags.maskControl.rawValue),
        (.hidpp(0x005D), 124, CGEventFlags.maskControl.rawValue),
        (.standard(3), 21, CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue),
    ]
    for (button, keyCode, modifiers) in samples {
        try store.setBinding(profileID: basicID, button: button, keys: KeyCombo(keyCode: keyCode, modifiers: modifiers))
    }
    try store.add(name: "웹 브라우징")
    try store.add(name: "코딩")
    return store
}

// 창이나 뷰를 화면 밖에서 그려 PNG로 쓴다. 뷰는 창에 넣어야 SwiftUI가 레이아웃한다.
@MainActor
private func writeImage(of window: NSWindow, to fileURL: URL) throws {
    window.orderBack(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(renderSettleSeconds))
    guard let frameView = window.contentView?.superview else { throw SnapshotError.noView }
    try writePNG(of: frameView, to: fileURL)
}

@MainActor
private func writeImage(of view: NSView, to fileURL: URL) throws {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [], backing: .buffered, defer: false)
    window.contentView = view
    window.orderBack(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(renderSettleSeconds))
    try writePNG(of: view, to: fileURL)
    window.close()
}

@MainActor
private func writePNG(of view: NSView, to fileURL: URL) throws {
    view.layoutSubtreeIfNeeded()
    // 글자가 읽히도록 2배 해상도로 그린다.
    let pixelsWide = Int(view.bounds.width) * snapshotScale
    let pixelsHigh = Int(view.bounds.height) * snapshotScale
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw SnapshotError.noView }
    bitmap.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError.noView }
    try pngData.write(to: fileURL)
    print("wrote \(fileURL.path) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
}

private enum SnapshotError: Error { case noView }

// NSMenu 항목(제목·체크·들여쓰기·단축키·구분선)을 읽어 메뉴처럼 그린다.
private struct MenuPreview: View {
    let items: [NSMenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                itemRow(items[index])
            }
        }
        .padding(.vertical, 6)
        .frame(width: menuWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: menuCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: menuCornerRadius).stroke(Color.secondary.opacity(0.3)))
        .padding(menuBackdropPadding)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private func itemRow(_ item: NSMenuItem) -> some View {
        if item.isSeparatorItem {
            Divider().padding(.vertical, 4)
        } else {
            let isEnabled = item.action != nil
            HStack(spacing: 4) {
                Text(item.state == .on ? "✓" : "").frame(width: menuCheckColumnWidth)
                Text(item.title).foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                Spacer()
                Text(item.keyEquivalent.isEmpty ? "" : "⌘\(item.keyEquivalent.uppercased())").foregroundStyle(.secondary)
            }
            .padding(.leading, 6 + CGFloat(item.indentationLevel) * menuIndentWidth)
            .padding(.trailing, 12)
            .padding(.vertical, 3)
        }
    }
}
