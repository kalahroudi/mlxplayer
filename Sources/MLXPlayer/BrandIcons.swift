import SwiftUI
import AppKit

/// The app mark: five rounded bars whose lengths form a play triangle. The middle bar is the live model.
enum Brand {
    /// Bar lengths as a fraction of the longest bar, top to bottom.
    static let lengths: [CGFloat] = [1.0 / 3, 2.0 / 3, 1, 2.0 / 3, 1.0 / 3]

    /// Template image for the menu bar. `dim` draws the "no model" state, `loading` highlights the middle bar,
    /// `attention` adds a corner dot.
    static func menuBarImage(dim: Bool = false, loading: Bool = false, attention: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            let barHeight: CGFloat = 2, gap: CGFloat = 1.25, x: CGFloat = 3, maxWidth: CGFloat = 12
            for (i, fraction) in lengths.enumerated() {
                let y = 1.5 + CGFloat(i) * (barHeight + gap)
                let rect = NSRect(x: x, y: y, width: maxWidth * fraction, height: barHeight)
                var alpha: CGFloat = 1
                if dim { alpha = 0.45 }
                if loading && i != 2 { alpha = 0.5 }
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            }
            if attention {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12.4, y: 0.9, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Draws the full-colour app icon at any size, used for the Dock tile and the About screen.
    static func appIconImage(size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let s = rect.width / 1024
            let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
            let path = NSBezierPath(roundedRect: tile, xRadius: 186 * s, yRadius: 186 * s)
            let gradient = NSGradient(colors: [NSColor(red: 0.482, green: 0.525, blue: 1, alpha: 1),
                                               NSColor(red: 0.227, green: 0.235, blue: 0.796, alpha: 1)])
            gradient?.draw(in: path, angle: -55)
            NSColor.white.withAlphaComponent(0.22).setStroke()
            path.lineWidth = 3 * s
            path.stroke()
            let longest: CGFloat = 330 * s
            for (i, fraction) in lengths.enumerated() {
                let r = NSRect(x: 347 * s, y: (314 + CGFloat(i) * 86) * s, width: longest * fraction, height: 52 * s)
                (i == 2 ? NSColor(red: 0.486, green: 0.949, blue: 0.753, alpha: 1) : NSColor.white.withAlphaComponent(0.96)).setFill()
                NSBezierPath(roundedRect: r, xRadius: 26 * s, yRadius: 26 * s).fill()
            }
            return true
        }
    }
}

/// SwiftUI view of the app icon, for headers and the setup screen.
struct AppMark: View {
    var size: CGFloat = 30
    var body: some View {
        Image(nsImage: Brand.appIconImage(size: size * 2))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
