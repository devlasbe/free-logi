import AppKit
import SwiftUI

// 설정 창. 열 때 만들고 닫으면 SwiftUI 뷰까지 해제한다(상시 SwiftUI scene을 두지 않아 유휴 메모리를 아낀다).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model: SettingsModel
    var onClose: (() -> Void)?
    let window: NSWindow

    init(model: SettingsModel, granted: [Permission: Bool] = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, true) })) {
        self.model = model
        model.updatePermissions(granted)
        window = NSWindow(contentViewController: NSHostingController(rootView: MainView(model: model)))
        super.init()
        window.title = "FreeLogi"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    func show() {
        if !window.isVisible { centerOnMouseScreen() }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // 마우스가 있는 화면 가운데. 크기는 SwiftUI 배치가 끝난 뒤에야 정해진다
    private func centerOnMouseScreen() {
        if let content = window.contentViewController?.view { window.setContentSize(content.fittingSize) }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        model.close()
        window.contentViewController = nil
        window.delegate = nil
        onClose?()
    }
}
