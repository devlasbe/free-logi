#!/usr/bin/env swift
// 추가 설치 없이 AppKit/CoreGraphics로 DMG 배경을 1x·2x로 그린다.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let CANVAS_SIZE = CGSize(width: 640, height: 400)
let ICON_ROW_Y: CGFloat = 210
let HEADER_ICON_RECT = CGRect(x: 44, y: 40, width: 48, height: 48)
let BACKGROUND = NSColor(srgbRed: 0.965, green: 0.962, blue: 0.953, alpha: 1)
let ROOT_DIRECTORY = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let OUTPUT_DIRECTORY = ROOT_DIRECTORY.appendingPathComponent("design/dmg")
let APP_ICON_URL = ROOT_DIRECTORY.appendingPathComponent("build/FreeLogi.app/Contents/Resources/AppIcon.icns")
let ICON_PALETTE_URL = ROOT_DIRECTORY.appendingPathComponent("design/icon/AppIcon.icon/icon.json")

struct IconPaletteType: Decodable {
    struct FillType: Decodable {
        let solid: String
    }
    let fill: FillType
}

func loadGraphite() throws -> NSColor {
    let data = try Data(contentsOf: ICON_PALETTE_URL)
    let palette = try JSONDecoder().decode(IconPaletteType.self, from: data)
    let prefix = "extended-srgb:"
    let components = palette.fill.solid.dropFirst(prefix.count).split(separator: ",")
    let channels = components.compactMap { Double($0) }
    guard palette.fill.solid.hasPrefix(prefix), channels.count == 4 else {
        throw NSError(domain: "FreeLogiDMG", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "icon.json fill.solid must contain four extended-srgb channels."
        ])
    }
    return NSColor(srgbRed: channels[0], green: channels[1], blue: channels[2], alpha: channels[3])
}

func drawBackground(scale: Int, appIcon: NSImage, graphite: NSColor) throws {
    let pixelWidth = Int(CANVAS_SIZE.width) * scale
    let pixelHeight = Int(CANVAS_SIZE.height) * scale
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight,
        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    // Finder와 같은 좌측 상단 원점으로 배경과 아이콘의 위치를 맞춘다.
    context.translateBy(x: 0, y: CANVAS_SIZE.height)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

    BACKGROUND.setFill()
    context.fill(CGRect(origin: .zero, size: CANVAS_SIZE))

    // 아이콘의 그래파이트·청회색을 얇게 겹치고, 이름이 놓이는 아래쪽은 밝게 둔다.
    let topTint = graphite.blended(withFraction: 0.86, of: BACKGROUND)!
    let verticalGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [topTint.cgColor, BACKGROUND.cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        verticalGradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 240),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    let cornerGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [graphite.withAlphaComponent(0.20).cgColor, graphite.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        cornerGradient, startCenter: .zero, startRadius: 0,
        endCenter: .zero, endRadius: 340, options: []
    )

    appIcon.draw(in: HEADER_ICON_RECT, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 27, weight: .bold),
        .foregroundColor: graphite
    ]
    ("FreeLogi" as NSString).draw(in: CGRect(x: 108, y: 36, width: 400, height: 36), withAttributes: titleAttributes)
    let subtitleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .regular),
        .foregroundColor: graphite.withAlphaComponent(0.78)
    ]
    ("Logitech button mapper for macOS" as NSString).draw(
        in: CGRect(x: 108, y: 74, width: 440, height: 20), withAttributes: subtitleAttributes
    )

    // 설치 방향만 나타내는 그래파이트 화살표. 아이콘은 Finder가 그린다.
    graphite.setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 298, y: ICON_ROW_Y))
    arrow.line(to: NSPoint(x: 342, y: ICON_ROW_Y))
    arrow.move(to: NSPoint(x: 332, y: ICON_ROW_Y - 10))
    arrow.line(to: NSPoint(x: 342, y: ICON_ROW_Y))
    arrow.line(to: NSPoint(x: 332, y: ICON_ROW_Y + 10))
    arrow.stroke()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 16, weight: .medium),
        .foregroundColor: graphite,
        .paragraphStyle: paragraph
    ]
    let instruction = "Drag FreeLogi to Applications" as NSString
    instruction.draw(in: CGRect(x: 40, y: 330, width: 560, height: 28), withAttributes: attributes)

    let suffix = scale == 1 ? "" : "@2x"
    let output = OUTPUT_DIRECTORY.appendingPathComponent("background\(suffix).png")
    let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
    // 두 PNG 모두 640×400pt로 해석되도록 해상도 메타데이터도 넣는다.
    let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
    print("\(output.path) (\(pixelWidth)×\(pixelHeight))")
}

do {
    guard let appIcon = NSImage(contentsOf: APP_ICON_URL), appIcon.isValid else {
        throw NSError(domain: "FreeLogiDMG", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "App icon is missing or unreadable: \(APP_ICON_URL.path). Run scripts/build-app.sh first."
        ])
    }
    let graphite = try loadGraphite()
    try FileManager.default.createDirectory(at: OUTPUT_DIRECTORY, withIntermediateDirectories: true)
    try drawBackground(scale: 1, appIcon: appIcon, graphite: graphite)
    try drawBackground(scale: 2, appIcon: appIcon, graphite: graphite)
} catch {
    FileHandle.standardError.write(Data("DMG background: \(error.localizedDescription)\n".utf8))
    exit(1)
}
