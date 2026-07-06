import Foundation
import CoreML
import CoreImage
import CoreVideo

// Generic CoreML depth inference shared by the LIVE engine (camera → point cloud) and the BAKE
// pipeline (imported media → stored depth → loop). Introspects the model's image input + depth
// output; handles MLMultiArray or image outputs; returns metric metres (metric models pass through,
// relative models are normalised to a metre range). One model catalog for both paths.

struct LiveModel: Sendable, Equatable {
    var name: String        // display
    var resource: String    // compiled .mlmodelc bundle resource
    var inverse: Bool       // RELATIVE models emit inverse depth (near = large) → flip
    var metric: Bool = false // METRIC models output true metres → use as-is (tune with node near/far)
    static let all: [LiveModel] = [
        // Metric (real metres — converted small models): tune near/far for the scene.
        LiveModel(name: "Metric Video DA S",    resource: "MetricVideoDA_S",    inverse: false, metric: true),
        LiveModel(name: "DA2 Metric Outdoor S", resource: "DAv2MetricOutdoor_S", inverse: false, metric: true),
        LiveModel(name: "DA2 Metric Indoor S",  resource: "DAv2MetricIndoor_S",  inverse: false, metric: true),
        // Relative (normalised to a metre range for display):
        LiveModel(name: "MoGe-2",              resource: "MoGe2_ViTB_Normal_504",    inverse: false),
        LiveModel(name: "Depth Anything V3 S", resource: "DepthAnythingV3_small_504", inverse: true),
        LiveModel(name: "Depth Anything V2 S", resource: "DepthAnythingV2SmallF16",  inverse: true),
    ]
    static func named(_ n: String) -> LiveModel { all.first { $0.name == n } ?? all[0] }
    /// The models offered in the import page + live node pickers (display names).
    static let pickerNames: [String] = all.map(\.name)
}

nonisolated final class DepthModelRunner: @unchecked Sendable {
    private let lock = NSLock()
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private var model: MLModel?
    private var inputName = "image", outputName = "depth"
    private var inputW = 518, inputH = 518
    private var inverse = false, metric = false
    private var loadedResource = ""

    var isLoaded: Bool { lock.withLock { model != nil } }

    /// Load + introspect the chosen model (idempotent for the same model). Returns whether it's ready.
    @discardableResult func load(_ m: LiveModel) -> Bool {
        lock.lock(); let already = (loadedResource == m.resource && model != nil); lock.unlock()
        if already { return true }
        guard let url = Bundle.main.url(forResource: m.resource, withExtension: "mlmodelc") else { return false }
        let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndNeuralEngine
        guard let ml = try? MLModel(contentsOf: url, configuration: cfg) else { return false }
        let desc = ml.modelDescription
        var iName = "image", iW = 518, iH = 518, oName = "depth"
        if let img = desc.inputDescriptionsByName.first(where: { $0.value.imageConstraint != nil }) {
            iName = img.key
            if let c = img.value.imageConstraint { iW = c.pixelsWide; iH = c.pixelsHigh }
        }
        oName = desc.outputDescriptionsByName.keys.first(where: { $0 == "depth" })
            ?? desc.outputDescriptionsByName.keys.first ?? "depth"
        lock.lock()
        model = ml; inputName = iName; inputW = iW; inputH = iH; outputName = oName
        inverse = m.inverse; metric = m.metric; loadedResource = m.resource
        lock.unlock()
        return true
    }

    /// CGImage → depth in metres (row-major) + (w, h). Nil if not loaded or inference fails.
    func depth(_ cg: CGImage) -> ([Float], Int, Int)? {
        lock.lock()
        guard let model else { lock.unlock(); return nil }
        let inName = inputName, outName = outputName, iw = inputW, ih = inputH, inv = inverse, met = metric
        lock.unlock()
        guard let feat = try? MLFeatureValue(cgImage: cg, pixelsWide: iw, pixelsHigh: ih,
                                             pixelFormatType: kCVPixelFormatType_32ARGB, options: nil),
              let provider = try? MLDictionaryFeatureProvider(dictionary: [inName: feat]),
              let out = try? model.prediction(from: provider),
              let dv = out.featureValue(for: outName) else { return nil }
        return metres(dv, inverse: inv, metric: met)
    }

    // MARK: depth feature → metres

    private func metres(_ v: MLFeatureValue, inverse: Bool, metric: Bool) -> ([Float], Int, Int)? {
        var raw: [Float] = []; var w = 0, h = 0
        if let a = v.multiArrayValue { (raw, w, h) = arrayFloats(a) }
        else if let px = v.imageBufferValue, let f = imageFloats(px) { (raw, w, h) = f }
        else { return nil }
        guard w > 0, h > 0, raw.count >= w * h else { return nil }
        if metric {                                  // already metres → pass through
            for i in 0..<(w * h) where !raw[i].isFinite { raw[i] = 0 }
            return (raw, w, h)
        }
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for x in raw where x.isFinite { lo = min(lo, x); hi = max(hi, x) }
        guard hi > lo else { return nil }
        let nearM: Float = 0.25, farM: Float = 2.5, span = hi - lo
        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            var t = raw[i].isFinite ? (raw[i] - lo) / span : 1
            if inverse { t = 1 - t }
            out[i] = nearM + (farM - nearM) * min(max(t, 0), 1)
        }
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
}
