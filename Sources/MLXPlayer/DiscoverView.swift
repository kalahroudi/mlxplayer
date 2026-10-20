import SwiftUI
import MLXPlayerCore

struct DiscoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScreenFrame {
            PageHeader(title: "Discover", subtitle: "\(model.filteredResults.count) models") {
                HStack(spacing: 8) {
                    searchBox
                    Picker("", selection: $model.searchSort) {
                        ForEach(SearchSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                }
            }
        } content: {
            HStack(alignment: .top, spacing: 16) {
                filters.frame(width: 250)
                results
            }
        }
        .task { if model.results.isEmpty { await model.search() } }
        .onChange(of: model.filter.variant) { _, _ in Task { await model.search() } }
        .onChange(of: model.searchSort) { _, _ in Task { await model.search() } }
    }

    private var searchBox: some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search models", text: $model.searchText)
                .textFieldStyle(.plain)
                .onSubmit { Task { await model.search() } }
                .frame(width: 220)
        }
        .padding(.vertical, 6).padding(.horizontal, 9)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var filters: some View {
        @Bindable var model = model
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                group("Alignment") {
                    Segmented(options: ModelVariant.allCases.map { ($0, $0.label) }, selection: $model.filter.variant)
                        .scaleEffect(0.86, anchor: .leading)
                }
                group("Size") {
                    ChipSet(options: ModelFilter.SizeBucket.allCases.map { ($0, $0.rawValue) }, selection: $model.filter.sizes)
                }
                group("Quantization") {
                    ChipSet(options: [4, 5, 6, 8, 16].map { ($0, "\($0)-bit") }, selection: $model.filter.bits)
                }
                group("Capability") {
                    ChipSet(options: Capability.allCases.map { ($0, $0.rawValue.capitalized) }, selection: $model.filter.capabilities)
                }
                group("Family") {
                    ChipSet(options: ModelFamily.allCases.map { ($0, $0.rawValue) }, selection: $model.filter.families)
                }
                Toggle(isOn: $model.filter.fitsMyMac) { Text("Fits my Mac").font(.system(size: 13)) }
                    .toggleStyle(.switch).tint(.accentIndigo)
                Spacer(minLength: 0)
            }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) { Label2(title); content() }
    }

    @ViewBuilder private var results: some View {
        let list = model.filteredResults
        if model.searching && list.isEmpty {
            centered { ProgressView() }
        } else if let error = model.searchError {
            centered {
                Text(error).foregroundStyle(.secondary)
                Button("Retry") { Task { await model.search() } }.buttonStyle(.pill)
            }
        } else if list.isEmpty {
            centered { Text("No matches").foregroundStyle(.secondary) }
        } else {
            ListPanel {
                ForEach(list) { meta in
                    ResultRow(meta: meta)
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 10) { content() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ResultRow: View {
    @Environment(AppModel.self) private var model
    let meta: ModelMetadata

    var body: some View {
        let a = model.advisor.assess(meta, task: model.advisorTask)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meta.displayName).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(meta.publisher).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    if let p = meta.totalParamsB { Chip(text: paramLabel(p, meta.activeParamsB)) }
                    Chip(text: "\(meta.bits)-bit")
                    ForEach(Array(meta.capabilities.sorted { $0.rawValue < $1.rawValue }.filter { $0 != .chat }), id: \.self) {
                        Chip(text: $0.rawValue.capitalized)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(formatBytes(a.weightsBytes)).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                Text("\(formatCount(meta.downloads)) downloads").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            FitBadge(verdict: a.verdict)
            DownloadButton(meta: meta).frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
