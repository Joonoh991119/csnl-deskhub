import AppKit
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func draw(_ px: Int) -> Data {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let s = CGFloat(px)
    let r = NSBezierPath(roundedRect: NSRect(x: s*0.06, y: s*0.06, width: s*0.88, height: s*0.88), xRadius: s*0.2, yRadius: s*0.2)
    let grad = NSGradient(colors: [NSColor(red: 0.18, green: 0.45, blue: 0.85, alpha: 1), NSColor(red: 0.10, green: 0.22, blue: 0.50, alpha: 1)])!
    grad.draw(in: r, angle: -60)
    // 2x2 유리 타일
    let g = s * 0.12, t = (s*0.88 - g*3) / 2
    for (i, j) in [(0,0),(1,0),(0,1),(1,1)] {
        let x = s*0.06 + g + CGFloat(i) * (t + g)
        let y = s*0.06 + g + CGFloat(j) * (t + g)
        let tile = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: t, height: t), xRadius: t*0.22, yRadius: t*0.22)
        NSColor.white.withAlphaComponent(i == 1 && j == 0 ? 0.92 : 0.55).setFill()
        tile.fill()
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
for px in sizes {
    try! draw(px).write(to: iconset.appendingPathComponent("icon_\(px)x\(px).png"))
    if px <= 512 { try! draw(px*2).write(to: iconset.appendingPathComponent("icon_\(px)x\(px)@2x.png")) }
}
