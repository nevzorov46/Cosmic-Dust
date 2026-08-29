import MetalKit
import SwiftUI

struct ContentView: View {
    /// "-clean" hides every overlay for capturing promo stills and video.
    private static let isClean = ProcessInfo.processInfo.arguments.contains("-clean")

    @StateObject private var model = RendererModel()
    @StateObject private var demo = DemoDirector()
    @StateObject private var exporter = WallpaperExporter()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let renderer = model.renderer {
                MetalView(renderer: renderer).ignoresSafeArea()
                if !Self.isClean, !isRecording {
                    StatsHUD(renderer: renderer, demo: demo, exporter: exporter)
                }
                if let note = exportNote {
                    VStack {
                        Spacer()
                        Text(note)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.55), in: Capsule())
                        Spacer()
                    }
                    .transition(.opacity)
                }
                #if targetEnvironment(simulator)
                if !Self.isClean {
                    VStack {
                        Text("SIMULATOR PREVIEW — NOT A BENCHMARK")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.orange.opacity(0.8))
                            .padding(.top, 2)
                        Spacer()
                    }
                }
                #endif
            } else {
                Text("Metal is not available on this device")
                    .foregroundStyle(.secondary)
            }
        }
        .persistentSystemOverlays(.hidden)
        .animation(.easeInOut(duration: 0.25), value: exportNote)
        .task {
            model.renderer?.exporter = exporter
            if DemoDirector.isRequested, let renderer = model.renderer {
                demo.start(renderer)
            }
            // "-wallpaper" records straight after launch, for scripted captures
            if ProcessInfo.processInfo.arguments.contains("-wallpaper") {
                try? await Task.sleep(for: .seconds(1.5))
                exporter.start()
            }
        }
    }

    private var isRecording: Bool {
        if case .capturing = exporter.status { return true }
        return false
    }

    private var exportNote: String? {
        switch exporter.status {
        case .idle, .capturing: return nil
        case .saving: return "Saving live wallpaper…"
        case .saved: return "Saved to Photos — set it from Settings › Wallpaper"
        case .failed(let message): return message
        }
    }
}

/// Owns the renderer so SwiftUI creates it exactly once.
final class RendererModel: ObservableObject {
    let renderer: Renderer?

    init() {
        renderer = MTLCreateSystemDefaultDevice().flatMap(Renderer.init)
    }
}
