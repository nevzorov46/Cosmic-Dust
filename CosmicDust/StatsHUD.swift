import SwiftUI

/// Live metrics plus the case-study controls: submission mode and particle count.
struct StatsHUD: View {
    @ObservedObject var renderer: Renderer
    @ObservedObject var demo: DemoDirector
    @State private var countExponent: Double = log10(200_000)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metrics
            Spacer()
            controls
        }
        .padding(16)
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 3) {
            metricRow("FPS", String(format: "%.0f", renderer.stats.fps))
            metricRow("CPU sim", String(format: "%.2f ms", renderer.stats.cpuSimMs))
            metricRow("CPU encode", String(format: "%.2f ms", renderer.stats.cpuEncodeMs))
            metricRow("GPU", String(format: "%.2f ms", renderer.stats.gpuMs))
            metricRow("Draw calls", renderer.stats.drawCalls.formatted())
            metricRow("Particles", renderer.stats.particleCount.formatted())
        }
        .font(.system(size: 17, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.92))
        .padding(14)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func labeledPicker<T: TitledOption>(_ label: String, selection: Binding<T>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 86, alignment: .leading)
            Picker(label, selection: selection) {
                ForEach(Array(T.allCases)) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 24)
            Text(value)
        }
        .frame(width: 240)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Button(demo.isRunning ? "Demo tour running…" : "▶ Demo tour") {
                    demo.start(renderer)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(demo.isRunning ? .orange : .white.opacity(0.7))
                .disabled(demo.isRunning)
            }

            labeledPicker("Simulation", selection: $renderer.simulationMode)

            if renderer.simulationMode == .cpu {
                Text("Swift loop + full buffer upload every frame — capped at \(Renderer.cpuModeCap.formatted()).")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            labeledPicker("Submission", selection: $renderer.mode)

            if renderer.mode == .naive {
                Text("One draw call per particle — capped at \(Renderer.naiveModeCap.formatted()). That cap is the case study.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            HStack {
                Slider(value: $countExponent, in: 3...6)
                    .onChange(of: countExponent) { _, newValue in
                        let raw = Int(pow(10, newValue))
                        renderer.requestedParticleCount = max(1_000, (raw / 1_000) * 1_000)
                    }
                Text(renderer.requestedParticleCount.formatted())
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 90, alignment: .trailing)
            }
        }
        .padding(12)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}
