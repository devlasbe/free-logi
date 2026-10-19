// 메뉴바 아이콘이 등록됐는지 확인한다. 화면이 잠겨 있어 screencapture로 못 볼 때도 쓴다.
// 사용: swift scripts/status-item.swift kr.lasbe.freelogi
// macOS 26에서 상태 아이템 창은 제어 센터 소유이고 창 이름이 번들 ID다. 아이콘이 있으면 너비가 30 안팎이다.
import CoreGraphics
import Foundation

let statusItemLayer = 25
let bundleIdentifier = CommandLine.arguments[1]

let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
    let name = window[kCGWindowName as String] as? String
    let layer = window[kCGWindowLayer as String] as? Int
    guard name == bundleIdentifier, layer == statusItemLayer else { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("\(bundleIdentifier) width=\(bounds["Width"] ?? "?") height=\(bounds["Height"] ?? "?")")
}
