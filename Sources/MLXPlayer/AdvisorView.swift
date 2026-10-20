import SwiftUI
import MLXPlayerCore

struct AdvisorView: View {
    enum Tab: Hashable { case recommended, compare, context }
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .recommended
    @State private var selected: String?

    var body: some View {
        @Bindable var model = model
        ScreenFrame {
            PageHeader(title: "Advisor",
                       subtitle: "\(model.hardware.chip) · \(formatBytes(model.hardware.memoryBytes)) · \(formatBytes(model.advisor.budgetBytes)) usable") {
                HelpButton(title: "Choosing a model", entries: HelpContent.advisor)
            }
        } content: {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label2("Job")
                        FlowLayout {
                            ForEach(AdvisorTask.allCases, id: \.self) { t in
                                ChipButton(text: t.label, selected: model.advisorTask == t) { model.advisorTask = t }
                            }
                        }
                    }
                    HStack(alignment: .bottom, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label2("Describe it")
                            TextBox(placeholder: "e.g. summarize PDFs offline", text: $model.advisorDescription, width: 380, mono: false)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Label2("Variant")
                            Segmented(options: ModelVariant.allCases.map { ($0, $0.label) }, selection: $model.advisorVariant)
                        }
                        Spacer()
                        Button { Task { await model.runAdvisor() } } label: { Text(model.advisorBusy ? "Working…" : "Advise") }
                            .buttonStyle(.pillPrimary).disabled(model.advisorBusy)
                    }
                }
            }
            if let error = model.advisorError { Text(error).font(.system(size: 12)).foregroundStyle(Color.bad) }
            if model.recommendations != nil {
                TabStrip(options: [(Tab.recommended, "Recommended"), (.compare, "Compare sizes"), (.context, "Context & command")],
                         selection: $tab)
                switch tab {
                case .recommended: recommended
                case .compare: compare
                case .context: contextTab
                }
            } else if !model.advisorBusy {
                Text("Pick a job and press Advise.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .task { if model.recommendations == nil { await model.runAdvisor() } }
        .onChange(of: model.advisorVariant) { _, _ in Task { await model.runAdvisor() } }
    }

    // MARK: Tabs

    private var recommended: some View {
        let r = model.recommendations
        return HStack(alignment: .top, spacing: 14) {
            pick("Best overall", r?.bestOverall)
            pick("Highest quality", r?.highestQuality)
            pick("Fastest", r?.fastest)
        }
    }

    private func pick(_ title: String, _ a: Assessment?) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label2(title)
                if let a {
                    Text(a.model.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 5) {
                        FitBadge(verdict: a.verdict)
                        Chip(text: "\(a.model.bits)-bit")
                        if let p = a.model.totalParamsB { Chip(text: paramLabel(p, a.model.activeParamsB)) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        kv("Size", formatBytes(a.weightsBytes))
                        kv("Speed", "~\(Int(a.tokensPerSecond)) t/s")
                        kv("Context", formatContext(a.recommendedContext))
                        kv("Headroom", a.headroomBytes >= 0 ? formatBytes(UInt64(a.headroomBytes)) : "–")
                    }
                    DownloadButton(meta: a.model)
                } else {
                    Text("–").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() }.font(.system(size: 12))
    }

    private var compare: some View {
        VStack(spacing: 0) {
            row(["Model", "Size", "Fit", "Context", "Speed", "Quality"], header: true)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.comparison) { a in
                        row([a.model.displayName, formatBytes(a.weightsBytes), a.verdict.label, formatContext(a.recommendedContext),
                             "\(Int(a.tokensPerSecond)) t/s", String(format: "%.0f", a.quality)], verdict: a.verdict)
                            .onTapGesture { selected = a.id; tab = .context }
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cardStroke))
    }

    private func row(_ cells: [String], header: Bool = false, verdict: FitVerdict? = nil) -> some View {
        HStack {
            ForEach(cells.indices, id: \.self) { i in
                Text(cells[i])
                    .font(.system(size: header ? 10.5 : 12.5, weight: header ? .semibold : .regular))
                    .foregroundStyle(header ? Color.secondary : (i == 2 ? fitColor(verdict ?? .comfortable) : Color.primary))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : .trailing)
                    .layoutPriority(i == 0 ? 1 : 0)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, header ? 8 : 9)
        .contentShape(Rectangle())
    }

    private var contextTab: some View {
        let a = model.comparison.first { $0.id == selected } ?? model.recommendations?.bestOverall
        return Group {
            if let a {
                HStack(alignment: .top, spacing: 14) {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            CardTitle(text: a.model.displayName, trailing: "Memory by context")
                            let adv = model.advisor
                            ForEach(Advisor.contextSteps, id: \.self) { step in
                                let kvBytes = a.model.kvBytesPerToken() * Double(step)
                                let total = Double(a.weightsBytes) + kvBytes
                                let ok = total <= Double(adv.budgetBytes)
                                HStack {
                                    Text(formatContext(step)).frame(width: 60, alignment: .leading)
                                    ProgressBar(fraction: total / Double(max(adv.budgetBytes, 1)), color: ok ? .good : .bad)
                                    Text(formatBytes(UInt64(total))).monospacedDigit().frame(width: 70, alignment: .trailing)
                                }
                                .font(.system(size: 12))
                            }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            CardTitle(text: "Command", trailing: "Context \(formatContext(a.recommendedContext))")
                            let cmd = command(for: a)
                            CodeBlock(text: cmd, height: 190)
                            HStack {
                                Button("Copy") { model.copy(cmd) }.buttonStyle(.pill)
                                Button("Use settings") {
                                    model.select(model: a.model.id)
                                    model.draft.contextLength = a.recommendedContext
                                }.buttonStyle(.pill)
                            }
                        }
                    }
                }
            }
        }
    }

    private func command(for a: Assessment) -> String {
        var s = ServerSettings(modelID: a.model.id)
        s.contextLength = a.recommendedContext
        return s.commandPreview(supported: model.supportedFlags, executable: "mlx_lm.server")
    }
}
