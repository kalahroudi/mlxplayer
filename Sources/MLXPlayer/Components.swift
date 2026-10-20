import SwiftUI
import MLXPlayerCore

/// Wraps children onto new lines when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 300, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (i, origin) in result.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

/// Chip group that toggles membership in a set.
struct ChipSet<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: Set<T>
    var body: some View {
        FlowLayout {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                ChipButton(text: title, selected: selection.contains(value)) {
                    if selection.contains(value) { selection.remove(value) } else { selection.insert(value) }
                }
            }
        }
    }
}

struct FitBadge: View {
    let verdict: FitVerdict
    var body: some View { Chip(text: verdict.label, tint: fitColor(verdict)) }
}

/// A big number with a small caption, used in KPI rows.
struct Stat: View {
    let title: String
    let value: String
    var detail: String?
    /// Set when several stats sit in a row so they share one height.
    var minHeight: CGFloat?
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Label2(title)
                Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(minHeight: minHeight, alignment: .topLeading)
        }
    }
}

struct TabStrip<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var body: some View { Segmented(options: options, selection: $selection) }
}
