import SwiftUI
import ServiceManagement
import MLXPlayerCore

struct SettingsView: View {
    enum Tab: Hashable { case general, agents, mlx, updates }
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav
    private var tab: Binding<Tab> { Binding(get: { nav.settingsTab }, set: { nav.settingsTab = $0 }) }
    @State private var installNote: String?
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
                    Picker("", selection: $model.app.menuBarDisplay) {
                        Text("Speed").tag(AppSettings.MenuBarDisplay.speed)
                        Text("Memory").tag(AppSettings.MenuBarDisplay.memory)
                        Text("Icon only").tag(AppSettings.MenuBarDisplay.iconOnly)
                    }.labelsHidden().frame(width: 120)
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
        .frame(maxWidth: 640)
    }

    private var agents: some View {
        @Bindable var model = model
        let command = model.claudeMCPCommand()
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
                    VStack(alignment: .leading, spacing: 6) {
                        Label2("Add to Claude Code").padding(.top, 10)
                        CodeBlock(text: command, height: 56)
                        HStack {
                            Button("Copy") { model.copy(command) }.buttonStyle(.pill)
                            Button("Install") { installMCP() }.buttonStyle(.pillPrimary)
                            if let installNote { Text(installNote).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
                        }
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
        .frame(maxWidth: 640)
    }

    /// Runs `claude mcp add` through a login shell so PATH matches the user's terminal.
    private func installMCP() {
        let command = model.claudeMCPCommand()
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            let pipe = Pipe()
            p.standardError = pipe; p.standardOutput = pipe
            do {
                try p.run(); p.waitUntilExit()
                let ok = p.terminationStatus == 0
                await MainActor.run { installNote = ok ? "Added" : "Failed. Copy the command instead." }
            } catch {
                await MainActor.run { installNote = "Claude Code not found" }
            }
        }
    }
}
