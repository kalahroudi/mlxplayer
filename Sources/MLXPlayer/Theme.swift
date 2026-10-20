import SwiftUI
import AppKit

extension Color {
    static let accentIndigo = Color(red: 0.357, green: 0.404, blue: 0.941)
    static let liveMint = Color(red: 0.486, green: 0.949, blue: 0.753)
    static let good = Color(red: 0.29, green: 0.87, blue: 0.61)
    static let warn = Color(red: 0.96, green: 0.71, blue: 0.27)
    static let bad = Color(red: 1.0, green: 0.54, blue: 0.54)
    static let seriesTeal = Color(red: 0.36, green: 0.75, blue: 0.92)
    static let cardFill = Color.primary.opacity(0.045)
    static let cardStroke = Color.primary.opacity(0.08)
}

// MARK: - Containers

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cardStroke))
    }
}

struct CardTitle: View {
    let text: String
    var trailing: String?
    var body: some View {
        HStack {
            Text(text).font(.system(size: 14, weight: .semibold))
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }
    }
}

struct Label2: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

// MARK: - Controls

struct Chip: View {
    let text: String
    var selected = false
    var tint: Color?
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(selected ? Color.white : (tint ?? Color.secondary))
            .background(selected ? Color.accentIndigo : (tint?.opacity(0.14) ?? Color.primary.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: 5))
    }
}

struct ChipButton: View {
    let text: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { Chip(text: text, selected: selected) }
            .buttonStyle(.plain)
    }
}

enum PillKind { case secondary, primary, destructive }

struct PillButtonStyle: ButtonStyle {
    var kind: PillKind = .secondary
    var height: CGFloat = 28
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: height)
            .foregroundStyle(kind == .primary ? Color.white : (kind == .destructive ? Color.bad : Color.primary))
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(kind == .primary ? Color.accentIndigo : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07))
            )
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(kind == .primary ? Color.clear : Color.primary.opacity(0.12)))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillPrimary: PillButtonStyle { PillButtonStyle(kind: .primary) }
    static var pillDestructive: PillButtonStyle { PillButtonStyle(kind: .destructive) }
    static func pill(height: CGFloat) -> PillButtonStyle { PillButtonStyle(height: height) }
}

/// Button label with a leading SF Symbol.
struct IconLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
            Text(title)
        }
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: color)
            Text(text).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(color.opacity(0.13), in: Capsule())
        .fixedSize()
    }
}

/// Segmented control with the app's look.
struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                Button { selection = value } label: {
                    Text(title)
                        .font(.system(size: 12.5, weight: selection == value ? .semibold : .regular))
                        .lineLimit(1)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(selection == value ? Color.primary.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(selection == value ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .fixedSize()
    }
}

// MARK: - Settings rows

struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control
    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.vertical, 9)
        }
    }
}

struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var body: some View {
        SettingRow(title: title, detail: detail) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(.accentIndigo)
        }
    }
}

struct SliderField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var format = "%.2f"
    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step).tint(.accentIndigo).frame(width: 190)
            Text(String(format: format, value))
                .font(.system(size: 12.5, design: .monospaced))
                .frame(width: 64, alignment: .trailing)
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct NumberField: View {
    @Binding var value: Int
    var width: CGFloat = 74
    var body: some View {
        TextField("", value: $value, format: .number.grouping(.never))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 12.5, design: .monospaced))
            .frame(width: width)
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
    }
}

struct DoubleField: View {
    @Binding var value: Double
    var width: CGFloat = 74
    var body: some View {
        TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 12.5, design: .monospaced))
            .frame(width: width)
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
    }
}

struct TextBox: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 270
    var mono = true
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: mono ? .monospaced : .default))
            .frame(width: width)
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
    }
}

func optionalBinding(_ source: Binding<String?>) -> Binding<String> {
    Binding(get: { source.wrappedValue ?? "" }, set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
}

// MARK: - Code & bars

/// Short commands and snippets. Wraps long lines instead of scrolling sideways.
struct CodeBlock: View {
    let text: String
    var height: CGFloat?
    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(height: height)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08)))
    }
}

/// Terminal-style panel for live output. Lines wrap, severity is tinted, and the view follows new
/// lines until the user scrolls up. Fixed dark colors keep it readable in light mode too.
struct LogPane: View {
    let lines: [String]
    var height: CGFloat?
    var maxLines = 400
    var emptyText = "Nothing yet"

    private struct Row: Identifiable { let id: Int; let text: String; let tint: Color }

    private var rows: [Row] {
        let tail = lines.suffix(maxLines)
        let base = lines.count - tail.count
        return tail.enumerated().map { i, raw in
            let text = LogPane.clean(raw)
            return Row(id: base + i, text: text, tint: LogPane.tint(for: text))
        }
    }

    var body: some View {
        let rows = rows
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if rows.isEmpty {
                        Text(emptyText).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.35))
                    }
                    ForEach(rows) { row in
                        Text(row.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(row.tint)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(row.id)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: lines.count) { _, _ in
                if let last = rows.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .frame(height: height)
        .frame(maxHeight: height == nil ? .infinity : nil)
        .background(Color(red: 0.075, green: 0.08, blue: 0.095), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }

    /// Removes ANSI color codes and carriage returns that tools like uv and hf emit.
    static func clean(_ line: String) -> String {
        var out = line
        if out.contains("\u{1B}") {
            out = out.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        }
        return out.replacingOccurrences(of: "\r", with: "")
    }

    static func tint(for line: String) -> Color {
        let l = line.lowercased()
        if l.contains("error") || l.contains("failed") || l.contains("traceback") || l.contains("fatal") { return .bad }
        if l.contains("warn") { return .warn }
        if l.hasPrefix("downloading") || l.hasPrefix("resolved") || l.hasPrefix("prepared") || l.hasPrefix("audited") {
            return Color.white.opacity(0.55)
        }
        if l.hasPrefix("installed") || l.contains("ready") || l.contains("running") { return .good }
        return Color.white.opacity(0.88)
    }
}

struct ProgressBar: View {
    let fraction: Double
    var color: Color = .accentIndigo
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: max(geo.size.width * min(max(fraction, 0), 1), 0))
            }
        }
        .frame(height: height)
    }
}

struct StackedBar: View {
    struct Segment: Identifiable { let id = UUID(); let value: Double; let color: Color }
    let segments: [Segment]
    let total: Double
    var height: CGFloat = 12
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segments) { s in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(s.color)
                        .frame(width: max(geo.size.width * s.value / max(total, 1) - 2, 0))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .clipShape(Capsule())
    }
}

struct Sparkline: View {
    let values: [Double]
    var color: Color = .good
    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            Path { path in
                guard values.count > 1 else { return }
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = geo.size.height * (1 - CGFloat(v / maxV))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Formatting

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    if s >= 60 { return "\(s / 60)m" }
    return "\(s)s"
}

func formatCount(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
    if n >= 1000 { return String(format: "%.0fK", Double(n) / 1000) }
    return "\(n)"
}
