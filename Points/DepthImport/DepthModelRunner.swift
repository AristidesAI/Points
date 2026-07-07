import Foundation
import CoreML
import CoreImage
import CoreVideo

// CoreML depth inference for the BAKE pipeline (imported media → stored depth → loop).
// Introspects the model's image input + depth output; returns RAW metres (per-pixel EMA) —
// the same contract as the TrueDepth/LiDAR feed.

struct LiveModel: Sendable, Equatable {
    var name: String        // display
    var resource: String    // compiled .mlmodelc bundle resource
    // MoGe-2 is the ONLY model — imports (photo/video) bake through it once, then loop.
    // The live-camera model path and the other models were removed (install size + focus:
    // TrueDepth / LiDAR are the app's live sensors).
    static let all: [LiveModel] = [
        LiveModel(name: "MoGe-2", resource: "MoGe2_ViTB_Normal_504"),
    ]
    static func named(_ n: String) -> LiveModel { all.first { $0.name == n } ?? all[0] }
}

nonisolated final class DepthModelRunner: @unchecked Sendable {
    // MARK: warm cache (shared across every runner — live + bake). Loading a ViT is ~1–9 s the first
    // time; keep the last few resident so switching models is instant and never re-freezes.
    private struct Loaded { let model: MLModel; let inputName: String; let inputW: Int; let inputH: Int; let outputName: String }
    private static let cacheLock = NSLock()
    private static var cache: [String: Loaded] = [:]
    private static var order: [String] = []
    private static let maxResident = 3

    private static func loaded(_ m: LiveModel) -> Loaded? {
        cacheLock.lock()
        if let hit = cache[m.resource] {
            order.removeAll { $0 == m.resource }; order.append(m.resource)
            cacheLock.unlock(); return hit
        }
        cacheLock.unlock()
        // Build outside the lock (slow — compiles for the ANE).
        guard let url = Bundle.main.url(forResource: m.resource, withExtension: "mlmodelc") else { return nil }
        let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndNeuralEngine
        guard let ml = try? MLModel(contentsOf: url, configuration: cfg) else { return nil }
        let d = ml.modelDescription
        var iName = "image", iW = 518, iH = 518, oName = "depth"
        if let img = d.inputDescriptionsByName.first(where: { $0.value.imageConstraint != nil }) {
            iName = img.key
            if let c = img.value.imageConstraint { iW = c.pixelsWide; iH = c.pixelsHigh }
        }
        oName = d.outputDescriptionsByName.keys.first(where: { $0 == "depth" })
            ?? d.outputDescriptionsByName.keys.first ?? "depth"
        let l = Loaded(model: ml, inputName: iName, inputW: iW, inputH: iH, outputName: oName)
        cacheLock.lock()
        cache[m.resource] = l; order.append(m.resource)
        while order.count > maxResident, let evict = order.first { order.removeFirst(); cache[evict] = nil }
        cacheLock.unlock()
        return l
    }

    private let lock = NSLock()
    private var model: MLModel?
    private var inputName = "image", outputName = "depth"
    private var inputW = 518, inputH = 518
    private var loadedResource = ""
    private var prevOut: [Float] = []                  // previous frame's metres (per-pixel EMA)

    /// Adopt the chosen model (from the warm cache, building it on first use). SLOW on a cache miss —
    /// call off the main thread (the bake runs it on a detached task).
    @discardableResult func load(_ m: LiveModel) -> Bool {
        if lock.withLock({ loadedResource == m.resource && model != nil }) { return true }
        guard let l = Self.loaded(m) else { return false }
        lock.lock()
        model = l.model; inputName = l.inputName; inputW = l.inputW; inputH = l.inputH; outputName = l.outputName
        loadedResource = m.resource
        prevOut = []                                   // new model → forget the EMA history
        lock.unlock()
        return true
    }

    /// CGImage → metre depth (row-major) + (w, h). Nil if not loaded or inference fails.
    /// ANY aspect ratio: the model's input shape is fixed (square), so a non-square image is
    /// letterboxed onto a centred black square for inference and the depth is cropped back to
    /// the content region — the returned map keeps the source aspect, nothing is squashed.
    func depth(_ cg: CGImage) -> ([Float], Int, Int)? {
        lock.lock()
        guard let model else { lock.unlock(); return nil }
        let inName = inputName, outName = outputName, iw = inputW, ih = inputH
        lock.unlock()
        var input = cg
        var contentFrac: (x: Float, y: Float, w: Float, h: Float)? = nil   // of the square, 0-1
        let sw = cg.width, sh = cg.height
        if sw != sh, sw > 0, sh > 0 {
            let side = max(sw, sh)
            if let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
                ctx.draw(cg, in: CGRect(x: (side - sw) / 2, y: (side - sh) / 2, width: sw, height: sh))
                if let sq = ctx.makeImage() {
                    input = sq
                    // Centred padding → symmetric, so CG's y-flip doesn't matter.
                    contentFrac = (x: Float(side - sw) / (2 * Float(side)),
                                   y: Float(side - sh) / (2 * Float(side)),
                                   w: Float(sw) / Float(side), h: Float(sh) / Float(side))
                }
            }
        }
        guard let feat = try? MLFeatureValue(cgImage: input, pixelsWide: iw, pixelsHigh: ih,
                                             pixelFormatType: kCVPixelFormatType_32ARGB, options: nil),
              let provider = try? MLDictionaryFeatureProvider(dictionary: [inName: feat]),
              let out = try? model.prediction(from: provider),
              let dv = out.featureValue(for: outName) else { return nil }
        // MoGe-2 extras: `mask` marks valid pixels (depth is arbitrary garbage where mask == 0 —
        // rendering it unmasked was the "garbled" cloud), `metric_scale` lifts its relative depth
        // to metres.
        let mask = out.featureValue(for: "mask")?.multiArrayValue
        let mScale = out.featureValue(for: "metric_scale")?.multiArrayValue
        guard let (m, mw, mh) = metres(dv, mask: mask, metricScale: mScale) else { return nil }
        guard let f = contentFrac else { return (m, mw, mh) }
        // Crop the letterbox back off (fractions → output pixels; the model output can differ
        // from the input dims, so scale by the ACTUAL mw/mh).
        let cx = min(max(Int((f.x * Float(mw)).rounded()), 0), mw - 1)
        let cy = min(max(Int((f.y * Float(mh)).rounded()), 0), mh - 1)
        let cw = min(max(Int((f.w * Float(mw)).rounded()), 1), mw - cx)
        let ch = min(max(Int((f.h * Float(mh)).rounded()), 1), mh - cy)
        if cw == mw, ch == mh { return (m, mw, mh) }
        var cropped = [Float](); cropped.reserveCapacity(cw * ch)
        for y in cy..<(cy + ch) {
            cropped.append(contentsOf: m[(y * mw + cx)..<(y * mw + cx + cw)])
        }
        return (cropped, cw, ch)
    }

    // MARK: depth feature → metres

    private func metres(_ v: MLFeatureValue, mask: MLMultiArray?, metricScale: MLMultiArray?) -> ([Float], Int, Int)? {
        var raw: [Float] = []; var w = 0, h = 0
        if let a = v.multiArrayValue { (raw, w, h) = arrayFloats(a) }
        else if let px = v.imageBufferValue, let f = imageFloats(px) { (raw, w, h) = f }
        else { return nil }
        guard w > 0, h > 0, raw.count >= w * h else { return nil }
        // MoGe-2: zero out invalid pixels (its depth is arbitrary garbage where mask == 0) and lift
        // to metres via metric_scale. RAW metres + a per-pixel EMA (TDLidar plan §2d) — the same
        // contract as the TrueDepth/LiDAR feed; no display normalisation.
        if let mask {
            let (mf, mw, mh) = arrayFloats(mask)
            if mw == w, mh == h {
                for i in 0..<(w * h) where mf[i] < 0.5 { raw[i] = 0 }
            }
        }
        let scale: Float = metricScale.flatMap { $0.count >= 1 ? $0[0].floatValue : nil } ?? 1
        lock.lock(); let prev = prevOut; lock.unlock()
        let usePrev = prev.count == w * h
        let a: Float = 0.55
        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let x = raw[i] * scale
            guard x.isFinite, x > 0.02 else { out[i] = 0; continue }   // hole → 0 → culled
            var m = x
            if usePrev, prev[i] > 0 { m = a * m + (1 - a) * prev[i] }
            out[i] = m
        }
        lock.lock(); prevOut = out; lock.unlock()
        return (out, w, h)
    }

    private func arrayFloats(_ a: MLMultiArray) -> ([Float], Int, Int) {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        let w = shape.last ?? 0, h = shape.count >= 2 ? shape[shape.count - 2] : 1
        let sw = strides.last ?? 1, sh = strides.count >= 2 ? strides[strides.count - 2] : w
        var out = [Float](repeating: 0, count: max(w * h, 0))
        switch a.dataType {
        case .float16:
            let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
            for y in 0..<h { for x in 0..<w { out[y * w + x] = Float(p[y * sh + x * sw]) } }
        case .float32, .double:
            let p = a.dataPointer.assumingMemoryBound(to: Float.self)
            for y in 0..<h { for x in 0..<w { out[y * w + x] = p[y * sh + x * sw] } }
        default:
            for i in 0..<(w * h) { out[i] = a[i].floatValue }
        }
        return (out, w, h)
    }

    private func imageFloats(_ px: CVPixelBuffer) -> ([Float], Int, Int)? {
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_OneComponent32Float,
                     kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h] as CFDictionary
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_OneComponent32Float, attrs, &out) == kCVReturnSuccess,
              let dst = out else { return nil }
        ci.render(CIImage(cvPixelBuffer: px), to: dst)
        CVPixelBufferLockBaseAddress(dst, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dst, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(dst)
        var arr = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<w { arr[y * w + x] = row[x] }
        }
        return (arr, w, h)
    }

    private let ci = CIContext(options: [.useSoftwareRenderer: false])
}
