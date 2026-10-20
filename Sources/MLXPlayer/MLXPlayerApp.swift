import SwiftUI
import AppKit
import MLXPlayerCore

enum Screen: String, CaseIterable, Identifiable {
    case overview, chat, server, library, discover, advisor, memory, usage, logs, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .chat: return "bubble.left.and.bubble.right"
        case .server: return "server.rack"
        case .library: return "books.vertical"
        case .discover: return "magnifyingglass"
        case .advisor: return "wand.and.stars"
        case .memory: return "memorychip"
        case .usage: return "chart.bar"
        case .logs: return "text.alignleft"
        case .settings: return "gearshape"
        }
    }
}

@MainActor @Observable
final class Navigator {
    var screen: Screen = .overview
    var settingsTab: SettingsView.Tab = .general
}

/// Owns the menu bar item, its popover and the main window. A real `NSStatusItem` + `NSPopover` gives the
/// standard arrow attached to the icon; SwiftUI's `MenuBarExtra` window style draws a detached panel instead.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    static let shared = AppController()
    let model = AppModel()
    let nav = Navigator()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only until a window opens; also covers `swift run` where Info.plist has no LSUIElement.
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--snapshot") {
            Task { @MainActor in
                await Snapshot.run(args: CommandLine.arguments)
                exit(0)
            }
            return
        }
        setUpStatusItem()
        model.launch()
        if model.showSetup { showMain() }
        // Scripted check: MLX_SHOW_POPOVER=1 opens the popover and writes where it landed.
        if ProcessInfo.processInfo.environment["MLX_SHOW_POPOVER"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                togglePopover(nil)
                try? await Task.sleep(nanoseconds: 800_000_000)
                let w = popover.contentViewController?.view.window
                let b = statusItem?.button?.window?.frame
                let line = "shown=\(popover.isShown) popover=\(String(describing: w?.frame)) button=\(String(describing: b)) size=\(popover.contentSize)\n"
                try? line.write(toFile: NSTemporaryDirectory() + "mlx-popover.txt", atomically: true, encoding: .utf8)
            }
        }
    }

    /// Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMain() }
        return true
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.imagePosition = .imageLeading

        let host = NSHostingController(rootView: PopoverView().environment(model).environment(nav))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        refreshStatusItem()
    }

    /// Re-reads the model whenever what the icon shows changes (Observation drives it, no polling).
    private func refreshStatusItem() {
        let state = withObservationTracking {
            (model.isRunning, model.serverState.isStarting, model.lastError != nil, model.menuBarText, model.app.appearance)
        } onChange: { [weak self] in
            Task { @MainActor in self?.refreshStatusItem() }
        }
        MainWindow.apply(state.4)
        guard let button = statusItem?.button else { return }
        button.image = Brand.menuBarImage(dim: !state.0 && !state.1, loading: state.1, attention: state.2)
        if let text = state.3 {
            button.attributedTitle = NSAttributedString(string: " " + text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
        } else {
            button.title = ""
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender); return }
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() { if popover.isShown { popover.performClose(nil) } }

    // MARK: Main window

    func showMain(_ screen: Screen? = nil) {
        if let screen { nav.screen = screen }
        closePopover()
        DockPresence.show()
        if mainWindow == nil {
            let hosting = NSHostingController(rootView: MainWindow().environment(model).environment(nav).frame(minWidth: 1100, minHeight: 740))
            let window = NSWindow(contentViewController: hosting)
            window.title = "MLX Player"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1240, height: 820))
            window.center()
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("MLXPlayerMain")
            window.delegate = self
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { DockPresence.hideIfNoWindows() }
    }
}

/// Plain AppKit entry point. SwiftUI's `App` would add a placeholder Settings window nobody asked for.
@main
enum MLXPlayerMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        // The updater runs this on a freshly built app before replacing the installed one.
        if args.contains("--self-test") {
            print("ok \(Bundle.main.object(forInfoDictionaryKey: "MLXCommit") as? String ?? "unknown")")
            exit(0)
        }
        // Build-time helper: `MLXPlayer --write-iconset DIR` renders the app icon, then exits.
        if let i = args.firstIndex(of: "--write-iconset"), i + 1 < args.count {
            writeIconSet(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        let app = NSApplication.shared
        app.delegate = AppController.shared
        app.mainMenu = makeMainMenu()
        app.run()
    }

    /// Edit and Window menus so copy/paste and Cmd-W keep working in text fields and the main window.
    @MainActor private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func entry(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        add("MLX Player", [entry("Hide MLX Player", #selector(NSApplication.hide(_:)), "h"),
                           .separator(),
                           entry("Quit MLX Player", #selector(NSApplication.terminate(_:)), "q")])
        add("Edit", [entry("Undo", Selector(("undo:")), "z"),
                     entry("Redo", Selector(("redo:")), "z", [.command, .shift]),
                     .separator(),
                     entry("Cut", #selector(NSText.cut(_:)), "x"),
                     entry("Copy", #selector(NSText.copy(_:)), "c"),
                     entry("Paste", #selector(NSText.paste(_:)), "v"),
                     entry("Select All", #selector(NSText.selectAll(_:)), "a")])
        add("Window", [entry("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                       entry("Close", #selector(NSWindow.performClose(_:)), "w")])
        return main
    }
}

/// Opens the main window on a screen. Used by the popover.
@MainActor
func openMain(_ screen: Screen?, nav: Navigator, open: Any? = nil) {
    AppController.shared.showMain(screen)
}

/// A menu bar app that also appears in the Dock (and Cmd-Tab) while its window is open.
@MainActor
enum DockPresence {
    static func show() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.applicationIconImage = Brand.appIconImage(size: 512)
        }
    }

    /// Back to menu-bar-only once the last real window closes.
    static func hideIfNoWindows() {
        let open = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) && $0.level == .normal }
        if !open { NSApp.setActivationPolicy(.accessory) }
    }
}

extension ServerState {
    var isStarting: Bool { if case .starting = self { return true } else { return false } }
    /// Detail text while loading, e.g. "Loading weights".
    var startingDetail: String? { if case .starting(let s) = self { return s } else { return nil } }
}

/// Writes the PNG sizes `iconutil` needs for an .icns.
func writeIconSet(to dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sizes: [(String, CGFloat)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, px) in sizes {
        let image = Brand.appIconImage(size: px)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
