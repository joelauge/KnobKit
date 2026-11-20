import AppKit
import Combine
import KnobCore
import SwiftUI

let simulateNotification = Notification.Name("com.knobkit.app.simulate")

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let state = AppState()
    private let hid = HIDWatcher()
    private let tap = InputTap()
    private let hud = HUDController()
    private let lights = LEDFlasher()
    private var runner: ActionRunner!
    private var dispatcher: Dispatcher!

    private var statusItem: NSStatusItem!
    private var menuPanel: MenuPanelController!
    private var window: NSWindow?
    private var permissionTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// Which icon is currently shown ("index/count"), to avoid redrawing it needlessly.
    private var iconKey = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("KnobKit \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") starting")

        // One look everywhere: menus, dialogs and panels follow the black theme.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        hud.settings = { [unowned self] in self.state.config.settings }
        runner = ActionRunner(state: state, hud: hud)
        dispatcher = Dispatcher(state: state, hid: hid, runner: runner, hud: hud)

        state.onConfigChanged = { [unowned self] in
            self.dispatcher.settingsChanged()
            self.updateStatusItem()
        }
        state.onModeChanged = { [unowned self] in self.updateStatusItem() }
        state.onKnobConnected = { [unowned self] device in
            let settings = self.state.config.settings
            guard settings.flashOnConnect, settings.deviceMode == .selected else { return }
            self.lights.flash(device)
        }
        // The active mode also changes when you switch apps, so follow the context itself.
        state.$context
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        tap.handler = { [unowned self] event in self.dispatcher.handle(event) }
        hid.onDevicesChanged = { [unowned self] devices in
            self.state.updateDevices(devices)
            self.state.hidListening = self.hid.isListening
        }
        hid.onRaw = { [weak self] device, usage, value in
            let name = usage == HIDWatcher.usageVolumeUp ? "vol+" : usage == HIDWatcher.usageVolumeDown ? "vol-" : "mute"
            Log.write("  hid \(device.name): \(name) \(value != 0 ? "down" : "up")")
            if value != 0 {
                DispatchQueue.main.async { self?.state.deviceSpoke(device) }
            }
        }

        setupMainMenu()
        setupStatusItem()
        // The first CoreAudio call loads the audio HAL (~150 ms). Do it now, off the main
        // thread, so the first volume tick from the knob is instant.
        DispatchQueue.global(qos: .utility).async { _ = SystemVolume.get() }
        hid.start()
        checkPermissions()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.checkPermissions() }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer

        // Test hook: `KnobKit --send "cw cw press"` drives the engine without hardware.
        // Off unless explicitly enabled, so other processes cannot trigger bindings.
        if CommandLine.arguments.contains("--allow-simulation") || UserDefaults.standard.bool(forKey: "allowSimulation") {
            DistributedNotificationCenter.default().addObserver(forName: simulateNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let text = note.object as? String else { return }
                let tokens = text.split(separator: " ").map(String.init)
                for token in tokens where token.hasPrefix("ui:") { self.handleUICommand(String(token.dropFirst(3))) }
                let knob = tokens.filter { !$0.hasPrefix("ui:") }
                if !knob.isEmpty { self.dispatcher.simulate(knob) }
            }
            Log.write("simulation hook enabled")
        }

        // First run or missing permission: open the setup page instead of hiding in the menu bar.
        // `--configure` opens the window, `--configure=monitor` (devices, feel, general) a page.
        let configure = CommandLine.arguments.first { $0.hasPrefix("--configure") }
        if !AX.isTrusted {
            showConfigurator(.devices)
        } else if let configure {
            switch configure.split(separator: "=").dropFirst().first.map(String.init) {
            case "monitor": showConfigurator(.monitor)
            case "devices": showConfigurator(.devices)
            case "feel": showConfigurator(.feel)
            case "general": showConfigurator(.general)
            default: showConfigurator(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        runner.releaseHeldModifiers()
        state.saveNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showConfigurator(nil)
        return false
    }

    /// Test hook companions to the simulated knob input: open a page or the popover.
    private func handleUICommand(_ command: String) {
        switch command {
        case "popover": togglePopover()
        case "snapshot": snapshotPopover()
        case "shot": snapshotWindow()
        case "flash":
            if let device = state.devices.first(where: { state.isSelected($0) }) { lights.flash(device, force: true) }
        case "hud:mode", "hud:level", "hud:plain":
            // Shows a sample HUD and writes it to hud.png next to the log.
            let url = Log.url.deletingLastPathComponent().appendingPathComponent("hud.png")
            switch command {
            case "hud:mode": hud.show(symbol: "arrow.up.arrow.down", title: "Scroll", subtitle: "Global", dotIndex: 1, dotCount: 5)
            case "hud:level": hud.show(symbol: "speaker.wave.2", title: "Monitor -32.0 dB", subtitle: "Apollo x4", level: 0.47)
            default: hud.show(symbol: "playpause", title: "Play / Pause")
            }
            hud.debugSnapshot(to: url)
        case "icons":
            let url = Log.url.deletingLastPathComponent().appendingPathComponent("menubar-icons.png")
            try? KnobIcon.contactSheet()?.representation(using: .png, properties: [:])?.write(to: url)
        case "global": showConfigurator(.profile(state.config.global.id))
        case "feel": showConfigurator(.feel)
        case "devices": showConfigurator(.devices)
        case "general": showConfigurator(.general)
        case "monitor": showConfigurator(.monitor)
        default:
            // action:<base64 JSON of an Action> runs one action directly, whatever app is in front.
            if command.hasPrefix("action:"),
               let data = Data(base64Encoded: String(command.dropFirst(7))),
               let action = try? JSONDecoder().decode(Action.self, from: data) {
                Log.write("test hook: running \(action.summary)")
                runner.run(action, info: RunInfo())
                return
            }
            if command.hasPrefix("profile:"),
               let p = state.config.profiles.first(where: { $0.name.lowercased().hasPrefix(command.dropFirst(8).lowercased()) }) {
                showConfigurator(.profile(p.id))
            }
        }
    }

    /// Renders the popover's content off screen to a PNG next to the log, so its layout
    /// can be checked without clicking the menu bar.
    private func snapshotPopover() {
        state.refreshContext()
        let host = NSHostingView(rootView: PopoverView(openConfigurator: { _ in }, quit: {}).environmentObject(state))
        let size = host.fittingSize
        let offscreen = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        offscreen.contentView = host
        host.layoutSubtreeIfNeeded()
        offscreen.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = Log.url.deletingLastPathComponent().appendingPathComponent("popover.png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        Log.write("popover snapshot written (\(Int(size.width))x\(Int(size.height)))")
    }

    /// Renders the configurator window's content to a PNG next to the log.
    private func snapshotWindow() {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = Log.url.deletingLastPathComponent().appendingPathComponent("window.png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        Log.write("window snapshot written (\(Int(view.bounds.width))x\(Int(view.bounds.height)))")
    }

    // MARK: Permissions

    private func checkPermissions() {
        let trusted = AX.isTrusted
        if trusted != state.axTrusted { state.axTrusted = trusted }
        if trusted, !tap.isRunning {
            let ok = tap.start()
            Log.write(ok ? "event tap started" : "event tap could not be created")
        } else if !trusted, tap.isRunning {
            tap.stop()
        }
        if tap.isRunning != state.tapRunning { state.tapRunning = tap.isRunning }

        let access = HIDWatcher.access
        if access != state.hidAccess {
            state.hidAccess = access
            if access == .granted, !hid.isListening { hid.start() }
        }
        if hid.isListening != state.hidListening { state.hidListening = hid.isListening }
    }

    // MARK: Status item and popover

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageLeading
        updateStatusItem()

        menuPanel = MenuPanelController { [unowned self] in
            PopoverView(openConfigurator: { [weak self] item in
                self?.menuPanel.close()
                self?.showConfigurator(item)
            }, quit: { NSApp.terminate(nil) })
            .environmentObject(self.state)
        }
        // The panel's height follows its content (modes, bindings, setup notes).
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.menuPanel.isShown else { return }
                DispatchQueue.main.async { self.menuPanel.layout() }
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let settings = state.config.settings
        let context = state.context
        let mode = context.displayMode
        // A knob whose pointer sits on the active mode's tick.
        let index = context.modeOwnerIndex
        let count = context.modeOwner.modes.count
        let key = "\(index)/\(count)"
        if key != iconKey {
            button.image = KnobIcon.image(modeIndex: index, modeCount: count)
            iconKey = key
        }
        button.title = settings.menuBarShowsModeName && settings.enabled ? " " + (mode?.name ?? "") : ""
        button.appearsDisabled = !settings.enabled
        button.toolTip = "KnobKit: \(mode?.name ?? "") mode"
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if !menuPanel.isShown { state.refreshContext() }
        menuPanel.toggle(from: button)
    }

    // MARK: Configurator window

    func showConfigurator(_ item: SidebarItem?) {
        if let item { state.selection = item }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "KnobKit"
            w.backgroundColor = Theme.nsBg
            w.appearance = NSAppearance(named: .darkAqua)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.delegate = self
            let host = NSHostingController(rootView:
                ConfiguratorView(simulate: { [weak self] tokens in self?.dispatcher.simulate(tokens) })
                    .environmentObject(state))
            // Do not let SwiftUI's measured min/ideal size drive the window: a page whose
            // minimum height is large (wrapping text probed at zero width) would otherwise
            // push the whole split view off screen.
            host.sizingOptions = []
            w.contentViewController = host
            w.contentMinSize = NSSize(width: 900, height: 560)
            w.setContentSize(NSSize(width: 1040, height: 720))
            w.center()
            w.setFrameAutosaveName("KnobKitConfigurator")
            window = w
        }
        // A regular activation policy gives the window a Dock icon, ⌘-Tab entry and menus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Do not open with a text field selected.
        window?.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        state.saveNow()
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Main menu (needed for ⌘C / ⌘V / ⌘W in the configurator)

    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About KnobKit", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide KnobKit", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit KnobKit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
