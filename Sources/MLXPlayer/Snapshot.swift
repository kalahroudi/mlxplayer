import SwiftUI
import AppKit

/// Developer tool: `MLXPlayer --snapshot DIR [dark] [screen]` renders screens of the real window to PNG files
/// (no screen-recording permission needed) so layouts can be checked without clicking through the app.
@MainActor
enum Snapshot {
    static func run(args: [String]) async {
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dark = args.contains("dark")
        let collapse = args.contains("collapsed")
        let only = args.compactMap { a in Screen(rawValue: a) }.first

        NSApp.setActivationPolicy(.accessory)
        let model = AppModel()
        let nav = Navigator()
        model.refreshInstalled()
        let wasCollapsed = model.app.sidebarCollapsed
        model.app.sidebarCollapsed = collapse
        defer { model.app.sidebarCollapsed = wasCollapsed }
        let root = MainWindow().environment(model).environment(nav).frame(width: 1240, height: 820)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.orderFrontRegardless()

        for _ in 0..<4 { model.sampleSystem(); try? await Task.sleep(for: .milliseconds(400)) }
        for screen in Screen.allCases where only == nil || only == screen {
            nav.screen = screen
            try? await Task.sleep(for: .seconds(screen == .discover ? 4 : 1.2))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(screen.rawValue)\(dark ? "-dark" : "")\(collapse ? "-collapsed" : "").png"))
            }
        }
    }
}
