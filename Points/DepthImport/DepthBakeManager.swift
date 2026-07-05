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

// MARK: - Depth model abstraction

struct DepthResult: Sendable {
    var width: Int
    var height: Int
    var depth: [Float]         // per-pixel depth (row-major, W*H). MoGe-2 gives metric-ish depth.
    var metricScale: Float     // MoGe-2 metric_scale (multiply depth for metres)
    /// Metric depth in metres — what the renderer's shader expects. // ponytail: calibration point if
    /// the point cloud reads flat/inverted, tune here or the Depth node's near/far.
    var metres: [Float] { metricScale > 0 && metricScale != 1 ? depth.map { $0 * metricScale } : depth }
}

protocol DepthModel: Sendable {
    var displayName: String { get }
    func prepare() async throws                    // load / warm-up (compiles on first run)
    func bake(_ image: CGImage) async throws -> DepthResult
}

/// MoGe-2 (ViT-B, 504²) — the bundled, already-converted model. Runs on the ANE. Direct `depth`
/// output + `metric_scale`. Model file is git-ignored (202 MB) — see .gitignore / the plan doc.
nonisolated final class MoGe2DepthModel: DepthModel, @unchecked Sendable {
    let displayName = "MoGe-2 (ViT-B 504)"
    private var model: MoGe2_ViTB_Normal_504?

    func prepare() async throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine     // ANE (background-legal); keeps the GPU free
        model = try await MoGe2_ViTB_Normal_504.load(configuration: cfg)
    }

    func bake(_ image: CGImage) async throws -> DepthResult {
        guard let model else { throw NSError(domain: "MoGe2", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: "Model not loaded"]) }
        let input = try MoGe2_ViTB_Normal_504Input(imageWith: image)   // resizes to 504×504 ARGB
        let out = try await model.prediction(input: input)
        // Read via MLShapedArray.scalars — it honours the array's shape/strides and returns clean
        // row-major values. Reading MLMultiArray.dataPointer linearly sheared each row (ANE outputs
        // are row-padded), which showed up as diagonal bands in the preview.
        let sa = out.depthShapedArray                                  // MLShapedArray<Float16>
        let shape = sa.shape
        let w = shape.last ?? 0
        let h = shape.count >= 2 ? shape[shape.count - 2] : 1
        let scalars = sa.scalars                                       // logical row-major
        var depth = [Float](repeating: 0, count: scalars.count)
        for i in scalars.indices { depth[i] = Float(scalars[i]) }
        let scale = out.metric_scaleShapedArray.scalars.first.map(Float.init) ?? 1
        return DepthResult(width: w, height: h, depth: depth, metricScale: scale)
    }
}

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

    private let model = MoGe2DepthModel()
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

    func start(url: URL, isVideo: Bool, options: BakeOptions) {
        guard !isRunning else { return }
        sourceName = url.lastPathComponent
        stage = .preparing; progress = 0; currentFrame = 0; totalFrames = 0; fps = 0; previewImage = nil
        BakeShared.snapshot.reset()
        submitBackgroundTask()
        let model = self.model
        bakeTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.prepareAndBake(url: url, isVideo: isVideo, model: model)
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
                        isVideo: Bool, first: Bool, preview: DepthPreview?) {
        if first { ImportedDepthStore.shared.begin(width: w, height: h, isVideo: isVideo) }
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

    private nonisolated func prepareAndBake(url: URL, isVideo: Bool, model: MoGe2DepthModel) async {
        do {
            try await model.prepare()
            if Task.isCancelled || BakeShared.snapshot.cancelled { await finish(.cancelled); return }
            await MainActor.run { self.stage = .baking }
            if isVideo { try await bakeVideo(url: url, model: model) }
            else { try await bakePhoto(url: url, model: model) }
            await finish(BakeShared.snapshot.cancelled ? .cancelled : .done)
        } catch {
            await finish(.failed(error.localizedDescription))
        }
    }

    private nonisolated func bakePhoto(url: URL, model: MoGe2DepthModel) async throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "bake", code: 2, userInfo: [NSLocalizedDescriptionKey: "Can't read image"])
        }
        let r = try await model.bake(cg)
        await record(metres: r.metres, w: r.width, h: r.height, frame: 1, total: 1, fps: 0,
                     isVideo: false, first: true, preview: Self.preview(from: r))
    }

    private nonisolated func bakeVideo(url: URL, model: MoGe2DepthModel) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "bake", code: 3, userInfo: [NSLocalizedDescriptionKey: "No video track"])
        }
        let srcFPS = (try? await track.load(.nominalFrameRate)) ?? 30
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        // Sample ~6 model runs / second of video so a test clip bakes quickly with a live preview.
        let stride = max(1, Int((srcFPS <= 0 ? 30 : srcFPS) / 6))
        let total = max(Int((dur.isFinite ? dur : 0) * 6), 1)

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
            let cgi = CIImage(cvPixelBuffer: pb)
            guard let cg = ci.createCGImage(cgi, from: cgi.extent) else { continue }
            let r = try await model.bake(cg)
            baked += 1
            let elapsed = Date().timeIntervalSince(started)
            await record(metres: r.metres, w: r.width, h: r.height, frame: baked, total: total,
                         fps: elapsed > 0 ? Double(baked) / elapsed : 0,
                         isVideo: true, first: baked == 1, preview: Self.preview(from: r))
        }
    }

    // MARK: depth → grayscale preview

    /// Normalise depth (near = bright), ignoring non-finite values.
    private nonisolated static func preview(from r: DepthResult) -> DepthPreview? {
        let w = r.width, h = r.height
        guard w > 0, h > 0, r.depth.count >= w * h else { return nil }
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for v in r.depth where v.isFinite { lo = min(lo, v); hi = max(hi, v) }
        guard hi > lo else { return nil }
        var px = [UInt8](repeating: 0, count: w * h)
        let inv = 1 / (hi - lo)
        for i in 0..<(w * h) {
            let v = r.depth[i]
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
