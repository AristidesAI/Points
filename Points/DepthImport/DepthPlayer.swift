import Foundation
import CoreVideo

// Playback for imported depth: the baked frames are pushed into PinRenderer.ingest — the SAME seam
// the live LiDAR/TrueDepth cameras use — so imported media renders as a point cloud identically to a
// live sensor (Plans/04). A photo holds one frame; a video loops. In-memory for now (PointsDepth v2
// persistence is a later milestone).

/// One imported clip's baked depth in metres, row-major W*H per frame. Set by the bake, read by the
/// player. Capped so a long clip can't blow up RAM.
@MainActor final class ImportedDepthStore {
    static let shared = ImportedDepthStore()
    private(set) var frames: [[Float]] = []
    private(set) var width = 0, height = 0
    private(set) var isVideo = false
    private(set) var playbackFPS: Double = 30    // play back at the rate frames were sampled
    private(set) var orient: UInt32 = 0          // the baking model's sensor→grid orientation bits
    /// Bumped whenever the media changes (new bake / clear) — lets the player's start() be
    /// idempotent for the SAME media (re-running it every graph tick restarted the loop and
    /// flashed the cloud black on every slider/orbit step).
    private(set) var generation = 0
    var isEmpty: Bool { frames.isEmpty }
    var count: Int { frames.count }

    func begin(width: Int, height: Int, isVideo: Bool, fps: Double, orient: UInt32 = 0) {
        frames.removeAll(keepingCapacity: true)
        self.width = width; self.height = height; self.isVideo = isVideo
        self.playbackFPS = fps > 0 ? fps : 30
        self.orient = orient
        generation += 1
    }
    func append(_ metres: [Float]) { if frames.count < 600 { frames.append(metres) } }   // ~600MB ceiling at 504²
    /// Vision Model node's X button — discard the media entirely.
    func clear() { frames.removeAll(); width = 0; height = 0; isVideo = false; generation += 1 }
}

/// Loops the store's frames into the renderer at ≤30 fps. Video advances + wraps; a photo repeats
/// frame 0. Orientation is identity (imported frames are already upright).
@MainActor final class DepthPlayer {
    private let renderer: PinRenderer
    private var timer: Timer?
    private var idx = 0
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0
    private var startedGeneration = -1   // media generation the running loop was started for

    init(renderer: PinRenderer) { self.renderer = renderer }

    func start() {
        let store = ImportedDepthStore.shared
        guard !store.isEmpty else { return }
        // Idempotent for the same media: start() re-runs on EVERY graph change (slider drags,
        // orbit steps), and restarting the loop + resetting the filter each time drew one frame
        // with no depth = the black flash per step. Only a NEW bake / clear restarts the loop.
        if timer != nil && startedGeneration == store.generation { return }
        stop()
        startedGeneration = store.generation
        idx = 0
        renderer.setOrient(store.orient)                       // the baking model's orientation
        // Imported media has no camera calibration — assume a ~60° hFOV lens at the media's own
        // aspect so METRIC mode unprojects it unsquashed (fx_n = 0.5/tan(30°); fy_n scales by W/H).
        let fxn: Float = 0.866
        let fyn: Float = store.height > 0 ? fxn * Float(store.width) / Float(store.height) : fxn
        renderer.setIntrinsics(SIMD4(fxn, fyn, 0.5, 0.5))
        renderer.resetFilter()
        // Fires on the main runloop (scheduled from the main actor) → assumeIsolated is valid.
        let interval = 1.0 / max(store.playbackFPS, 1)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let store = ImportedDepthStore.shared
        guard !store.isEmpty else { return }
        let frame = store.frames[idx % store.count]
        if let pb = buffer(frame, store.width, store.height) {
            renderer.ingest(depth: pb, color: nil, lumaOnly: false)
        }
        if store.isVideo {
            idx += 1
            if idx >= store.count { idx = 0; renderer.resetFilter() }   // no EMA smear across the loop seam
        }
    }

    /// [Float] metres (row-major) → a DepthFloat32 CVPixelBuffer from a rotating pool (so the renderer
    /// isn't reading a buffer we're overwriting). Respects the buffer's padded bytesPerRow.
    private func buffer(_ metres: [Float], _ w: Int, _ h: Int) -> CVPixelBuffer? {
        guard w > 0, h > 0, metres.count >= w * h else { return nil }
        if pool == nil || poolW != w || poolH != h {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_DepthFloat32,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p; poolW = w; poolH = h
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        metres.withUnsafeBufferPointer { src in
            guard let s = src.baseAddress else { return }
            for y in 0..<h {
                let dst = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                dst.update(from: s.advanced(by: y * w), count: w)
            }
        }
        return pb
    }
}
