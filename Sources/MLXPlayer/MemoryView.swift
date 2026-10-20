import SwiftUI
import MLXPlayerCore

struct MemoryView: View {
    enum Tab: Hashable { case live, rules }
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .live

    var body: some View {
        @Bindable var model = model
        ScreenFrame {
            PageHeader(title: "Memory", subtitle: "\(formatBytes(model.hardware.memoryBytes)) unified") {
              HStack(spacing: 10) {
                Segmented(options: [(AppSettings.Profile.performance, "Performance"), (.balanced, "Balanced"), (.saver, "Saver")],
                          selection: Binding(get: { model.app.profile }, set: { p in model.app.apply(profile: p) }))
                HelpButton(title: "Memory and limits", entries: HelpContent.memory)
              }
            }
        } content: {
            TabStrip(options: [(Tab.live, "Live & limits"), (.rules, "Loading & rules")], selection: $tab)
            if tab == .live { live } else { rules }
            Spacer(minLength: 0)
        }
    }

    @State private var limitBusy = false
    @State private var limitNote: String?

    /// Asks macOS for admin rights and sets the limit; it lasts until restart.
    private func applyLimit(_ mb: Int) {
        limitBusy = true; limitNote = nil
        Task {
            do {
                try await GPULimit.apply(mb: mb, totalBytes: model.hardware.memoryBytes)
                model.hardware = HardwareProbe.current()
                limitNote = mb == 0 ? "Reset to default" : "Applied until restart"
            } catch { limitNote = error.localizedDescription }
            limitBusy = false
        }
    }

    private var pressureColor: Color {
        switch model.memoryPressure { case .normal: return .good; case .warning: return .warn; default: return .bad }
    }

    private var live: some View {
        @Bindable var model = model
        let hw = model.hardware
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Stat(title: "Pressure", value: model.memoryPressure.label)
                Stat(title: "Available", value: formatBytes(hw.availableBytes))
                Stat(title: "Model server", value: model.isRunning ? formatBytes(model.serverMemoryBytes) : "–")
                Stat(title: "Swap", value: formatBytes(model.swapBytes))
            }
            HStack(alignment: .top, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        CardTitle(text: "Memory used", trailing: "last \(Int(Double(AppModel.historyLength) * 1.5 / 60 + 0.5)) min")
                        AreaChart(values: model.memoryHistory, color: pressureColor).frame(height: 110)
                        CardTitle(text: "GPU memory", trailing: "of \(formatBytes(hw.gpuLimitBytes)) limit")
                        AreaChart(values: model.vramHistory, color: .accentIndigo).frame(height: 110)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardTitle(text: "GPU memory limit", trailing: formatBytes(hw.gpuLimitBytes))
                        Text("macOS lets the GPU wire part of unified memory. Raise it in Terminal if a model is close.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        let mb = GPULimit.suggestedMB(totalBytes: hw.memoryBytes)
                        CodeBlock(text: "sudo sysctl iogpu.wired_limit_mb=\(mb)", height: 44)
                        HStack {
                            Button("Apply") { applyLimit(mb) }.buttonStyle(.pillPrimary).disabled(limitBusy)
                            Button("Reset") { applyLimit(0) }.buttonStyle(.pill).disabled(limitBusy)
                            Button("Copy") { model.copy("sudo sysctl iogpu.wired_limit_mb=\(mb)") }.buttonStyle(.pill)
                        }
                        if let limitNote { Text(limitNote).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
                        SettingRow(title: "Keep free") {
                            SliderField(value: $model.app.reserveGB, range: 2...32, step: 1, format: "%.0f GB")
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(text: "Events")
                    if model.memoryEvents.isEmpty {
                        Text("Nothing yet").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.memoryEvents.prefix(5).enumerated()), id: \.offset) { _, e in
                        HStack {
                            Text(e.time, style: .time).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                            Text(e.text).font(.system(size: 12.5)).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var rules: some View {
        @Bindable var model = model
        return HStack(alignment: .top, spacing: 14) {
            Card {
                VStack(spacing: 0) {
                    CardTitle(text: "Loading").padding(.bottom, 6)
                    ToggleRow(title: "Load on first request", isOn: $model.app.onDemandLoading)
                    SettingRow(title: "Unload when idle") {
                        Picker("", selection: $model.app.idleUnloadMinutes) {
                            Text("Never").tag(0)
                            ForEach([5, 15, 30, 60, 120], id: \.self) { Text("\($0) min").tag($0) }
                        }.labelsHidden().frame(width: 100)
                    }
                    ToggleRow(title: "Unload on sleep", isOn: $model.app.unloadOnSleep)
                    ToggleRow(title: "Unload on screen lock", isOn: $model.app.unloadOnScreenLock)
                    ToggleRow(title: "Load at login", isOn: $model.app.preloadAtLogin)
                    ToggleRow(title: "Switch by request", detail: "Use the request's model name", isOn: $model.app.switchModelsByRequest)
                }
            }
            VStack(spacing: 14) {
                Card {
                    VStack(spacing: 0) {
                        CardTitle(text: "When memory is tight").padding(.bottom, 6)
                        ToggleRow(title: "Trim cache on warning", detail: "Applies with a restart when idle", isOn: $model.app.trimCacheOnWarning)
                        SettingRow(title: "Trim to") {
                            Picker("", selection: $model.app.trimCacheToPercent) {
                                ForEach([25, 50, 75], id: \.self) { Text("\($0)%").tag($0) }
                            }.labelsHidden().frame(width: 90)
                        }
                        ToggleRow(title: "Cap context when high", isOn: $model.app.capContextOnHigh)
                        SettingRow(title: "Cap at") {
                            Picker("", selection: $model.app.cappedContext) {
                                ForEach([4_096, 8_192, 16_384, 32_768], id: \.self) { Text(formatContext($0)).tag($0) }
                            }.labelsHidden().frame(width: 90)
                        }
                        ToggleRow(title: "Unload when critical", isOn: $model.app.unloadOnCritical)
                    }
                }
                Card {
                    VStack(spacing: 0) {
                        CardTitle(text: "Safeguards").padding(.bottom, 6)
                        ToggleRow(title: "Check fit before loading", isOn: $model.app.preflightFitCheck)
                        ToggleRow(title: "Reduce context to fit", isOn: $model.app.autoReduceContext)
                    }
                }
            }
        }
    }
}
