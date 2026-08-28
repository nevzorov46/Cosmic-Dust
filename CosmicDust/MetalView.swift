import MetalKit
import SwiftUI

/// MTKView wrapper that forwards touches to the renderer as a gravity well.
struct MetalView: UIViewRepresentable {
    let renderer: Renderer

    func makeUIView(context: Context) -> TouchMTKView {
        let view = TouchMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.delegate = renderer
        view.preferredFramesPerSecond = 120
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.008, green: 0.01, blue: 0.028, alpha: 1)
        view.framebufferOnly = true
        view.isMultipleTouchEnabled = false
        view.onTouch = { [weak renderer] location, size in
            renderer?.setTouch(location: location, in: size)
        }
        return view
    }

    func updateUIView(_ view: TouchMTKView, context: Context) {}
}

final class TouchMTKView: MTKView {
    var onTouch: ((CGPoint?, CGSize) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        report(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        report(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouch?(nil, bounds.size)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouch?(nil, bounds.size)
    }

    private func report(_ touches: Set<UITouch>) {
        guard let touch = touches.first else { return }
        onTouch?(touch.location(in: self), bounds.size)
    }
}
