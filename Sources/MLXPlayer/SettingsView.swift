import SwiftUI
import ServiceManagement
import MLXPlayerCore

struct SettingsView: View {
    enum Tab: Hashable { case general, agents, mlx, updates }
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav
    private var tab: Binding<Tab> { Binding(get: { nav.settingsTab }, set: { nav.settingsTab = $0 }) }
    @State private var statuses: [AgentStatus] = []
    @State private var busy: AgentKind?
    @State private var restartHint: AgentKind?
    @State private var agentError: String?
    private let server = AgentIntegrations.serverPath()
    @State private var tokenDraft = ""
    @State private var tokenSaved = HFToken.isSaved

    private let tools: [(String, String)] = [
        ("get_hardware", "Chip, memory, limits"), ("search_models", "Search Hugging Face"),
        ("analyze_model", "Will it fit?"), ("recommend_models", "Best for a job"),
        ("get_status", "Server state and speed"), ("download_model", "Download, with approval"),
        ("start_server", "Load a model"), ("update_settings", "Change saved settings"),
        ("stop_server", "Unload"), ("delete_model", "Always asks"),
    ]

    var body: some View {
        ScreenFrame {
            PageHeader(title: "Settings") { HelpButton(title: "Settings", entries: HelpContent.settings) }
        } content: {
            TabStrip(options: [(Tab.general, "General"), (.agents, "Agents (MCP)"), (.mlx, "mlx-lm"), (.updates, "Updates")],
                     selection: tab)
            switch nav.settingsTab {
            case .general: general
            case .agents: agents
            case .mlx: mlx
            case .updates: UpdatesPane()
            }
            Spacer(minLength: 0)
        }
    }

    private var general: some View {
        @Bindable var model = model
        return Card {
            VStack(spacing: 0) {
                SettingRow(title: "Menu bar shows") {
                    Dropdown(options: [(AppSettings.MenuBarDisplay.speed, "Speed"), (.memory, "Memory"), (.iconOnly, "Icon only")],
                             selection: $model.app.menuBarDisplay, width: 120)
                }
                SettingRow(title: "Appearance") {
                    Segmented(options: [(AppSettings.Appearance.system, "System"), (.light, "Light"), (.dark, "Dark")],
                              selection: $model.app.appearance)
                }
                ToggleRow(title: "Open at login", isOn: Binding(get: { model.app.launchAtLogin }, set: { on in
                    model.app.launchAtLogin = on
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { model.logs.append("Login item: \(error.localizedDescription)") }
                }))
                ToggleRow(title: "Start server at launch", isOn: $model.app.startServerAtLaunch)
                ToggleRow(title: "Lighter on battery", isOn: $model.app.lighterOnBattery)
                SettingRow(title: "Hugging Face token", detail: tokenSaved ? "Saved in Keychain" : "For gated models") {
                    HStack(spacing: 8) {
                        SecureField("hf_…", text: $tokenDraft).textFieldStyle(.roundedBorder).frame(width: 150)
                        Button("Save") { HFToken.save(tokenDraft); model.hf.invalidateCache(); tokenDraft = ""; tokenSaved = HFToken.isSaved }
                            .buttonStyle(.pill).disabled(tokenDraft.isEmpty)
                        if tokenSaved {
                            Button("Remove") { HFToken.clear(); model.hf.invalidateCache(); tokenSaved = HFToken.isSaved }.buttonStyle(.pill)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var agents: some View {
        @Bindable var model = model
        return HStack(alignment: .top, spacing: 14) {
            Card {
                VStack(spacing: 0) {
                    ToggleRow(title: "Allow agents", detail: "Claude Code, Cursor and others",
                              isOn: Binding(get: { model.app.mcpEnabled }, set: { model.setMCP(enabled: $0) }))
                    SettingRow(title: "Permission") {
                        Segmented(options: [(AppSettings.AgentPermission.readOnly, "Read only"), (.askFirst, "Ask first"),
                                            (.fullControl, "Full")], selection: $model.app.agentPermission)
                    }
                    SettingRow(title: "Always ask above") {
                        SliderField(value: $model.app.largeDownloadGB, range: 1...100, step: 1, format: "%.0f GB")
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Label2("Connect an agent")
                            Spacer()
                            Button("Rescan") { scan() }.buttonStyle(.pill)
                        }.padding(.top, 10)
                        if !FileManager.default.isExecutableFile(atPath: server) {
                            Text("The MCP server was not found at \(server). Move MLX Player into Applications to connect agents.")
                                .font(.system(size: 11.5)).foregroundStyle(Color.warn).padding(.vertical, 6)
                        }
                        ForEach(statuses) { st in agentRow(st) }
                        if let k = restartHint {
                            Text("Restart \(k.name) to load the new tools.").font(.system(size: 11.5)).foregroundStyle(Color.accentIndigo).padding(.top, 6)
                        }
                        if let agentError { Text(agentError).font(.system(size: 11.5)).foregroundStyle(Color.bad).padding(.top, 6) }
                        DisclosureGroup("Set up another agent manually") {
                            VStack(alignment: .leading, spacing: 6) {
                                CodeBlock(text: model.claudeMCPCommand(), height: 56)
                                CodeBlock(text: "{ \"mcpServers\": { \"mlxplayer\": { \"command\": \"\(server)\" } } }", height: 56)
                                Button("Copy command") { model.copy(model.claudeMCPCommand()) }.buttonStyle(.pill)
                            }.padding(.top, 6)
                        }
                        .font(.system(size: 12.5)).padding(.top, 8)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(text: "Tools")
                    ForEach(tools, id: \.0) { t in
                        HStack {
                            Text(t.0).font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Text(t.1).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .frame(width: 400)
        }
        .onAppear { scan() }
    }

    private var mlx: some View {
        @Bindable var model = model
        return Card {
            VStack(spacing: 0) {
                SettingRow(title: "mlx-lm", detail: model.app.customServerPath ?? "Managed install") {
                    Text(model.installedVersion ?? "–").font(.system(size: 12.5, design: .monospaced))
                }
                SettingRow(title: "Update") {
                    HStack {
                        if model.installing { ProgressView().controlSize(.small) }
                        Button("Upgrade") { Task { await model.upgradeMLX() } }.buttonStyle(.pill).disabled(model.installing)
                    }
                }
                if model.app.customServerPath != nil {
                    SettingRow(title: "Custom server") {
                        Button("Use managed") { model.app.customServerPath = nil; model.supportedFlags = nil }.buttonStyle(.pill)
                    }
                }
                SettingRow(title: "Setup") { Button("Run again") { model.showSetup = true }.buttonStyle(.pill) }
                if !model.installLog.isEmpty { LogPane(lines: model.installLog, height: 160).padding(.top, 8) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func agentRow(_ st: AgentStatus) -> some View {
        let missing = !FileManager.default.isExecutableFile(atPath: server)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(st.kind.name).font(.system(size: 13, weight: .medium))
                Text(detail(st)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if busy == st.kind { ProgressView().controlSize(.small) }
            else {
                switch st.state {
                case .notDetected: EmptyView()
                case .available:
                    Button("Connect") { run(st.kind, install: true) }.buttonStyle(.pillPrimary).disabled(missing || busy != nil)
                case .connected:
                    Button("Disconnect") { run(st.kind, install: false) }.buttonStyle(.pill).disabled(busy != nil)
                case .outdated:
                    Button("Update") { run(st.kind, install: true) }.buttonStyle(.pillPrimary).disabled(missing || busy != nil)
                    Button("Disconnect") { run(st.kind, install: false) }.buttonStyle(.pill).disabled(busy != nil)
                }
            }
        }
        .padding(.vertical, 7)
    }

    private func detail(_ st: AgentStatus) -> String {
        switch st.state {
        case .notDetected: "Not found on this Mac."
        case .available: "Found. Not connected yet."
        case .connected: st.kind.needsRestart ? "Connected. Restart the app after changes." : "Connected."
        case .outdated(let old): "Points to \(old). Update it to use this copy."
        }
    }

    private func scan() {
        Task {
            let found = await Task.detached { AgentIntegrations.scan(serverPath: server) }.value
            statuses = found
        }
    }

    private func run(_ kind: AgentKind, install: Bool) {
        busy = kind; agentError = nil; restartHint = nil
        Task {
            do {
                if install { try await AgentIntegrations.install(kind, serverPath: server) } else { try await AgentIntegrations.remove(kind) }
                if install && kind.needsRestart { restartHint = kind }
            } catch { agentError = "\(kind.name): \(error.localizedDescription)" }
            statuses = await Task.detached { AgentIntegrations.scan(serverPath: server) }.value
            busy = nil
        }
    }
}
