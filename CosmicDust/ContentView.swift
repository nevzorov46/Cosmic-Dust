import MetalKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = RendererModel()
    @StateObject private var demo = DemoDirector()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let renderer = model.renderer {
                MetalView(renderer: renderer).ignoresSafeArea()
                StatsHUD(renderer: renderer, demo: demo)
                #if targetEnvironment(simulator)
                VStack {
                    Text("SIMULATOR PREVIEW — NOT A BENCHMARK")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.8))
                        .padding(.top, 2)
                    Spacer()
                }
                #endif
            } else {
                Text("Metal is not available on this device")
                    .foregroundStyle(.secondary)
            }
        }
        .persistentSystemOverlays(.hidden)
        .task {
            if DemoDirector.isRequested, let renderer = model.renderer {
                demo.start(renderer)
            }
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
