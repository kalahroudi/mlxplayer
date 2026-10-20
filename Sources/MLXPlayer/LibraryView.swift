import SwiftUI
import MLXPlayerCore

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav
    @State private var pending: [InstalledModel] = []
    @State private var showConfirm = false
    @State private var query = ""
    @State private var selection: Set<String> = []
    @State private var visible = 25

    private var total: UInt64 { model.installed.reduce(0) { $0 + $1.sizeBytes } }
    private var freeBytes: UInt64 {
        let v = try? model.paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    var body: some View {
        ScreenFrame {
            PageHeader(title: "Library", subtitle: "\(model.installed.count) models · \(formatBytes(total))") {
                HStack(spacing: 8) {
                    TextBox(placeholder: "Search", text: $query, width: 200, mono: false)
                    Button { model.refreshInstalled() } label: { IconLabel(title: "Refresh", symbol: "arrow.clockwise") }
                        .buttonStyle(.pill)
                    HelpButton(title: "Your models", entries: [
                        ("Library", "Models downloaded to this Mac. They live in the Hugging Face cache and can be re-downloaded."),
                        ("Loaded", "The model the server currently holds in memory. Unload frees that memory but keeps the files."),
                        ("Delete", "Removes the files from disk. You will be asked to type the name first."),
                    ])
                }
            }
        } content: {
            diskBar
            downloadsCard
            if model.installed.isEmpty {
                VStack(spacing: 10) {
                    Text("No models yet").foregroundStyle(.secondary)
                    Button("Find a model") { nav.screen = .discover }.buttonStyle(.pillPrimary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                bulkBar
                let list = filtered
                if list.isEmpty {
                    Text("No models match \"\(query)\"").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ListPanel {
                        ForEach(list.prefix(visible)) { m in
                            row(m)
                            Divider().opacity(0.4)
                        }
                        if list.count > visible {
                            Button("Show more (\(list.count - visible))") { visible += 25 }.buttonStyle(.pill).padding(.vertical, 14)
                        }
                    }
                }
            }
        }
        .onAppear { model.refreshInstalled() }
        .sideOverlay(isPresented: $showConfirm, title: pending.count == 1 ? "Delete model" : "Delete \(pending.count) models", width: 420) {
            TypedConfirmPanel(
                warning: "This removes \(pending.count == 1 ? "the files" : "the files of \(pending.count) models") from disk and frees \(formatBytes(pending.reduce(0) { $0 + $1.sizeBytes })). Downloading again takes time.",
                phrase: confirmPhrase, confirmTitle: "Delete", onConfirm: {
                    for m in pending { model.delete(model: m.id) }
                    selection.subtract(pending.map(\.id)); pending = []; showConfirm = false
                }, onCancel: { showConfirm = false })
            .id(confirmPhrase)
        }
    }

    private var filtered: [InstalledModel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? model.installed : model.installed.filter { $0.id.localizedCaseInsensitiveContains(q) }
    }

    /// One model: its short name. Several: a phrase that includes the count.
    private var confirmPhrase: String {
        pending.count == 1 ? (pending[0].id.split(separator: "/").last.map(String.init) ?? pending[0].id) : "delete \(pending.count) models"
    }

    private func ask(_ models: [InstalledModel]) { pending = models; showConfirm = true }

    private var bulkBar: some View {
        let list = filtered
        let allSelected = !list.isEmpty && list.allSatisfy { selection.contains($0.id) }
        return HStack(spacing: 10) {
            Button {
                if allSelected { selection.subtract(list.map(\.id)) } else { selection.formUnion(list.map(\.id)) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: allSelected ? "checkmark.square.fill" : (selection.isEmpty ? "square" : "minus.square"))
                        .foregroundStyle(selection.isEmpty ? Color.secondary : Color.accentIndigo)
                    Text("Select all").font(.system(size: 12.5))
                }
            }.buttonStyle(.plain)
            if !selection.isEmpty {
                Text("\(selection.count) selected · \(formatBytes(model.installed.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Delete…") { ask(model.installed.filter { selection.contains($0.id) && !(model.isRunning && model.activeModelID == $0.id) }) }
                    .buttonStyle(.pillDestructive)
            }
            Spacer()
        }
    }

    private var diskBar: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label2("Disk")
                    Spacer()
                    Text("\(formatBytes(total)) used by models · \(formatBytes(freeBytes)) free")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                ProgressBar(fraction: Double(total) / Double(max(total + freeBytes, 1)), color: .seriesTeal)
            }
        }
    }

    private var downloadIDs: [String] {
        let live = model.downloads.filter { !$0.value.finished }.keys
        return Array(Set(live).union(model.partials.map(\.id))).sorted()
    }

    /// Active, paused and left-over downloads in one place, each with resume / pause / discard.
    @ViewBuilder private var downloadsCard: some View {
        let ids = downloadIDs
        if !ids.isEmpty {
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label2("Downloads")
                        Spacer()
                        if model.downloads.values.contains(where: { !$0.finished && $0.failed == nil }) {
                            Button("Pause all") { model.pauseAllDownloads() }.buttonStyle(.pill(height: 24))
                        }
                        if !model.partials.isEmpty {
                            Button("Resume all") { model.resumeAllPartials() }.buttonStyle(.pillPrimary)
                        }
                    }
                    ForEach(ids, id: \.self) { id in downloadRow(id) }
                }
            }
        }
    }

    private func downloadRow(_ id: String) -> some View {
        let d = model.downloads[id]
        let partial = model.partials.first { $0.id == id }
        let bytes = d?.downloadedBytes ?? partial?.bytes ?? 0
        let running = d != nil && d?.failed == nil && d?.finished == false
        let status: String = {
            if let f = d?.failed { return f == "Paused" ? "Paused" : f }
            if let d, !d.finished {
                let pct = d.totalBytes != nil ? "\(Int(d.fraction * 100))% · " : ""
                return "\(pct)\(formatBytes(UInt64(max(d.bytesPerSecond, 0))))/s"
            }
            return "Stopped"
        }()
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ModelMetadata.fromName(id).displayName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text("\(formatBytes(bytes))\(d?.totalBytes.map { " of \(formatBytes($0))" } ?? "") · \(status)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer()
            if running {
                ProgressBar(fraction: d?.fraction ?? 0).frame(width: 110)
                Button { model.pauseDownload(id) } label: { Image(systemName: "pause.fill") }.buttonStyle(.pill(height: 26))
            } else {
                Button("Resume") { model.resumePartial(id) }.buttonStyle(.pill(height: 26))
            }
            Button { model.cancelDownload(id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.pill(height: 26)).help("Discard download and delete partial files")
        }
    }

    private func row(_ m: InstalledModel) -> some View {
        let active = (model.activeModelID == m.id) && model.isRunning
        let a = model.advisor.assess(m.meta, task: .coding)
        return HStack(spacing: 12) {
            Button {
                if selection.contains(m.id) { selection.remove(m.id) } else { selection.insert(m.id) }
            } label: {
                Image(systemName: selection.contains(m.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selection.contains(m.id) ? Color.accentIndigo : Color.secondary)
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(m.meta.displayName).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if active { Chip(text: "Loaded", tint: .good) }
                }
                HStack(spacing: 5) {
                    if let p = m.meta.totalParamsB { Chip(text: paramLabel(p, m.meta.activeParamsB)) }
                    Chip(text: "\(m.meta.bits)-bit")
                    if m.meta.variant != .standard { Chip(text: m.meta.variant.label, tint: .warn) }
                    if let b = model.app.benchmarks[m.id] {
                        Chip(text: "\(Int(b.decodeTokensPerSecond)) t/s measured", tint: .seriesTeal)
                    }
                }
            }
            Spacer()
            CopyIcon(text: m.id, help: "Copy model ID")
            HubLink(id: m.id)
            Text(formatBytes(m.sizeBytes)).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(.secondary)
            FitBadge(verdict: a.verdict)
            if active {
                AsyncButton(title: "Unload", busyTitle: "Unloading…") { await model.stopServer() }.buttonStyle(.pill(height: 26))
            } else {
                AsyncButton(title: "Load", busyTitle: "Loading…") { await model.startServer(model: m.id) }.buttonStyle(.pillPrimary)
            }
            Button("Settings") { model.select(model: m.id); nav.screen = .server }.buttonStyle(.pill(height: 26))
            Menu {
                Button("Benchmark") { Task { await model.benchmark(model: m.id) } }
                    .disabled(model.benchmarking != nil)
                Button("Reveal in Finder") { model.reveal(model: m.id) }
                Button("Copy ID") { model.copy(m.id) }
                Divider()
                Button("Delete…", role: .destructive) { ask([m]) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
