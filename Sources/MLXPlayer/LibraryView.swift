import SwiftUI
import MLXPlayerCore

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var nav
    @State private var pendingDelete: InstalledModel?

    private var total: UInt64 { model.installed.reduce(0) { $0 + $1.sizeBytes } }
    private var freeBytes: UInt64 {
        let v = try? model.paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return UInt64(v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    var body: some View {
        ScreenFrame {
            PageHeader(title: "Library", subtitle: "\(model.installed.count) models · \(formatBytes(total))") {
                Button { model.refreshInstalled() } label: { IconLabel(title: "Refresh", symbol: "arrow.clockwise") }
                    .buttonStyle(.pill)
            }
        } content: {
            diskBar
            if model.installed.isEmpty {
                VStack(spacing: 10) {
                    Text("No models yet").foregroundStyle(.secondary)
                    Button("Find a model") { nav.screen = .discover }.buttonStyle(.pillPrimary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ListPanel {
                    ForEach(model.installed) { m in
                        row(m)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .onAppear { model.refreshInstalled() }
        .confirmationDialog("Delete \(pendingDelete?.meta.displayName ?? "")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) { if let m = pendingDelete { model.delete(model: m.id) }; pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("Frees \(formatBytes(pendingDelete?.sizeBytes ?? 0)).") }
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

    private func row(_ m: InstalledModel) -> some View {
        let active = (model.activeModelID == m.id) && model.isRunning
        let a = model.advisor.assess(m.meta, task: .coding)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(m.meta.displayName).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if active { Chip(text: "Loaded", tint: .good) }
                }
                HStack(spacing: 5) {
                    if let p = m.meta.totalParamsB { Chip(text: paramLabel(p, m.meta.activeParamsB)) }
                    Chip(text: "\(m.meta.bits)-bit")
                    if m.meta.variant != .standard { Chip(text: m.meta.variant.label, tint: .warn) }
                }
            }
            Spacer()
            Text(formatBytes(m.sizeBytes)).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(.secondary)
            FitBadge(verdict: a.verdict)
            if active {
                Button("Unload") { Task { await model.stopServer() } }.buttonStyle(.pill(height: 26))
            } else {
                Button("Load") { Task { await model.startServer(model: m.id) } }.buttonStyle(.pillPrimary)
            }
            Button("Settings") { model.select(model: m.id); nav.screen = .server }.buttonStyle(.pill(height: 26))
            Menu {
                Button("Reveal in Finder") { model.reveal(model: m.id) }
                Button("Copy ID") { model.copy(m.id) }
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = m }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
