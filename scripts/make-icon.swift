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
    // Lines never go below one pixel, so the small sizes stay legible.
    func width(_ w: CGFloat) -> CGFloat { max(1, w * s) }
    func ink(_ alpha: CGFloat) -> CGColor { CGColor(red: 0.925, green: 0.863, blue: 0.722, alpha: alpha) }

    // Matte black plate with a hairline edge, like the card in the F75's box.
    let plate = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.addPath(platePath)
    ctx.setFillColor(CGColor(red: 0.039, green: 0.039, blue: 0.043, alpha: 1))
    ctx.fillPath()
    let edge = plate.insetBy(dx: width(5) / 2, dy: width(5) / 2)
    ctx.addPath(CGPath(roundedRect: edge, cornerWidth: 182 * s, cornerHeight: 182 * s, transform: nil))
    ctx.setStrokeColor(ink(0.3))
    ctx.setLineWidth(width(5))
    ctx.strokePath()

    let center = CGPoint(x: 512 * s, y: 512 * s)
    func point(_ angle: CGFloat, _ r: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * r * s, y: center.y + sin(angle) * r * s)
    }
    func ring(_ r: CGFloat, _ w: CGFloat, _ alpha: CGFloat) {
        ctx.setStrokeColor(ink(alpha))
        ctx.setLineWidth(width(w))
        ctx.strokeEllipse(in: CGRect(x: center.x - r * s, y: center.y - r * s, width: r * 2 * s, height: r * 2 * s))
    }

    // Scale around the knob, bright up to where it points.
    let level: CGFloat = 0.62
    let tickCount = size < 64 ? 9 : 21
    ctx.setLineCap(.round)
    for i in 0..<tickCount {
        let t = CGFloat(i) / CGFloat(tickCount - 1)
        let angle = (225 - 270 * t) * .pi / 180
        ctx.setStrokeColor(ink(t <= level + 0.001 ? 1 : 0.3))
        ctx.setLineWidth(width(12))
        ctx.move(to: point(angle, 318))
        ctx.addLine(to: point(angle, 362))
        ctx.strokePath()
    }

    // Knob in outline: grip ring, cap, and the indicator dot.
    ring(252, 16, 1)
    if size >= 64 { ring(204, 8, 0.5) }
    let pointer = (225 - 270 * level) * CGFloat.pi / 180
    let dot = point(pointer, 138)
    let dotRadius = max(1.2, 24 * s)
    ctx.setFillColor(ink(1))
    ctx.fillEllipse(in: CGRect(x: dot.x - dotRadius, y: dot.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))

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
