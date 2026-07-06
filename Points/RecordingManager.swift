//
//  RecordingManager.swift
//  Points
//
//  Captures the finished BGRA render to a video file and saves it to Photos. Fed the same
//  offscreen pixel buffer the NDI pass uses, so recording works at its own resolution /
//  orientation / fps / alpha, independent of NDI. Driven by the Record node's toggle.
//
//  Lifecycle is split so a stale GPU-completion `append` can never touch a finished writer:
//    · begin()  — idempotent, called on the render thread while the node is armed
//    · append() — append-only, no-ops unless recording (called from the GPU completion handler)
//    · finishIfRecording() — fully locked; markAsFinished + finish happen atomically vs append
//

import AVFoundation
import Photos
import CoreVideo
import VideoToolbox

/// What the Record node wants captured — read from its params each frame by the renderer.
struct RecordConfig: Equatable {
    var width = 1080
    var height = 1440          // 3:4 portrait by default
    var alpha = false          // record with a transparent background (HEVC-with-alpha)
    var fpsN: Int32 = 60_000
    var fpsD: Int32 = 1_000
}

nonisolated final class RecordingManager: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recording = false
    private var sessionStarted = false
    private var frameIndex: Int64 = 0
    private var fpsN: Int32 = 60_000
    private var fpsD: Int32 = 1_000
    private var url: URL?

    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return recording }

    /// Request Photos add-only access up front (at Record-node creation) so the save at STOP
    /// never has to prompt from inside a GPU completion handler.
    func requestAuthorization() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }

    /// Open the writer if not already recording. Idempotent; called on the render thread while
    /// the node is armed. Never called from `append`, so a stale append can't re-arm after STOP.
    func begin(_ config: RecordConfig) {
        lock.lock(); defer { lock.unlock() }
        guard !recording else { return }
        let w = max(config.width, 16), h = max(config.height, 16)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("points-\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: out, fileType: .mov) else { return }

        let codec: AVVideoCodecType = config.alpha ? .hevcWithAlpha : .hevc
        var settings: [String: Any] = [
            AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ]
        if config.alpha {
            settings[AVVideoCompressionPropertiesKey] =
                [kVTCompressionPropertyKey_TargetQualityForAlpha as String: 1.0]
        }
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        inp.expectsMediaDataInRealTime = true
        let adp = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        guard writer.canAdd(inp) else { return }
        writer.add(inp)
        guard writer.startWriting() else { return }

        self.writer = writer; input = inp; adaptor = adp
        url = out; fpsN = config.fpsN; fpsD = config.fpsD
        frameIndex = 0; sessionStarted = false; recording = true
    }

    /// Append one composited BGRA frame (the GPU has finished with `pb`). No-op unless recording,
    /// so a completion handler that fires after STOP is harmless.
    func append(_ pb: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard recording, let writer, let input, let adaptor, input.isReadyForMoreMediaData,
              writer.status == .writing else { return }
        // PTS of frame k = k / fps = k·fpsD/fpsN seconds → timescale fpsN, value k·fpsD.
        let pts = CMTime(value: frameIndex * Int64(fpsD), timescale: fpsN)
        if !sessionStarted { writer.startSession(atSourceTime: pts); sessionStarted = true }
        adaptor.append(pb, withPresentationTime: pts)
        frameIndex += 1
    }

    /// Toggle off / node removed → finalize and save. Fully locked so it can't race `append`.
    func finishIfRecording() {
        lock.lock(); defer { lock.unlock() }
        guard recording, let writer, let input else { return }
        recording = false
        self.writer = nil; self.input = nil; self.adaptor = nil
        let saveURL = url

        guard sessionStarted, writer.status == .writing else {
            writer.cancelWriting()                       // no frames — nothing to save
            if let saveURL { try? FileManager.default.removeItem(at: saveURL) }
            return
        }
        input.markAsFinished()
        nonisolated(unsafe) let w = writer               // single-threaded through the callback
        w.finishWriting {
            guard w.status == .completed, let saveURL else { return }
            Self.saveToPhotos(saveURL)
        }
    }

    private static func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: url); return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { _, _ in
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
