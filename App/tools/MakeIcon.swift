import AppKit
// 应用图标：浅灰圆角底 + 一条深色小圆角条（不起眼）
func draw(size s: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s)); img.lockFocus()
    let inset = s * 0.075
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2), xRadius: s * 0.205, yRadius: s * 0.205)
    NSGradient(starting: NSColor(white: 0.93, alpha: 1), ending: NSColor(white: 0.84, alpha: 1))!.draw(in: bg, angle: -90)
    let barW = s * 0.56, barH = s * 0.14
    let bar = NSBezierPath(roundedRect: NSRect(x: (s - barW) / 2, y: (s - barH) / 2, width: barW, height: barH), xRadius: barH / 2, yRadius: barH / 2)
    NSColor(red: 0x1B/255.0, green: 0x24/255.0, blue: 0x30/255.0, alpha: 0.9).setFill(); bar.fill()
    // 条上三个淡点，暗示「几个数」
    for k in 0..<3 {
        let x = (s - barW) / 2 + barW * (0.22 + 0.28 * CGFloat(k))
        NSColor(white: 0.93, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - s * 0.028, y: s / 2 - s * 0.028, width: s * 0.056, height: s * 0.056)).fill()
    }
    img.unlockFocus(); return img
}
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let img = draw(size: CGFloat(px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px)); NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/\(name).png"))
}
