import Foundation
import CoreML
import CoreImage
import CoreVideo

// Generic CoreML depth inference shared by the LIVE engine (camera → point cloud) and the BAKE
// pipeline (imported media → stored depth → loop). Introspects the model's image input + depth
// output; handles MLMultiArray or image outputs; returns a stable DISPLAY-metre field the pin
// stage can render (robust-percentile normalised + temporally smoothed — see `metres`). One model
// catalog + one warm cache for both paths.

struct LiveModel: Sendable, Equatable {
    var name: String        // display
    var resource: String    // compiled .mlmodelc bundle resource
    var inverse: Bool       // model emits inverse/disparity depth (near = large) → flip
    var metric: Bool = false // METRIC models output true metres (kept for reference; still normalised)
    var orient: UInt32 = 0  // per-model sensor→grid orientation bits (1 swapUV, 2 flipU, 4 flipV) —
                            // some conversions come out rotated/180°; calibration knob (see below).
    // Kept the two that perform: the metric video model (the one that "sort of works") + DA V3 S.
    // Removed the slow ones (DA2 Metric Indoor/Outdoor, MoGe-2, DA V2 S) per testing — all sluggish.
    static let all: [LiveModel] = [
        LiveModel(name: "Metric Video DA S",    resource: "MetricVideoDA_S",    inverse: false, metric: true, orient: 0),
        LiveModel(name: "Depth Anything V3 S", resource: "DepthAnythingV3_small_504", inverse: false, orient: 0),
    ]
    static func named(_ n: String) -> LiveModel { all.first { $0.name == n } ?? all[0] }
    /// The models offered in the import page + live node pickers (display names).
    static let pickerNames: [String] = all.map(\.name)
}

nonisolated final class DepthModelRunner: @unchecked Sendable {
    // Display range the pin stage expects (Depth node defaults). Every model is normalised into this
    // so a 0–80 m metric model and a 0–1 disparity model both render on the same stage; the node's
    // near/far then fine-tune. (Was: metric passthrough → 0–80 m dumped into a 2.5 m stage = "zoomed in".)
    private static let nearM: Float = 0.25, farM: Float = 2.5

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

    /// Free every resident model (called when the last Live Depth node is deleted).
    static func purgeCache() { cacheLock.lock(); cache.removeAll(); order.removeAll(); cacheLock.unlock() }

    private let lock = NSLock()
    private var model: MLModel?
    private var inputName = "image", outputName = "depth"
    private var inputW = 518, inputH = 518
    private var inverse = false
    private var loadedResource = ""
    private var smLo = Float.nan, smHi = Float.nan     // temporally-smoothed depth range (stops breathing)

    var isLoaded: Bool { lock.withLock { model != nil } }
    /// True when a `load(m)` for this model would actually have to build/adopt (drives the loading UI).
    func needsLoad(_ m: LiveModel) -> Bool { lock.withLock { !(loadedResource == m.resource && model != nil) } }

    /// Adopt the chosen model (from the warm cache, building it on first use). SLOW on a cache miss —
    /// call off the main thread (LiveDepthEngine.load does; the bake runs it on a detached task).
    @discardableResult func load(_ m: LiveModel) -> Bool {
        if lock.withLock({ loadedResource == m.resource && model != nil }) { return true }
        guard let l = Self.loaded(m) else { return false }
        lock.lock()
        model = l.model; inputName = l.inputName; inputW = l.inputW; inputH = l.inputH; outputName = l.outputName
        inverse = m.inverse; loadedResource = m.resource
        smLo = .nan; smHi = .nan                       // new model → forget the old range
        lock.unlock()
        return true
    }

    /// CGImage → display-metre depth (row-major) + (w, h). Nil if not loaded or inference fails.
    func depth(_ cg: CGImage) -> ([Float], Int, Int)? {
        lock.lock()
        guard let model else { lock.unlock(); return nil }
        let inName = inputName, outName = outputName, iw = inputW, ih = inputH, inv = inverse
        lock.unlock()
        guard let feat = try? MLFeatureValue(cgImage: cg, pixelsWide: iw, pixelsHigh: ih,
                                             pixelFormatType: kCVPixelFormatType_32ARGB, options: nil),
              let provider = try? MLDictionaryFeatureProvider(dictionary: [inName: feat]),
              let out = try? model.prediction(from: provider),
              let dv = out.featureValue(for: outName) else { return nil }
        return metres(dv, inverse: inv)
    }

    // MARK: depth feature → display metres

    private func metres(_ v: MLFeatureValue, inverse: Bool) -> ([Float], Int, Int)? {
        var raw: [Float] = []; var w = 0, h = 0
        if let a = v.multiArrayValue { (raw, w, h) = arrayFloats(a) }
        else if let px = v.imageBufferValue, let f = imageFloats(px) { (raw, w, h) = f }
        else { return nil }
        guard w > 0, h > 0, raw.count >= w * h else { return nil }
        // Robust range (2nd–98th percentile of valid pixels) rejects sky/hole outliers that used to
        // blow out raw min/max → the scene compresses to ~flat and folds ("wraps around itself").
        guard let (loP, hiP) = robustRange(raw, count: w * h) else { return nil }
        // EMA the range across frames so it doesn't breathe frame-to-frame.
        lock.lock()
        smLo = smLo.isFinite ? smLo + (loP - smLo) * 0.15 : loP
        smHi = smHi.isFinite ? smHi + (hiP - smHi) * 0.15 : hiP
        let lo = smLo, hi = smHi
        lock.unlock()
        let span = max(hi - lo, 1e-4)
        let n = Self.nearM, f = Self.farM
        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let x = raw[i]
            guard x.isFinite, x > 0.02 else { out[i] = 0; continue }   // hole → 0 → culled by the shader
            var t = min(max((x - lo) / span, 0), 1)
            if inverse { t = 1 - t }
            out[i] = n + (f - n) * t
        }
        return (out, w, h)
    }

    /// Subsampled 2nd/98th percentile of finite, non-hole values. Cheap enough per frame.
    private func robustRange(_ raw: [Float], count: Int) -> (Float, Float)? {
        var s: [Float] = []; s.reserveCapacity(count / 12 + 1)
        var i = 0
        while i < count { let x = raw[i]; if x.isFinite && x > 0.02 { s.append(x) }; i += 12 }
        guard s.count > 32 else { return nil }
        s.sort()
        let lo = s[Int(Double(s.count) * 0.02)]
        let hi = s[Int(Double(s.count) * 0.98)]
        return hi > lo ? (lo, hi) : nil
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
