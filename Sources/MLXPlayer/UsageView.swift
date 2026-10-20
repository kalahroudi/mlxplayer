import SwiftUI
import AppKit
import MLXPlayerCore

struct UsageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let s = model.usageSummary
        ScreenFrame {
            PageHeader(title: "Usage", subtitle: "Local requests through the proxy") {
                HStack(spacing: 10) {
                    Segmented(options: UsageRange.allCases.map { ($0, $0.label) }, selection: $model.usageRange)
                    Button { exportCSV() } label: { IconLabel(title: "Export", symbol: "square.and.arrow.up") }.buttonStyle(.pill)
                }
            }
        } content: {
            HStack(spacing: 14) {
                Stat(title: "Requests", value: formatCount(s.requests), detail: s.errors > 0 ? "\(s.errors) failed" : nil)
                Stat(title: "Tokens in", value: formatCount(s.tokensIn))
                Stat(title: "Tokens out", value: formatCount(s.tokensOut))
                Stat(title: "Avg speed", value: String(format: "%.0f t/s", s.averageTokensPerSecond),
                     detail: "peak \(Int(s.peakTokensPerSecond))")
                Stat(title: "First token", value: s.medianFirstTokenMs.map { "\($0) ms" } ?? "–", detail: "median")
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle(text: model.usageRange == .today ? "Tokens per hour" : "Tokens per day")
                    chart(s)
                    HStack(spacing: 14) {
                        HStack(spacing: 5) { StatusDot(color: .accentIndigo); Text("In").font(.system(size: 11)).foregroundStyle(.secondary) }
                        HStack(spacing: 5) { StatusDot(color: .liveMint); Text("Out").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                }
            }
            HStack(alignment: .top, spacing: 14) {
                table("By client", s.byClient)
                table("By model", s.byModel)
            }
            Spacer(minLength: 0)
        }
        .onAppear { model.refreshUsage() }
        .onChange(of: model.usageRange) { _, _ in model.refreshUsage() }
    }

    private func chart(_ s: UsageSummary) -> some View {
        let peak = max(s.buckets.map { $0.tokensIn + $0.tokensOut }.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(s.buckets.indices, id: \.self) { i in
                let b = s.buckets[i]
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.liveMint).frame(height: 150 * CGFloat(b.tokensOut) / CGFloat(peak))
                        Rectangle().fill(Color.accentIndigo).frame(height: 150 * CGFloat(b.tokensIn) / CGFloat(peak))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    if s.buckets.count <= 12 || i % 3 == 0 {
                        Text(b.label).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    } else {
                        Text(" ").font(.system(size: 9.5))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 175)
    }

    private func table(_ title: String, _ rows: [UsageSummary.Row]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(text: title)
                if rows.isEmpty { Text("No data").font(.system(size: 12)).foregroundStyle(.secondary) }
                ForEach(rows.prefix(5)) { r in
                    HStack {
                        Text(r.name).font(.system(size: 12.5)).lineLimit(1)
                        Spacer()
                        Text("\(r.requests) req").foregroundStyle(.secondary)
                        Text(formatCount(r.tokensIn + r.tokensOut)).monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mlx-player-usage.csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? model.usage.csv(model.usageRange).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
