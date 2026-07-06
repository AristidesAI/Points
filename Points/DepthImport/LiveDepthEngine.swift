import Foundation
import CoreML
import CoreImage
import CoreVideo

// Live monocular depth: runs the chosen depth model (via DepthModelRunner) on each RGB camera frame
// and pushes the result into renderer.ingest — so phones WITHOUT back LiDAR still drive the point
// cloud, and we can try any model live on the back lenses. LiveModel + the generic inference live in
// DepthModelRunner (shared with the bake pipeline).

nonisolated final class LiveDepthEngine: @unchecked Sendable {
    private let renderer: PinRenderer
    private let runner = DepthModelRunner()
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private let lock = NSLock()
    private var busy = false
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0
    private let loadQueue = DispatchQueue(label: "points.livedepth.load", qos: .userInitiated)

    init(renderer: PinRenderer) { self.renderer = renderer }

    /// True when switching to `m` would block on a (cold) model build — drives the loading overlay.
    func needsLoad(_ m: LiveModel) -> Bool { runner.needsLoad(m) }

    /// Load the model OFF the main thread (a cold ViT is ~1–9 s — loading it on main froze the app).
    /// `done(ok)` fires on the main actor. Warm models resolve almost instantly.
    /// NOTE: does NOT touch renderer orientation — preloading happens on node *presence* (before it
    /// drives the display), so setting orient here rotated the live LiDAR feed. The gating applies
    /// the model's orient only when the RGB camera is the active source.
    func load(_ m: LiveModel, done: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        loadQueue.async { [self] in
            let ok = runner.load(m)
            if let done { Task { @MainActor in done(ok) } }
        }
    }

    /// One BGRA camera frame (+ its real normalized intrinsics) → depth → renderer. Drops frames
    /// while an inference is in flight.
    func process(_ bgra: CVPixelBuffer, intrinsics: SIMD4<Float>) {
        lock.lock(); if busy || !runner.isLoaded { lock.unlock(); return }; busy = true; lock.unlock()
        defer { lock.lock(); busy = false; lock.unlock() }
        let src = CIImage(cvPixelBuffer: bgra)
        guard let cg = ci.createCGImage(src, from: src.extent),
              let (metres, w, h) = runner.depth(cg), let pb = buffer(metres, w, h) else { return }
        renderer.setIntrinsics(intrinsics)   // real per-frame camera intrinsics → METRIC mode
        renderer.ingest(depth: pb, color: nil, lumaOnly: false)
    }

    private func buffer(_ metres: [Float], _ w: Int, _ h: Int) -> CVPixelBuffer? {
        if pool == nil || poolW != w || poolH != h {
            let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_DepthFloat32,
                         kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                         kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary
            var p: CVPixelBufferPool?; CVPixelBufferPoolCreate(nil, nil, attrs, &p)
            pool = p; poolW = w; poolH = h
        }
        guard let pool else { return nil }
        var o: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &o) == kCVReturnSuccess, let pb = o else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        metres.withUnsafeBufferPointer { s in
            guard let sb = s.baseAddress else { return }
            for y in 0..<h {
                base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                    .update(from: sb.advanced(by: y * w), count: w)
            }
        }
        return pb
    }
}
