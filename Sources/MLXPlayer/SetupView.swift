import SwiftUI
import AppKit
import MLXPlayerCore

struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 18) {
            AppMark(size: 64)
            Text("Set up MLX Player").font(.system(size: 24, weight: .bold))
            detectedCard

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(InstallStep.allCases, id: \.self) { step in stepRow(step) }
                }
            }
            .frame(width: 520)

            if model.isInstalled && !model.installing {
                modelStep
                Toggle(isOn: Binding(get: { model.app.mcpEnabled }, set: { model.setMCP(enabled: $0) })) {
                    Text("Let agents manage models").font(.system(size: 13))
                }
                .toggleStyle(.switch).tint(.accentIndigo).frame(width: 520)
            }

            HStack(spacing: 10) {
                if !model.isInstalled {
                    Button { Task { await model.runSetup() } } label: { Text(model.installing ? "Installing…" : "Install") }
                        .buttonStyle(.pillPrimary).disabled(model.installing)
                    Button("Use existing") { chooseExisting() }.buttonStyle(.pill).disabled(model.installing)
                } else {
                    Button("Done") { model.finishSetup() }.buttonStyle(.pillPrimary)
                }
            }
            if !model.installLog.isEmpty {
                LogPane(lines: model.installLog, height: 150).frame(width: 520)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { if model.isInstalled && model.recommendations == nil { await model.runAdvisor() } }
        .onChange(of: model.isInstalled) { _, installed in
            if installed { Task { await model.runAdvisor() } }
        }
    }

    /// What the app found about this Mac, labelled so it is clear these are detected values.
    private var detectedCard: some View {
        let hw = model.hardware
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal").foregroundStyle(Color.accentIndigo)
                    Label2("Detected on this Mac")
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles").font(.system(size: 10))
                        Text("For smart model suggestions").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(Color.accentIndigo)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentIndigo.opacity(0.14), in: Capsule())
                    .fixedSize()
                }
                HStack(spacing: 0) {
                    detected("Chip", hw.chip.isEmpty ? "Unknown" : hw.chip)
                    detected("Memory", formatBytes(hw.memoryBytes))
                    detected("GPU limit", formatBytes(hw.gpuLimitBytes))
                    detected("Bandwidth", "\(Int(hw.bandwidthGBs)) GB/s" + (hw.bandwidthIsEstimate ? " est." : ""))
                }
            }
        }
        .frame(width: 520)
    }

    private func detected(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepRow(_ step: InstallStep) -> some View {
        let state = model.installStates[step] ?? (model.isInstalled ? .done("") : .pending)
        return HStack(spacing: 10) {
            Group {
                switch state {
                case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.good)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Color.bad)
                }
            }
            .frame(width: 18)
            Text(step.title).font(.system(size: 13, weight: .medium))
            Spacer()
            switch state {
            case .done(let note): Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            case .failed(let note): Text(note).font(.system(size: 11.5)).foregroundStyle(Color.bad).lineLimit(1)
            default: EmptyView()
            }
        }
    }

    private var modelStep: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label2("First model")
                if let best = model.recommendations?.bestOverall {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(best.model.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text("\(formatBytes(best.weightsBytes)) · \(Int(best.tokensPerSecond)) t/s")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        DownloadButton(meta: best.model)
                    }
                } else if model.advisorBusy {
                    HStack { ProgressView().controlSize(.small); Text("Finding a fit…").font(.system(size: 12)).foregroundStyle(.secondary) }
                } else {
                    Text("Pick one later in Discover.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 520)
    }

    private func chooseExisting() {
        let panel = NSOpenPanel()
        panel.message = "Choose mlx_lm.server"
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { model.useExisting(server: url.path) }
    }
}

/// Download / pause / cancel / installed / load control for one model.
struct DownloadButton: View {
    @Environment(AppModel.self) private var model
    let meta: ModelMetadata

    var body: some View {
        let isInstalled = model.installed.contains { $0.id == meta.id }
        if let d = model.downloads[meta.id] {
            if let failed = d.failed {
                HStack(spacing: 6) {
                    Button(failed == "Paused" ? "Resume" : "Retry") { model.resumeDownload(meta) }.buttonStyle(.pill(height: 26))
                    Button { model.cancelDownload(meta.id) } label: { Image(systemName: "xmark") }.buttonStyle(.pill(height: 26))
                }
            } else if d.finished {
                Text("Installed").font(.system(size: 12)).foregroundStyle(Color.good)
            } else {
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 3) {
                        ProgressBar(fraction: d.fraction).frame(width: 90)
                        Text("\(Int(d.fraction * 100))% · \(formatBytes(UInt64(max(d.bytesPerSecond, 0))))/s")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                    Button { model.pauseDownload(meta.id) } label: { Image(systemName: "pause.fill") }.buttonStyle(.pill(height: 26))
                    Button { model.cancelDownload(meta.id) } label: { Image(systemName: "xmark") }.buttonStyle(.pill(height: 26))
                }
            }
        } else if isInstalled {
            Button("Load") { Task { await model.startServer(model: meta.id) } }.buttonStyle(.pill(height: 26))
        } else {
            Button { model.download(meta) } label: { IconLabel(title: "Download", symbol: "arrow.down.circle") }
                .buttonStyle(.pillPrimary)
        }
    }
}
