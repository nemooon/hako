// アプリアイコンの 1024x1024 PNG を生成する
// 使い方: swift scripts/make-icon.swift <出力パス>
import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let canvas = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvas,
    pixelsHigh: canvas,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("ビットマップを作れませんでした")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS 標準の squircle(1024 キャンバスに 824 の角丸矩形、余白 100)
let iconRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: iconRect, xRadius: 185, yRadius: 185)

// 段ボールっぽい暖色グラデーション
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.36, alpha: 1), // 上: 明るいクラフト色
    ending: NSColor(calibratedRed: 0.85, green: 0.48, blue: 0.16, alpha: 1)    // 下: 濃い段ボール色
)!
gradient.draw(in: squircle, angle: -90)

// 白の shippingbox を中央に
let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .medium)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let size = symbol.size
    // アスペクト比を保って中央配置(少しだけ上に寄せて光学的に中央へ)
    let scale = min(560 / size.width, 560 / size.height)
    let drawSize = NSSize(width: size.width * scale, height: size.height * scale)
    let origin = NSPoint(
        x: (CGFloat(canvas) - drawSize.width) / 2,
        y: (CGFloat(canvas) - drawSize.height) / 2
    )
    symbol.draw(
        in: NSRect(origin: origin, size: drawSize),
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0
    )
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG を生成できませんでした")
}
try! png.write(to: URL(fileURLWithPath: outputPath))
print("生成しました: \(outputPath)")
