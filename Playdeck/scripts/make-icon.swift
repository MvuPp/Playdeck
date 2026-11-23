// Draws Playdeck's icon (a deck of cards with a play symbol) and writes Resources/AppIcon.icns.
// Run from Playdeck/: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let out = URL(fileURLWithPath: "Resources", isDirectory: true)
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")

func draw(_ ctx: CGContext) {
    let space = CGColorSpaceCreateDeviceRGB()
    // macOS grid: 824 pt body centered in 1024, ~185 pt corner radius, soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.16, green: 0.20, blue: 0.55, alpha: 1),  // indigo
        CGColor(red: 0.05, green: 0.55, blue: 0.62, alpha: 1),  // teal
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    ctx.restoreGState()

    // Three cards fanned out; the front one carries the play triangle.
    let card = CGRect(x: -190, y: -250, width: 380, height: 500)
    for (angle, alpha) in [(-16.0, 0.35), (-6.0, 0.6), (5.0, 1.0)] {
        ctx.saveGState()
        ctx.translateBy(x: 512, y: 500)
        ctx.rotate(by: angle * .pi / 180)
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.25))
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 48, cornerHeight: 48, transform: nil))
        ctx.setFillColor(CGColor(gray: 1, alpha: alpha))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.translateBy(x: 512, y: 500)
    ctx.rotate(by: 5 * .pi / 180)
    let play = CGMutablePath()
    play.move(to: CGPoint(x: -70, y: 115))
    play.addLine(to: CGPoint(x: 120, y: 0))
    play.addLine(to: CGPoint(x: -70, y: -115))
    play.closeSubpath()
    ctx.addPath(play)
    ctx.clip()
    let accent = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.20, green: 0.27, blue: 0.70, alpha: 1),
        CGColor(red: 0.04, green: 0.62, blue: 0.66, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(accent, start: CGPoint(x: -70, y: 115), end: CGPoint(x: 120, y: -115), options: [])
    ctx.restoreGState()
}

func png(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / size, y: CGFloat(pixels) / size)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try fm.createDirectory(at: out, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("OK : Resources/AppIcon.icns")
