import Foundation
import AVFoundation
import CoreML
import CoreImage
import CoreVideo

// Live monocular depth: runs a chosen CoreML depth model on the RGB camera each frame and pushes the
// result into renderer.ingest — so phones WITHOUT back LiDAR still drive the point cloud, and we can
// try MoGe-2 / Depth-Anything live on the back lenses. Generic over the model (introspects the image
// input + depth output; handles MLMultiArray or image outputs). Relative models are normalised to a
// metre range so the shader's metre-based gates render something; tune with the node's near/far.

struct LiveModel: Sendable, Equatable {
    var name: String        // display
    var resource: String    // compiled .mlmodelc bundle resource
    var inverse: Bool       // relative models emit inverse depth (near = large) → flip
    static let all: [LiveModel] = [
        LiveModel(name: "MoGe-2",             resource: "MoGe2_ViTB_Normal_504",    inverse: false),
        LiveModel(name: "Depth Anything V3 S", resource: "DepthAnythingV3_small_504", inverse: true),
        LiveModel(name: "Depth Anything V2 S", resource: "DepthAnythingV2SmallF16",  inverse: true),
    ]
    static func named(_ n: String) -> LiveModel { all.first { $0.name == n } ?? all[0] }
}

nonisolated final class LiveDepthEngine: @unchecked Sendable {
    private let renderer: PinRenderer
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private let lock = NSLock()
    private var model: MLModel?
    private var inputName = "image", outputName = "depth"
    private var inputW = 504, inputH = 504
    private var inverse = false
    private var busy = false
    private var loadedResource = ""
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0

    init(renderer: PinRenderer) { self.renderer = renderer }

    /// Load (once) the chosen model + introspect its I/O. Cheap to call repeatedly with the same model.
    func load(_ m: LiveModel) {
        lock.lock(); let already = loadedResource == m.resource; lock.unlock()
        if already { return }
        guard let url = Bundle.main.url(forResource: m.resource, withExtension: "mlmodelc") else { return }
        let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndNeuralEngine
        guard let ml = try? MLModel(contentsOf: url, configuration: cfg) else { return }
        let desc = ml.modelDescription
        var iName = "image", iW = 504, iH = 504, oName = "depth"
        if let img = desc.inputDescriptionsByName.first(where: { $0.value.imageConstraint != nil }) {
            iName = img.key
            if let c = img.value.imageConstraint { iW = c.pixelsWide; iH = c.pixelsHigh }
        }
        oName = desc.outputDescriptionsByName.keys.first(where: { $0 == "depth" })
            ?? desc.outputDescriptionsByName.keys.first ?? "depth"
        lock.lock()
        model = ml; inputName = iName; inputW = iW; inputH = iH; outputName = oName
        inverse = m.inverse; loadedResource = m.resource
        lock.unlock()
        renderer.setOrient(0)   // upright RGB → identity
    }

    /// One BGRA camera frame → depth → renderer. Drops frames while an inference is in flight.
    func process(_ bgra: CVPixelBuffer) {
        lock.lock()
        guard let model, !busy else { lock.unlock(); return }
        busy = true
        let inName = inputName, outName = outputName, iw = inputW, ih = inputH, inv = inverse
        lock.unlock()
        defer { lock.lock(); busy = false; lock.unlock() }

        let src = CIImage(cvPixelBuffer: bgra)
        guard let cg = ci.createCGImage(src, from: src.extent),
              let feat = try? MLFeatureValue(cgImage: cg, pixelsWide: iw, pixelsHigh: ih,
                                             pixelFormatType: kCVPixelFormatType_32ARGB, options: nil),
              let provider = try? MLDictionaryFeatureProvider(dictionary: [inName: feat]),
              let out = try? model.prediction(from: provider),
              let dv = out.featureValue(for: outName) else { return }

        guard let (metres, w, h) = depthFloats(dv, inverse: inv), let pb = buffer(metres, w, h) else { return }
        renderer.ingest(depth: pb, color: nil, lumaOnly: false)
    }

    // MARK: depth → normalised metres

    private func depthFloats(_ v: MLFeatureValue, inverse: Bool) -> ([Float], Int, Int)? {
        var raw: [Float] = []; var w = 0, h = 0
        if let a = v.multiArrayValue {
            (raw, w, h) = arrayFloats(a)
        } else if let px = v.imageBufferValue, let f = imageFloats(px) {
            (raw, w, h) = f
        } else { return nil }
        guard w > 0, h > 0, raw.count >= w * h else { return nil }
        // Normalise valid values → 0.25…2.5 m (near objects small), flipping inverse-depth models.
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for x in raw where x.isFinite { lo = min(lo, x); hi = max(hi, x) }
        guard hi > lo else { return nil }
        let nearM: Float = 0.25, farM: Float = 2.5, span = hi - lo
        var metres = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let x = raw[i]
            var t = x.isFinite ? (x - lo) / span : 1        // 0 near … 1 far (assuming direct depth)
            if inverse { t = 1 - t }
            metres[i] = nearM + (farM - nearM) * min(max(t, 0), 1)
        }
        return (metres, w, h)
    }

    /// Stride-safe read of a depth MLMultiArray (Float16/Float32) → row-major [Float] + (w,h).
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

    /// Any depth CVPixelBuffer (image-output models) → [Float] by rendering to 32-bit float.
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
