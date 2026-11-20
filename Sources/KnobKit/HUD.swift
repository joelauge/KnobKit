import AppKit
import KnobCore
import SwiftUI

final class HUDModel: ObservableObject {
    @Published var symbol = "dial.medium"
    @Published var title = ""
    @Published var subtitle: String?
    @Published var level: Double?
    @Published var dotIndex = 0
    @Published var dotCount = 0
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 14) {
            gauge
            VStack(alignment: .leading, spacing: 6) {
                Text(model.title.uppercased())
                    .font(.kkDisplay(13))
                    .tracking(0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
                if let level = model.level {
                    LevelRuler(level: level)
                }
                if model.dotCount > 1 {
                    HStack(spacing: 8) {
                        Eyebrow("Mode")
                        Leader()
                        Text(String(format: "%02d / %02d", model.dotIndex + 1, model.dotCount))
                            .font(.kkMono).foregroundStyle(Theme.ink2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .padding(.vertical, 12)
        .frame(width: 290)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.ink.opacity(0.34), lineWidth: 1))
        .kkRoot()
    }

    /// The knob itself: pointing at the mode, or at the level, with the action's symbol
    /// in its cap when there is neither.
    @ViewBuilder private var gauge: some View {
        if model.dotCount > 1 {
            DialView(position: DialView.position(index: model.dotIndex, count: model.dotCount),
                     majorTicks: model.dotCount, activeTick: model.dotIndex, size: 52)
        } else if let level = model.level {
            DialView(position: min(max(level, 0), 1), litScale: true, size: 52)
        } else {
            ZStack {
                Circle().strokeBorder(Theme.ink, lineWidth: 1).frame(width: 40, height: 40)
                Image(systemName: model.symbol)
                    .font(.system(size: 17, weight: .light))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 52, height: 52)
        }
    }
}

/// A level drawn as a ruler: a hairline with ticks, filled up to the value.
private struct LevelRuler: View {
    let level: Double

    var body: some View {
        Canvas { ctx, size in
            let x = (size.width * CGFloat(min(max(level, 0), 1))).rounded()
            var track = Path()
            track.move(to: CGPoint(x: 0, y: 1.5))
            track.addLine(to: CGPoint(x: size.width, y: 1.5))
            ctx.stroke(track, with: .color(Theme.ink.opacity(0.26)), lineWidth: 1)
            var filled = Path()
            filled.move(to: CGPoint(x: 0, y: 1.5))
            filled.addLine(to: CGPoint(x: x, y: 1.5))
            ctx.stroke(filled, with: .color(Theme.ink), lineWidth: 3)
            let count = 20
            for i in 0...count {
                let tx = (size.width - 1) * CGFloat(i) / CGFloat(count)
                var tick = Path()
                tick.move(to: CGPoint(x: tx.rounded() + 0.5, y: 5))
                tick.addLine(to: CGPoint(x: tx.rounded() + 0.5, y: i % 5 == 0 ? 10 : 8))
                ctx.stroke(tick, with: .color(Theme.ink.opacity(tx <= x ? 0.7 : 0.26)), lineWidth: 1)
            }
        }
        .frame(height: 11)
    }
}

/// Small non-activating overlay that confirms mode changes and levels.
final class HUDController {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var hosting: NSHostingView<HUDView>?
    private var hideWork: DispatchWorkItem?

    var settings: () -> KnobCore.Settings = { KnobCore.Settings() }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 290, height: 76),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.animationBehavior = .none
        let host = NSHostingView(rootView: HUDView(model: model))
        p.contentView = host
        hosting = host
        panel = p
        return p
    }

    func show(symbol: String, title: String, subtitle: String? = nil, level: Double? = nil,
              dotIndex: Int = 0, dotCount: Int = 0) {
        let s = settings()
        guard s.showHUD else { return }
        model.symbol = symbol
        model.title = title
        model.subtitle = subtitle
        model.level = level
        model.dotIndex = dotIndex
        model.dotCount = dotCount

        let p = ensurePanel()
        let size = hosting?.fittingSize ?? NSSize(width: 290, height: 76)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 90)
        switch s.hudPosition {
        case .bottomCenter: break
        case .topCenter: origin.y = frame.maxY - size.height - 24
        case .center: origin.y = frame.midY - size.height / 2
        case .topRight: origin = NSPoint(x: frame.maxX - size.width - 20, y: frame.maxY - size.height - 20)
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.3, s.hudDuration), execute: work)
    }

    /// Test hook: writes what the HUD currently shows to a PNG.
    func debugSnapshot(to url: URL) {
        guard let host = hosting else { return }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func hide() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A newer show() may have fired while fading out.
            if self?.hideWork?.isCancelled == false, p.alphaValue == 0 { p.orderOut(nil) }
        })
    }
}
