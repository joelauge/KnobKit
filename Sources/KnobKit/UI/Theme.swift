import AppKit
import SwiftUI

/// The look of every KnobKit surface: matte black, warm cream ink, one-pixel lines.
/// It follows the quick-guide card that ships in the F75's box: outline drawings,
/// leader lines from a part to its label, a wide heavy title face.
enum Theme {
    /// One background everywhere, so outlined controls can sit on any surface.
    static let bg = Color(red: 0.039, green: 0.039, blue: 0.043)
    static let nsBg = NSColor(srgbRed: 0.039, green: 0.039, blue: 0.043, alpha: 1)
    /// Hover and inset fill.
    static let raised = Color(red: 0.09, green: 0.087, blue: 0.08)
    /// The cream of the card's print.
    static let ink = Color(red: 0.925, green: 0.863, blue: 0.722)
    /// Secondary text. Still readable on `bg` (about 6:1).
    static var ink2: Color { ink.opacity(0.64) }
    /// Placeholders and quiet marks, not body text.
    static var ink3: Color { ink.opacity(0.42) }
    /// Structure: rules, panel outlines, leader lines.
    static var line: Color { ink.opacity(0.2) }
    /// Control outlines at rest.
    static var lineStrong: Color { ink.opacity(0.46) }
    /// The one colour: something needs attention.
    static let warn = Color(red: 0.98, green: 0.52, blue: 0.3)
    static let radius: CGFloat = 4
}

extension Font {
    /// Wide heavy face for titles and the active mode, after the card's headline.
    static func kkDisplay(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy).width(.expanded) }
    static var kkEyebrow: Font { .system(size: 10, weight: .semibold).width(.expanded) }
    static var kkCaption: Font { .system(size: 11.5) }
    static var kkMono: Font { .system(size: 11.5, design: .monospaced) }
}

extension View {
    /// Applied once at the root of each surface (popover, configurator, HUD).
    func kkRoot() -> some View {
        self
            .buttonStyle(KKButtonStyle())
            .toggleStyle(KKCheckStyle())
            .textFieldStyle(KKFieldStyle())
            .font(.system(size: 13))
            .foregroundStyle(Theme.ink)
            .tint(Theme.ink)
            .environment(\.colorScheme, .dark)
    }

    /// One-pixel outline in the theme's corner radius.
    func kkOutline(_ color: Color = Theme.line, radius: CGFloat = Theme.radius) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(color, lineWidth: 1))
    }
}

// MARK: - Lines and labels

/// Horizontal one-pixel rule.
struct Rule: View {
    var color = Theme.line
    var body: some View { Rectangle().fill(color).frame(height: 1) }
}

struct VRule: View {
    var color = Theme.line
    var body: some View { Rectangle().fill(color).frame(width: 1) }
}

/// A rule that stretches between a label and its value, like the card's leader lines.
struct Leader: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1).frame(minWidth: 10, maxWidth: .infinity)
    }
}

/// Small wide capitals for section and field labels.
struct Eyebrow: View {
    let text: String
    var color = Theme.ink2

    init(_ text: String, color: Color = Theme.ink2) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased()).font(.kkEyebrow).tracking(1.1).foregroundStyle(color).lineLimit(1)
    }
}

/// Help and explanation text.
struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.kkCaption).foregroundStyle(Theme.ink2).lineSpacing(2)
    }
}

// MARK: - Buttons

struct KKButtonStyle: ButtonStyle {
    enum Kind { case outline, solid, ghost, icon }
    var kind: Kind = .outline
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        KKButtonBody(configuration: configuration, kind: kind, small: small)
    }
}

private struct KKButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: KKButtonStyle.Kind
    let small: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    private var destructive: Bool { configuration.role == .destructive }
    private var base: Color { destructive ? Theme.warn : Theme.ink }

    private var foreground: Color {
        switch kind {
        case .solid: return Theme.bg
        case .icon, .ghost: return hover || configuration.isPressed ? base : base.opacity(0.7)
        case .outline: return base
        }
    }

    private var fill: Color {
        switch kind {
        case .solid: return base.opacity(configuration.isPressed ? 0.8 : 1)
        case .outline, .ghost, .icon:
            return configuration.isPressed ? base.opacity(0.16) : (hover ? Theme.raised : .clear)
        }
    }

    private var stroke: Color {
        switch kind {
        case .outline: return hover ? base : base.opacity(0.46)
        default: return .clear
        }
    }

    var body: some View {
        let height: CGFloat = small ? 22 : 26
        configuration.label
            .font(.system(size: small ? 11.5 : 12.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, kind == .icon ? 0 : (small ? 9 : 12))
            .frame(width: kind == .icon ? height : nil, height: height)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(stroke, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.35)
            .onHover { hover = $0 }
    }
}

extension ButtonStyle where Self == KKButtonStyle {
    static var kk: KKButtonStyle { KKButtonStyle() }
    static var kkSmall: KKButtonStyle { KKButtonStyle(small: true) }
    static var kkSolid: KKButtonStyle { KKButtonStyle(kind: .solid) }
    static var kkGhost: KKButtonStyle { KKButtonStyle(kind: .ghost, small: true) }
    static var kkIcon: KKButtonStyle { KKButtonStyle(kind: .icon, small: true) }
}

/// A selectable chip: outlined at rest, filled cream when selected.
struct Chip<Label: View>: View {
    var selected: Bool
    var action: () -> Void
    @ViewBuilder var label: Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .foregroundStyle(selected ? Theme.bg : Theme.ink)
                .background(RoundedRectangle(cornerRadius: Theme.radius)
                    .fill(selected ? Theme.ink : (hover ? Theme.raised : .clear)))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(selected ? Theme.ink : (hover ? Theme.ink : Theme.lineStrong), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Toggles

/// Outlined box with a cream block inside when on. The default toggle.
struct KKCheckStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { KKCheckBody(configuration: configuration) }
}

private struct KKCheckBody: View {
    let configuration: ToggleStyle.Configuration
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(configuration.isOn ? Theme.ink : Theme.lineStrong, lineWidth: 1)
                    if configuration.isOn {
                        RoundedRectangle(cornerRadius: 1.5).fill(Theme.ink).padding(3)
                    }
                }
                .frame(width: 14, height: 14)
                configuration.label.foregroundStyle(Theme.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// Thin-line switch: a hollow thumb when off, a solid one when on.
struct KKSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { KKSwitchBody(configuration: configuration) }
}

private struct KKSwitchBody: View {
    let configuration: ToggleStyle.Configuration
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.16)) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 9) {
                configuration.label.foregroundStyle(Theme.ink2)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().strokeBorder(configuration.isOn ? Theme.ink : Theme.lineStrong, lineWidth: 1)
                    Group {
                        if configuration.isOn {
                            Circle().fill(Theme.ink)
                        } else {
                            Circle().strokeBorder(Theme.lineStrong, lineWidth: 1)
                        }
                    }
                    .frame(width: 10, height: 10)
                    .padding(.horizontal, 4)
                }
                .frame(width: 34, height: 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// Square on / off key for one symbol, such as a modifier.
struct KeyToggle: View {
    let text: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(isOn ? Theme.bg : Theme.ink)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(isOn ? Theme.ink : .clear))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(isOn ? Theme.ink : Theme.lineStrong, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Radio row: a ring with a dot.
struct RadioRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().strokeBorder(selected ? Theme.ink : Theme.lineStrong, lineWidth: 1)
                    if selected { Circle().fill(Theme.ink).padding(4) }
                }
                .frame(width: 14, height: 14)
                Text(title)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Fields

struct KKFieldStyle: TextFieldStyle {
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.raised.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.lineStrong, lineWidth: 1))
    }
}

/// − / + pair for stepping a number.
struct KKStepper<V: Strideable>: View {
    var label: String?
    @Binding var value: V
    let range: ClosedRange<V>
    var step: V.Stride = 1

    init(_ label: String? = nil, value: Binding<V>, in range: ClosedRange<V>, step: V.Stride = 1) {
        self.label = label
        _value = value
        self.range = range
        self.step = step
    }

    private func bump(_ by: V.Stride) {
        value = min(max(value.advanced(by: by), range.lowerBound), range.upperBound)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let label { Text(label).monospacedDigit() }
            HStack(spacing: 0) {
                key("minus") { bump(-step) }.disabled(value <= range.lowerBound)
                VRule(color: Theme.lineStrong).frame(height: 24)
                key("plus") { bump(step) }.disabled(value >= range.upperBound)
            }
            .kkOutline(Theme.lineStrong)
        }
    }

    private func key(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
        }
        .buttonStyle(.kkIcon)
    }
}

/// Number box with a stepper.
struct NumberField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var decimals = 0
    var width: CGFloat = 58

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: $value, format: .number.precision(.fractionLength(0...decimals)))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: width)
            KKStepper(value: $value, in: range, step: step)
        }
    }
}

/// Segmented choice with hairline dividers.
struct Segmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, title: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 { VRule(color: Theme.lineStrong).frame(height: 24) }
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: selection == option.value ? .semibold : .regular))
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .foregroundStyle(selection == option.value ? Theme.bg : Theme.ink)
                        .background(selection == option.value ? Theme.ink : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .kkOutline(Theme.lineStrong)
        .fixedSize()
    }
}

// MARK: - Slider

/// A ruler: hairline track with tick marks and a ring for a thumb.
struct KKSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    @State private var dragging = false
    @State private var hover = false

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 0) {
        _value = value
        self.range = range
        self.step = step
    }

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private func set(_ x: CGFloat, width: CGFloat, inset: CGFloat) {
        let usable = max(width - inset * 2, 1)
        let f = Double(min(max((x - inset) / usable, 0), 1))
        var v = range.lowerBound + f * (range.upperBound - range.lowerBound)
        if step > 0 { v = (v / step).rounded() * step }
        value = min(max(v, range.lowerBound), range.upperBound)
    }

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 6
            let width = geo.size.width
            let x = (inset + (width - inset * 2) * fraction).rounded()
            let y: CGFloat = 7.5
            Canvas { ctx, size in
                // Track, brighter up to the thumb.
                var track = Path()
                track.move(to: CGPoint(x: inset, y: y))
                track.addLine(to: CGPoint(x: size.width - inset, y: y))
                ctx.stroke(track, with: .color(Theme.ink.opacity(0.3)), lineWidth: 1)
                var filled = Path()
                filled.move(to: CGPoint(x: inset, y: y))
                filled.addLine(to: CGPoint(x: x, y: y))
                ctx.stroke(filled, with: .color(Theme.ink), lineWidth: 1)
                // Ruler ticks under the track.
                let count = 40
                for i in 0...count {
                    let tx = (inset + (size.width - inset * 2) * CGFloat(i) / CGFloat(count)).rounded() + 0.5
                    let major = i % 10 == 0
                    var tick = Path()
                    tick.move(to: CGPoint(x: tx, y: y + 4))
                    tick.addLine(to: CGPoint(x: tx, y: y + (major ? 9 : 6)))
                    ctx.stroke(tick, with: .color(Theme.ink.opacity(tx <= x + 1 ? 0.7 : 0.3)), lineWidth: 1)
                }
                // Thumb.
                let r: CGFloat = dragging ? 5.5 : 5
                let thumb = Path(ellipseIn: CGRect(x: x - r + 0.5, y: y - r, width: r * 2, height: r * 2))
                ctx.fill(thumb, with: .color(dragging || hover ? Theme.ink : Theme.bg))
                ctx.stroke(thumb, with: .color(Theme.ink), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    dragging = true
                    set(g.location.x, width: width, inset: inset)
                }
                .onEnded { _ in dragging = false })
            .onHover { hover = $0 }
        }
        .frame(height: 18)
    }
}

// MARK: - Menus

/// One entry of a pop-up menu built by `KKMenu` / `KKPicker`.
enum KKMenuItem {
    case action(String, checked: Bool = false, destructive: Bool = false, enabled: Bool = true, run: () -> Void)
    case submenu(String, [KKMenuItem])
    case header(String)
    case separator
}

private final class ClosureMenuItem: NSMenuItem {
    private var run: (() -> Void)?

    convenience init(title: String, run: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.run = run
        target = self
    }

    @objc private func fire() { run?() }
}

private func buildMenu(_ items: [KKMenuItem]) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for item in items {
        switch item {
        case .action(let title, let checked, let destructive, let enabled, let run):
            let entry = ClosureMenuItem(title: title, run: run)
            entry.state = checked ? .on : .off
            entry.isEnabled = enabled
            if destructive {
                entry.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
            }
            menu.addItem(entry)
        case .submenu(let title, let children):
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            entry.submenu = buildMenu(children)
            menu.addItem(entry)
        case .header(let title):
            menu.addItem(.sectionHeader(title: title))
        case .separator:
            menu.addItem(.separator())
        }
    }
    return menu
}

/// Remembers the AppKit view a menu should drop from.
final class MenuAnchor {
    weak var view: NSView?

    func pop(_ items: [KKMenuItem]) {
        let menu = buildMenu(items)
        guard let view, view.window != nil else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        // Just under the control's bottom-left corner.
        let point = view.isFlipped ? NSPoint(x: 0, y: view.bounds.height + 4) : NSPoint(x: 0, y: -4)
        menu.popUp(positioning: nil, at: point, in: view)
    }
}

private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}

/// A button in the theme's style that drops a system menu.
struct KKMenu<Label: View>: View {
    private let kind: KKButtonStyle.Kind
    private let small: Bool
    private let items: () -> [KKMenuItem]
    private let label: Label
    @State private var anchor = MenuAnchor()

    init(kind: KKButtonStyle.Kind = .outline, small: Bool = false,
         items: @escaping () -> [KKMenuItem], @ViewBuilder label: () -> Label) {
        self.kind = kind
        self.small = small
        self.items = items
        self.label = label()
    }

    var body: some View {
        Button {
            anchor.pop(items())
        } label: {
            label
        }
        .buttonStyle(KKButtonStyle(kind: kind, small: small))
        .background(MenuAnchorView(anchor: anchor))
        .fixedSize()
    }
}

struct KKMenuLabel: View {
    let title: String
    var systemImage: String?
    var chevron = "chevron.down"

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .medium)) }
            Text(title)
            Image(systemName: chevron).font(.system(size: 7.5, weight: .bold)).opacity(0.6)
        }
    }
}

extension KKMenu where Label == KKMenuLabel {
    init(_ title: String, systemImage: String? = nil, kind: KKButtonStyle.Kind = .outline, small: Bool = false,
         items: @escaping () -> [KKMenuItem]) {
        self.init(kind: kind, small: small, items: items) {
            KKMenuLabel(title: title, systemImage: systemImage)
        }
    }
}

/// Pop-up choice: shows the current value, drops a menu with the options.
struct KKPicker<T: Hashable>: View {
    @Binding var selection: T
    let groups: [(title: String?, options: [(value: T, title: String)])]

    init(selection: Binding<T>, options: [(value: T, title: String)]) {
        _selection = selection
        groups = [(nil, options)]
    }

    init(selection: Binding<T>, groups: [(title: String?, options: [(value: T, title: String)])]) {
        _selection = selection
        self.groups = groups
    }

    private var current: String {
        for group in groups {
            if let hit = group.options.first(where: { $0.value == selection }) { return hit.title }
        }
        return ""
    }

    private func items() -> [KKMenuItem] {
        var out: [KKMenuItem] = []
        for group in groups {
            if let title = group.title { out.append(.header(title)) }
            for option in group.options {
                out.append(.action(option.title, checked: option.value == selection) { selection = option.value })
            }
        }
        return out
    }

    var body: some View {
        KKMenu(items: items) {
            KKMenuLabel(title: current, chevron: "chevron.up.chevron.down")
        }
    }
}

// MARK: - Panels

/// A section drawn like a drawing's title block: a hairline frame whose label sits on
/// the top edge, with an optional control on the same edge at the right.
struct Card<Content: View>: View {
    private let title: String?
    private let warning: Bool
    private let accessory: AnyView?
    private let content: Content

    init(title: String? = nil, warning: Bool = false, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.warning = warning
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(.horizontal, 16)
            .padding(.top, title == nil && accessory == nil ? 14 : 20)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if let title {
                    HStack(spacing: 6) {
                        Eyebrow(title, color: Theme.ink)
                        if warning {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.warn)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 14)
                    .background(Theme.bg)
                    .offset(x: 9, y: -7)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let accessory {
                    accessory
                        .padding(.horizontal, 6)
                        .background(Theme.bg)
                        .offset(x: -9, y: -11)
                }
            }
            .padding(.top, 8)
    }
}
