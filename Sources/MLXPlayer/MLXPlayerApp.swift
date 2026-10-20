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
