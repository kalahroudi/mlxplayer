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

extension Notification.Name { static let openMainWindow = Notification.Name("MLXPlayer.openMainWindow") }

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: .openMainWindow, object: nil) }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only; also covers `swift run` where Info.plist has no LSUIElement.
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--snapshot") {
            Task { @MainActor in
                await Snapshot.run(args: CommandLine.arguments)
                exit(0)
            }
        }
    }
}

@main
struct MLXPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @State private var nav = Navigator()

    init() {
        // Build-time helper: `MLXPlayer --write-iconset DIR` renders the app icon, then exits.
        let args = CommandLine.arguments
        // The updater runs this on a freshly built app before replacing the installed one.
        if args.contains("--self-test") {
            print("ok \(Bundle.main.object(forInfoDictionaryKey: "MLXCommit") as? String ?? "unknown")")
            exit(0)
        }
        if let i = args.firstIndex(of: "--write-iconset"), i + 1 < args.count {
            writeIconSet(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(model)
                .environment(nav)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("MLX Player", id: "main") {
            MainWindow()
                .onAppear { DockPresence.show() }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                    guard (note.object as? NSWindow)?.title == "MLX Player" else { return }
                    DispatchQueue.main.async { DockPresence.hideIfNoWindows() }
                }
                .environment(model)
                .environment(nav)
                .frame(minWidth: 1100, minHeight: 740)
        }
        .defaultSize(width: 1240, height: 820)
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: Brand.menuBarImage(dim: !model.isRunning && !model.serverState.isStarting,
                                              loading: model.serverState.isStarting,
                                              attention: model.lastError != nil))
            if let text = model.menuBarText { Text(text).monospacedDigit() }
        }
        .task {
            model.launch()
            if model.showSetup { show() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in show() }
    }

    private func show() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Opens the main window on a screen. Used by the popover.
@MainActor
func openMain(_ screen: Screen?, nav: Navigator, open: OpenWindowAction) {
    if let screen { nav.screen = screen }
    DockPresence.show()
    open(id: "main")
    NSApp.activate(ignoringOtherApps: true)
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
