// Draws the KnobKit app icon and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // Rounded-square plate.
    let plate = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.16, green: 0.17, blue: 0.21, alpha: 1),
        CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
    ctx.restoreGState()

    let center = CGPoint(x: 512 * s, y: 512 * s)

    // Detent ticks around the knob, with the lit arc showing a level.
    let tickCount = 21
    for i in 0..<tickCount {
        let t = CGFloat(i) / CGFloat(tickCount - 1)
        let angle = (225 - 270 * t) * .pi / 180
        let lit = t <= 0.62
        ctx.setStrokeColor(lit ? CGColor(red: 1.0, green: 0.62, blue: 0.18, alpha: 1)
                               : CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
        ctx.setLineWidth(15 * s)
        ctx.setLineCap(.round)
        let inner = 318 * s, outer = 356 * s
        ctx.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
        ctx.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        ctx.strokePath()
    }

    // Knob body.
    let radius = 250 * s
    let knob = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * s), blur: 40 * s, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
    ctx.setFillColor(CGColor(red: 0.3, green: 0.31, blue: 0.35, alpha: 1))
    ctx.fillEllipse(in: knob)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: knob)
    ctx.clip()
    let metal = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.80, green: 0.81, blue: 0.84, alpha: 1),
        CGColor(red: 0.42, green: 0.43, blue: 0.47, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(metal, start: CGPoint(x: 0, y: knob.maxY), end: CGPoint(x: 0, y: knob.minY), options: [])
    ctx.restoreGState()

    // Knurled cap.
    let capRadius = 196 * s
    let cap = CGRect(x: center.x - capRadius, y: center.y - capRadius, width: capRadius * 2, height: capRadius * 2)
    ctx.saveGState()
    ctx.addEllipse(in: cap)
    ctx.clip()
    let capGradient = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.26, green: 0.27, blue: 0.31, alpha: 1),
        CGColor(red: 0.13, green: 0.13, blue: 0.16, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(capGradient, start: CGPoint(x: 0, y: cap.maxY), end: CGPoint(x: 0, y: cap.minY), options: [])
    ctx.restoreGState()

    // Pointer at the end of the lit arc.
    let pointerAngle = (225 - 270 * 0.62) * CGFloat.pi / 180
    ctx.setStrokeColor(CGColor(red: 1.0, green: 0.62, blue: 0.18, alpha: 1))
    ctx.setLineWidth(26 * s)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: center.x + cos(pointerAngle) * 70 * s, y: center.y + sin(pointerAngle) * 70 * s))
    ctx.addLine(to: CGPoint(x: center.x + cos(pointerAngle) * 160 * s, y: center.y + sin(pointerAngle) * 160 * s))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let rep = draw(size: CGFloat(points * scale))
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
print("wrote \(out.path)")
