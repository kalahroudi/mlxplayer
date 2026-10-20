import SwiftUI
import AppKit
import MLXPlayerCore

enum Screen: String, CaseIterable, Identifiable {
    case server, library, discover, advisor, memory, usage, logs, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
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
    var screen: Screen = .server
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only; also covers `swift run` where Info.plist has no LSUIElement.
        NSApp.setActivationPolicy(.accessory)
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
                .environment(model)
                .environment(nav)
                .frame(minWidth: 1100, minHeight: 740)
                .preferredColorScheme(nil)
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
    open(id: "main")
    NSApp.activate(ignoringOtherApps: true)
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
