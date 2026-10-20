import SwiftUI
import MLXPlayerCore

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav
    @State private var query = ""
    @State private var today = UsageSummary()
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.isInstalled {
                setupCard
            } else {
                modelCard
                endpointCard
                tiles
                systemCard
                todayRow
                switchList
            }
            if let info = model.updater.available {
                Button {
                    nav.settingsTab = .updates
                    openMain(.settings, nav: nav)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentIndigo)
                        Text("Update available").font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Text(info.label).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .padding(9)
                    .background(Color.accentIndigo.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let error = model.lastError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Color.bad).lineLimit(3)
            }
            searchField
            Divider().opacity(0.5)
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.refreshInstalled() }
        .task {
            // The popover stays alive while hidden, so keep its numbers fresh instead of reading them once.
            while !Task.isCancelled {
                today = model.usage.summary(.today)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // MARK: Parts

    private var statusText: (String, Color) {
        switch model.serverState {
        case .running: return ("Running", .good)
        case .starting: return ("Loading", .warn)
        case .stopping: return ("Stopping", .warn)
        case .failed: return ("Error", .bad)
        default: return (model.app.onDemandLoading && model.isInstalled ? "Idle" : "Stopped", .secondary)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AppMark(size: 22)
            Text("MLX Player").font(.system(size: 14, weight: .semibold))
            Spacer()
            StatusPill(text: statusText.0, color: statusText.1)
        }
    }

    private var setupCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set up MLX").font(.system(size: 13, weight: .semibold))
                Text("Installs mlx-lm in its own folder.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Button("Set up") { model.showSetup = true; openMain(nil, nav: nav) }
                    .buttonStyle(.pillPrimary)
            }
        }
    }

    private var modelCard: some View {
        let id = model.activeModelID ?? model.app.lastModelID
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                if let id {
                    let meta = model.activeMeta ?? ModelMetadata.fromName(id)
                    Text(meta.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        if let p = meta.totalParamsB { Chip(text: paramLabel(p, meta.activeParamsB)) }
                        Chip(text: "\(meta.bits)-bit")
                        Chip(text: formatContext(model.effectiveContextLimit))
                    }
                    HStack(spacing: 8) {
                        if model.isRunning {
                            Button { Task { await model.restartServer() } } label: { Text("Restart") }.buttonStyle(.pill)
                            Button { Task { await model.stopServer() } } label: { Text("Unload") }.buttonStyle(.pill)
                        } else if model.serverState.isStarting {
                            Text("Loading…").font(.system(size: 12)).foregroundStyle(.secondary)
                        } else {
                            Button { Task { await model.startServer(model: id) } } label: { Text("Load") }.buttonStyle(.pillPrimary)
                        }
                    }
                } else {
                    Text("No model yet").font(.system(size: 13, weight: .semibold))
                    Button("Find a model") { openMain(.discover, nav: nav) }.buttonStyle(.pillPrimary)
                }
            }
        }
    }

    private var endpointCard: some View {
        Card(padding: 10) {
            HStack(spacing: 8) {
                Text(model.endpoint).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button(copied ? "Copied" : "Copy URL") {
                    model.copy(model.endpoint)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_200_000_000); copied = false }
                }
                .buttonStyle(.pill(height: 24))
                Menu {
                    Button("Copy cURL") { model.copy(model.curlSnippet) }
                    Button("Copy env") { model.copy(model.envSnippet) }
                    Button("Copy model ID") { model.copy(model.draft.modelID) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
    }

    private var tiles: some View {
        HStack(spacing: 8) {
            tile("Speed", model.tokensPerSecond > 0.5 ? String(format: "%.0f t/s", model.tokensPerSecond) : "–")
            tile("Memory", model.isRunning ? formatBytes(model.serverMemoryBytes) : "–")
            tile("Requests", "\(model.requestsToday)")
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label2(title)
                Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }

    private var systemCard: some View {
        let s = model.system
        let hw = model.hardware
        let mem = Double(s.memory.used) / Double(max(s.memory.total, 1))
        let vram = Double(s.gpuMemoryBytes ?? 0) / Double(max(hw.gpuLimitBytes, 1))
        return Card(padding: 10) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label2("This Mac")
                    Spacer()
                    Text("Pressure \(model.memoryPressure.label)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                meter("Memory", mem, "\(formatBytes(s.memory.used)) / \(formatBytes(s.memory.total))", mem > 0.9 ? .bad : (mem > 0.75 ? .warn : .good))
                meter("GPU", s.gpu ?? 0, s.gpu.map { "\(Int($0 * 100))%" } ?? "–", .seriesTeal)
                meter("VRAM", vram, "\(formatBytes(s.gpuMemoryBytes ?? 0)) / \(formatBytes(hw.gpuLimitBytes))", .accentIndigo)
            }
        }
    }

    private func meter(_ title: String, _ fraction: Double, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            ProgressBar(fraction: min(max(fraction, 0), 1), color: color)
            Text(value).font(.system(size: 11)).monospacedDigit().lineLimit(1).frame(width: 96, alignment: .trailing)
        }
    }

    private var todayRow: some View {
        HStack {
            Label2("Today")
            Spacer()
            Text("\(formatCount(today.tokensIn)) in · \(formatCount(today.tokensOut)) out")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private var switchList: some View {
        let loaded = model.isRunning ? model.activeModelID : nil
        let cardID = model.activeModelID ?? model.app.lastModelID
        let others = Array(model.installed.filter { loaded != nil || $0.id != cardID }.sorted { ($0.id == loaded ? 0 : 1) < ($1.id == loaded ? 0 : 1) }.prefix(4))
        return VStack(alignment: .leading, spacing: 2) {
            if !others.isEmpty { Label2("Switch model").padding(.bottom, 2) }
            ForEach(others) { m in
                Button { if m.id != loaded { Task { await model.startServer(model: m.id) } } } label: {
                    HStack {
                        Text(m.meta.displayName).font(.system(size: 12.5)).lineLimit(1)
                        if m.id == loaded { Chip(text: "Loaded", tint: .good) }
                        Spacer()
                        Text(formatBytes(m.sizeBytes)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find a model", text: $query)
                .textFieldStyle(.plain)
                .onSubmit {
                    model.searchText = query
                    Task { await model.search() }
                    openMain(.discover, nav: nav)
                    query = ""
                }
        }
        .padding(.vertical, 6).padding(.horizontal, 9)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open") { openMain(.server, nav: nav) }.buttonStyle(.pill(height: 26))
            Button("Logs") { openMain(.logs, nav: nav) }.buttonStyle(.pill(height: 26))
            Spacer()
            Button("Quit") { Task { await model.stopServer(); NSApp.terminate(nil) } }.buttonStyle(.pill(height: 26))
        }
    }
}

func paramLabel(_ total: Double, _ active: Double?) -> String {
    func f(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))B" : String(format: "%.1fB", v) }
    if let a = active, a < total { return "\(f(total)) · \(f(a)) active" }
    return f(total)
}
