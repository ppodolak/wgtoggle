// Renders the app icon iconset: usage `swift make-icon.swift <out.iconset> [preview.png]`
// Design: dark graphite squircle (macOS icon grid), white shield with a toggle switch, teal "on" knob.
import AppKit

let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, _ colors: [CGColor], center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

/// Continuous-corner ("squircle") rounded rect, close to Apple's icon shape.
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let n: CGFloat = 5          // superellipse exponent
    let steps = 360
    let cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * copysign(pow(abs(c), 2 / n), c)
        let y = cy + b * copysign(pow(abs(s), 2 / n), s)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

func shield() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 512, y: 790))
    p.addCurve(to: CGPoint(x: 728, y: 712), control1: CGPoint(x: 590, y: 772), control2: CGPoint(x: 668, y: 748))
    p.addLine(to: CGPoint(x: 728, y: 520))
    p.addCurve(to: CGPoint(x: 512, y: 232), control1: CGPoint(x: 728, y: 380), control2: CGPoint(x: 640, y: 282))
    p.addCurve(to: CGPoint(x: 296, y: 520), control1: CGPoint(x: 384, y: 282), control2: CGPoint(x: 296, y: 380))
    p.addLine(to: CGPoint(x: 296, y: 712))
    p.addCurve(to: CGPoint(x: 512, y: 790), control1: CGPoint(x: 356, y: 748), control2: CGPoint(x: 434, y: 772))
    p.closeSubpath()
    return p
}

func draw(_ ctx: CGContext) {   // 1024×1024 canvas, y up
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = squircle(tile)

    // Drop shadow under the tile
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.45))
    ctx.addPath(tilePath); ctx.setFillColor(rgb(0x14181f)); ctx.fillPath()
    ctx.restoreGState()

    // Tile body: graphite gradient + soft teal glow behind the shield
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    linear(ctx, [rgb(0x343b48), rgb(0x161a21), rgb(0x0b0d11)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    radial(ctx, [rgb(0x2ee6c0, 0.28), rgb(0x2ee6c0, 0)], center: CGPoint(x: 512, y: 470), radius: 420)
    // top sheen
    linear(ctx, [rgb(0xffffff, 0.10), rgb(0xffffff, 0)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 640))
    ctx.restoreGState()

    // Hairline edge
    ctx.addPath(tilePath); ctx.setStrokeColor(rgb(0xffffff, 0.12)); ctx.setLineWidth(3); ctx.strokePath()

    // Shield: shadow, white→silver gradient, inner edge
    let sh = shield()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0x000000, 0.55))
    ctx.addPath(sh); ctx.setFillColor(rgb(0xe9edf2)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(sh); ctx.clip()
    linear(ctx, [rgb(0xffffff), rgb(0xdfe4ea), rgb(0xb9c1cc)], from: CGPoint(x: 512, y: 790), to: CGPoint(x: 512, y: 232))
    ctx.restoreGState()
    ctx.addPath(sh); ctx.setStrokeColor(rgb(0xffffff, 0.9)); ctx.setLineWidth(4); ctx.strokePath()

    // Toggle track (inset look)
    let track = CGRect(x: 512 - 138, y: 530 - 66, width: 276, height: 132)
    let trackPath = CGPath(roundedRect: track, cornerWidth: 66, cornerHeight: 66, transform: nil)
    ctx.saveGState()
    ctx.addPath(trackPath); ctx.clip()
    linear(ctx, [rgb(0x0a0d12), rgb(0x232a35)], from: CGPoint(x: 512, y: track.maxY), to: CGPoint(x: 512, y: track.minY))
    // inner top shadow
    linear(ctx, [rgb(0x000000, 0.6), rgb(0x000000, 0)], from: CGPoint(x: 512, y: track.maxY), to: CGPoint(x: 512, y: track.maxY - 30))
    ctx.restoreGState()

    // Knob: teal, glowing, on the "on" side
    let kc = CGPoint(x: track.maxX - 66, y: track.midY)
    let kr: CGFloat = 52
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 46, color: rgb(0x2ee6c0, 0.9))
    ctx.addEllipse(in: CGRect(x: kc.x - kr, y: kc.y - kr, width: kr * 2, height: kr * 2))
    ctx.setFillColor(rgb(0x2ee6c0)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: kc.x - kr, y: kc.y - kr, width: kr * 2, height: kr * 2)); ctx.clip()
    linear(ctx, [rgb(0x8dffe6), rgb(0x2ee6c0), rgb(0x0fa88c)], from: CGPoint(x: kc.x, y: kc.y + kr), to: CGPoint(x: kc.x, y: kc.y - kr))
    ctx.restoreGState()
    // specular dot
    ctx.addEllipse(in: CGRect(x: kc.x - 22, y: kc.y + 14, width: 30, height: 20))
    ctx.setFillColor(rgb(0xffffff, 0.55)); ctx.fillPath()

    // "off" dot on the left of the track
    ctx.addEllipse(in: CGRect(x: track.minX + 50, y: track.midY - 12, width: 24, height: 24))
    ctx.setFillColor(rgb(0xffffff, 0.18)); ctx.fillPath()

    // Small lock-slot under the toggle for the "secure tunnel" read
    let slot = CGRect(x: 512 - 9, y: 330, width: 18, height: 70)
    ctx.addPath(CGPath(roundedRect: slot, cornerWidth: 9, cornerHeight: 9, transform: nil))
    ctx.setFillColor(rgb(0x6b7684, 0.55)); ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: 512 - 26, y: 382, width: 52, height: 52))
    ctx.setFillColor(rgb(0x6b7684, 0.55)); ctx.fillPath()
}

func render(_ px: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 2 {
    try render(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
