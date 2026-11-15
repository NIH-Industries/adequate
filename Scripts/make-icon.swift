// Draws Adequate's app icon (one sensible checkmark on a plain grey tile) and writes every
// size macOS needs into the AppIcon asset catalog.
// Usage: swift Scripts/make-icon.swift Adequate/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func draw(size: Int) -> Data {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // A plain grey tile on Apple's 824pt icon grid.
    let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bgPath = CGPath(roundedRect: bg, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.3))
    ctx.addPath(bgPath); ctx.setFillColor(color(0xD4D4D8)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bgPath); ctx.clip()
    let bgGradient = CGGradient(colorsSpace: space, colors: [color(0xF4F4F6), color(0xC8C8CD)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // One checkmark. It'll do.
    let check = CGMutablePath()
    check.move(to: CGPoint(x: 330, y: 520))
    check.addLine(to: CGPoint(x: 455, y: 395))
    check.addLine(to: CGPoint(x: 700, y: 640))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 6, color: color(0xFFFFFF, 0.6))
    ctx.addPath(check)
    ctx.setStrokeColor(color(0x6E6E73))
    ctx.setLineWidth(84); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try draw(size: points * scale).write(to: outDir.appendingPathComponent(name))
        images.append("""
            {"idiom":"mac","size":"\(points)x\(points)","scale":"\(scale)x","filename":"\(name)"}
        """)
    }
}
let contents = "{\"images\":[\n\(images.joined(separator: ",\n"))\n],\"info\":{\"version\":1,\"author\":\"xcode\"}}\n"
try contents.write(to: outDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
