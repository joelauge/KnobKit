import SwiftUI

// MARK: - Dial

/// A line-drawn knob seen from above, with a scale around it. The scale runs from
/// lower left, over the top, to lower right, like a volume knob.
struct DialView: View {
    /// Where the knob points, 0…1 along the scale.
    var position: Double
    /// Long ticks, one per mode. 0 draws the fine scale only.
    var majorTicks = 0
    var activeTick: Int?
    /// Draws the fine scale bright up to `position`, for levels.
    var litScale = false
    var size: CGFloat = 96

    private func angle(_ t: Double) -> Double { (225 - 270 * t) * .pi / 180 }

    static func position(index: Int, count: Int) -> Double {
        count > 1 ? Double(index) / Double(count - 1) : 0.5
    }

    var body: some View {
        let radius = size / 2
        ZStack {
            Canvas { ctx, canvas in
                let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                func point(_ a: Double, _ r: CGFloat) -> CGPoint {
                    CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y - CGFloat(sin(a)) * r)
                }
                func tick(_ t: Double, from r0: CGFloat, to r1: CGFloat, _ color: Color, width: CGFloat = 1) {
                    var path = Path()
                    path.move(to: point(angle(t), r0))
                    path.addLine(to: point(angle(t), r1))
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
                func ring(_ r: CGFloat, _ color: Color, width: CGFloat = 1) {
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                               with: .color(color), lineWidth: width)
                }

                // Fine scale.
                let fine = size >= 80 ? 36 : (size >= 50 ? 24 : 12)
                for i in 0...fine {
                    let t = Double(i) / Double(fine)
                    let lit = litScale && t <= position + 0.0001
                    tick(t, from: radius * 0.80, to: radius * 0.87, lit ? Theme.ink : Theme.ink.opacity(0.26))
                }
                // One long tick per mode; the active one reaches the edge.
                if majorTicks > 0 {
                    for i in 0..<majorTicks {
                        let t = DialView.position(index: i, count: majorTicks)
                        let on = i == activeTick
                        tick(t, from: radius * 0.76, to: radius * (on ? 0.99 : 0.92),
                             on ? Theme.ink : Theme.ink.opacity(0.62), width: on ? 1.6 : 1)
                    }
                }
                // Knob body: grip ring and cap, as on the card's drawing.
                ring(radius * 0.63, Theme.ink, width: size >= 50 ? 1.2 : 1)
                ring(radius * 0.52, Theme.ink.opacity(0.5))
            }
            // The indicator turns with the mode.
            Circle()
                .fill(Theme.ink)
                .frame(width: max(3, size * 0.055), height: max(3, size * 0.055))
                .offset(y: -radius * 0.37)
                .rotationEffect(.degrees(90 - (225 - 270 * position)))
                .animation(.snappy(duration: 0.28), value: position)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - F75 outline

/// The F75's key layout in key units, with macOS key codes where a key can be remapped.
enum F75Layout {
    struct Cap {
        let x: CGFloat
        let y: CGFloat
        let w: CGFloat
        let code: Int?
    }

    static let width: CGFloat = 16
    static let height: CGFloat = 6.25
    static let knobCenter = CGPoint(x: 15.3, y: 0.5)
    static let knobRadius: CGFloat = 0.58

    static let caps: [Cap] = {
        var out: [Cap] = []
        func row(_ y: CGFloat, start: CGFloat = 0, _ keys: [(CGFloat, Int?)]) {
            var x = start
            for (w, code) in keys {
                out.append(Cap(x: x, y: y, w: w, code: code))
                x += w
            }
        }
        func k(_ w: CGFloat, _ code: Int?) -> (CGFloat, Int?) { (w, code) }
        func ones(_ codes: [Int]) -> [(CGFloat, Int?)] { codes.map { (1, $0) } }

        // Function row: Esc, three groups of four, then the knob.
        row(0, [k(1, 53)])
        row(0, start: 1.6, ones([122, 120, 99, 118]))
        row(0, start: 5.9, ones([96, 97, 98, 100]))
        row(0, start: 10.2, ones([101, 109, 103, 111]))
        row(1.25, ones([50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]) + [k(2, 51), k(1, 117)])
        row(2.25, [k(1.5, 48)] + ones([12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30]) + [k(1.5, 42), k(1, 116)])
        row(3.25, [k(1.75, nil)] + ones([0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39]) + [k(2.25, 36), k(1, 121)])
        row(4.25, [k(2.25, nil)] + ones([6, 7, 8, 9, 11, 45, 46, 43, 47, 44]) + [k(1.75, nil), k(1, 126), k(1, 119)])
        row(5.25, [k(1.25, nil), k(1.25, nil), k(1.25, nil), k(6.25, 49), k(1.25, nil), k(1.25, nil)])
        row(5.25, start: 13, ones([123, 125, 124]))
        return out
    }()
}

/// The keyboard drawn in outline, as on the card. The knob is the subject; remapped
/// keys are filled in.
struct KeyboardDrawing: View {
    var unit: CGFloat = 22
    var highlighted: Set<Int> = []

    static func pad(_ unit: CGFloat) -> CGFloat { (unit * 0.42).rounded() }

    static func size(unit: CGFloat) -> CGSize {
        let p = pad(unit)
        return CGSize(width: (F75Layout.width * unit).rounded() + p * 2 + 1,
                      height: (F75Layout.height * unit).rounded() + p * 2 + 1)
    }

    /// Centre of the knob in this view's coordinates.
    static func knobCenter(unit: CGFloat) -> CGPoint {
        let p = pad(unit)
        return CGPoint(x: (p + F75Layout.knobCenter.x * unit).rounded() + 0.5,
                       y: (p + F75Layout.knobCenter.y * unit).rounded() + 0.5)
    }

    static func knobRadius(unit: CGFloat) -> CGFloat { (F75Layout.knobRadius * unit).rounded() }

    var body: some View {
        let size = Self.size(unit: unit)
        Canvas { ctx, _ in
            let p = Self.pad(unit)
            // Edges land on half pixels so one-pixel lines stay sharp.
            func edge(_ v: CGFloat) -> CGFloat { v.rounded() + 0.5 }
            func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
                CGRect(x: edge(x0), y: edge(y0), width: edge(x1) - edge(x0), height: edge(y1) - edge(y0))
            }

            // Case: two outlines.
            let outer = box(0, 0, size.width - 1, size.height - 1)
            ctx.stroke(Path(roundedRect: outer, cornerRadius: unit * 0.55), with: .color(Theme.ink.opacity(0.55)), lineWidth: 1)
            let inner = outer.insetBy(dx: (unit * 0.16).rounded(), dy: (unit * 0.16).rounded())
            ctx.stroke(Path(roundedRect: inner, cornerRadius: unit * 0.42), with: .color(Theme.ink.opacity(0.26)), lineWidth: 1)

            // Keys: an outline with the cap's top face inside it.
            let gap = max(1, (unit * 0.07).rounded())
            for cap in F75Layout.caps {
                let x0 = p + cap.x * unit + gap, x1 = p + (cap.x + cap.w) * unit - gap
                let y0 = p + cap.y * unit + gap, y1 = p + (cap.y + 1) * unit - gap
                let rect = box(x0, y0, x1, y1)
                let on = cap.code.map { highlighted.contains($0) } ?? false
                ctx.stroke(Path(roundedRect: rect, cornerRadius: unit * 0.14),
                           with: .color(Theme.ink.opacity(on ? 1 : 0.42)), lineWidth: 1)
                let side = (unit * 0.15).rounded(), top = (unit * 0.1).rounded(), bottom = (unit * 0.22).rounded()
                let face = CGRect(x: rect.minX + side, y: rect.minY + top,
                                  width: rect.width - side * 2, height: rect.height - top - bottom)
                let facePath = Path(roundedRect: face, cornerRadius: unit * 0.1)
                if on {
                    ctx.fill(facePath, with: .color(Theme.ink))
                } else {
                    ctx.stroke(facePath, with: .color(Theme.ink.opacity(0.2)), lineWidth: 1)
                }
            }

            // The knob, drawn at full strength.
            let k = Self.knobCenter(unit: unit)
            let r = Self.knobRadius(unit: unit)
            func ring(_ radius: CGFloat, _ opacity: Double, _ width: CGFloat) {
                ctx.stroke(Path(ellipseIn: CGRect(x: k.x - radius, y: k.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(Theme.ink.opacity(opacity)), lineWidth: width)
            }
            ring(r, 1, 1.5)
            ring(r * 0.76, 0.7, 1)
            let dot: CGFloat = max(1.5, unit * 0.08)
            ctx.fill(Path(ellipseIn: CGRect(x: k.x + r * 0.42 - dot, y: k.y - dot, width: dot * 2, height: dot * 2)),
                     with: .color(Theme.ink))
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Knob callouts

/// One labelled line off the knob.
struct Callout: Identifiable {
    var label: String
    var value: String
    /// False when the value is inherited or the system default.
    var own: Bool
    var id: String { label }
}

/// The keyboard with leader lines running from the knob to what it does, in the manner
/// of the card ("Multifunctional roller ────").
struct KnobHero: View {
    var callouts: [Callout]
    var highlighted: Set<Int> = []

    var body: some View {
        // The biggest drawing that leaves room for the labels.
        ViewThatFits(in: .horizontal) {
            layout(unit: 26)
            layout(unit: 22)
            layout(unit: 18)
            layout(unit: 15)
        }
    }

    private func layout(unit: CGFloat) -> some View {
        let board = KeyboardDrawing.size(unit: unit)
        let knob = KeyboardDrawing.knobCenter(unit: unit)
        let r = KeyboardDrawing.knobRadius(unit: unit)
        let rowHeight: CGFloat = 24
        let trunkX = (board.width + 16).rounded() + 0.5
        let labelX = trunkX + 18
        let height = max(board.height, knob.y + CGFloat(max(callouts.count, 1)) * rowHeight)

        return ZStack(alignment: .topLeading) {
            KeyboardDrawing(unit: unit, highlighted: highlighted)
            Canvas { ctx, _ in
                guard !callouts.isEmpty else { return }
                var path = Path()
                // From the knob out to the first label, then down to the others.
                path.move(to: CGPoint(x: knob.x + r + 3, y: knob.y))
                path.addLine(to: CGPoint(x: labelX - 8, y: knob.y))
                if callouts.count > 1 {
                    let last = knob.y + CGFloat(callouts.count - 1) * rowHeight
                    path.move(to: CGPoint(x: trunkX, y: knob.y))
                    path.addLine(to: CGPoint(x: trunkX, y: last))
                    for i in 1..<callouts.count {
                        let y = knob.y + CGFloat(i) * rowHeight
                        path.move(to: CGPoint(x: trunkX, y: y))
                        path.addLine(to: CGPoint(x: labelX - 8, y: y))
                    }
                }
                ctx.stroke(path, with: .color(Theme.ink.opacity(0.6)), lineWidth: 1)
            }
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(callouts) { callout in
                    HStack(alignment: .center, spacing: 10) {
                        Eyebrow(callout.label, color: Theme.ink)
                            .frame(width: 84, alignment: .leading)
                        Text(callout.value)
                            .font(.system(size: 12.5, weight: callout.own ? .medium : .regular))
                            .foregroundStyle(callout.own ? Theme.ink : Theme.ink2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(height: rowHeight)
                }
            }
            .padding(.leading, labelX)
            .offset(y: knob.y - rowHeight / 2)
        }
        .frame(minWidth: labelX + 84 + 10 + 180, maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .topLeading)
    }
}
