import AppKit
import ApplicationServices

/// Accessibility helpers: permission, front window title, and driving menu bar items.
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system dialog pointing at Privacy & Security > Accessibility.
    static func promptForTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    struct MenuNode: Identifiable, Hashable {
        let id = UUID()
        var title: String
        var children: [MenuNode]
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    static func frontWindowTitle(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let window = element(app, kAXFocusedWindowAttribute) else { return nil }
        return string(window, kAXTitleAttribute)
    }

    private static func menuBar(pid: pid_t) -> AXUIElement? {
        guard pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.6)
        return element(app, kAXMenuBarAttribute)
    }

    private static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "…", with: "...").trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Presses a menu item by its title path, e.g. ["View", "Zoom In"].
    static func pressMenuItem(path: [String], pid: pid_t) -> Bool {
        guard !path.isEmpty, var current = menuBar(pid: pid) else { return false }
        for (i, name) in path.enumerated() {
            let wanted = normalize(name)
            guard let item = children(current).first(where: { normalize(string($0, kAXTitleAttribute) ?? "") == wanted })
            else { return false }
            if i == path.count - 1 {
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
            }
            guard let submenu = children(item).first else { return false }
            current = submenu
        }
        return false
    }

    /// The app's menu bar as a tree, for picking a menu item in the configurator.
    static func menuTree(pid: pid_t, depth: Int = 3) -> [MenuNode] {
        guard let bar = menuBar(pid: pid) else { return [] }
        return children(bar).dropFirst().compactMap { node($0, depth: depth) }
    }

    private static func node(_ item: AXUIElement, depth: Int) -> MenuNode? {
        guard let title = string(item, kAXTitleAttribute), !title.isEmpty else { return nil }
        var kids: [MenuNode] = []
        if depth > 0, let submenu = children(item).first {
            kids = children(submenu).compactMap { node($0, depth: depth - 1) }
        }
        return MenuNode(title: title, children: kids)
    }
}
