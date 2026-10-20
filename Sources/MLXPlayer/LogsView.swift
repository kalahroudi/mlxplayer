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
            LogPane(lines: lines, maxLines: 600, emptyText: filter.isEmpty ? "No log lines yet" : "No matches")
        }
    }
}
