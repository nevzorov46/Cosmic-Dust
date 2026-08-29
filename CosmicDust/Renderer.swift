import Foundation
import Metal
import MetalKit
import QuartzCore
import simd

/// Option enums the HUD can render as a labeled segmented picker.
protocol TitledOption: CaseIterable, Identifiable, Hashable {
    var title: String { get }
}

enum SimulationMode: String, TitledOption {
    case cpu
    case gpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        }
    }
}

enum SubmissionMode: String, TitledOption {
    case naive
    case instanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .naive: return "Naive"
        case .instanced: return "Instanced"
        }
    }
}

struct RenderStats {
    var fps: Double = 0
    var cpuSimMs: Double = 0
    var cpuEncodeMs: Double = 0
    var gpuMs: Double = 0
    var drawCalls: Int = 0
    var particleCount: Int = 0
}

final class Renderer: NSObject, MTKViewDelegate, ObservableObject {
    static let maxParticles = 1_000_000
    // The naive path submits one draw call per particle; past this count a single
    // frame takes seconds, which is the case study's whole point.
    static let naiveModeCap = 20_000
    // The CPU path runs the same physics in a single-threaded Swift loop and
    // re-uploads the whole buffer every frame; this cap keeps the app responsive.
    static let cpuModeCap = 100_000

    @Published var stats = RenderStats()
    @Published var mode: SubmissionMode = .instanced
    @Published var simulationMode: SimulationMode = .gpu

    var requestedParticleCount = 200_000

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let computePipeline: MTLComputePipelineState
    private let instancedPipeline: MTLRenderPipelineState
    private let singlePipeline: MTLRenderPipelineState
    private let particleBuffer: MTLBuffer

    private var aspect: Float = 0.5
    private var pixelsPerUnit: Float = 1000
    private var isSeeded = false

    private var time: Float = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var fpsAverage: Double = 0
    private var lastStatsPublish: CFTimeInterval = 0

    /// Set while a live-wallpaper capture is running; frames are drawn into its
    /// textures and mirrored to the screen.
    weak var exporter: WallpaperExporter?

    // Written by the UI/touch on the main thread, read in draw()
    private var well: SIMD2<Float>?

    // CPU-simulation state: a Swift-side copy of the particles, re-snapshotted
    // from the GPU buffer every time the user switches into CPU mode
    private var cpuParticles: [Particle] = []
    private var cpuStateIsFresh = false

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let updateFunction = library.makeFunction(name: "updateParticles"),
              let instancedVertex = library.makeFunction(name: "particleVertexInstanced"),
              let singleVertex = library.makeFunction(name: "particleVertexSingle"),
              let fragment = library.makeFunction(name: "particleFragment"),
              let buffer = device.makeBuffer(
                  length: MemoryLayout<Particle>.stride * Self.maxParticles,
                  options: .storageModeShared
              )
        else { return nil }

        self.device = device
        self.commandQueue = queue
        self.particleBuffer = buffer

        do {
            computePipeline = try device.makeComputePipelineState(function: updateFunction)
            instancedPipeline = try Self.makeRenderPipeline(device: device, vertex: instancedVertex, fragment: fragment)
            singlePipeline = try Self.makeRenderPipeline(device: device, vertex: singleVertex, fragment: fragment)
        } catch {
            assertionFailure("Pipeline creation failed: \(error)")
            return nil
        }

        super.init()
    }

    private static func makeRenderPipeline(
        device: MTLDevice,
        vertex: MTLFunction,
        fragment: MTLFunction
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment

        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        // Additive blending: order-independent, no sorting needed for glowing dust
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one

        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - Input

    /// Scripted gravity well for demo recordings: unit coordinates in -1...1 on both axes.
    func setDemoWell(unit: SIMD2<Float>?) {
        guard let unit else {
            well = nil
            return
        }
        well = SIMD2<Float>(unit.x * aspect, unit.y)
    }

    func setTouch(location: CGPoint?, in viewSize: CGSize) {
        guard let location, viewSize.width > 0, viewSize.height > 0 else {
            well = nil
            return
        }
        let x = (Float(location.x / viewSize.width) * 2 - 1) * aspect
        let y = -(Float(location.y / viewSize.height) * 2 - 1)
        well = SIMD2<Float>(x, y)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        aspect = Float(size.width / size.height)
        pixelsPerUnit = Float(size.height) / 2
        if !isSeeded {
            seedParticles()
            isSeeded = true
        }
    }

    func draw(in view: MTKView) {
        // A drawable can only be blitted into when it is not framebuffer-only,
        // and the flag has to be set before the drawable is created
        let isExporting = exporter?.isActive ?? false
        view.framebufferOnly = !isExporting

        guard isSeeded,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let captureFrame = isExporting
            ? exporter?.dequeueFrame(device: device, size: view.drawableSize)
            : nil

        let now = CACurrentMediaTime()
        // rawDelta is the true frame time (feeds the FPS counter); deltaTime is
        // clamped for the physics so a long hitch cannot explode the simulation
        let rawDelta = lastFrameTime == 0 ? 1.0 / 60.0 : now - lastFrameTime
        let deltaTime = min(rawDelta, 1.0 / 30.0)
        lastFrameTime = now
        time += Float(deltaTime)

        let activeMode = mode
        let activeSim = simulationMode
        var cap = activeMode == .naive ? Self.naiveModeCap : Self.maxParticles
        if activeSim == .cpu { cap = min(cap, Self.cpuModeCap) }
        let count = min(requestedParticleCount, cap)

        // At high counts the additive accumulation saturates the screen, so both
        // sprite size and brightness scale down with density (a visual LOD)
        let density = 250_000 / Float(max(count, 1))
        let sizeScale = min(1.15, max(0.6, density.squareRoot()))
        let emission = min(1.25, max(0.4, pow(density, 0.6)))

        var uniforms = Uniforms(
            wellPosition: well ?? .zero,
            wellStrength: well == nil ? 0 : 2.6,
            deltaTime: Float(deltaTime),
            time: time,
            aspect: aspect,
            particleSizePx: max(2.5, pixelsPerUnit * 0.0055 * sizeScale),
            pixelsPerUnit: pixelsPerUnit,
            emission: emission,
            particleCount: shader_uint(count)
        )

        var cpuSimMs = 0.0
        switch activeSim {
        case .cpu:
            // The "before" of case study 02: same physics, but a single Swift
            // loop plus a full-buffer upload, all inside the frame.
            let simStart = CACurrentMediaTime()
            simulateOnCPU(count: count, deltaTime: Float(deltaTime))
            cpuSimMs = (CACurrentMediaTime() - simStart) * 1000
        case .gpu:
            cpuStateIsFresh = false
        }

        let encodeStart = CACurrentMediaTime()

        if activeSim == .gpu, let compute = commandBuffer.makeComputeCommandEncoder() {
            compute.setComputePipelineState(computePipeline)
            compute.setBuffer(particleBuffer, offset: 0, index: Int(BufferIndexParticles.rawValue))
            compute.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: Int(BufferIndexUniforms.rawValue))
            let width = min(256, computePipeline.maxTotalThreadsPerThreadgroup)
            let groups = MTLSize(width: (count + width - 1) / width, height: 1, depth: 1)
            compute.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            compute.endEncoding()
        }

        var drawCalls = 0
        let renderDescriptor: MTLRenderPassDescriptor
        if let captureFrame {
            let capture = MTLRenderPassDescriptor()
            capture.colorAttachments[0].texture = captureFrame.texture
            capture.colorAttachments[0].loadAction = .clear
            capture.colorAttachments[0].clearColor = view.clearColor
            capture.colorAttachments[0].storeAction = .store
            renderDescriptor = capture
        } else {
            renderDescriptor = descriptor
        }

        if let render = commandBuffer.makeRenderCommandEncoder(descriptor: renderDescriptor) {
            render.setVertexBuffer(particleBuffer, offset: 0, index: Int(BufferIndexParticles.rawValue))
            render.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: Int(BufferIndexUniforms.rawValue))

            switch activeMode {
            case .instanced:
                render.setRenderPipelineState(instancedPipeline)
                render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
                drawCalls = 1
            case .naive:
                render.setRenderPipelineState(singlePipeline)
                for i in 0..<count {
                    var index = shader_uint(i)
                    render.setVertexBytes(&index, length: MemoryLayout<shader_uint>.stride, index: Int(BufferIndexDrawParams.rawValue))
                    render.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
                drawCalls = count
            }
            render.endEncoding()
        }

        // While capturing, the frame lives in the exporter's texture — copy it
        // to the screen so the app still looks live
        if let captureFrame, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: captureFrame.texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: captureFrame.texture.width,
                                    height: captureFrame.texture.height, depth: 1),
                to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        commandBuffer.present(drawable)

        let cpuEncodeMs = (CACurrentMediaTime() - encodeStart) * 1000

        // Time-weighted smoothing: at 60 fps this averages gently, but a single
        // 300 ms frame pulls the number down immediately — the counter must not
        // keep showing 40 while the app visibly runs at 3 fps
        let instantFps = rawDelta > 0 ? 1.0 / rawDelta : 0
        let smoothing = min(1.0, rawDelta * 4)
        fpsAverage = fpsAverage == 0 ? instantFps : fpsAverage + (instantFps - fpsAverage) * smoothing

        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            if let captureFrame { self.exporter?.submit(captureFrame) }
            let gpuMs = max(0, buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            self.publishStats(gpuMs: gpuMs, cpuSimMs: cpuSimMs, cpuEncodeMs: cpuEncodeMs, drawCalls: drawCalls, count: count)
        }

        commandBuffer.commit()
    }

    // MARK: - Private

    private func seedParticles() {
        let particles = particleBuffer.contents().bindMemory(to: Particle.self, capacity: Self.maxParticles)
        var generator = SystemRandomNumberGenerator()
        for i in 0..<Self.maxParticles {
            // Four visual layers: a few crisp stars, lots of fine dust,
            // some mid-size grains, and rare huge soft clouds.
            let roll = Float.random(in: 0...1, using: &generator)
            let size: Float
            let depth: Float
            let brightness: Float
            if roll < 0.02 {  // stars
                size = Float.random(in: 0.35...0.5, using: &generator)
                depth = Float.random(in: 0.1...0.35, using: &generator)
                brightness = Float.random(in: 0.5...0.9, using: &generator)
            } else if roll < 0.72 {  // fine dust
                size = Float.random(in: 0.6...1.1, using: &generator)
                depth = Float.random(in: 0.3...1.0, using: &generator)
                brightness = Float.random(in: 0.05...0.16, using: &generator)
            } else if roll < 0.98 {  // mid grains
                size = Float.random(in: 1.1...2.4, using: &generator)
                depth = Float.random(in: 0.3...1.0, using: &generator)
                brightness = Float.random(in: 0.04...0.10, using: &generator)
            } else {  // soft clouds
                size = Float.random(in: 6...11, using: &generator)
                depth = Float.random(in: 0.2...0.7, using: &generator)
                brightness = Float.random(in: 0.015...0.04, using: &generator)
            }
            particles[i] = Particle(
                position: SIMD2<Float>(
                    Float.random(in: -aspect...aspect, using: &generator),
                    Float.random(in: -1...1, using: &generator)
                ),
                velocity: SIMD2<Float>(
                    Float.random(in: -0.04...0.04, using: &generator),
                    Float.random(in: -0.04...0.04, using: &generator)
                ),
                size: size,
                seed: Float.random(in: 0...1, using: &generator),
                depth: depth,
                brightness: brightness
            )
        }
    }

    // HUD strings re-render at 4 Hz, not 120 — keeps the render loop allocation-light
    private func publishStats(gpuMs: Double, cpuSimMs: Double, cpuEncodeMs: Double, drawCalls: Int, count: Int) {
        let now = CACurrentMediaTime()
        guard now - lastStatsPublish > 0.25 else { return }
        lastStatsPublish = now
        let snapshot = RenderStats(
            fps: fpsAverage,
            cpuSimMs: cpuSimMs,
            cpuEncodeMs: cpuEncodeMs,
            gpuMs: gpuMs,
            drawCalls: drawCalls,
            particleCount: count
        )
        DispatchQueue.main.async { [weak self] in
            self?.stats = snapshot
        }
    }

    // MARK: - CPU simulation (the deliberate "before" of case study 02)

    private func simulateOnCPU(count: Int, deltaTime: Float) {
        // Re-snapshot from the GPU buffer when entering CPU mode, so the dust
        // continues from wherever the GPU left it
        if !cpuStateIsFresh {
            let pointer = particleBuffer.contents().bindMemory(to: Particle.self, capacity: Self.maxParticles)
            cpuParticles = Array(UnsafeBufferPointer(start: pointer, count: Self.maxParticles))
            cpuStateIsFresh = true
        }

        let wellPosition = well
        let bounds = SIMD2<Float>(aspect + 0.05, 1.05)
        for i in 0..<count {
            var p = cpuParticles[i]

            var force = curlNoise(p.position * 1.7, time) * (0.02 + 0.08 * p.depth)
            if let wellPosition {
                let d = wellPosition - p.position
                let r2 = simd_dot(d, d) + 0.015
                force += simd_normalize(d) * (2.6 * (0.4 + 0.6 * p.depth) / r2)
            }

            p.velocity += force * deltaTime
            p.velocity *= exp(-1.1 * deltaTime)
            p.position += p.velocity * deltaTime

            if p.position.x > bounds.x { p.position.x = -bounds.x }
            if p.position.x < -bounds.x { p.position.x = bounds.x }
            if p.position.y > bounds.y { p.position.y = -bounds.y }
            if p.position.y < -bounds.y { p.position.y = bounds.y }

            cpuParticles[i] = p
        }

        // The naive hallmark: push the entire array back to the GPU every frame
        cpuParticles.withUnsafeBytes { raw in
            particleBuffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }
    }

    // Swift port of the shader's noise stack — deliberately identical math,
    // so CPU and GPU modes produce the same motion
    private func hash21(_ p: SIMD2<Float>) -> Float {
        var q = SIMD2<UInt32>(
            UInt32(bitPattern: Int32(p.x.rounded(.down))),
            UInt32(bitPattern: Int32(p.y.rounded(.down)))
        )
        q &*= SIMD2<UInt32>(1_597_334_673, 3_812_015_801)
        let n = (q.x ^ q.y) &* 1_597_334_673
        return Float(n) * (1.0 / 4_294_967_296.0)
    }

    private func valueNoise(_ p: SIMD2<Float>) -> Float {
        let i = p.rounded(.down)
        let f = p - i
        let u = f * f * (SIMD2<Float>(repeating: 3) - 2 * f)
        let a = hash21(i)
        let b = hash21(i + SIMD2<Float>(1, 0))
        let c = hash21(i + SIMD2<Float>(0, 1))
        let d = hash21(i + SIMD2<Float>(1, 1))
        let ab = a + (b - a) * u.x
        let cd = c + (d - c) * u.x
        return ab + (cd - ab) * u.y
    }

    private func streamPotential(_ p: SIMD2<Float>, _ t: Float) -> Float {
        var psi: Float = 0
        var amplitude: Float = 1
        var frequency: Float = 1
        for octave in 0..<3 {
            let drift = SIMD2<Float>(0.11, -0.07) * t * frequency
            psi += amplitude * valueNoise(p * frequency + drift + SIMD2<Float>(repeating: Float(octave) * 17))
            amplitude *= 0.5
            frequency *= 2.1
        }
        return psi
    }

    private func curlNoise(_ p: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
        let e: Float = 0.08
        let dPsiDy = streamPotential(p + SIMD2<Float>(0, e), t) - streamPotential(p - SIMD2<Float>(0, e), t)
        let dPsiDx = streamPotential(p + SIMD2<Float>(e, 0), t) - streamPotential(p - SIMD2<Float>(e, 0), t)
        return SIMD2<Float>(dPsiDy, -dPsiDx) / (2 * e)
    }
}
