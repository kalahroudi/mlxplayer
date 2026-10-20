import SwiftUI
import MLXPlayerCore

struct ServerView: View {
    enum Tab: Hashable { case context, sampling, model, network }
    enum Rail: Hashable { case endpoint, command, log }
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .context
    @State private var rail: Rail = .endpoint

    var body: some View {
        ScreenFrame {
            header
        } content: {
            if !model.pendingChanges.isEmpty { banner }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    TabStrip(options: [(Tab.context, "Context & memory"), (.sampling, "Sampling"), (.model, "Model"), (.network, "Network")],
                             selection: $tab)
                    Card { VStack(spacing: 0) { settings } }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 14) {
                    budget
                    railCard
                }
                .frame(width: 400)
            }
        }
        .onChange(of: model.draft) { _, _ in model.saveDraft() }
    }

    // MARK: Header

    private var header: some View {
        let name = model.draft.modelID.isEmpty ? "No model" : ModelMetadata.fromName(model.draft.modelID).displayName
        return PageHeader(title: "Server", subtitle: name) {
            HStack(spacing: 8) {
                if model.isRunning {
                    Button("Restart") { Task { await model.restartServer() } }.buttonStyle(.pill)
                    Button("Stop") { Task { await model.stopServer() } }.buttonStyle(.pill)
                } else if model.serverState.isStarting {
                    ProgressView().controlSize(.small)
                    Text(model.serverState.startingDetail ?? "Loading").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button("Start") { Task { await model.startServer() } }
                        .buttonStyle(.pillPrimary).disabled(model.draft.modelID.isEmpty)
                }
            }
        }
    }

    private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Color.warn)
            Text("Changes: \(model.pendingChanges.joined(separator: ", "))").font(.system(size: 12.5)).lineLimit(1)
            Spacer()
            Button("Revert") { model.revertDraft() }.buttonStyle(.pill(height: 24))
            Button("Apply") { Task { await model.applyAndRestart() } }.buttonStyle(.pillPrimary)
        }
        .padding(10)
        .background(Color.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Settings tabs

    @ViewBuilder private var settings: some View {
        @Bindable var model = model
        switch tab {
        case .context:
            SettingRow(title: "Context length", detail: contextHint) {
                Picker("", selection: $model.draft.contextLength) {
                    ForEach(contextOptions, id: \.self) { Text(formatContext($0)).tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            ToggleRow(title: "Prompt cache", detail: "Reuses work between requests", isOn: $model.draft.promptCacheEnabled)
            SettingRow(title: "Cache size") {
                SliderField(value: $model.draft.promptCacheGB, range: 1...64, step: 1, format: "%.0f GB")
            }
            SettingRow(title: "KV cache", detail: model.draft.kvBits == nil ? nil : "One request at a time") {
                Picker("", selection: $model.draft.kvBits) {
                    Text("Full").tag(Int?.none)
                    Text("8-bit").tag(Int?.some(8))
                    Text("4-bit").tag(Int?.some(4))
                }.labelsHidden().frame(width: 100)
            }
            SettingRow(title: "Prefill step") { NumberField(value: $model.draft.prefillStepSize) }
            SettingRow(title: "Prompt concurrency") { NumberField(value: $model.draft.promptConcurrency) }
            SettingRow(title: "Decode concurrency") { NumberField(value: $model.draft.decodeConcurrency) }
        case .sampling:
            SettingRow(title: "Temperature") { SliderField(value: $model.draft.temperature, range: 0...2) }
            SettingRow(title: "Top P") { SliderField(value: $model.draft.topP, range: 0...1) }
            SettingRow(title: "Top K") { NumberField(value: $model.draft.topK) }
            SettingRow(title: "Min P") { SliderField(value: $model.draft.minP, range: 0...1) }
            SettingRow(title: "Max tokens") { NumberField(value: $model.draft.maxTokens) }
        case .model:
            SettingRow(title: "Model") {
                Picker("", selection: Binding(get: { model.draft.modelID }, set: { model.select(model: $0) })) {
                    if !model.installed.contains(where: { $0.id == model.draft.modelID }) {
                        Text(model.draft.modelID.isEmpty ? "None" : model.draft.modelID).tag(model.draft.modelID)
                    }
                    ForEach(model.installed) { Text($0.meta.displayName).tag($0.id) }
                }
                .labelsHidden().frame(width: 270)
            }
            ToggleRow(title: "Thinking", detail: "Turn off for faster, shorter replies",
                      isOn: Binding(get: { model.draft.chatTemplateArgs == nil },
                                    set: { model.draft.chatTemplateArgs = $0 ? nil : #"{"enable_thinking":false}"# }))
            SettingRow(title: "Draft model", detail: "Speeds up decoding") {
                TextBox(placeholder: "None", text: optionalBinding($model.draft.draftModel))
            }
            SettingRow(title: "Draft tokens") { NumberField(value: $model.draft.numDraftTokens) }
            SettingRow(title: "Chat template") { TextBox(placeholder: "Default", text: optionalBinding($model.draft.chatTemplatePath)) }
            SettingRow(title: "Adapter") { TextBox(placeholder: "None", text: optionalBinding($model.draft.adapterPath)) }
            ToggleRow(title: "Trust remote code", isOn: $model.draft.trustRemoteCode)
        case .network:
            SettingRow(title: "Host") {
                Picker("", selection: $model.draft.host) {
                    Text("This Mac only").tag("127.0.0.1")
                    Text("Local network").tag("0.0.0.0")
                }
                .labelsHidden().frame(width: 150)
            }
            SettingRow(title: "Port") { NumberField(value: $model.draft.port) }
            SettingRow(title: "Allowed origins") { TextBox(placeholder: "*", text: $model.draft.allowedOrigins, width: 200) }
            SettingRow(title: "Log level") {
                Picker("", selection: $model.draft.logLevel) {
                    ForEach(["DEBUG", "INFO", "WARNING", "ERROR"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 120)
            }
            SettingRow(title: "Extra arguments") { TextBox(placeholder: "--flag value", text: $model.draft.extraArguments) }
        }
    }

    private var contextOptions: [Int] {
        var all = Advisor.contextSteps
        if !all.contains(model.draft.contextLength) { all.append(model.draft.contextLength); all.sort() }
        return all
    }

    private var contextHint: String? {
        guard let a = model.currentAssessment, a.safeMaxContext > 0 else { return nil }
        return model.draft.contextLength > a.safeMaxContext ? "Safe up to \(formatContext(a.safeMaxContext)) on this Mac" : nil
    }

    // MARK: Right rail

    private var budget: some View {
        let meta = model.installed.first { $0.id == model.draft.modelID }?.meta ?? ModelMetadata.fromName(model.draft.modelID)
        let adv = model.advisor
        let weights = Double(adv.weightsBytes(meta))
        let kv = meta.kvBytesPerToken(elementBytes: Double(model.draft.kvBits ?? 16) / 8) * Double(model.draft.contextLength)
        let cache = model.draft.promptCacheEnabled ? model.draft.promptCacheGB * 1_073_741_824 : 0
        let budget = Double(adv.budgetBytes)
        let used = weights + kv + cache
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(text: "Memory budget", trailing: "\(formatBytes(UInt64(used))) of \(formatBytes(adv.budgetBytes))")
                StackedBar(segments: [.init(value: weights, color: .accentIndigo), .init(value: kv, color: .seriesTeal),
                                      .init(value: cache, color: .warn)], total: max(budget, used))
                HStack(spacing: 14) {
                    legend("Weights", weights, .accentIndigo)
                    legend("Context", kv, .seriesTeal)
                    legend("Cache", cache, .warn)
                }
                if used > budget {
                    Text("Over budget. Lower context or cache.").font(.system(size: 11.5)).foregroundStyle(Color.bad)
                }
            }
        }
    }

    private func legend(_ name: String, _ bytes: Double, _ color: Color) -> some View {
        HStack(spacing: 5) {
            StatusDot(color: color)
            Text("\(name) \(formatBytes(UInt64(max(bytes, 0))))").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var railCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                TabStrip(options: [(Rail.endpoint, "Endpoint"), (.command, "Command"), (.log, "Log")], selection: $rail)
                switch rail {
                case .endpoint:
                    snippet("Base URL", model.endpoint)
                    snippet("cURL", model.curlSnippet)
                    snippet("Environment", model.envSnippet)
                case .command:
                    let exe = model.app.customServerPath ?? model.paths.mlxServer.path
                    CodeBlock(text: model.draft.commandPreview(supported: model.supportedFlags, executable: exe), height: 300)
                    Button("Copy") { model.copy(model.draft.commandPreview(supported: model.supportedFlags, executable: exe)) }
                        .buttonStyle(.pill(height: 24))
                case .log:
                    CodeBlock(text: model.logLines.suffix(150).joined(separator: "\n"), height: 330)
                }
            }
        }
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Label2(title); Spacer(); Button("Copy") { model.copy(text) }.buttonStyle(.pill(height: 22)) }
            CodeBlock(text: text, height: text.contains("\n") ? 84 : 40)
        }
    }
}
