import SwiftUI
import MLXPlayerCore

struct UpdatesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let u = model.updater
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(spacing: 0) {
                    SettingRow(title: "Installed", detail: u.build.isDirty ? "Built with local changes" : nil) {
                        Text("\(u.build.version) · \(u.build.shortCommit)").font(.system(size: 12.5, design: .monospaced))
                    }
                    SettingRow(title: "Source", detail: "Updates come from this branch") {
                        Text("\(u.build.repo) · \(u.build.branch)").font(.system(size: 12.5, design: .monospaced))
                    }
                    ToggleRow(title: "Check daily", detail: "One small request to GitHub", isOn: $model.app.autoCheckUpdates)
                    SettingRow(title: "Status", detail: statusDetail(u)) {
                        HStack(spacing: 8) {
                            if u.busy { ProgressView().controlSize(.small) }
                            Text(statusText(u)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(statusColor(u))
                            if let info = u.available {
                                Button { Task { await u.install() } } label: { Text("Update to \(info.shortSha)") }
                                    .buttonStyle(.pillPrimary).disabled(u.busy)
                            }
                            Button("Check") { Task { await u.check() } }.buttonStyle(.pill).disabled(u.busy)
                        }
                    }
                }
            }
            .frame(maxWidth: 700)

            if let notice = u.notice {
                Text(notice).font(.system(size: 12.5)).foregroundStyle(Color.warn).frame(maxWidth: 700, alignment: .leading)
            }
            if let info = u.available, !info.summaries.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 5) {
                        CardTitle(text: "What's new", trailing: "\(info.aheadBy) commits")
                        ForEach(Array(info.summaries.reversed().enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 12)).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: 700)
            }
            if !u.log.isEmpty {
                CodeBlock(text: u.log.suffix(40).joined(separator: "\n"), height: 150).frame(maxWidth: 700)
            }
        }
    }

    private func statusText(_ u: Updater) -> String {
        switch u.phase {
        case .checking: return "Checking…"
        case .working(let s): return s
        case .failed: return "Failed"
        case .idle:
            switch u.status {
            case .upToDate: return "Up to date"
            case .available: return "Update available"
            case .notComparable: return "Not comparable"
            case nil: return u.isBundled ? "Not checked" : "Development build"
            }
        }
    }

    private func statusDetail(_ u: Updater) -> String? {
        if case .failed(let m) = u.phase { return m }
        if case .notComparable(let m)? = u.status { return m }
        if let d = u.lastChecked { return "Checked \(d.formatted(.relative(presentation: .named)))" }
        return u.isBundled ? "Builds from source with Xcode tools. The old version is restored if the new one fails to start." : nil
    }

    private func statusColor(_ u: Updater) -> Color {
        if case .failed = u.phase { return .bad }
        if u.available != nil { return .accentIndigo }
        if case .upToDate? = u.status { return .good }
        return .secondary
    }
}
