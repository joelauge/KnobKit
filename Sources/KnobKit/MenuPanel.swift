import AppKit
import SwiftUI

/// Where the stem from the menu bar icon meets the panel.
final class MenuPanelModel: ObservableObject {
    @Published var stemX: CGFloat = 170
}

/// The panel's frame: a short leader line up to the menu bar icon, then the black card.
private struct MenuPanelChrome<Content: View>: View {
    @ObservedObject var model: MenuPanelModel
    let content: Content
    static var stem: CGFloat { 7 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color.clear
                Rectangle().fill(Theme.ink).frame(width: 1, height: Self.stem)
                    .offset(x: model.stemX.rounded())
            }
            .frame(height: Self.stem)
            content
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.ink.opacity(0.34), lineWidth: 1))
        }
    }
}

private final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A borderless panel under the status item. Used instead of NSPopover so the whole
/// surface, edge to edge, is the theme's black rather than the system's material.
final class MenuPanelController: NSObject, NSWindowDelegate {
    private let model = MenuPanelModel()
    private var panel: KeyPanel?
    private var host: NSHostingView<AnyView>?
    private var monitors: [Any] = []
    private weak var button: NSStatusBarButton?
    private let makeContent: () -> AnyView

    init<Content: View>(content: @escaping () -> Content) {
        makeContent = { AnyView(content()) }
    }

    var isShown: Bool { panel?.isVisible == true }

    func toggle(from button: NSStatusBarButton) {
        if isShown { close() } else { show(from: button) }
    }

    private func ensurePanel() -> KeyPanel {
        if let panel { return panel }
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isFloatingPanel = true
        // After isFloatingPanel, which resets the level.
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        p.appearance = NSAppearance(named: .darkAqua)
        p.delegate = self
        p.onCancel = { [weak self] in self?.close() }
        let host = NSHostingView(rootView: AnyView(MenuPanelChrome(model: model, content: makeContent())))
        p.contentView = host
        self.host = host
        panel = p
        return p
    }

    func show(from button: NSStatusBarButton) {
        let p = ensurePanel()
        self.button = button
        layout()
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            p.animator().alphaValue = 1
        }
        button.highlight(true)
        installMonitors()
    }

    func close() {
        removeMonitors()
        button?.highlight(false)
        panel?.orderOut(nil)
    }

    /// Sizes the panel to its content and hangs it under the status item. Call again
    /// whenever the content may have changed height.
    func layout() {
        guard let p = panel, let host, let button, let window = button.window else { return }
        let size = host.fittingSize
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        var x = (anchor.midX - size.width / 2).rounded()
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        // The stem reaches a few points up into the menu bar; the card hangs just under it.
        let top = window.frame.minY + 3
        let frame = NSRect(x: x, y: (top - size.height).rounded(), width: size.width, height: size.height)
        model.stemX = min(max(anchor.midX - x, 14), size.width - 14)
        if p.frame != frame {
            p.setFrame(frame, display: true)
            p.invalidateShadow()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func installMonitors() {
        removeMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.close() }) {
            monitors.append(global)
        }
        // Clicks in our own windows. The status item toggles the panel itself.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel, event.window !== self.button?.window { self.close() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}
