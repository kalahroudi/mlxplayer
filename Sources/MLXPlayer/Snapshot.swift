import SwiftUI
import AppKit
import MLXPlayerCore

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
        let format = ModelFormat.allCases.first { args.contains($0.rawValue) && $0 != .mlx }
        let only = args.compactMap { a in Screen(rawValue: a) }.first

        NSApp.setActivationPolicy(.accessory)
        let model = AppModel()
        let nav = Navigator()
        model.refreshInstalled()
        let wasCollapsed = model.app.sidebarCollapsed
        model.app.sidebarCollapsed = collapse
        defer { model.app.sidebarCollapsed = wasCollapsed }
        if let format { model.filter.format = format }
        if args.contains("popover") {
            let pop = NSHostingView(rootView: PopoverView().environment(model).environment(nav).background(Color(nsColor: .windowBackgroundColor)))
            pop.frame = NSRect(x: 0, y: 0, width: 340, height: pop.fittingSize.height)
            let w = NSWindow(contentRect: pop.frame, styleMask: [.titled], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.contentView = pop
            w.orderFrontRegardless()
            for _ in 0..<4 { model.sampleSystem(); try? await Task.sleep(for: .milliseconds(400)) }
            pop.frame = NSRect(x: 0, y: 0, width: 340, height: pop.fittingSize.height)
            pop.layoutSubtreeIfNeeded()
            if let rep = pop.bitmapImageRepForCachingDisplay(in: pop.bounds) {
                pop.cacheDisplay(in: pop.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("popover\(dark ? "-dark" : "").png"))
            }
            return
        }
        let root = MainWindow().environment(model).environment(nav).frame(width: 1240, height: 820)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.orderFrontRegardless()

        if args.contains("toast") {
            model.notify(.success, "Download complete", detail: "Qwen3-8B-4bit", action: "Open library", screen: .library)
            model.notify(.error, "Model failed to start", detail: "Not enough memory for 128K context. Try a smaller model.", action: "Show logs", screen: .logs)
        }
        for _ in 0..<4 { model.sampleSystem(); try? await Task.sleep(for: .milliseconds(400)) }
        for screen in Screen.allCases where only == nil || only == screen {
            nav.screen = screen
            try? await Task.sleep(for: .seconds(screen == .discover ? 4 : 1.2))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(screen.rawValue)\(dark ? "-dark" : "")\(collapse ? "-collapsed" : "")\(format.map { "-" + $0.rawValue } ?? "")\(args.contains("toast") ? "-toast" : "").png"))
            }
        }
    }
}
