import Foundation
import AVFoundation
import CoreImage
import CoreML
import CoreGraphics
import ImageIO
import BackgroundTasks
import Observation

// Video / photo depth-bake pipeline — Plans/04-Depth-Import-Pipeline.md. RGB in → one-time on-device
// metric-depth bake on the ANE → (future) stored depth → looped point cloud. This runs the REAL
// MoGe-2 model per frame and shows a live depth preview so you can confirm it works. AVAssetReader
// decodes video frames; a single photo bakes one frame. The PointsDepth writer + sequential looper
// (playback as a point cloud) are the next milestone; for now the bake proves the model + pipeline.

// The depth model + generic inference now live in DepthModelRunner (shared with the live engine), so
// the bake can use ANY bundled model, chosen on the import page.

// MARK: - Import options

struct BakeOptions: Sendable, Equatable {
    enum SceneKind: String, CaseIterable, Sendable { case indoor = "Indoor", outdoor = "Outdoor" }
    enum Quality: String, CaseIterable, Sendable { case best = "Best", fast = "Fast" }
    var scene: SceneKind = .indoor
    var quality: Quality = .fast
}

// MARK: - Cross-actor progress snapshot (read by the nonisolated background-task handler)

nonisolated final class BakeSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var _fraction = 0.0, _subtitle = "Preparing…", _finished = false, _cancelled = false
    var fraction: Double { lock.withLock { _fraction } }
    var subtitle: String { lock.withLock { _subtitle } }
    var finished: Bool { lock.withLock { _finished } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    func update(_ f: Double, _ s: String) { lock.withLock { _fraction = f; _subtitle = s } }
    func markFinished() { lock.withLock { _finished = true } }
    func markCancelled() { lock.withLock { _cancelled = true } }
    func reset() { lock.withLock { _fraction = 0; _subtitle = "Preparing…"; _finished = false; _cancelled = false } }
}

nonisolated enum BakeShared { static let snapshot = BakeSnapshot() }

/// Sendable grayscale preview handed from the off-main bake loop to the MainActor UI.
struct DepthPreview: Sendable { var pixels: [UInt8]; var width: Int; var height: Int }

// MARK: - Manager

@MainActor @Observable final class DepthBakeManager {
    // Continued-processing id MUST be prefixed with the real bundle id and permitted as a wildcard
    // (…depthbake.*) in Info.plist; each run appends a fresh suffix.
    nonisolated static var taskPrefix: String { (Bundle.main.bundleIdentifier ?? "aristides.lintzeris.Points") + ".depthbake" }

    enum Stage: Equatable { case idle, preparing, baking, done, cancelled, failed(String) }
    private(set) var stage: Stage = .idle
    private(set) var progress = 0.0
    private(set) var totalFrames = 0
    private(set) var currentFrame = 0
    private(set) var fps = 0.0
    private(set) var sourceName = ""
    private(set) var previewImage: CGImage?
    private(set) var bgStatus = ""          // surfaced so we can see if the background task actually submits
    var etaSeconds: Double { fps > 0 ? Double(max(totalFrames - currentFrame, 0)) / fps : 0 }
    var isRunning: Bool { stage == .preparing || stage == .baking }

    private let runner = DepthModelRunner()
    private var bakeTask: Task<Void, Never>?

    // MARK: background task (keeps the bake alive + drives the Dynamic Island when minimised)

    /// Runs on the system's task queue: drives the Dynamic Island progress and holds the app alive
    /// while the bake runs, until it finishes or the user cancels.
    nonisolated static func driveContinuedTask(_ cont: BGContinuedProcessingTask) {
        let snap = BakeShared.snapshot
        cont.progress.totalUnitCount = 1000
        cont.expirationHandler = { snap.markCancelled() }
        while !snap.finished && !snap.cancelled {
            cont.progress.completedUnitCount = Int64(snap.fraction * 1000)
            cont.updateTitle("Processing video", subtitle: snap.subtitle)
            Thread.sleep(forTimeInterval: 0.2)
        }
        cont.progress.completedUnitCount = 1000
        cont.setTaskCompleted(success: !snap.cancelled)
    }

    // MARK: control

    func start(url: URL, isVideo: Bool, options: BakeOptions, model: LiveModel) {
        guard !isRunning else { return }
        sourceName = url.lastPathComponent
        stage = .preparing; progress = 0; currentFrame = 0; totalFrames = 0; fps = 0; previewImage = nil
        BakeShared.snapshot.reset()
        submitBackgroundTask()
        let runner = self.runner
        bakeTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.prepareAndBake(url: url, isVideo: isVideo, runner: runner, model: model)
        }
    }

    func cancel() {
        BakeShared.snapshot.markCancelled()
        bakeTask?.cancel()
    }

    private func submitBackgroundTask() {
        // Register a handler for THIS run's concrete id (dynamic per-submission avoids double-register).
        let id = "\(Self.taskPrefix).\(UUID().uuidString)"
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            guard let cont = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            Self.driveContinuedTask(cont)
        }
        guard ok else { bgStatus = "bg register refused — is \(Self.taskPrefix).* in BGTaskSchedulerPermittedIdentifiers?"; return }
        let req = BGContinuedProcessingTaskRequest(identifier: id, title: "Processing video", subtitle: "Preparing…")
        do { try BGTaskScheduler.shared.submit(req); bgStatus = "background task running" }
        catch { bgStatus = "bg submit failed: \(error.localizedDescription)" }
    }

    // MARK: publish (MainActor)

    /// Store the frame (for playback) + update the UI. `metres` + `preview` are Sendable so this
    /// hops cleanly from the off-main bake loop.
    private func record(metres: [Float], w: Int, h: Int, frame: Int, total: Int, fps: Double,
                        playbackFPS: Double, isVideo: Bool, first: Bool, preview: DepthPreview?) {
        if first { ImportedDepthStore.shared.begin(width: w, height: h, isVideo: isVideo, fps: playbackFPS) }
        ImportedDepthStore.shared.append(metres)
        currentFrame = frame; totalFrames = total; self.fps = fps
        progress = total > 0 ? Double(frame) / Double(total) : 0
        BakeShared.snapshot.update(progress, "Frame \(frame) of \(total)")
        if let p = preview { previewImage = Self.grayscaleCGImage(p) }
    }

    private func finish(_ s: Stage) {
        stage = s
        if s == .done { progress = 1 }
        BakeShared.snapshot.markFinished()
    }

    // MARK: bake loop (off main; publishes back to MainActor)

    private nonisolated func prepareAndBake(url: URL, isVideo: Bool, runner: DepthModelRunner, model: LiveModel) async {
        guard runner.load(model) else { await finish(.failed("Couldn't load \(model.name)")); return }
        if Task.isCancelled || BakeShared.snapshot.cancelled { await finish(.cancelled); return }
        await MainActor.run { self.stage = .baking }
        do {
            if isVideo { try await bakeVideo(url: url, runner: runner) }
            else { try await bakePhoto(url: url, runner: runner) }
            await finish(BakeShared.snapshot.cancelled ? .cancelled : .done)
        } catch {
            await finish(.failed(error.localizedDescription))
        }
    }

    private nonisolated func bakePhoto(url: URL, runner: DepthModelRunner) async throws {
        let ci = CIContext(options: [.useSoftwareRenderer: false])
        guard let img = CIImage(contentsOf: url) else {
            throw NSError(domain: "bake", code: 2, userInfo: [NSLocalizedDescriptionKey: "Can't read image"])
        }
        // Upright per EXIF orientation so the depth (preview + point cloud) isn't rotated.
        let orient = (img.properties[kCGImagePropertyOrientation as String] as? UInt32)
            .flatMap { CGImagePropertyOrientation(rawValue: $0) } ?? .up
        let up = img.oriented(orient)
        guard let cg = ci.createCGImage(up, from: up.extent) else {
            throw NSError(domain: "bake", code: 2, userInfo: [NSLocalizedDescriptionKey: "Can't render image"])
        }
        guard let (metres, w, h) = runner.depth(cg) else {
            throw NSError(domain: "bake", code: 4, userInfo: [NSLocalizedDescriptionKey: "Inference failed"])
        }
        await record(metres: metres, w: w, h: h, frame: 1, total: 1, fps: 0,
                     playbackFPS: 0, isVideo: false, first: true, preview: Self.preview(metres, w, h))
    }

    private nonisolated func bakeVideo(url: URL, runner: DepthModelRunner) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "bake", code: 3, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }
        let srcFPS = (try? await track.load(.nominalFrameRate)) ?? 30
        let transform = (try? await track.load(.preferredTransform)) ?? .identity   // upright portrait video
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        // Sample ~6 model runs / second of video so a test clip bakes quickly with a live preview.
        let stride = max(1, Int((srcFPS <= 0 ? 30 : srcFPS) / 6))
        // Play back at the SAMPLED rate so the clip's real-time duration is preserved (was baking at
        // ~6 fps then playing at 30 → ~5× too fast).
        let playbackFPS = Double(srcFPS <= 0 ? 30 : srcFPS) / Double(stride)
        let total = max(Int((dur.isFinite ? dur : 0) * playbackFPS), 1)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        let ci = CIContext(options: [.useSoftwareRenderer: false])
        let started = Date()
        var read = 0, baked = 0
        while let sample = output.copyNextSampleBuffer() {
            defer { read += 1 }
            if Task.isCancelled || BakeShared.snapshot.cancelled { reader.cancelReading(); return }
            guard read % stride == 0, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let cgi = CIImage(cvPixelBuffer: pb).transformed(by: transform)   // upright per track transform
            guard let cg = ci.createCGImage(cgi, from: cgi.extent) else { continue }
            guard let (metres, w, h) = runner.depth(cg) else { continue }
            baked += 1
            let elapsed = Date().timeIntervalSince(started)
            await record(metres: metres, w: w, h: h, frame: baked, total: total,
                         fps: elapsed > 0 ? Double(baked) / elapsed : 0,
                         playbackFPS: playbackFPS, isVideo: true, first: baked == 1, preview: Self.preview(metres, w, h))
        }
    }

    // MARK: depth → grayscale preview

    /// Normalise depth (near = bright), ignoring non-finite values.
    private nonisolated static func preview(_ depth: [Float], _ w: Int, _ h: Int) -> DepthPreview? {
        guard w > 0, h > 0, depth.count >= w * h else { return nil }
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for v in depth where v.isFinite { lo = min(lo, v); hi = max(hi, v) }
        guard hi > lo else { return nil }
        var px = [UInt8](repeating: 0, count: w * h)
        let inv = 1 / (hi - lo)
        for i in 0..<(w * h) {
            let v = depth[i]
            px[i] = v.isFinite ? UInt8(max(0, min(1, (hi - v) * inv)) * 255) : 0   // near→white
        }
        return DepthPreview(pixels: px, width: w, height: h)
    }

    private nonisolated static func grayscaleCGImage(_ p: DepthPreview) -> CGImage? {
        var px = p.pixels
        return px.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: p.width, height: p.height,
                                      bitsPerComponent: 8, bytesPerRow: p.width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }
}
