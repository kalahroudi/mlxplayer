import SwiftUI
import MLXPlayerCore

// Shared building blocks: right-side overlay, copy icon, help popover, skeleton loading, filter menu.

/// Slides a pane in from the right over the current screen. Click outside or press Esc to close.
/// Actions that need a form or detail open here, so the user never leaves the list.
private struct SideOverlayModifier<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    var width: CGFloat
    @ViewBuilder var panel: Panel

    func body(content: Content) -> some View {
        content.overlay {
            ZStack(alignment: .trailing) {
                if isPresented {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                        .transition(.opacity)
                    VStack(spacing: 0) {
                        HStack {
                            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Button { close() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .keyboardShortcut(.cancelAction)
                                .help("Close")
                        }
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        Divider()
                        ScrollView { panel.padding(18).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .leading) { Divider() }
                    .shadow(color: .black.opacity(0.18), radius: 18, x: -4)
                    .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.18), value: isPresented)
        }
    }

    private func close() { isPresented = false }
}

extension View {
    func sideOverlay<P: View>(isPresented: Binding<Bool>, title: String, width: CGFloat = 440,
                              @ViewBuilder panel: @escaping () -> P) -> some View {
        modifier(SideOverlayModifier(isPresented: isPresented, title: title, width: width, panel: panel))
    }
}

/// Small copy icon with no padding. Flips to a check for a moment after copying.
struct CopyIcon: View {
    @Environment(AppModel.self) private var model
    let text: String
    var help = "Copy"
    @State private var done = false

    var body: some View {
        Button {
            model.copy(text)
            done = true
            Task { try? await Task.sleep(for: .seconds(1.2)); done = false }
        } label: {
            Image(systemName: done ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(done ? Color.good : .secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// "?" button that opens a short explanation. Keeps terminology one click away on every screen.
struct HelpButton: View {
    let title: String
    let entries: [(term: String, meaning: String)]
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle").font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("What is this?")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 13, weight: .semibold))
                ForEach(entries.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entries[i].term).font(.system(size: 12, weight: .semibold))
                        Text(entries[i].meaning).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16).frame(width: 340, alignment: .leading)
        }
    }
}

/// Placeholder rows shown while the first page loads, so the screen never appears half filled.
struct SkeletonRows: View {
    var count = 8
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        bar(width: 180 + CGFloat((i * 37) % 90), height: 12)
                        bar(width: 120 + CGFloat((i * 23) % 60), height: 9)
                    }
                    Spacer()
                    bar(width: 60, height: 12)
                    bar(width: 70, height: 22)
                    bar(width: 96, height: 26)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                Divider().opacity(0.4)
            }
        }
        .opacity(pulse ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityLabel("Loading")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)).frame(width: width, height: height)
    }
}

/// A filter that collapses to one button. The popover holds the options with Select all and Clear.
struct FilterMenu<T: Hashable>: View {
    let title: String
    let options: [(T, String)]
    @Binding var selection: Set<T>
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12.5))
                if !selection.isEmpty { Chip(text: "\(selection.count)", selected: true) }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selection.isEmpty ? Color.primary.opacity(0.06) : Color.accentIndigo.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selection.isEmpty ? Color.primary.opacity(0.1) : Color.accentIndigo.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Select all") { selection = Set(options.map(\.0)) }.buttonStyle(.plain)
                        .foregroundStyle(Color.accentIndigo).disabled(selection.count == options.count)
                    Button("Clear") { selection = [] }.buttonStyle(.plain)
                        .foregroundStyle(Color.accentIndigo).disabled(selection.isEmpty)
                }
                .font(.system(size: 12))
                ChipSet(options: options, selection: $selection)
            }
            .padding(16).frame(width: 300, alignment: .leading)
        }
    }
}
