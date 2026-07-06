import Metal
import MetalKit
import MetalPerformanceShaders
import CoreVideo
import simd
import SwiftUI
import UIKit

/// Keeps CVMetalTexture wrappers alive until the GPU finishes with them.
private final class Retainer: @unchecked Sendable {
    let items: [CVMetalTexture]
    init(_ items: [CVMetalTexture]) { self.items = items }
}

// Field order MUST match VMParams in Shaders.metal.
struct VMParamsSwift {
    var instrCount: UInt32 = 0, stateStride: UInt32 = 0, colorIsLuma: UInt32 = 0, colorEnabled: UInt32 = 0
    var time: Float = 0, beatPhase: Float = 0, dt: Float = 1 / 60, pad: Float = 0
    var waveT: SIMD4<Float> = SIMD4(repeating: -1e6)
    var waveCA: SIMD4<Float> = .zero
    var waveCB: SIMD4<Float> = .zero
    var uvT: SIMD4<Float> = [0, 0, 1, 0]    // UV Transform: offset, scale, rotate
    var edge: SIMD4<Float> = .zero          // Edge Policy: mode, margin
    var domain: SIMD4<Float> = .zero        // Domain: topoA, topoB, morph
}

// Field order MUST match FillParams in Shaders.metal.
struct FillParamsSwift {
    var w: UInt32 = 0, h: UInt32 = 0
    var radius: Int32 = 3
    var gapThresh: Float = 0.08     // metres — fill the shadow toward the foreground only
}

// Field order MUST match CleanParams in Shaders.metal.
struct CleanParamsSwift {
    var w: UInt32 = 0, h: UInt32 = 0
    var gap: Float = 0.02, radius: Float = 1, alpha: Float = 0.125, reset: Float = 0
    var pad0: Float = 0, pad1: Float = 0
}

// Field order MUST match EmaParams in Shaders.metal.
struct EmaParamsSwift {
    var alpha: Float = 1, deadband: Float = 0, deadbandPerM: Float = 0, motionAdapt: Float = 5
    var holePersist: Float = 1, reset: Float = 0, pad0: Float = 0, pad1: Float = 0
}

// Field order MUST match PostParams in Shaders.metal.
struct PostParamsSwift {
    var bg: SIMD4<Float> = .zero     // Background rgb + gradient
    var fx: SIMD4<Float> = .zero     // bloomIntensity, vignette, grain, time
    var misc: SIMD4<Float> = .zero   // alphaKey, bloomOn
}

// Field order MUST match Uniforms in Shaders.metal.
struct PinUniforms {
    var viewProj: simd_float4x4
    var cols: UInt32 = 200, rows: UInt32 = 150, count: UInt32 = 30_000, orient: UInt32 = 1
    var extX: Float = 1.5, extY: Float = 2.0, zWorldScale: Float = 1.0, pinSize: Float = 0.012
    var stemThickness: Float = 0.004, nearM: Float = 0.25, farM: Float = 2.5, colorMode: UInt32 = 0
    var isStem: UInt32 = 0, pad0: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
    // Light nodes (up to 4) — tuples lay out like float4[4] in the Metal struct.
    var lightPos: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    var lightParams: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    var material: SIMD4<Float> = [1, 1, 0, 0]   // mode, roughness, metallic, lightCount
    var lookAt: SIMD4<Float> = .zero            // target xyz + amount
    var stemParams: SIMD4<Float> = [0, 0, 1, 0] // profile, taper, thickness×, unused
    var eyePos: SIMD4<Float> = [0, 0, 3, 0]     // camera eye — speculars track the orbit
    var camIntrin: SIMD4<Float> = [1, 1, 0.5, 0.5]  // fx_n, fy_n, cx_n, cy_n (METRIC unproject)
}

/// Instanced pin-wall renderer. Fixed camera, Z=0 wall, depth pulls pins toward the camera.
/// ponytail: single-file MVP renderer — domain warps / node engine / shape morphs come later.
nonisolated final class PinRenderer: NSObject, MTKViewDelegate {
    static let maxPins = 307_200

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState!
    private var ghostPipeline: MTLRenderPipelineState!    // Render Settings GHOST: additive, no depth
    private var postPipeline: MTLRenderPipelineState!     // composite: background/bloom/vignette/grain
    private var brightPipeline: MTLComputePipelineState!  // bloom bright-pass
    private var bloomBlur: MPSImageGaussianBlur!
    private var emaPipeline: MTLComputePipelineState!
    private var fillPipeline: MTLComputePipelineState!    // depth hole-fill (IR-shadow closer)
    private var despecklePipeline: MTLComputePipelineState!
    private var bilateralPipeline: MTLComputePipelineState!
    private var accumulatePipeline: MTLComputePipelineState!
    private var jbuPipeline: MTLComputePipelineState!     // Detail Upsample (joint bilateral)
    private var jbuTex: MTLTexture?
    private var depthState: MTLDepthStencilState!
    private var depthStateGhost: MTLDepthStencilState!    // always pass, no write
    private var textureCache: CVMetalTextureCache!

    /// Offscreen set per output (view / NDI / Record): scene color+depth, half-res bloom pair.
    private struct SceneTargets {
        let color: MTLTexture, depth: MTLTexture, bright: MTLTexture, blur: MTLTexture
        var w: Int { color.width }; var h: Int { color.height }
    }
    private var mainTargets: SceneTargets?
    private var ndiSceneTargets: SceneTargets?
    private var recSceneTargets: SceneTargets?

    // Meshes (interleaved pos+normal, stride 32)
    private var sphereHi: Mesh!, sphereLo: Mesh!, stemBox: Mesh!, stemRound: Mesh!
    private var fallbackColor: MTLTexture!   // 1×1 white, used before first camera frame
    private var fallbackDepth: MTLTexture!   // 1×1 zero → all pins rest on the wall

    // Latest camera frame (any thread) — lock-guarded.
    private let lock = NSLock()
    private var pendingDepth: CVPixelBuffer?
    private var pendingColor: CVPixelBuffer?
    private var pendingLumaOnly = false
    private var pendingReset = true

    // Filter state (ping-pong r32Float at depth resolution)
    private var emaTex: [MTLTexture] = []
    private var cleanTex: [MTLTexture] = []   // despeckle/bilateral scratch pair (r32Float)
    private var accTex: [MTLTexture] = []     // Accumulate ping-pong (r32Float)
    private var accParity = 0
    private var accValid = false
    private var fillTex: MTLTexture?          // hole-filled depth scratch (r32Float)
    private var _fillRadius: Int = 3          // 0 = off; IR-shadow fill radius (front camera)
    private var emaParity = 0
    private var filteredValid = false
    private var colorTexRef: CVMetalTexture?   // keep wrapper alive through GPU work
    private var colorTex: MTLTexture?

    // Node-engine execution (Layer A interpreter)
    private var vmPipeline: MTLComputePipelineState!
    private var paletteTex: MTLTexture!
    private var instanceBuf: MTLBuffer!
    private var stateBuf: MTLBuffer?
    private var stateStrideAllocated = 0
    private var lastProgramGeneration = -1
    /// Pulled once per frame on the main thread — supplies the live pin program.
    var programProvider: (@MainActor () -> ProgramFrame)?

    // NDI output: a second render pass into an IOSurface-backed BGRA pixel buffer, sent
    // to the network. Active only while an NDI node exists (config non-nil).
    var ndi: NDIManager?
    var ndiConfigProvider: (@MainActor () -> NDIRenderConfig?)?
    private var ndiPool: CVPixelBufferPool?
    private var ndiPoolW = 0, ndiPoolH = 0
    private var ndiDepthTex: MTLTexture?

    // Record: same offscreen-pass idea as NDI, but into an AVAssetWriter. Independent pool so it
    // records at its own resolution even when NDI is off. Active only while a Record node exists.
    // ponytail: a separate pass from NDI — a second offscreen render only when BOTH are live.
    var recorder: RecordingManager?
    var recordConfigProvider: (@MainActor () -> RecordConfig?)?
    private var recPool: CVPixelBufferPool?
    private var recPoolW = 0, recPoolH = 0
    private var recDepthTex: MTLTexture?

    // FPS (EMA over draw intervals) for the test HUD
    private var lastDrawAt: CFTimeInterval = 0
    private var fpsEMA: Double = 0
    var fps: Int { lock.lock(); defer { lock.unlock() }; return Int(fpsEMA.rounded()) }

    // Tweakables (set from UI; plain stores guarded by lock for MVP)
    private var _pinCount: Int = 30_000
    private var _orient: UInt32 = 1
    private var _camIntrin: SIMD4<Float> = [1, 1, 0.5, 0.5]   // METRIC-mode normalized intrinsics
    private var _zGain: Float = 1.2
    private var _pinScale: Float = 1.0
    private var _stemsOn = true
    private var _colorEnabled = false   // color OFF by default — manual enable in settings

    override init() {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else {
            fatalError("Metal unavailable")
        }
        device = dev; queue = q
        super.init()
        buildPipelines()
        buildMeshes()
        buildFallbacks()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    // MARK: - Public controls (callable from main)

    func ingest(depth: CVPixelBuffer, color: CVPixelBuffer?, lumaOnly: Bool) {
        // Sparse nearest-depth scan for the Proximity node (every 16th pixel, ~1200 reads).
        var nearest: Float = 0
        if CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32 ||
           CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_OneComponent32Float {
            CVPixelBufferLockBaseAddress(depth, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(depth) {
                let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
                let rowBytes = CVPixelBufferGetBytesPerRow(depth)
                var minD = Float.greatestFiniteMagnitude
                var y = 0
                while y < h {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                    var x = 0
                    while x < w {
                        let d = row[x]
                        if d > 0.05, d.isFinite, d < minD { minD = d }
                        x += 16
                    }
                    y += 16
                }
                nearest = minD == .greatestFiniteMagnitude ? 0 : minD
            }
            CVPixelBufferUnlockBaseAddress(depth, .readOnly)
        }
        lock.lock()
        pendingDepth = depth
        pendingColor = color
        pendingLumaOnly = lumaOnly
        _nearestDepth = nearest
        lock.unlock()
    }

    /// Nearest valid depth (metres) seen in the last frame — 0 while empty. Proximity node bus.
    var nearestDepth: Float { lock.lock(); defer { lock.unlock() }; return _nearestDepth }
    private var _nearestDepth: Float = 0

    func resetFilter() { lock.lock(); pendingReset = true; lock.unlock() }
    func setPinCount(_ n: Int) { lock.lock(); _pinCount = max(64, min(n, Self.maxPins)); lock.unlock() }
    func setOrient(_ o: UInt32) { lock.lock(); _orient = o & 7; lock.unlock() }
    /// Normalized camera intrinsics (fx/W, fy/H, cx/W, cy/H) for Point Display METRIC unprojection.
    func setIntrinsics(_ v: SIMD4<Float>) { lock.lock(); _camIntrin = v; lock.unlock() }
    func setZGain(_ g: Float) { lock.lock(); _zGain = max(0, min(g, 3)); lock.unlock() }
    func setPinScale(_ s: Float) { lock.lock(); _pinScale = max(0.2, min(s, 3)); lock.unlock() }
    func setStems(_ on: Bool) { lock.lock(); _stemsOn = on; lock.unlock() }
    func setColorEnabled(_ on: Bool) { lock.lock(); _colorEnabled = on; lock.unlock() }
    var pinCount: Int { lock.lock(); defer { lock.unlock() }; return _pinCount }
    var orient: UInt32 { lock.lock(); defer { lock.unlock() }; return _orient }
    var colorEnabled: Bool { lock.lock(); defer { lock.unlock() }; return _colorEnabled }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // MTKView calls its delegate on the main thread; view properties are MainActor-isolated.
        let (rpdOpt, drawableOpt, dsize) = MainActor.assumeIsolated {
            (view.currentRenderPassDescriptor, view.currentDrawable, view.drawableSize)
        }
        guard let rpd = rpdOpt,
              let drawable = drawableOpt,
              let cmd = queue.makeCommandBuffer() else { return }
        let viewAspect = dsize.height > 1 ? Float(dsize.width / dsize.height) : 0.75

        // Snapshot state under lock
        lock.lock()
        let depthBuf = pendingDepth
        let colorBuf = pendingColor
        let lumaOnly = pendingLumaOnly
        let reset = pendingReset
        pendingDepth = nil
        pendingColor = nil
        pendingReset = false
        let count = _pinCount, orientNow = _orient, pinScaleNow = _pinScale, stemsNow = _stemsOn
        let camIntrinNow = _camIntrin
        let colorOn = _colorEnabled
        lock.unlock()

        // This frame's pin program + camera (MTKView drives draw on the main thread).
        let frame = MainActor.assumeIsolated { self.programProvider?() }
            ?? ProgramFrame(instructions: [PinInstruction(.halt)], stateStride: 0,
                            generation: 0, time: 0, beatPhase: 0, dt: 1 / 60)

        var keeps: [CVMetalTexture] = []

        // 1. Filter new depth through the TDLidar temporal EMA: deadband hysteresis hold
        //    (zero static jitter) + velocity-adaptive alpha (motion → alpha ≈ 1, no lag).
        //    stabilize 0 = bit-exact passthrough (raw TDLidar life), 1 = locked statue.
        if let db = depthBuf, let wrapped = wrap(db, format: .r32Float, plane: 0, keeps: &keeps) {
            ensureEmaTextures(w: wrapped.width, h: wrapped.height)
            let effectiveReset = reset || !filteredValid

            // 0. Hole-fill the IR depth shadow (front camera) so it closes without Apple's filter,
            //    THEN feed the EMA. This kills the black band + the persist "trail".
            var emaInput = wrapped
            if _fillRadius > 0 {
                ensureFillTex(w: wrapped.width, h: wrapped.height)
                if let ft = fillTex, let enc = cmd.makeComputeCommandEncoder() {
                    enc.setComputePipelineState(fillPipeline)
                    enc.setTexture(wrapped, index: 0)
                    enc.setTexture(ft, index: 1)
                    var fp = FillParamsSwift(w: UInt32(wrapped.width), h: UInt32(wrapped.height),
                                             radius: Int32(_fillRadius))
                    enc.setBytes(&fp, length: MemoryLayout<FillParamsSwift>.stride, index: 0)
                    let tg = MTLSize(width: 16, height: 16, depth: 1)
                    enc.dispatchThreads(MTLSize(width: wrapped.width, height: wrapped.height, depth: 1),
                                        threadsPerThreadgroup: tg)
                    enc.endEncoding()
                    emaInput = ft
                }
            }

            if let enc = cmd.makeComputeCommandEncoder() {
                let s = min(max(frame.depthStabilize, 0), 1)
                enc.setComputePipelineState(emaPipeline)
                enc.setTexture(emaInput, index: 0)
                enc.setTexture(emaTex[emaParity], index: 1)          // prev (.r emaZ, .g vel)
                enc.setTexture(emaTex[1 - emaParity], index: 2)      // out
                // TDLidar host constants: alpha = 1-0.9s, deadband 0.008s (+0.012s/m), motionAdapt 5
                var p = EmaParamsSwift(alpha: 1 - 0.9 * s,
                                       deadband: 0.008 * s,
                                       deadbandPerM: 0.012 * s,
                                       motionAdapt: 5,
                                       holePersist: frame.holePersist ? 1 : 0,
                                       reset: effectiveReset ? 1 : 0)
                enc.setBytes(&p, length: MemoryLayout<EmaParamsSwift>.stride, index: 0)
                let tg = MTLSize(width: 16, height: 16, depth: 1)
                let grid = MTLSize(width: wrapped.width, height: wrapped.height, depth: 1)
                enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
                enc.endEncoding()
                emaParity = 1 - emaParity
                filteredValid = true
            }
        }
        if reset { filteredValid = filteredValid && depthBuf != nil }

        // 2. Wrap color (bound for loadColor ops; the program decides whether it's used)
        if let cb = colorBuf {
            if lumaOnly {
                if let t = wrap(cb, format: .r8Unorm, plane: 0, keeps: &keeps) { colorTex = t }
            } else {
                if let t = wrap(cb, format: .bgra8Unorm, plane: 0, keeps: &keeps) { colorTex = t }
            }
            colorTexRef = keeps.last
        }

        // 3. Grid dims from count at 3:4
        let cols = max(2, Int((Float(count) * 0.75).squareRoot().rounded()))
        let rows = max(2, Int((Float(count) / Float(cols)).rounded(.up)))
        let actual = cols * rows

        let (viewProj, eye) = Self.buildCamera(frame.camera, aspect: viewAspect)
        var u = PinUniforms(viewProj: viewProj)
        u.eyePos = SIMD4(eye, 0)
        u.camIntrin = camIntrinNow
        u.cols = UInt32(cols); u.rows = UInt32(rows); u.count = UInt32(actual)
        u.orient = orientNow
        u.zWorldScale = frame.camera.depthPush
        u.lightPos = (frame.light(0).0, frame.light(1).0, frame.light(2).0, frame.light(3).0)
        u.lightParams = (frame.light(0).1, frame.light(1).1, frame.light(2).1, frame.light(3).1)
        u.material = frame.material
        u.lookAt = frame.lookAt
        u.stemParams = frame.stem
        // pin size scales with grid pitch so pins tile the wall at any density
        let pitch = 3.0 / Float(cols - 1)
        u.pinSize = pitch * 0.42 * pinScaleNow
        u.stemThickness = pitch * 0.16 * pinScaleNow

        // 4. Pin program instructions (frame fetched above)
        var instrs = frame.instructions
        if instrs.count > 128 { instrs = Array(instrs.prefix(127)) + [PinInstruction(.halt)] }

        // 5. State pool — zero-fill ONLY when the layout (stride) changes, so slider
        //    recompiles keep spring/lag/trail/freeze memory alive (no pops mid-drag).
        let strideNeeded = max(frame.stateStride, 0)
        var needsClear = false
        if strideNeeded > 0 && (stateBuf == nil || stateStrideAllocated < strideNeeded) {
            stateBuf = device.makeBuffer(length: Self.maxPins * strideNeeded * 4, options: .storageModePrivate)
            stateStrideAllocated = strideNeeded
            needsClear = true
        }
        if frame.generation != lastProgramGeneration {
            lastProgramGeneration = frame.generation
            // layout unchanged → keep state; changed stride was handled above
        }
        if needsClear, let sb = stateBuf, let blit = cmd.makeBlitCommandEncoder() {
            blit.fill(buffer: sb, range: 0..<sb.length, value: 0)
            blit.endEncoding()
        }

        // 5b. FILTER-node cleanup chain on the filtered depth: Despeckle → Smooth Surface →
        //     Accumulate (each runs only while its node is in the graph).
        var depthForVM: MTLTexture = filteredValid ? emaTex[emaParity] : fallbackDepth
        if filteredValid, let src = emaTex.first {
            let w = src.width, h = src.height
            func clean(_ pipe: MTLComputePipelineState, _ input: MTLTexture, _ output: MTLTexture,
                       _ p: inout CleanParamsSwift) {
                guard let enc = cmd.makeComputeCommandEncoder() else { return }
                enc.setComputePipelineState(pipe)
                enc.setTexture(input, index: 0)
                enc.setTexture(output, index: 1)
                enc.setBytes(&p, length: MemoryLayout<CleanParamsSwift>.stride, index: 0)
                enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                enc.endEncoding()
            }
            if frame.despeckleGap > 0.0001 || frame.smoothRadius >= 1 { ensureCleanTextures(w: w, h: h) }
            if frame.despeckleGap > 0.0001, cleanTex.count == 2 {
                var p = CleanParamsSwift(w: UInt32(w), h: UInt32(h), gap: frame.despeckleGap)
                clean(despecklePipeline, depthForVM, cleanTex[0], &p)
                depthForVM = cleanTex[0]
            }
            if frame.smoothRadius >= 1, cleanTex.count == 2 {
                var p = CleanParamsSwift(w: UInt32(w), h: UInt32(h), radius: frame.smoothRadius)
                let dst = depthForVM === cleanTex[0] ? cleanTex[1] : cleanTex[0]
                clean(bilateralPipeline, depthForVM, dst, &p)
                depthForVM = dst
            }
            if frame.accumFrames > 1.5 {
                ensureAccTextures(w: w, h: h)
                if accTex.count == 2, let enc = cmd.makeComputeCommandEncoder() {
                    var p = CleanParamsSwift(w: UInt32(w), h: UInt32(h),
                                             alpha: 1 / max(frame.accumFrames, 2),
                                             reset: accValid ? 0 : 1)
                    enc.setComputePipelineState(accumulatePipeline)
                    enc.setTexture(depthForVM, index: 0)
                    enc.setTexture(accTex[accParity], index: 1)
                    enc.setTexture(accTex[1 - accParity], index: 2)
                    enc.setBytes(&p, length: MemoryLayout<CleanParamsSwift>.stride, index: 0)
                    enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                    enc.endEncoding()
                    accParity = 1 - accParity
                    accValid = true
                    depthForVM = accTex[accParity]
                }
            } else {
                accValid = false   // node removed → reseed next time
            }
            // Detail Upsample (JBU): depth resampled at FACTOR× res, edges guided by RGB.
            if frame.jbuFactor > 1.01, let guide = colorTex {
                let f = min(max(Int(frame.jbuFactor.rounded()), 2), 4)
                let jw = w * f, jh = h * f
                if jbuTex == nil || jbuTex!.width != jw || jbuTex!.height != jh {
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float,
                                                                     width: jw, height: jh, mipmapped: false)
                    d.usage = [.shaderRead, .shaderWrite]
                    d.storageMode = .private
                    jbuTex = device.makeTexture(descriptor: d)
                }
                if let jt = jbuTex, let enc = cmd.makeComputeCommandEncoder() {
                    var p = CleanParamsSwift(w: UInt32(jw), h: UInt32(jh),
                                             gap: 0.08, alpha: lumaOnly ? 1 : 0)
                    enc.setComputePipelineState(jbuPipeline)
                    enc.setTexture(depthForVM, index: 0)
                    enc.setTexture(guide, index: 1)
                    enc.setTexture(jt, index: 2)
                    enc.setBytes(&p, length: MemoryLayout<CleanParamsSwift>.stride, index: 0)
                    enc.dispatchThreads(MTLSize(width: jw, height: jh, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                    enc.endEncoding()
                    depthForVM = jt
                }
            }
        }

        // FPS EMA for the test HUD
        let nowT = CACurrentMediaTime()
        if lastDrawAt > 0 {
            let inst = 1.0 / max(nowT - lastDrawAt, 0.0001)
            lock.lock(); fpsEMA = fpsEMA == 0 ? inst : fpsEMA * 0.9 + inst * 0.1; lock.unlock()
        }
        lastDrawAt = nowT

        // 6. Interpreter pass → instance buffer
        var vm = VMParamsSwift(instrCount: UInt32(instrs.count), stateStride: UInt32(strideNeeded),
                               colorIsLuma: lumaOnly ? 1 : 0, colorEnabled: colorOn ? 1 : 0,
                               time: frame.time, beatPhase: frame.beatPhase, dt: frame.dt, pad: 0,
                               waveT: frame.waveT, waveCA: frame.waveCA, waveCB: frame.waveCB,
                               uvT: frame.uvTransform, edge: frame.edgePolicy, domain: frame.domain)
        if let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(vmPipeline)
            enc.setBytes(&u, length: MemoryLayout<PinUniforms>.stride, index: 0)
            enc.setBytes(&vm, length: MemoryLayout<VMParamsSwift>.stride, index: 1)
            instrs.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 2) }
            enc.setBuffer(stateBuf ?? instanceBuf, offset: 0, index: 3)   // dummy bind when stateless
            enc.setBuffer(instanceBuf, offset: 0, index: 4)
            enc.setTexture(depthForVM, index: 0)
            enc.setTexture(colorTex ?? fallbackColor, index: 1)
            enc.setTexture(paletteTex, index: 2)
            enc.dispatchThreads(MTLSize(width: actual, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            enc.endEncoding()
        }

        // 7. Scene pass offscreen, then the post composite (Background/Bloom/Vignette/Grain)
        //    into the drawable. NDI/Record repeat the same path at their own sizes.
        let hiDetail = actual <= 100_000
        let capMesh = hiDetail ? sphereHi! : sphereLo!
        // arms = Point Display node param (graph is the truth); menu cube toggles that param
        let drawStems = frame.stems && stemsNow && actual <= 150_000

        ensureSceneTargets(&mainTargets, w: max(Int(dsize.width), 4), h: max(Int(dsize.height), 4))
        if let targets = mainTargets {
            encodeScene(cmd: cmd, targets: targets, u: &u, frame: frame,
                        actual: actual, capMesh: capMesh, drawStems: drawStems)
            if frame.post.y > 0.001 { encodeBloom(cmd: cmd, targets: targets, threshold: frame.post.x) }
            encodePost(cmd: cmd, targets: targets, rpd: rpd, frame: frame, alphaKey: false)
        }

        // 8. NDI: same instanced draw into an offscreen BGRA pixel buffer at the node's
        //    resolution/aspect, sent to the network after the GPU finishes this buffer.
        let ndiCfg = MainActor.assumeIsolated { self.ndiConfigProvider?() }
        if let cfg = ndiCfg, let mgr = ndi {
            encodeNDI(cmd: cmd, base: u, frame: frame, actual: actual,
                      capMesh: capMesh, drawStems: drawStems, cfg: cfg, mgr: mgr)
        }

        // 9. Record: same offscreen instanced pass → AVAssetWriter, driven by the Record node.
        let recCfg = MainActor.assumeIsolated { self.recordConfigProvider?() }
        if let cfg = recCfg, let rec = recorder {
            rec.begin(cfg)                           // idempotent (render thread only)
            encodeRecord(cmd: cmd, base: u, frame: frame, actual: actual,
                         capMesh: capMesh, drawStems: drawStems, cfg: cfg, rec: rec)
        } else {
            recorder?.finishIfRecording()            // node removed / STOP → finalize + save
        }

        let retainer = Retainer(keeps)               // retain CVMetalTextures through GPU execution
        cmd.addCompletedHandler { _ in _ = retainer.items }
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - NDI offscreen pass

    /// Reuse the already-computed instance buffer to draw the pins into a BGRA pixel buffer
    /// at the NDI resolution, then hand it to the manager once the GPU is done with it.
    private func encodeNDI(cmd: MTLCommandBuffer, base: PinUniforms, frame: ProgramFrame,
                           actual: Int, capMesh: Mesh, drawStems: Bool,
                           cfg: NDIRenderConfig, mgr: NDIManager) {
        let w = max(cfg.width, 16), h = max(cfg.height, 16)
        ensureNDITargets(w: w, h: h)
        guard let pool = ndiPool, let depth = ndiDepthTex else { return }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess,
              let pb = pbOut,
              let surfRef = CVPixelBufferGetIOSurface(pb) else { return }
        let surf = surfRef.takeUnretainedValue()
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                          width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let color = device.makeTexture(descriptor: td, iosurface: surf, plane: 0) else { return }

        var u = base
        (u.viewProj, _) = Self.buildCamera(frame.camera, aspect: Float(w) / Float(h))
        ensureSceneTargets(&ndiSceneTargets, w: w, h: h)
        guard let targets = ndiSceneTargets else { return }
        encodeScene(cmd: cmd, targets: targets, u: &u, frame: frame,
                    actual: actual, capMesh: capMesh, drawStems: drawStems)
        if frame.post.y > 0.001 { encodeBloom(cmd: cmd, targets: targets, threshold: frame.post.x) }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .dontCare   // composite covers every pixel
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .dontCare
        rpd.depthAttachment.storeAction = .dontCare
        encodePost(cmd: cmd, targets: targets, rpd: rpd, frame: frame, alphaKey: cfg.alpha)

        let n = cfg.fpsN, d = cfg.fpsD
        // pb captured → retained until the send completes (base address valid once GPU done).
        nonisolated(unsafe) let out = pb        // read-only CF handoff to the completion thread
        cmd.addCompletedHandler { _ in mgr.send(out, fpsN: n, fpsD: d) }
    }

    private func ensureNDITargets(w: Int, h: Int) {
        if ndiPool == nil || ndiPoolW != w || ndiPoolH != h {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            ndiPool = pool; ndiPoolW = w; ndiPoolH = h
            ndiDepthTex = nil
        }
        if ndiDepthTex == nil {
            let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                              width: w, height: h, mipmapped: false)
            dd.usage = [.renderTarget]
            dd.storageMode = .private
            ndiDepthTex = device.makeTexture(descriptor: dd)
        }
    }

    // MARK: - Record offscreen pass

    /// Draw the pins into a BGRA pixel buffer at the Record resolution, then append it to the
    /// recorder once the GPU is done. Mirrors `encodeNDI` with its own pool (independent of NDI).
    private func encodeRecord(cmd: MTLCommandBuffer, base: PinUniforms, frame: ProgramFrame,
                              actual: Int, capMesh: Mesh, drawStems: Bool,
                              cfg: RecordConfig, rec: RecordingManager) {
        let w = max(cfg.width, 16), h = max(cfg.height, 16)
        ensureRecordTargets(w: w, h: h)
        guard let pool = recPool, let depth = recDepthTex else { return }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess,
              let pb = pbOut,
              let surfRef = CVPixelBufferGetIOSurface(pb) else { return }
        let surf = surfRef.takeUnretainedValue()
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                          width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let color = device.makeTexture(descriptor: td, iosurface: surf, plane: 0) else { return }

        var u = base
        (u.viewProj, _) = Self.buildCamera(frame.camera, aspect: Float(w) / Float(h))
        ensureSceneTargets(&recSceneTargets, w: w, h: h)
        guard let targets = recSceneTargets else { return }
        encodeScene(cmd: cmd, targets: targets, u: &u, frame: frame,
                    actual: actual, capMesh: capMesh, drawStems: drawStems)
        if frame.post.y > 0.001 { encodeBloom(cmd: cmd, targets: targets, threshold: frame.post.x) }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .dontCare   // composite covers every pixel
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .dontCare
        rpd.depthAttachment.storeAction = .dontCare
        encodePost(cmd: cmd, targets: targets, rpd: rpd, frame: frame, alphaKey: cfg.alpha)

        // pb captured → retained until the append completes (base address valid once GPU done).
        nonisolated(unsafe) let out = pb        // read-only CF handoff to the completion thread
        cmd.addCompletedHandler { _ in rec.append(out) }
    }

    private func ensureRecordTargets(w: Int, h: Int) {
        if recPool == nil || recPoolW != w || recPoolH != h {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            recPool = pool; recPoolW = w; recPoolH = h
            recDepthTex = nil
        }
        if recDepthTex == nil {
            let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                              width: w, height: h, mipmapped: false)
            dd.usage = [.renderTarget]
            dd.storageMode = .private
            recDepthTex = device.makeTexture(descriptor: dd)
        }
    }

    // MARK: - Setup

    /// Camera node → viewProj. Always orbiting the cloud centre so pins warp around it.
    /// FOV sets the lens (flat↔wide); ZOOM frames the wall; PARALLAX pulls the camera in for
    /// stronger perspective warp while the FOV widens to keep the framing constant; CENTRE nudges
    /// the pivot; ORBIT (joystick) walks the eye around the pivot on a sphere — TDLidar turntable.
    private static func buildCamera(_ c: CameraFrame, aspect: Float) -> (simd_float4x4, SIMD3<Float>) {
        // Frame by WIDTH (the 3:4 wall's extX = 1.5) so the grid always fills the width and
        // stays 1:1 no matter the viewport aspect — a taller viewport just reveals more black
        // above/below, never stretches. At aspect 0.75 this is identical to the old 3:4 framing.
        let a = max(aspect, 0.1)
        let halfH = (1.5 / a) / max(c.zoom, 0.1)                 // vertical half-extent for this aspect
        let fovBase = max(min(c.fov, 110), 10) * .pi / 180
        let dFrame = halfH / tan(fovBase * 0.5)                  // distance that frames the wall at fovBase
        let dEff = dFrame * (1 - 0.65 * min(max(c.parallax, 0), 1))   // parallax pulls the camera in
        let fovEff = 2 * atan(halfH / dEff)                      // widen FOV to keep framing constant
        let proj = perspective(fovY: fovEff, aspect: a, near: 0.05, far: 200)
        let yaw = c.orbitX                                        // unbounded — full turntable both ways
        let pitch = min(max(c.orbitY, -1.5), 1.5)                 // ~±86°; avoids the up-vector flip over the pole
        let dir = SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        let center = SIMD3<Float>(c.centerX, c.centerY, 0)
        let eye = center + dir * dEff
        return (proj * lookAt(eye: eye, center: center, up: [0, 1, 0]), eye)
    }

    private func buildPipelines() {
        let lib = device.makeDefaultLibrary()!
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "pin_vertex")
        desc.fragmentFunction = lib.makeFunction(name: "pin_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.depthAttachmentPixelFormat = .depth32Float
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3; vd.attributes[1].offset = 16; vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = 32
        desc.vertexDescriptor = vd
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)

        // GHOST (Render Settings): additive accumulation, no depth occlusion.
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .one
        ghostPipeline = try! device.makeRenderPipelineState(descriptor: desc)

        // Post composite (fullscreen triangle) — background / bloom / vignette / grain.
        let post = MTLRenderPipelineDescriptor()
        post.vertexFunction = lib.makeFunction(name: "post_vertex")
        post.fragmentFunction = lib.makeFunction(name: "post_composite")
        post.colorAttachments[0].pixelFormat = .bgra8Unorm
        post.depthAttachmentPixelFormat = .depth32Float
        postPipeline = try! device.makeRenderPipelineState(descriptor: post)

        emaPipeline = try! device.makeComputePipelineState(function: lib.makeFunction(name: "depth_ema")!)
        fillPipeline = try! device.makeComputePipelineState(function: lib.makeFunction(name: "depth_fill_holes")!)
        despecklePipeline = try! device.makeComputePipelineState(function: lib.makeFunction(name: "depth_despeckle")!)
        bilateralPipeline = try! device.makeComputePipelineState(function: lib.makeFunction(name: "depth_bilateral")!)
        accumulatePipeline = try! device.makeComputePipelineState(function: lib.makeFunction(name: "depth_accumulate")!)
        jbuPipeline = try! device.makeComputePipelineState(function: lib.makeFunction(name: "depth_jbu")!)
        brightPipeline = try! device.makeComputePipelineState(function: lib.makeFunction(name: "bloom_brightpass")!)
        vmPipeline = try! device.makeComputePipelineState(function: lib.makeFunction(name: "pin_program")!)
        bloomBlur = MPSImageGaussianBlur(device: device, sigma: 6)

        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .less
        ds.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: ds)
        ds.depthCompareFunction = .always
        ds.isDepthWriteEnabled = false
        depthStateGhost = device.makeDepthStencilState(descriptor: ds)
    }

    // MARK: - Scene → post shared encoders (view, NDI and Record all use the same path)

    private func ensureSceneTargets(_ slot: inout SceneTargets?, w: Int, h: Int) {
        if let t = slot, t.w == w, t.h == h { return }
        func tex(_ w: Int, _ h: Int, _ fmt: MTLPixelFormat, _ usage: MTLTextureUsage) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: max(w, 4),
                                                             height: max(h, 4), mipmapped: false)
            d.usage = usage; d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        slot = SceneTargets(
            color: tex(w, h, .bgra8Unorm, [.renderTarget, .shaderRead]),
            depth: tex(w, h, .depth32Float, [.renderTarget]),
            bright: tex(w / 2, h / 2, .bgra8Unorm, [.shaderRead, .shaderWrite]),
            blur: tex(w / 2, h / 2, .bgra8Unorm, [.shaderRead, .shaderWrite]))
    }

    /// Instanced pin pass into an offscreen scene (alpha 0 where empty, so post can lay
    /// the Background behind). GHOST switches to additive blending with no depth test.
    private func encodeScene(cmd: MTLCommandBuffer, targets: SceneTargets, u: inout PinUniforms,
                             frame: ProgramFrame, actual: Int, capMesh: Mesh, drawStems: Bool) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = targets.color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = targets.depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(frame.ghost ? ghostPipeline : pipeline)
        enc.setDepthStencilState(frame.ghost ? depthStateGhost : depthState)
        enc.setCullMode(.back)
        enc.setFrontFacing(.counterClockwise)
        enc.setVertexBuffer(instanceBuf, offset: 0, index: 2)
        if drawStems {
            u.isStem = 1
            let stemMesh = frame.stem.x > 0.5 && frame.stem.x < 1.5 ? stemRound! : stemBox!
            enc.setVertexBytes(&u, length: MemoryLayout<PinUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<PinUniforms>.stride, index: 1)
            enc.setVertexBuffer(stemMesh.vertices, offset: 0, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: stemMesh.indexCount,
                                      indexType: .uint16, indexBuffer: stemMesh.indices,
                                      indexBufferOffset: 0, instanceCount: actual)
        }
        u.isStem = 0
        enc.setVertexBytes(&u, length: MemoryLayout<PinUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<PinUniforms>.stride, index: 1)
        enc.setVertexBuffer(capMesh.vertices, offset: 0, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: capMesh.indexCount,
                                  indexType: .uint16, indexBuffer: capMesh.indices,
                                  indexBufferOffset: 0, instanceCount: actual)
        enc.endEncoding()
    }

    /// Bloom: bright-pass at half res, gaussian blur (MPS), sampled back in the composite.
    private func encodeBloom(cmd: MTLCommandBuffer, targets: SceneTargets, threshold: Float) {
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(brightPipeline)
        enc.setTexture(targets.color, index: 0)
        enc.setTexture(targets.bright, index: 1)
        var th = threshold
        enc.setBytes(&th, length: MemoryLayout<Float>.stride, index: 0)
        enc.dispatchThreads(MTLSize(width: targets.bright.width, height: targets.bright.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        bloomBlur.encode(commandBuffer: cmd, sourceTexture: targets.bright, destinationTexture: targets.blur)
    }

    /// Composite the offscreen scene into the output target with the STAGE post nodes applied.
    private func encodePost(cmd: MTLCommandBuffer, targets: SceneTargets,
                            rpd: MTLRenderPassDescriptor, frame: ProgramFrame, alphaKey: Bool) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(postPipeline)
        enc.setDepthStencilState(depthStateGhost)   // fullscreen: always pass, no depth write
        var p = PostParamsSwift()
        p.bg = frame.background
        p.fx = [frame.post.y, frame.post.w, frame.post.z, frame.time]
        p.misc = [alphaKey ? 1 : 0, frame.post.y > 0.001 ? 1 : 0, 0, 0]
        enc.setFragmentBytes(&p, length: MemoryLayout<PostParamsSwift>.stride, index: 0)
        enc.setFragmentTexture(targets.color, index: 0)
        enc.setFragmentTexture(targets.blur, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func buildFallbacks() {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead]
        fallbackDepth = device.makeTexture(descriptor: d)
        var zero: Float = 0
        fallbackDepth.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)

        let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        c.usage = [.shaderRead]
        fallbackColor = device.makeTexture(descriptor: c)
        var white: UInt32 = 0xFFFFFFFF
        fallbackColor.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)

        // Palette LUT (8 rows × 256) for the `palette` op
        let p = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 8, mipmapped: false)
        p.usage = [.shaderRead]
        paletteTex = device.makeTexture(descriptor: p)
        let lut = PaletteLUT.generate()
        lut.withUnsafeBytes {
            paletteTex.replace(region: MTLRegionMake2D(0, 0, 256, 8), mipmapLevel: 0,
                               withBytes: $0.baseAddress!, bytesPerRow: 256 * 4)
        }

        // Interpreter output: one InstanceOut (64B: posSize + color + rot + scl) per pin (~19.6MB, private)
        instanceBuf = device.makeBuffer(length: Self.maxPins * 64, options: .storageModePrivate)
    }

    private func ensureCleanTextures(w: Int, h: Int) {
        if let t = cleanTex.first, t.width == w, t.height == h { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        cleanTex = [device.makeTexture(descriptor: d)!, device.makeTexture(descriptor: d)!]
    }

    private func ensureAccTextures(w: Int, h: Int) {
        if let t = accTex.first, t.width == w, t.height == h { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        accTex = [device.makeTexture(descriptor: d)!, device.makeTexture(descriptor: d)!]
        accParity = 0
        accValid = false
    }

    private func ensureFillTex(w: Int, h: Int) {
        if let t = fillTex, t.width == w, t.height == h { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        fillTex = device.makeTexture(descriptor: d)
    }

    private func ensureEmaTextures(w: Int, h: Int) {
        if let t = emaTex.first, t.width == w, t.height == h { return }
        // .rg: r = filtered depth (sampled by the pin program), g = jitter-energy velocity
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        emaTex = [device.makeTexture(descriptor: d)!, device.makeTexture(descriptor: d)!]
        emaParity = 0
        filteredValid = false   // forces reset-seed on next filter pass (private tex is undefined at alloc)
    }

    private func wrap(_ buf: CVPixelBuffer, format: MTLPixelFormat, plane: Int, keeps: inout [CVMetalTexture]) -> MTLTexture? {
        let planar = CVPixelBufferGetPlaneCount(buf) > 0
        let w = planar ? CVPixelBufferGetWidthOfPlane(buf, plane) : CVPixelBufferGetWidth(buf)
        let h = planar ? CVPixelBufferGetHeightOfPlane(buf, plane) : CVPixelBufferGetHeight(buf)
        var out: CVMetalTexture?
        let res = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buf, nil, format, w, h, plane, &out)
        guard res == kCVReturnSuccess, let cvTex = out, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        keeps.append(cvTex)
        return tex
    }

    // MARK: - Meshes

    private struct Mesh { let vertices: MTLBuffer; let indices: MTLBuffer; let indexCount: Int }

    private func buildMeshes() {
        sphereHi = makeSphere(rings: 6, segs: 10)
        sphereLo = makeSphere(rings: 3, segs: 4)
        stemBox = makeBox()
        stemRound = makeCylinder(segs: 8)
    }

    /// Open-ended cylinder for the Stem node's ROUND profile (ends hidden by wall/cap).
    private func makeCylinder(segs: Int) -> Mesh {
        var verts: [(SIMD3<Float>, SIMD3<Float>)] = []
        var idx: [UInt16] = []
        for s in 0...segs {
            let a = Float(s) / Float(segs) * 2 * .pi
            let n = SIMD3<Float>(cos(a), sin(a), 0)
            verts.append((SIMD3(n.x * 0.5, n.y * 0.5, -0.5), n))
            verts.append((SIMD3(n.x * 0.5, n.y * 0.5, 0.5), n))
        }
        for s in 0..<segs {
            let a = UInt16(s * 2), b = UInt16(s * 2 + 1)
            let c = UInt16(s * 2 + 2), d = UInt16(s * 2 + 3)
            idx += [a, c, b, b, c, d]
        }
        return packMesh(verts, idx)
    }

    /// Interleaved [pos.xyz pad][nrm.xyz pad] — SIMD3<Float> stride 16, total 32B/vertex.
    private func packMesh(_ verts: [(SIMD3<Float>, SIMD3<Float>)], _ idx: [UInt16]) -> Mesh {
        var data = [SIMD4<Float>]()
        data.reserveCapacity(verts.count * 2)
        for (p, n) in verts {
            data.append(SIMD4(p, 0))
            data.append(SIMD4(n, 0))
        }
        let vb = device.makeBuffer(bytes: data, length: data.count * 16, options: [])!
        let ib = device.makeBuffer(bytes: idx, length: idx.count * 2, options: [])!
        return Mesh(vertices: vb, indices: ib, indexCount: idx.count)
    }

    private func makeSphere(rings: Int, segs: Int) -> Mesh {
        var verts: [(SIMD3<Float>, SIMD3<Float>)] = []
        var idx: [UInt16] = []
        for r in 0...rings {
            let phi = Float(r) / Float(rings) * .pi
            for s in 0...segs {
                let theta = Float(s) / Float(segs) * 2 * .pi
                let n = SIMD3<Float>(sin(phi) * cos(theta), sin(phi) * sin(theta), cos(phi))
                verts.append((n * 0.5, n))
            }
        }
        let stride = segs + 1
        for r in 0..<rings {
            for s in 0..<segs {
                let a = UInt16(r * stride + s), b = UInt16(r * stride + s + 1)
                let c = UInt16((r + 1) * stride + s), d = UInt16((r + 1) * stride + s + 1)
                idx += [a, c, b, b, c, d]
            }
        }
        return packMesh(verts, idx)
    }

    private func makeBox() -> Mesh {
        var verts: [(SIMD3<Float>, SIMD3<Float>)] = []
        var idx: [UInt16] = []
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [   // (normal, uAxis, vAxis)
            ([0, 0, 1], [1, 0, 0], [0, 1, 0]), ([0, 0, -1], [-1, 0, 0], [0, 1, 0]),
            ([1, 0, 0], [0, 0, -1], [0, 1, 0]), ([-1, 0, 0], [0, 0, 1], [0, 1, 0]),
            ([0, 1, 0], [1, 0, 0], [0, 0, -1]), ([0, -1, 0], [1, 0, 0], [0, 0, 1]),
        ]
        for (n, uA, vA) in faces {
            let base = UInt16(verts.count)
            for (du, dv) in [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)] {
                let p = n * 0.5 + uA * Float(du) + vA * Float(dv)
                verts.append((p, n))
            }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return packMesh(verts, idx)
    }
}

// MARK: - Matrix helpers

private nonisolated func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovY * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4(x, 0, 0, 0),
        SIMD4(0, y, 0, 0),
        SIMD4(0, 0, z, -1),
        SIMD4(0, 0, z * near, 0)
    ))
}

private nonisolated func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = simd_normalize(center - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)
    return simd_float4x4(columns: (
        SIMD4(s.x, u.x, -f.x, 0),
        SIMD4(s.y, u.y, -f.y, 0),
        SIMD4(s.z, u.z, -f.z, 0),
        SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
    ))
}

// MARK: - SwiftUI host

struct MetalViewport: UIViewRepresentable {
    let renderer: PinRenderer
    /// Pause the render loop while a full-screen cover (node palette) hides the view — otherwise
    /// it keeps drawing at 60fps + running the NDI/record offscreen passes behind the cover,
    /// starving the capture session and hitching the keyboard/search.
    var paused: Bool = false

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = MTLCreateSystemDefaultDevice()
        v.delegate = renderer
        v.colorPixelFormat = .bgra8Unorm
        v.depthStencilPixelFormat = .depth32Float
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        v.preferredFramesPerSecond = 60
        v.isPaused = paused
        v.enableSetNeedsDisplay = false
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        if uiView.isPaused != paused { uiView.isPaused = paused }
    }
}
