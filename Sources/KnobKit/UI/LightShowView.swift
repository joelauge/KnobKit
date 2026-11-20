import AppKit
import KnobCore
import SwiftUI

/// The keyboard with its keys filled in as lights: what a frame looks like on the F75.
struct KeyboardLights: View {
    var unit: CGFloat = 24
    /// Colour by light index. Keys that are missing are dark.
    var colors: [Int: Color]

    var body: some View {
        let size = KeyboardDrawing.size(unit: unit)
        Canvas { ctx, _ in
            let p = KeyboardDrawing.pad(unit)
            func edge(_ v: CGFloat) -> CGFloat { v.rounded() + 0.5 }
            let outer = CGRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1)
            ctx.stroke(Path(roundedRect: outer, cornerRadius: unit * 0.55), with: .color(Theme.ink.opacity(0.5)), lineWidth: 1)

            let gap = max(1, (unit * 0.07).rounded())
            for cap in F75Layout.caps {
                let x0 = edge(p + cap.x * unit + gap), x1 = edge(p + (cap.x + cap.w) * unit - gap)
                let y0 = edge(p + cap.y * unit + gap), y1 = edge(p + (cap.y + 1) * unit - gap)
                let path = Path(roundedRect: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), cornerRadius: unit * 0.14)
                if let color = colors[cap.light] {
                    ctx.fill(path, with: .color(color))
                } else {
                    ctx.stroke(path, with: .color(Theme.ink.opacity(0.16)), lineWidth: 1)
                }
            }

            let k = KeyboardDrawing.knobCenter(unit: unit)
            let r = KeyboardDrawing.knobRadius(unit: unit)
            ctx.stroke(Path(ellipseIn: CGRect(x: k.x - r, y: k.y - r, width: r * 2, height: r * 2)),
                       with: .color(Theme.ink.opacity(0.5)), lineWidth: 1)
        }
        .frame(width: size.width, height: size.height)
    }

    /// The colours of one frame as the keyboard would show it.
    static func colors(of frame: [AulaLighting.Group]) -> [Int: Color] {
        var out: [Int: Color] = [:]
        for group in frame {
            let color = Color(red: Double(group.red) / 255, green: Double(group.green) / 255, blue: Double(group.blue) / 255)
            for light in group.lights { out[light] = color }
        }
        return out
    }
}

/// Holds the picture being played, rebuilt only when what it depends on changes.
final class LightShowModel: ObservableObject {
    @Published private(set) var show: LightShow?
    @Published private(set) var problem = ""
    private var built: LightShowSettings?
    /// The on-screen preview's own clock, used while nothing plays on the keyboard.
    let previewStart = Date()

    func rebuild(for settings: LightShowSettings) {
        guard settings != built else { return }
        // Only the picture itself is expensive to make; everything else is swapped in.
        func picture(_ s: LightShowSettings) -> [String] {
            [s.source.rawValue, s.text, s.imagePath, s.color, s.source == .image ? "\(s.lines)" : ""]
        }
        if let previous = built, picture(previous) == picture(settings), var current = show {
            LightShowSource.apply(settings, to: &current)
            show = current
        } else {
            show = LightShowSource.show(for: settings)
            if show == nil {
                problem = settings.imagePath.isEmpty ? "Choose an image to play." : "That image could not be read."
            } else {
                problem = ""
            }
        }
        built = settings
    }
}

struct LightShowView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var player: LightShowPlayer
    @StateObject private var model = LightShowModel()

    private var settings: Binding<LightShowSettings> { $state.config.settings.lightShow }

    private static let swatches: [(String, String)] = [
        ("FFFFFF", "White"), ("EBDCB8", "Cream"), ("FF3B30", "Red"), ("FF9500", "Orange"),
        ("FFD60A", "Yellow"), ("30D158", "Green"), ("40C8E0", "Cyan"), ("0A84FF", "Blue"), ("BF5AF2", "Purple"), ("FF375F", "Pink"),
    ]

    var body: some View {
        Page(title: "Light show",
             subtitle: "The keys become pixels, and the keyboard a small window that a banner or a picture slides past.",
             maxWidth: 860) {
            Card(title: "Preview") {
                preview
            }
            Card(title: "What to play") {
                Segmented(selection: settings.source, options: [(value: .text, title: "Text"), (value: .image, title: "Image")])
                if settings.wrappedValue.source == .text {
                    TextField("Text to scroll", text: settings.text)
                    HStack(spacing: 6) {
                        Text("Colour").foregroundStyle(Theme.ink2).padding(.trailing, 4)
                        ForEach(Self.swatches, id: \.0) { hex, name in
                            swatch(hex, name)
                        }
                    }
                    Note("Letters are drawn five keys tall in capitals, one key per dot.")
                } else {
                    imageChooser
                }
            }
            Card(title: "Motion") {
                SliderRow(title: "Speed", help: "", value: settings.speed, range: 1...80, step: 0.5,
                          format: { String(format: "%.1f keys a second", $0) })
                Rule()
                SliderRow(title: "Brightness", help: "", value: settings.brightness, range: 0.1...1, step: 0.05,
                          format: { "\(Int(($0 * 100).rounded())) %" })
                Rule()
                Toggle("Soft edges", isOn: settings.softEdges)
                    .help("Keys partly covered by the picture glow dimmer, which makes movement smoother. Off gives hard on / off dots that move a whole key at a time.")
                Toggle("Move a whole key at a time", isOn: settings.wholeKeySteps)
                    .help("The picture holds its shape and jumps one key per step instead of gliding. The keyboard then gets one frame per key of travel, so the frame rate equals the speed. Turn it off for the smoothest motion the connection can carry.")
                Toggle("Follow the true key positions", isOn: settings.upright)
                    .help("Each row of keys sits a little to the right of the one above. On: every key shows what is physically above it, so the picture stays upright. Off: rows are read key under key and move a whole key at a time, so upright strokes lean with the keys.")
                Toggle("Loop", isOn: settings.loop)
                Rule()
                SliderRow(title: "Frame rate limit",
                          help: "The most frames a second KnobKit sends. 21 is the pace of Epomaker's own app and the safe choice. Higher is smoother over the 2.4G receiver (Bluetooth cannot carry more than about 12), but if keys start to miss or repeat while it plays, bring it back down. Switching the keyboard off and on clears any trouble.",
                          value: settings.frameRateLimit, range: 10...60, step: 1,
                          format: { "\(Int($0)) frames a second" })
            }
            Note("Plays on an F75 over Bluetooth or its 2.4G receiver. Nothing is saved on the keyboard: when you stop, its own lighting comes back by itself. Bluetooth carries about 12 frames a second; the 2.4G receiver carries as many as the frame rate limit allows.")
        }
        .onAppear { sync() }
        .onChange(of: state.config.settings.lightShow) { _, _ in sync() }
    }

    private func sync() {
        model.rebuild(for: state.config.settings.lightShow)
        if let show = model.show { player.update(show) }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let start = player.startedAt ?? model.previewStart
                let frame = model.show?.frame(at: timeline.date.timeIntervalSince(start)) ?? []
                KeyboardLights(unit: 26, colors: KeyboardLights.colors(of: frame))
            }
            HStack(spacing: 12) {
                if player.isPlaying {
                    Button("Stop") { player.stop() }
                        .buttonStyle(.kkSolid)
                } else {
                    Button("Play on keyboard") {
                        if let show = model.show, let device = state.lightShowDevice { player.play(show, on: device) }
                    }
                    .buttonStyle(.kkSolid)
                    .disabled(model.show == nil || state.lightShowDevice == nil)
                }
                Note(statusText)
                Spacer(minLength: 0)
                if let show = model.show {
                    Text(String(format: "%.0f s a pass", show.duration)).font(.kkMono).foregroundStyle(Theme.ink2)
                }
            }
        }
    }

    private var statusText: String {
        if !model.problem.isEmpty { return model.problem }
        if player.isPlaying || !player.status.isEmpty && state.lightShowDevice != nil { return player.status }
        if let device = state.lightShowDevice { return "Ready to play on \(device.name)." }
        return state.knobConnected
            ? "This keyboard's backlight can't be driven from the Mac. The preview still plays."
            : "Connect an F75 to play it on the keys. The preview still plays."
    }

    // MARK: Pieces

    private func swatch(_ hex: String, _ name: String) -> some View {
        let (r, g, b) = LightShowSource.rgb(hex: hex)
        let selected = settings.wrappedValue.color.caseInsensitiveCompare(hex) == .orderedSame
        return Button {
            settings.wrappedValue.color = hex
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255))
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Theme.ink : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private var imageChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button("Choose image…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { settings.wrappedValue.imagePath = url.path }
                }
                if !settings.wrappedValue.imagePath.isEmpty {
                    Text((settings.wrappedValue.imagePath as NSString).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                    if let show = model.show {
                        Text(String(format: "%.0f keys wide", show.widthInKeys)).font(.kkMono).foregroundStyle(Theme.ink2)
                    }
                }
                Spacer(minLength: 0)
            }
            KKStepper(settings.wrappedValue.lines == 1 ? "Read in 1 line" : "Read in \(settings.wrappedValue.lines) lines",
                      value: settings.lines, in: 1...12)
                .help("A banner is one line: its whole height fits the keyboard's six rows. A taller picture can be read in several lines, like text, each line sliding past in turn.")
            Note("The picture is scaled so each line is six keys tall. Wide, short pictures with bold shapes on a dark background read best: white text on black, about six times as wide as the keyboard or more.")
        }
    }
}

/// Debug aid: a column of successive frames, to judge by eye how a show reads.
enum LightShowSheet {
    static func render(_ show: LightShow, frames: Int = 14, step: Double = 0.35, from start: Double = 1.6) -> NSBitmapImageRep? {
        let unit: CGFloat = 16
        let board = KeyboardDrawing.size(unit: unit)
        let columns = 2
        let rows = Int((Double(frames) / Double(columns)).rounded(.up))
        let pad: CGFloat = 10
        let width = Int(pad + CGFloat(columns) * (board.width + pad))
        let height = Int(pad + CGFloat(rows) * (board.height + pad))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let ctx = context.cgContext
        ctx.setFillColor(CGColor(gray: 0.04, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let p = KeyboardDrawing.pad(unit)
        for index in 0..<frames {
            let frame = show.frame(at: start + Double(index) * step)
            var colors: [Int: CGColor] = [:]
            for group in frame {
                let color = CGColor(red: CGFloat(group.red) / 255, green: CGFloat(group.green) / 255, blue: CGFloat(group.blue) / 255, alpha: 1)
                for light in group.lights { colors[light] = color }
            }
            // Frames run down the first column, then the second; y is flipped in CG.
            let column = index / rows, row = index % rows
            let originX = pad + CGFloat(column) * (board.width + pad)
            let originY = CGFloat(height) - pad - CGFloat(row + 1) * board.height - CGFloat(row) * pad
            for cap in F75Layout.caps {
                let rect = CGRect(x: originX + p + cap.x * unit + 1,
                                  y: originY + board.height - (p + (cap.y + 1) * unit) + 1,
                                  width: cap.w * unit - 2, height: unit - 2)
                ctx.setFillColor(colors[cap.light] ?? CGColor(gray: 0.11, alpha: 1))
                ctx.fill(rect)
            }
        }
        return rep
    }
}
