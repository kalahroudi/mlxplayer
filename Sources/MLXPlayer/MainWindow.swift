import SwiftUI
import MLXPlayerCore

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav

    var body: some View {
        Group {
            if model.showSetup {
                SetupView()
            } else {
                HStack(spacing: 0) {
                    Sidebar()
                    Divider()
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottomTrailing) { ToastHost() }
        .onChange(of: model.app.appearance, initial: true) { _, mode in Self.apply(mode) }
    }

    /// Applies the chosen look to every window and the menu bar popover.
    static func apply(_ mode: AppSettings.Appearance) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @ViewBuilder private var content: some View {
        switch nav.screen {
        case .overview: OverviewView()
        case .chat: ChatView()
        case .server: ServerView()
        case .library: LibraryView()
        case .discover: DiscoverView()
        case .advisor: AdvisorView()
        case .memory: MemoryView()
        case .usage: UsageView()
        case .logs: LogsView()
        case .settings: SettingsView()
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav

    var body: some View {
        let collapsed = model.app.sidebarCollapsed
        return VStack(alignment: collapsed ? .center : .leading, spacing: 2) {
            HStack(spacing: 8) {
                if collapsed {
                    AppMark(size: 26)
                } else {
                    AppMark(size: 26)
                    Text("MLX Player").font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, collapsed ? 0 : 10).padding(.bottom, 14).padding(.top, 6)

            ForEach(Screen.allCases) { screen in
                Button { nav.screen = screen } label: {
                    HStack(spacing: 10) {
                        Image(systemName: screen.symbol).font(.system(size: 14)).frame(width: 18)
                            .foregroundStyle(nav.screen == screen ? Color.accentIndigo : .secondary)
                        if !collapsed {
                            Text(screen.title).lineLimit(1)
                            Spacer()
                            if screen == .library, !model.installed.isEmpty {
                                Chip(text: "\(model.installed.count)")
                            }
                        }
                    }
                    .font(.system(size: 13, weight: nav.screen == screen ? .semibold : .regular))
                    .padding(.horizontal, collapsed ? 0 : 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(nav.screen == screen ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(screen.title)
            }
            Spacer()
            if !collapsed { statusCard } else { StatusDot(color: model.isRunning ? .good : (model.serverState.isStarting ? .warn : .secondary)).padding(.bottom, 8) }
            footer(collapsed)
        }
        .padding(collapsed ? 8 : 12)
        .frame(width: collapsed ? 64 : 210)
        .background(Color.primary.opacity(0.025))
        .animation(.easeOut(duration: 0.16), value: collapsed)
    }

    /// Collapse toggle and a quick light/dark switch.
    private func footer(_ collapsed: Bool) -> some View {
        let mode = model.app.appearance
        let next: AppSettings.Appearance = mode == .system ? .light : (mode == .light ? .dark : .system)
        let symbol = mode == .system ? "circle.lefthalf.filled" : (mode == .light ? "sun.max" : "moon")
        return (collapsed ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))) {
            Button { model.app.sidebarCollapsed.toggle() } label: {
                Image(systemName: collapsed ? "sidebar.right" : "sidebar.left").font(.system(size: 14))
            }.help(collapsed ? "Expand menu" : "Collapse menu")
            Button { model.app.appearance = next } label: { Image(systemName: symbol).font(.system(size: 14)) }
                .help("Appearance: \(mode.rawValue.capitalized)")
            if !collapsed { Spacer() }
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .padding(.horizontal, collapsed ? 0 : 6).padding(.top, 6)
    }

    private var statusCard: some View {
        let running = model.isRunning
        return Card(padding: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    StatusDot(color: running ? .good : (model.serverState.isStarting ? .warn : .secondary))
                    Text(running ? "Running" : (model.serverState.isStarting ? "Loading" : "Idle"))
                        .font(.system(size: 12, weight: .semibold))
                }
                if let id = model.activeModelID ?? model.app.lastModelID, model.isRunning || model.installed.contains(where: { $0.id == id }) {
                    Text(ModelMetadata.fromName(id).displayName).font(.system(size: 11.5)).lineLimit(1)
                }
                Text("\(model.draft.host == "0.0.0.0" ? "127.0.0.1" : model.draft.host):\(model.draft.port)")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Title row at the top of every screen.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 22, weight: .bold))
                if let subtitle { Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Standard screen frame: header, optional tab strip, body that fits the window.
struct ScreenFrame<Header: View, Body: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Body
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A list panel that scrolls on its own.
struct ListPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) { content }
        }
        .scrollIndicators(.automatic)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cardStroke))
    }
}

func fitColor(_ v: FitVerdict) -> Color {
    switch v { case .comfortable: return .good; case .tight: return .warn; case .wontFit: return .bad }
}
