import AppKit

/// The menu bar icon: a knob with a scale of ticks around it, one tick per mode, and
/// the knob's pointer aimed at the active mode. Drawn in code so it stays crisp at any
/// scale and can turn with the mode.
enum KnobIcon {
    /// Most ticks that stay legible at menu bar size.
    private static let maxTicks = 9

    /// Template image (tinted by the menu bar for light / dark and highlight states).
    static func image(modeIndex: Int, modeCount: Int, pointSize: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        for scale in [1, 2, 3] as [CGFloat] {
            let pixels = Int((pointSize * scale).rounded())
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep)
            else { continue }
            context.cgContext.scaleBy(x: scale, y: scale)
            draw(in: context.cgContext, size: pointSize, modeIndex: modeIndex, modeCount: modeCount,
                 color: CGColor(gray: 0, alpha: 1))
            rep.size = NSSize(width: pointSize, height: pointSize)
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = "KnobKit"
        return image
    }

    /// Angle of a tick: the scale runs from lower left, over the top, to lower right,
    /// like a volume knob. A single mode points straight up.
    private static func angle(_ index: Int, of count: Int) -> CGFloat {
        guard count > 1 else { return .pi / 2 }
        let t = CGFloat(index) / CGFloat(count - 1)
        return (225 - 270 * t) * .pi / 180
    }

    /// Draws into an 18-unit square scaled to `size`.
    static func draw(in ctx: CGContext, size: CGFloat, modeIndex: Int, modeCount: Int, color: CGColor) {
        let s = size / 18
        let center = CGPoint(x: 9 * s, y: 8.2 * s)
        let ticks = max(1, min(modeCount, maxTicks))
        // With more modes than ticks, the pointer lands on the nearest tick.
        let active = modeCount <= maxTicks
            ? max(0, min(modeIndex, ticks - 1))
            : Int((CGFloat(modeIndex) / CGFloat(max(modeCount - 1, 1)) * CGFloat(ticks - 1)).rounded())

        // Scale: short radial ticks, like the markings around a real knob. The active
        // mode's tick is solid, the rest are quieter.
        ctx.setLineCap(.round)
        ctx.setLineWidth(1.2 * s)
        for i in 0..<ticks {
            let a = angle(i, of: ticks)
            ctx.setStrokeColor(color.copy(alpha: i == active ? 1 : 0.42) ?? color)
            ctx.move(to: CGPoint(x: center.x + cos(a) * 6.7 * s, y: center.y + sin(a) * 6.7 * s))
            ctx.addLine(to: CGPoint(x: center.x + cos(a) * 8.1 * s, y: center.y + sin(a) * 8.1 * s))
            ctx.strokePath()
        }

        // Knob body.
        let radius = 5.0 * s
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

        // Pointer: an indicator line cut into the body, aimed at the active tick. It stops
        // short of the rim so the body keeps its round outline.
        let a = angle(active, of: ticks)
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(1.5 * s)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: center.x + cos(a) * 1.3 * s, y: center.y + sin(a) * 1.3 * s))
        ctx.addLine(to: CGPoint(x: center.x + cos(a) * 3.5 * s, y: center.y + sin(a) * 3.5 * s))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Debug aid: every pointer position for several mode counts, on light and dark
    /// menu bar colours, enlarged. Written next to the log by the test hook.
    static func contactSheet() -> NSBitmapImageRep? {
        let counts = [1, 3, 5, 8]
        let cell: CGFloat = 18, pad: CGFloat = 8, zoom: CGFloat = 5
        let columns = counts.max() ?? 1
        let widthPoints = pad + CGFloat(columns) * (cell + pad)
        let rowHeight = cell + pad
        let heightPoints = pad + CGFloat(counts.count) * rowHeight
        // Left: enlarged on a light bar. Right: enlarged on a dark bar. Bottom strip: actual size.
        let width = Int(widthPoints * zoom * 2)
        let height = Int(heightPoints * zoom + 70)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        let ctx = context.cgContext
        let half = CGFloat(width) / 2
        let themes: [(CGFloat, CGColor, CGColor)] = [
            (0, CGColor(gray: 0.93, alpha: 1), CGColor(gray: 0.1, alpha: 1)),
            (half, CGColor(gray: 0.16, alpha: 1), CGColor(gray: 0.96, alpha: 1)),
        ]
        for (x, background, ink) in themes {
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: x, y: 0, width: half, height: CGFloat(height)))
            for (row, count) in counts.enumerated() {
                for index in 0..<count {
                    // Each icon is drawn on its own transparent layer so the notch cuts
                    // through to the bar colour rather than to transparent black.
                    let origin = CGPoint(x: x + (pad + CGFloat(index) * (cell + pad)) * zoom,
                                         y: 70 + (pad + CGFloat(counts.count - 1 - row) * rowHeight) * zoom)
                    ctx.saveGState()
                    ctx.translateBy(x: origin.x, y: origin.y)
                    ctx.scaleBy(x: zoom, y: zoom)
                    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                    draw(in: ctx, size: cell, modeIndex: index, modeCount: count, color: ink)
                    ctx.endTransparencyLayer()
                    ctx.restoreGState()
                }
            }
            // Actual menu bar size on a Retina display (2x pixels), five-mode set.
            for index in 0..<5 {
                ctx.saveGState()
                ctx.translateBy(x: x + 24 + CGFloat(index) * 60, y: 16)
                ctx.scaleBy(x: 2, y: 2)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                draw(in: ctx, size: cell, modeIndex: index, modeCount: 5, color: ink)
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }
        return rep
    }
}
