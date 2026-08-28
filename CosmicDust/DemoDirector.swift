import Foundation
import simd

/// Scripted tour of the case-study toggles for hands-free screen recordings.
/// Starts automatically with the "-demo" launch argument, or manually from the HUD.
/// Cut for social video: no intro, the before/after contrast lands in the first seconds.
@MainActor
final class DemoDirector: ObservableObject {
    static let isRequested = ProcessInfo.processInfo.arguments.contains("-demo")

    @Published private(set) var isRunning = false

    private var task: Task<Void, Never>?

    func start(_ renderer: Renderer) {
        guard task == nil else { return }
        isRunning = true
        task = Task { [weak renderer] in
            let start = Date()
            while !Task.isCancelled {
                guard let renderer else { break }
                let t = Date().timeIntervalSince(start)
                if t > 21 { break }
                Self.applyScript(at: t, to: renderer)
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
            task = nil
            isRunning = false
        }
    }

    private static func applyScript(at t: TimeInterval, to renderer: Renderer) {
        let phase = Float(t)
        switch t {
        case ..<4:
            // Open on the "before": one draw call per particle, capped and thin
            renderer.simulationMode = .gpu
            renderer.mode = .naive
            renderer.requestedParticleCount = 500_000
            renderer.setDemoWell(unit: nil)
        case ..<10:
            // The reveal: same app, one instanced draw — 25x the particles, plus touch
            renderer.mode = .instanced
            renderer.setDemoWell(unit: SIMD2<Float>(0.55 * sin(1.1 * phase), 0.6 * sin(1.6 * phase)))
        case ..<14:
            // Case 02 "before": CPU simulation, visibly janky
            renderer.setDemoWell(unit: nil)
            renderer.simulationMode = .cpu
            renderer.requestedParticleCount = 20_000
        default:
            // Finale: 500k free-drifting — the sweet spot of look and speed on
            // today's phones. The full million returns here once the bandwidth
            // and overdraw case studies earn it.
            renderer.simulationMode = .gpu
            renderer.requestedParticleCount = 500_000
        }
    }
}
