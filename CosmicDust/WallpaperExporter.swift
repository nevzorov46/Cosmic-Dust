import AVFoundation
import CoreImage
import Metal
import Photos
import UniformTypeIdentifiers

/// Records a few seconds of the live view and saves it to Photos as a Live Photo,
/// which iOS accepts as an animated Lock Screen wallpaper.
///
/// A Live Photo is a still image plus a short movie, tied together by a shared
/// asset identifier: the JPEG carries it in the Apple maker note, the movie in a
/// `com.apple.quicktime.content.identifier` metadata item, and a metadata track
/// marks which movie time the still was taken from.
final class WallpaperExporter: ObservableObject {
    enum Status: Equatable {
        case idle
        case capturing(progress: Double)
        case saving
        case saved
        case failed(String)
    }

    /// One frame the renderer draws into instead of the drawable.
    struct Frame {
        let texture: MTLTexture
        let pixelBuffer: CVPixelBuffer
        let time: CMTime
        let isStill: Bool
    }

    static let duration = 3.0
    private static let frameInterval = 1.0 / 30.0
    private static let warmupFrames = 2

    @Published private(set) var status: Status = .idle

    /// True while the renderer should draw into capture frames instead of the drawable.
    private(set) var isActive = false

    private let writeQueue = DispatchQueue(label: "com.cosmicdust.wallpaper-export")
    private let ciContext = CIContext()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var textureCache: CVMetalTextureCache?
    private var videoURL: URL?
    private var assetIdentifier = UUID().uuidString

    private var warmupLeft = 0
    private var startTime: CFTimeInterval = 0
    private var lastCaptureTime = -Double.infinity
    private var stillTaken = false
    private var isFinishing = false

    // MARK: - Control

    func start() {
        guard !isActive else { return }
        assetIdentifier = UUID().uuidString
        warmupLeft = Self.warmupFrames
        startTime = 0
        lastCaptureTime = -.infinity
        stillTaken = false
        isFinishing = false
        isActive = true
        status = .capturing(progress: 0)
    }

    // MARK: - Renderer hooks

    /// Called on the render thread: hands back a texture to draw this frame into,
    /// or nil when this frame should go straight to the drawable as usual.
    func dequeueFrame(device: MTLDevice, size: CGSize) -> Frame? {
        guard isActive, !isFinishing, size.width > 0, size.height > 0 else { return nil }

        // The first frames are skipped so the view's framebufferOnly change,
        // which enables the blit to the drawable, has taken effect
        if warmupLeft > 0 {
            warmupLeft -= 1
            return nil
        }

        if writer == nil, !prepare(device: device, size: size) { return nil }

        let now = CACurrentMediaTime()
        if startTime == 0 { startTime = now }
        let elapsed = now - startTime

        if elapsed >= Self.duration {
            finish()
            return nil
        }
        guard elapsed - lastCaptureTime >= Self.frameInterval else { return nil }
        lastCaptureTime = elapsed

        guard let pool = adaptor?.pixelBufferPool,
              let cache = textureCache else { return nil }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }

        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture
        ) == kCVReturnSuccess,
              let wrapped = cvTexture,
              let texture = CVMetalTextureGetTexture(wrapped) else { return nil }

        let isStill = !stillTaken
        stillTaken = true
        publish(.capturing(progress: min(1, elapsed / Self.duration)))

        return Frame(
            texture: texture,
            pixelBuffer: buffer,
            time: CMTime(seconds: elapsed, preferredTimescale: 600),
            isStill: isStill
        )
    }

    /// Called once the GPU has finished drawing the frame.
    func submit(_ frame: Frame) {
        writeQueue.async { [weak self] in
            guard let self, let input = self.videoInput, let adaptor = self.adaptor else { return }
            if input.isReadyForMoreMediaData {
                adaptor.append(frame.pixelBuffer, withPresentationTime: frame.time)
            }
            if frame.isStill {
                self.writeStillImage(from: frame.pixelBuffer)
            }
        }
    }

    // MARK: - Writing

    private func prepare(device: MTLDevice, size: CGSize) -> Bool {
        let width = Int(size.width), height = Int(size.height)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cosmic-dust-\(assetIdentifier).mov")
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            publish(.failed("Could not create the movie file"))
            isActive = false
            return false
        }

        // Ties the movie to its still image
        let identifierItem = AVMutableMetadataItem()
        identifierItem.key = "com.apple.quicktime.content.identifier" as NSString
        identifierItem.keySpace = .quickTimeMetadata
        identifierItem.value = assetIdentifier as NSString
        identifierItem.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [identifierItem]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000],
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { return false }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        )

        // The metadata track that marks the still frame's time in the movie
        var formatDescription: CMFormatDescription?
        let specification: [NSString: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType:
                "com.apple.metadata.datatype.int8",
        ]
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &formatDescription
        )
        let metadataInput = AVAssetWriterInput(
            mediaType: .metadata, outputSettings: nil, sourceFormatHint: formatDescription
        )
        metadataInput.expectsMediaDataInRealTime = true
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        if writer.canAdd(metadataInput) { writer.add(metadataInput) }

        guard writer.startWriting() else {
            publish(.failed(writer.error?.localizedDescription ?? "Could not start recording"))
            isActive = false
            return false
        }
        writer.startSession(atSourceTime: .zero)

        let stillTimeItem = AVMutableMetadataItem()
        stillTimeItem.key = "com.apple.quicktime.still-image-time" as NSString
        stillTimeItem.keySpace = .quickTimeMetadata
        stillTimeItem.value = 0 as NSNumber
        stillTimeItem.dataType = "com.apple.metadata.datatype.int8"
        metadataAdaptor.append(AVTimedMetadataGroup(
            items: [stillTimeItem],
            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30))
        ))
        metadataInput.markAsFinished()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)

        self.writer = writer
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.textureCache = cache
        self.videoURL = url
        return true
    }

    private func writeStillImage(from pixelBuffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cosmic-dust-\(assetIdentifier).jpg")
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return }
        // Key 17 of the Apple maker note is the Live Photo asset identifier
        CGImageDestinationAddImage(destination, cgImage, [
            kCGImagePropertyMakerAppleDictionary: ["17": assetIdentifier],
            kCGImageDestinationLossyCompressionQuality: 0.95,
        ] as CFDictionary)
        CGImageDestinationFinalize(destination)
        stillURL = url
    }

    private var stillURL: URL?

    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        isActive = false
        publish(.saving)

        writeQueue.async { [weak self] in
            guard let self, let writer = self.writer else { return }
            self.videoInput?.markAsFinished()
            writer.finishWriting {
                guard writer.status == .completed else {
                    self.publish(.failed(writer.error?.localizedDescription ?? "Recording failed"))
                    self.reset()
                    return
                }
                self.saveToPhotos()
            }
        }
    }

    private func saveToPhotos() {
        guard let videoURL, let stillURL else {
            publish(.failed("Nothing was recorded"))
            reset()
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] authorization in
            guard let self else { return }
            guard authorization == .authorized || authorization == .limited else {
                self.publish(.failed("Photos access denied"))
                self.reset()
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                request.addResource(with: .photo, fileURL: stillURL, options: options)
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: options)
            } completionHandler: { success, error in
                self.publish(success ? .saved : .failed(error?.localizedDescription ?? "Could not save"))
                self.reset()
            }
        }
    }

    private func reset() {
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.writer = nil
            self.videoInput = nil
            self.adaptor = nil
            self.textureCache = nil
        }
    }

    private func publish(_ new: Status) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.status != new else { return }
            self.status = new
        }
    }
}
