import SwiftUI
import OpenAI
import MarkdownUI
import MLXPlayerCore

/// A message in the quick-test conversation.
struct ChatTurn: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var failed = false
}

/// Talks to the local server through the app's own proxy with the MacPaw OpenAI client (standard
/// OpenAI streaming), so a request here loads the model on demand like any other client.
@MainActor @Observable
final class ChatModel {
    var turns: [ChatTurn] = []
    var input = ""
    var sending = false
    var tokensPerSecond: Double?
    var system = ""
    private var task: Task<Void, Never>?

    func send(model: AppModel) {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !sending, let modelID = model.activeModelID ?? model.app.lastModelID else { return }
        input = ""
        turns.append(ChatTurn(role: .user, text: prompt))
        turns.append(ChatTurn(role: .assistant, text: ""))
        let index = turns.count - 1
        var messages: [ChatQuery.ChatCompletionMessageParam] = []
        if !system.isEmpty, let m = ChatQuery.ChatCompletionMessageParam(role: .system, content: system) { messages.append(m) }
        for t in turns.dropLast() {
            if let m = ChatQuery.ChatCompletionMessageParam(role: t.role == .user ? .user : .assistant, content: t.text) { messages.append(m) }
        }
        let client = OpenAI(configuration: .init(token: nil, host: "127.0.0.1", port: model.publicPort, scheme: "http",
                                                  timeoutInterval: 900, customHeaders: ["User-Agent": "MLX Player Chat"]))
        let query = ChatQuery(messages: messages, model: modelID, temperature: model.draft.temperature, stream: true)
        sending = true
        tokensPerSecond = nil
        task = Task { [weak self] in
            let start = Date()
            var first: Date?
            var chunks = 0
            do {
                for try await result in client.chatsStream(query: query) {
                    guard let self else { return }
                    if let piece = result.choices.first?.delta.content, !piece.isEmpty {
                        if first == nil { first = Date() }
                        chunks += 1
                        self.turns[index].text += piece
                        if let f = first, Date().timeIntervalSince(f) > 0.5 {
                            self.tokensPerSecond = Double(chunks) / Date().timeIntervalSince(f)
                        }
                    }
                }
            } catch is CancellationError {
            } catch {
                self?.turns[index].text += (self?.turns[index].text.isEmpty == false ? "\n\n" : "") + error.localizedDescription
                self?.turns[index].failed = true
            }
            _ = start
            self?.sending = false
        }
    }

    func stop() { task?.cancel(); sending = false }
    func clear() { stop(); turns = []; tokensPerSecond = nil }
}

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var chat = ChatModel()
    @FocusState private var focused: Bool

    private var modelName: String? { (model.activeModelID ?? model.app.lastModelID).map { ModelMetadata.fromName($0).displayName } }

    var body: some View {
        ScreenFrame {
            PageHeader(title: "Chat", subtitle: subtitle) {
                HStack(spacing: 8) {
                    if let t = chat.tokensPerSecond { Chip(text: String(format: "%.0f t/s", t), tint: .seriesTeal) }
                    Button("Clear") { chat.clear() }.buttonStyle(.pill).disabled(chat.turns.isEmpty)
                    HelpButton(title: "Quick chat", entries: HelpContent.chat)
                }
            }
        } content: {
            VStack(spacing: 12) {
                transcript
                composer
            }
        }
    }

    private var subtitle: String {
        guard let name = modelName else { return "No model selected" }
        return model.isRunning ? "\(name) · loaded" : "\(name) · loads on first message"
    }

    private var transcript: some View {
        ListPanel {
            if chat.turns.isEmpty {
                VStack(spacing: 6) {
                    Text("Say hello to your model").font(.system(size: 14, weight: .medium))
                    Text("Messages go through the same endpoint your apps use.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 60)
            }
            ForEach(chat.turns) { turn in
                bubble(turn).padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
    }

    private func bubble(_ turn: ChatTurn) -> some View {
        HStack(alignment: .top) {
            if turn.role == .user { Spacer(minLength: 80) }
            Group {
                if turn.role == .assistant && turn.text.isEmpty {
                    ProgressView().controlSize(.small)
                } else if turn.role == .assistant {
                    Markdown(turn.text).markdownTheme(.gitHub).textSelection(.enabled)
                } else {
                    Text(turn.text).textSelection(.enabled)
                }
            }
            .font(.system(size: 13.5))
            .foregroundStyle(turn.failed ? Color.bad : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(turn.role == .user ? Color.accentIndigo.opacity(0.18) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            if turn.role == .assistant { Spacer(minLength: 80) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $chat.input, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...5)
                .padding(.vertical, 8).padding(.horizontal, 10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                .focused($focused)
                .onSubmit { chat.send(model: model) }
            if chat.sending {
                Button("Stop") { chat.stop() }.buttonStyle(.pill)
            } else {
                Button("Send") { chat.send(model: model) }.buttonStyle(.pillPrimary)
                    .disabled(chat.input.trimmingCharacters(in: .whitespaces).isEmpty || modelName == nil)
            }
        }
        .onAppear { focused = true }
    }
}
