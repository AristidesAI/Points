import Foundation
import AVFoundation
import BackgroundTasks
import Observation

// Video / photo depth-bake pipeline — ARCHITECTURE GROUNDWORK for Plans/04-Depth-Import-Pipeline.md.
//
// The plan: RGB video/photo in → one-time on-device metric-depth bake on the ANE → stored depth →
// infinite looped playback (live sensors NEVER use these models). The real models — Metric-Video-
// Depth-Anything-S (video "Best"), Depth Anything V2-S (video "Fast"), MoGe-2 (photos) — aren't
// converted/bundled yet, so this ships a StubDepthModel that simulates the per-frame ANE timing.
// Everything else is real: PHPicker import, a real frame count off the asset, live progress, and
// BGContinuedProcessingTask so the bake keeps running when backgrounded AND the system renders the
// Dynamic Island progress for free (iOS 26). Drop a real DepthModel in and wire AVAssetReader +
// the PointsDepth writer to finish it.

// MARK: - Depth model abstraction

/// A monocular metric-depth backend. Real backends run on the ANE
/// (`MLModelConfiguration.computeUnits = .cpuAndNeuralEngine` — ANE is background-legal, GPU is not).
protocol DepthModel: Sendable {
    var displayName: String { get }
    /// Warm-up: on-device compile / first load ("Preparing engine…", 10–60 s on first import).
    func prepare() async throws
    /// Bake one frame's metric depth. The stub sleeps ≈ the real ANE per-frame budget.
    func bakeFrame(_ index: Int) async throws
}

/// Stand-in until the CoreML models are converted/bundled. Simulates the timing so the whole
/// import → background → Dynamic Island pipeline is real and testable now.
struct StubDepthModel: DepthModel {
    var displayName = "Simulated depth (stub)"
    var msPerFrame: UInt64 = 24        // ≈ DAv2-S ANE budget (17–34 ms/frame from the spike notes)
    func prepare() async throws { try? await Task.sleep(nanoseconds: 500_000_000) }
    func bakeFrame(_ index: Int) async throws { try? await Task.sleep(nanoseconds: msPerFrame * 1_000_000) }
}

// MARK: - Import options (the import sheet: Indoor/Outdoor always, quality tier)

struct BakeOptions: Sendable, Equatable {
    enum SceneKind: String, CaseIterable, Sendable { case indoor = "Indoor", outdoor = "Outdoor" }
    enum Quality: String, CaseIterable, Sendable { case best = "Best", fast = "Fast" }
    var scene: SceneKind = .indoor
    var quality: Quality = .fast
}

// MARK: - Cross-actor progress snapshot

/// Written by the MainActor bake loop, read by the nonisolated background-task handler. One shared
/// Sendable value so the handler never touches the MainActor manager.
final class BakeSnapshot: @unchecked Sendable {
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

/// File-scope so the nonisolated launch handler reaches it without the MainActor manager.
enum BakeShared { static let snapshot = BakeSnapshot() }

// MARK: - Manager

@MainActor @Observable final class DepthBakeManager {
    nonisolated static let taskID = "com.points.depthbake"

    enum Stage: Equatable { case idle, preparing, baking, done, cancelled, failed(String) }
    private(set) var stage: Stage = .idle
    private(set) var progress = 0.0
    private(set) var totalFrames = 0
    private(set) var currentFrame = 0
    private(set) var fps = 0.0
    private(set) var sourceName = ""
    var etaSeconds: Double { fps > 0 ? Double(max(totalFrames - currentFrame, 0)) / fps : 0 }
    var isRunning: Bool { stage == .preparing || stage == .baking }

    private var model: DepthModel = StubDepthModel()
    private var bakeTask: Task<Void, Never>?

    // Register once, early (App init). The system calls this to keep the app alive while the bake
    // runs in the background and to drive the Dynamic Island; the bake itself runs on the manager.
    nonisolated static func registerBackgroundHandler() {
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let cont = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false); return
            }
            let snap = BakeShared.snapshot
            cont.progress.totalUnitCount = 1000
            var expired = false
            cont.expirationHandler = { expired = true; snap.markCancelled() }
            while !snap.finished && !expired {
                cont.progress.completedUnitCount = Int64(snap.fraction * 1000)
                cont.updateTitle("Processing video", subtitle: snap.subtitle)
                Thread.sleep(forTimeInterval: 0.25)
            }
            cont.progress.completedUnitCount = 1000
            cont.setTaskCompleted(success: !expired)
        }
    }

    func start(url: URL, options: BakeOptions) {
        guard !isRunning else { return }
        sourceName = url.lastPathComponent
        stage = .preparing; progress = 0; currentFrame = 0; totalFrames = 0; fps = 0
        BakeShared.snapshot.reset()
        submitBackgroundTask()
        bakeTask = Task { await runBake(url: url, options: options) }
    }

    func cancel() {
        BakeShared.snapshot.markCancelled()
        bakeTask?.cancel()
    }

    // Ask the system to keep us alive + show the Dynamic Island while we bake. Failing (e.g. on the
    // simulator, or without the Info.plist identifier) is fine — the foreground bake still runs.
    private func submitBackgroundTask() {
        let req = BGContinuedProcessingTaskRequest(identifier: Self.taskID,
                                                   title: "Processing video",
                                                   subtitle: "Preparing…")
        do { try BGTaskScheduler.shared.submit(req) } catch { }
    }

    private func runBake(url: URL, options: BakeOptions) async {
        let frames = (try? await Self.frameCount(url)) ?? 300
        totalFrames = frames
        let started = Date()
        do {
            try await model.prepare()
            guard !BakeShared.snapshot.cancelled else { return finish(.cancelled) }
            stage = .baking
            for i in 0..<frames {
                if Task.isCancelled || BakeShared.snapshot.cancelled { return finish(.cancelled) }
                // Real path (future): AVAssetReader → CVPixelBuffer → model → PointsDepth writer.
                try await model.bakeFrame(i)
                currentFrame = i + 1
                progress = Double(currentFrame) / Double(frames)
                let elapsed = Date().timeIntervalSince(started)
                fps = elapsed > 0 ? Double(currentFrame) / elapsed : 0
                BakeShared.snapshot.update(progress, "Frame \(currentFrame) of \(frames)")
            }
            finish(.done)
        } catch { finish(.failed(error.localizedDescription)) }
    }

    private func finish(_ s: Stage) {
        stage = s
        if s == .done { progress = 1 }
        BakeShared.snapshot.markFinished()
    }

    /// Real frame count off the asset, sampled ≤30 fps as the spec bakes.
    private static func frameCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let dur = try await asset.load(.duration)
        let seconds = dur.seconds.isFinite ? dur.seconds : 0
        var rate: Float = 30
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            rate = try await track.load(.nominalFrameRate)
        }
        let capped = Double(min(rate <= 0 ? 30 : rate, 30))
        return max(Int(seconds * capped), 1)
    }
}
