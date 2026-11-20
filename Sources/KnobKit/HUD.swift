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

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: model.symbol)
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 38, height: 38)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 5) {
                Text(model.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let level = model.level {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.15))
                            Capsule().fill(.primary.opacity(0.85))
                                .frame(width: max(4, geo.size.width * level))
                        }
                    }
                    .frame(height: 5)
                }
                if model.dotCount > 1 {
                    HStack(spacing: 5) {
                        ForEach(0..<model.dotCount, id: \.self) { i in
                            Capsule()
                                .fill(.primary.opacity(i == model.dotIndex ? 0.9 : 0.22))
                                .frame(width: i == model.dotIndex ? 14 : 5, height: 5)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 280)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
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
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 70),
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
        let size = hosting?.fittingSize ?? NSSize(width: 280, height: 70)
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
