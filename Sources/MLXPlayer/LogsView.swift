import SwiftUI
import MLXPlayerCore

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    var body: some View {
        let lines = filter.isEmpty ? model.logLines : model.logLines.filter { $0.localizedCaseInsensitiveContains(filter) }
        ScreenFrame {
            PageHeader(title: "Logs", subtitle: "Last \(model.logLines.count) lines") {
                HStack(spacing: 8) {
                    TextBox(placeholder: "Filter", text: $filter, width: 180, mono: false)
                    Button("Copy") { model.copy(lines.joined(separator: "\n")) }.buttonStyle(.pill)
                    Button("Clear") { model.logs.clear(); model.logLines = [] }.buttonStyle(.pill)
                }
            }
        } content: {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.suffix(600).enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).id(i)
                        }
                    }
                    .padding(12)
                }
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cardStroke))
                .onChange(of: lines.count) { _, _ in proxy.scrollTo(min(lines.count, 600) - 1, anchor: .bottom) }
            }
        }
    }
}
