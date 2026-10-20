import SwiftUI
import MLXPlayerCore

struct DiscoverView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: ModelMetadata?
    @State private var showDetail = false
    @State private var loadedOnce = false

    private let help: [(term: String, meaning: String)] = [
        ("Alignment", "Standard models refuse some requests. Uncensored and abliterated ones have that behavior reduced or removed."),
        ("Quantization (bit)", "How compactly the weights are stored. 4-bit is about a quarter of the size of 16-bit, with a small quality loss."),
        ("Parameters (B)", "Model size in billions. More parameters usually means better answers and more memory."),
        ("MoE", "Mixture of experts. A large model that only uses part of itself per token, so it runs faster than its size suggests."),
        ("Fit", "Whether the model leaves enough memory free on this Mac. Comfortable runs well, Tight may be slow, Won't fit will fail to load."),
    ]

    var body: some View {
        @Bindable var model = model
        ScreenFrame {
            PageHeader(title: "Discover", subtitle: subtitle) {
                HStack(spacing: 10) {
                    Picker("", selection: $model.searchSort) {
                        ForEach(SearchSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                    HelpButton(title: "Finding a model", entries: help)
                }
            }
        } content: {
            toolbar
            results
        }
        .sideOverlay(isPresented: $showDetail, title: selected?.displayName ?? "Model", width: 440) {
            if let meta = selected { ModelDetail(meta: meta) }
        }
        .task {
            if model.results.isEmpty { await model.search() }
            loadedOnce = true
        }
        .onChange(of: model.filter.variant) { _, _ in Task { await model.search() } }
        .onChange(of: model.searchSort) { _, _ in Task { await model.search() } }
    }

    private var subtitle: String {
        let shown = model.filteredResults.count
        if model.searching && model.results.isEmpty { return "Searching…" }
        let total = model.results.count
        let more = model.hasMoreResults ? "+" : ""
        return shown == total ? "\(total)\(more) models" : "\(shown) of \(total)\(more) models match your filters"
    }

    // MARK: Toolbar

    private var toolbar: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search models, for example qwen coder", text: $model.searchText)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .onSubmit { Task { await model.search() } }
                if !model.searchText.isEmpty {
                    Button { model.searchText = ""; Task { await model.search() } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.vertical, 9).padding(.horizontal, 12)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))

            HStack(spacing: 8) {
                Segmented(options: ModelVariant.allCases.map { ($0, $0.label) }, selection: $model.filter.variant)
                Divider().frame(height: 20)
                FilterMenu(title: "Size", options: ModelFilter.SizeBucket.allCases.map { ($0, $0.rawValue) }, selection: $model.filter.sizes)
                FilterMenu(title: "Quantization", options: [4, 5, 6, 8, 16].map { ($0, "\($0)-bit") }, selection: $model.filter.bits)
                FilterMenu(title: "Capability", options: Capability.allCases.map { ($0, $0.rawValue.capitalized) }, selection: $model.filter.capabilities)
                FilterMenu(title: "Family", options: ModelFamily.allCases.map { ($0, $0.rawValue) }, selection: $model.filter.families)
                Toggle(isOn: $model.filter.fitsMyMac) { Text("Fits my Mac").font(.system(size: 12.5)) }
                    .toggleStyle(.switch).controlSize(.small).tint(.accentIndigo)
                Spacer(minLength: 0)
                if filtersActive {
                    Button("Clear filters") {
                        let variant = model.filter.variant
                        model.filter = ModelFilter(); model.filter.variant = variant
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.accentIndigo)
                }
            }
        }
    }

    private var filtersActive: Bool {
        let f = model.filter
        return !f.sizes.isEmpty || !f.bits.isEmpty || !f.capabilities.isEmpty || !f.families.isEmpty || f.fitsMyMac
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        let list = model.filteredResults
        if (model.searching && model.results.isEmpty) || !loadedOnce {
            ListPanel { SkeletonRows() }
        } else if let error = model.searchError, model.results.isEmpty {
            centered {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 26)).foregroundStyle(.secondary)
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Retry") { Task { await model.search() } }.buttonStyle(.pill)
            }
        } else if list.isEmpty {
            centered {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 26)).foregroundStyle(.secondary)
                Text(model.results.isEmpty ? "No models found" : "No loaded models match these filters")
                    .foregroundStyle(.secondary)
                if model.hasMoreResults {
                    Button(model.loadingMore ? "Loading…" : "Load more") { Task { await model.loadMoreResults() } }
                        .buttonStyle(.pill).disabled(model.loadingMore)
                }
            }
        } else {
            ListPanel {
                ForEach(list) { meta in
                    ResultRow(meta: meta) { selected = meta; showDetail = true }
                    Divider().opacity(0.4)
                }
                footer
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if model.loadingMore {
                ProgressView().controlSize(.small)
            } else if model.hasMoreResults {
                Button("Load more") { Task { await model.loadMoreResults() } }.buttonStyle(.pill)
            } else {
                Text("End of results").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 14)
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 10) { content() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

struct ResultRow: View {
    @Environment(AppModel.self) private var model
    let meta: ModelMetadata
    var onOpen: () -> Void

    var body: some View {
        let a = model.advisor.assess(meta, task: model.advisorTask)
        HStack(spacing: 12) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 5) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                CopyIcon(text: meta.id, help: "Copy model ID")
                HubLink(id: meta.id)
            }
            VStack(alignment: .trailing, spacing: 3) {
                Text(formatBytes(a.weightsBytes)).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                Text("\(formatCount(meta.downloads)) downloads").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .frame(minWidth: 96, alignment: .trailing)
            FitBadge(verdict: a.verdict).frame(minWidth: 80, alignment: .trailing)
            DownloadButton(meta: meta).frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// Opens the model page on Hugging Face in the browser, so third-party details can be checked.
struct HubLink: View {
    let id: String
    var body: some View {
        if let url = URL(string: "https://huggingface.co/\(id)") {
            Link(destination: url) { Image(systemName: "arrow.up.right.square").font(.system(size: 12)) }
                .foregroundStyle(.secondary).help("Open on Hugging Face")
        }
    }
}

// MARK: - Detail overlay

struct ModelDetail: View {
    @Environment(AppModel.self) private var model
    let meta: ModelMetadata

    var body: some View {
        let a = model.advisor.assess(meta, task: model.advisorTask)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(meta.id).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                CopyIcon(text: meta.id, help: "Copy model ID")
                HubLink(id: meta.id)
            }
            FlowLayout {
                if let p = meta.totalParamsB { Chip(text: paramLabel(p, meta.activeParamsB)) }
                Chip(text: "\(meta.bits)-bit")
                ForEach(Array(meta.capabilities.sorted { $0.rawValue < $1.rawValue }), id: \.self) { Chip(text: $0.rawValue.capitalized) }
                if meta.variant != .standard { Chip(text: meta.variant.label, tint: .warn) }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { CardTitle(text: "On this Mac"); Spacer(); FitBadge(verdict: a.verdict) }
                    ProgressBar(fraction: fraction(a), color: fitColor(a.verdict))
                    Text(explain(a)).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 12) {
                Stat(title: "Weights", value: formatBytes(a.weightsBytes))
                Stat(title: "Context", value: contextLabel(a.recommendedContext), detail: "recommended")
                Stat(title: "Speed", value: a.tokensPerSecond > 0 ? "~\(Int(a.tokensPerSecond)) t/s" : "–", detail: "estimate")
            }

            HStack(spacing: 18) {
                Label("\(formatCount(meta.downloads)) downloads", systemImage: "arrow.down.circle")
                Label("\(formatCount(meta.likes)) likes", systemImage: "heart")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)

            DownloadButton(meta: meta)
        }
    }

    private func fraction(_ a: Assessment) -> Double {
        let budget = Double(max(model.advisor.hardware.gpuLimitBytes, 1))
        return Double(a.weightsBytes + a.kvBytesAtRecommended) / budget
    }

    private func explain(_ a: Assessment) -> String {
        switch a.verdict {
        case .comfortable: return "Fits with \(formatBytes(UInt64(max(a.headroomBytes, 0)))) to spare at \(contextLabel(a.recommendedContext)) context."
        case .tight: return "Fits, but only just. Expect slowdowns; keep the context at or below \(contextLabel(a.safeMaxContext))."
        case .wontFit: return "Needs more memory than this Mac can give the GPU. Pick a smaller size or lower bit count."
        }
    }

    private func contextLabel(_ tokens: Int) -> String { tokens >= 1024 ? "\(tokens / 1024)K" : "\(tokens)" }
}
