import SwiftUI
import MLXPlayerCore

/// Bird's-eye view of the machine: memory, GPU and its memory (VRAM), CPU and the model server, on one screen.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    private let help: [(term: String, meaning: String)] = [
        ("Unified memory", "On Apple silicon the CPU and GPU share one pool of memory, so there is no separate VRAM. The 'VRAM' gauge shows how much of that pool the GPU is using against its limit."),
        ("GPU limit", "macOS lets the GPU wire only part of memory (about 2/3 to 3/4). A model larger than this limit cannot load. Raise it on the Memory screen."),
        ("Wired", "Memory that cannot be swapped out. GPU buffers for the loaded model live here."),
        ("Apps", "Memory used by running programs, including the Python process serving the model."),
        ("Compressed", "Idle app memory that macOS squeezed to avoid swapping. A growing number means memory is getting tight."),
        ("Cached", "Files and purgeable data macOS can drop instantly. It counts as available."),
        ("Pressure", "macOS's own verdict on memory health: Normal, Warning, High, Critical."),
    ]

    var body: some View {
        let s = model.system
        let hw = model.hardware
        ScreenFrame {
            PageHeader(title: "Overview", subtitle: "\(hw.chip) · \(formatBytes(hw.memoryBytes)) unified memory · \(hw.gpuCores) GPU cores") {
                HStack(spacing: 10) {
                    StatusPill(text: "Pressure \(model.memoryPressure.label)", color: pressureColor)
                    HelpButton(title: "Reading this screen", entries: help)
                }
            }
        } content: {
            HStack(alignment: .top, spacing: 14) {
                GaugeCard(title: "Memory", value: usedFraction(s), headline: formatBytes(s.memory.used),
                          detail: "of \(formatBytes(s.memory.total))", history: model.memoryHistory, color: memoryColor(usedFraction(s)))
                GaugeCard(title: "GPU", value: s.gpu ?? 0, headline: s.gpu.map { "\(Int($0 * 100))%" } ?? "–",
                          detail: "\(hw.gpuCores) cores", history: model.gpuHistory, color: .seriesTeal)
                GaugeCard(title: "VRAM", value: vramFraction(s), headline: s.gpuMemoryBytes.map(formatBytes) ?? "–",
                          detail: "of \(formatBytes(hw.gpuLimitBytes)) limit", history: model.vramHistory, color: .accentIndigo)
                GaugeCard(title: "CPU", value: s.cpu, headline: "\(Int(s.cpu * 100))%",
                          detail: "\(hw.cpuCores) cores", history: model.cpuHistory, color: .warn)
            }
            HStack(alignment: .top, spacing: 14) {
                memoryMap(s).frame(maxWidth: .infinity)
                coresCard(s).frame(width: 380)
            }
            HStack(alignment: .top, spacing: 14) {
                serverCard
                healthCard(s).frame(width: 380)
            }
        }
    }

    // MARK: Helpers

    private func usedFraction(_ s: SystemSnapshot) -> Double { Double(s.memory.used) / Double(max(s.memory.total, 1)) }
    private func vramFraction(_ s: SystemSnapshot) -> Double {
        Double(s.gpuMemoryBytes ?? 0) / Double(max(model.hardware.gpuLimitBytes, 1))
    }
    private func memoryColor(_ f: Double) -> Color { f > 0.9 ? .bad : (f > 0.75 ? .warn : .good) }
    private var pressureColor: Color {
        switch model.memoryPressure { case .normal: return .good; case .warning: return .warn; default: return .bad }
    }

    // MARK: Memory map

    private func memoryMap(_ s: SystemSnapshot) -> some View {
        let seg = s.memory.segments(modelBytes: model.isRunning ? model.serverMemoryBytes : 0)
        let total = Double(max(s.memory.total, 1))
        let parts: [(String, UInt64, Color)] = [
            ("Model", seg.model, .accentIndigo), ("Wired", seg.wired, .seriesTeal), ("Apps", seg.apps, .warn),
            ("Compressed", seg.compressed, Color.purple), ("Cached", seg.cached, Color.gray.opacity(0.55)),
            ("Free", seg.free, Color.primary.opacity(0.14)),
        ]
        // Kernel categories can overlap by a few percent, so scale to whichever is larger and never overflow.
        let scale = max(total, Double(parts.reduce(0) { $0 + $1.1 }))
        let limitFraction = Double(model.hardware.gpuLimitBytes) / scale
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(text: "Memory map", trailing: "\(formatBytes(s.memory.total)) total")
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        HStack(spacing: 1.5) {
                            ForEach(parts.indices, id: \.self) { i in
                                parts[i].2
                                    .frame(width: max(geo.size.width * Double(parts[i].1) / scale - 1.5, 0))
                            }
                            Spacer(minLength: 0)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 2)
                            .offset(x: geo.size.width * limitFraction - 1)
                    }
                }
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                Text("Marker: GPU limit, \(formatBytes(model.hardware.gpuLimitBytes)). A model plus its context must fit left of it.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 12) {
                    ForEach(parts.indices, id: \.self) { i in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 3).fill(parts[i].2).frame(width: 10, height: 10)
                            Text(parts[i].0).font(.system(size: 12))
                            Spacer(minLength: 4)
                            Text(formatBytes(parts[i].1)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    // MARK: CPU cores

    private func coresCard(_ s: SystemSnapshot) -> some View {
        let efficiency = max(model.hardware.cpuCores - model.hardware.performanceCores, 0)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(text: "CPU cores", trailing: "\(model.hardware.performanceCores) performance · \(efficiency) efficiency")
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(s.cpuCores.indices, id: \.self) { i in
                        let isEfficiency = i < efficiency
                        VStack(spacing: 3) {
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                                RoundedRectangle(cornerRadius: 3).fill(isEfficiency ? Color.seriesTeal : Color.warn)
                                    .frame(height: max(112 * s.cpuCores[i], 2))
                            }
                            .frame(height: 112)
                            Text(isEfficiency ? "E" : "P").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .animation(.easeOut(duration: 0.3), value: s.cpuCores)
            }
        }
    }

    // MARK: Server

    private var serverCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardTitle(text: "Model server")
                    StatusPill(text: model.isRunning ? "Running" : "Idle", color: model.isRunning ? .good : .secondary)
                }
                if model.isRunning, let id = model.activeModelID {
                    Text(id).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Stat(title: "Memory", value: formatBytes(model.serverMemoryBytes),
                             detail: "\(Int(100 * Double(model.serverMemoryBytes) / Double(max(model.hardware.gpuLimitBytes, 1))))% of GPU limit")
                        Stat(title: "Speed", value: model.tokensPerSecond > 0 ? "\(Int(model.tokensPerSecond)) t/s" : "–")
                        Stat(title: "Context", value: "\(model.draft.contextLength / 1024)K")
                        Stat(title: "Uptime", value: formatDuration(model.uptime))
                    }
                } else {
                    Text("No model loaded. It loads on the first request, or start one from Server or Library.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Library") { nav.screen = .library }.buttonStyle(.pill)
                        Button("Discover") { nav.screen = .discover }.buttonStyle(.pill)
                    }
                }
            }
        }
    }

    @Environment(Navigator.self) private var nav

    private func healthCard(_ s: SystemSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(text: "Health")
                healthRow("Memory pressure", model.memoryPressure.label, pressureColor)
                healthRow("Swap used", formatBytes(s.swapBytes), s.swapBytes > 1_073_741_824 ? .warn : .good)
                healthRow("Thermal", thermalLabel(s.thermal), s.thermal == .nominal ? .good : (s.thermal == .fair ? .warn : .bad))
            }
        }
    }

    private func healthRow(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack {
            StatusDot(color: color)
            Text(title).font(.system(size: 12.5))
            Spacer()
            Text(value).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
        }
    }

    private func thermalLabel(_ t: ProcessInfo.ThermalState) -> String {
        switch t { case .nominal: return "Cool"; case .fair: return "Warm"; case .serious: return "Hot"; case .critical: return "Throttling"; @unknown default: return "–" }
    }
}

/// Ring with a headline number, a caption and a short history, one per resource.
struct GaugeCard: View {
    let title: String
    let value: Double
    let headline: String
    let detail: String
    let history: [Double]
    let color: Color

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(text: title)
                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.1), lineWidth: 9)
                        Circle().trim(from: 0, to: min(max(value, 0), 1))
                            .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.5), value: value)
                        Text("\(Int(min(max(value, 0), 1) * 100))%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    }
                    .frame(width: 66, height: 66)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline).font(.system(size: 20, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                AreaChart(values: history, color: color).frame(height: 84)
            }
        }
    }
}

/// Filled line chart on a fixed 0...1 scale, newest value on the right.
struct AreaChart: View {
    let values: [Double]
    var color: Color = .good
    var body: some View {
        GeometryReader { geo in
            let pts: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                        y: geo.size.height * (1 - CGFloat(min(max(v, 0), 1))))
            }
            ZStack {
                VStack { Divider().opacity(0.5); Spacer(); Divider().opacity(0.5) }
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0]); pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}
