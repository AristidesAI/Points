import Foundation
import simd

// Shared 'shape the signal before it drives anything' transform for continuous Vision control
// nodes: gain → remap(in→out) → deadzone → invert → smoothing. `prev` is the node's persistent
// smoothing memory (one state lane per output).
nonisolated func shapeVisionValue(_ raw: Float, _ node: GraphNode, _ dt: Float, _ prev: inout Float) -> Float {
    var v = raw * node.float("gain", 1)
    let inLo = node.float("inMin", 0), inHi = node.float("inMax", 1)
    v = (v - inLo) / max(inHi - inLo, 1e-4)
    let dz = node.float("deadzone", 0)
    if dz > 0 && abs(v - 0.5) < dz { v = 0.5 }
    let outLo = node.float("outMin", 0), outHi = node.float("outMax", 1)
    v = v * (outHi - outLo) + outLo
    if node.float("invert", 0) > 0.5 { v = (outLo + outHi) - v }
    let sm = node.float("smoothing", 0)
    if sm > 0.001 { prev += (v - prev) * (1 - sm * 0.97); return prev }
    prev = v
    return v
}

// The rest of the Plans/03 catalog. Every node is REGISTERED (ports/params/descriptions power
// the palette + future editor). Execution classes:
//   • real      — full emitter / control eval, works today
//   • stub      — control node returning bus values that are zeros until its engine lands
//                 (audio / MIDI / OSC / Vision body), description says so
//   • passthrough — domain-filter whose render feature isn't in the pipeline yet
//                 (shapes/materials/lights); wiring it compiles and passes data through

extension NodeRegistry {

    // MARK: helpers

    private func stubControl(_ id: String, _ name: String, _ family: NodeFamily,
                             _ outputs: [PortSpec], _ desc: String,
                             bus: @escaping @Sendable (ControlContext) -> [SIMD4<Float>]) {
        registerSpec(NodeSpec(id: id, name: name, family: family, outputs: outputs,
                              execution: .control, description: desc,
                              controlEval: { _, _, ctx in bus(ctx) }))
    }

    /// Palm/fist/peace/point trigger node reading a chosen gesture bus (all hands / left / right),
    /// with HOLD (linger) + SMOOTHING. Source is continuous while the gesture is recognised.
    private func gestureShapeNode(_ id: String, _ name: String, _ desc: String,
                                  _ source: @escaping @Sendable (ControlContext) -> SIMD4<Float>) {
        registerSpec(NodeSpec(
            id: id, name: name, family: .body,
            outputs: [PortSpec("palm", .trigger), PortSpec("fist", .trigger),
                      PortSpec("peace", .trigger), PortSpec("point", .trigger)],
            params: [.float("hold", 0...3, 0.25), .float("smoothing", 0...1, 0)],
            execution: .control, description: desc,
            controlEvalStateful: { node, _, ctx, state in
                let raw = source(ctx)
                let hold = node.float("hold", 0.25), sm = node.float("smoothing", 0)
                let atk: Float = sm > 0.001 ? (1 - sm * 0.97) : 1               // rise to the gesture
                let rel: Float = hold > 0.001 ? (1 - exp(-ctx.dt / hold)) : 1    // linger ~HOLD after it stops
                var s = state
                for i in 0..<4 { let t = raw[i]; s[i] += (t - s[i]) * (t > s[i] ? atk : rel) }
                state = s
                return [SIMD4(repeating: s.x), SIMD4(repeating: s.y),
                        SIMD4(repeating: s.z), SIMD4(repeating: s.w)]
            }))
    }

    /// Hand-pinch distance node (0 touching → wide) reading a chosen pinch bus (first / left / right),
    /// SHAPED via the shared vision params.
    private func handPinchNode(_ id: String, _ name: String, _ desc: String,
                               _ source: @escaping @Sendable (ControlContext) -> Float) {
        registerSpec(NodeSpec(
            id: id, name: name, family: .body,
            outputs: [PortSpec("distance", .signal)],
            params: Self.pinchParams, execution: .control, description: desc,
            controlEvalStateful: { node, _, ctx, state in
                var p = state.x
                let d = shapeVisionValue(source(ctx), node, ctx.dt, &p)
                state = SIMD4(p, 0, 0, 0)
                return [SIMD4(repeating: d)]
            }))
    }

    private static let shapeNames = ["sphere", "cube", "tube", "slab", "cone", "ring", "disc", "spike", "diamond"]

    /// Shared richer settings for continuous Vision nodes (Hand Position, Head Pose, Pinch, Openness).
    private static let visionParams: [ParamSpec] = [
        .float("gain", 0...4, 1), .float("inMin", 0...1, 0), .float("inMax", 0...1, 1),
        .float("outMin", 0...1, 0), .float("outMax", 0...1, 1),
        .float("deadzone", 0...0.5, 0), .float("smoothing", 0...1, 0), .bool("invert", false)]

    /// Pinch nodes: like visionParams but OUT scales to 10 — a full-spread pinch reads 10, not 1.
    /// (Driving an exposed 0-1 param? Lower outMax to 1 or add a Remap, else it saturates fast.)
    private static let pinchParams: [ParamSpec] = [
        .float("gain", 0...4, 1), .float("inMin", 0...1, 0), .float("inMax", 0...1, 1),
        .float("outMin", 0...10, 0), .float("outMax", 0...10, 10),
        .float("deadzone", 0...0.5, 0), .float("smoothing", 0...1, 0), .bool("invert", false)]

    // MARK: - SOURCE (rest)

    func registerFullCatalog() {
        registerTriggerNodes()   // §13 v2 — control-rate trigger-layer nodes (nested triggerGraph)
        registerVisualPack()     // 20 field-transform visual nodes (color / depth / shape)
        registerSpec(NodeSpec(
            id: "source", name: "Source", family: .source,
            outputs: [PortSpec("source", .source)],
            params: [.option("mode", ["auto", "trueDepth", "lidar", "media", "still"], "auto"),
                     .bool("mirror", true)],
            execution: .control,
            description: "The one live input: TrueDepth front, LiDAR back, an imported clip or a still. Auto picks the best available.",
            controlEval: { _, _, _ in [] }))

        registerSpec(NodeSpec(
            id: "clip-transport", name: "Video Source", family: .source,
            outputs: [PortSpec("depth", .fieldFloat)],
            params: [.float("near", 0.05...5, 0.1), .float("far", 0.2...8, 2.5), .bool("invert", false), .bool("loop", true)],
            execution: .interpreterOp,
            description: "An imported video's baked depth, per pin, playing on loop, remapped near→far — its presence takes over the depth feed — no wiring needed. Import a video to fill it.",
            emit: { b, _, node in
                let r = b.reg()
                b.emitPatched(PinInstruction(.loadDepth, dst: r,
                                             imm: [node.float("near", 0.1), node.float("far", 2.5), node.float("invert"), 0]),
                              key: "\(node.id).range", lanes: [0, 1, 2])
                b.addPatchKey("\(node.id).near", lane: 0)
                b.addPatchKey("\(node.id).far", lane: 1)
                b.addPatchKey("\(node.id).invert", lane: 2)
                return [r]
            }))

        registerSpec(NodeSpec(
            id: "live-depth", name: "Live Depth Model", family: .source,
            outputs: [PortSpec("depth", .fieldFloat), PortSpec("position", .fieldVec3),
                      PortSpec("z", .fieldFloat)],
            params: [.option("model", ["Metric Video DA S", "Depth Anything V2 S", "MoGe-2"], "Metric Video DA S"),
                     .option("lens", ["Wide", "Ultra-wide", "Tele", "Front"], "Wide"),
                     .float("near", 0.05...5, 0.1), .float("far", 0.2...8, 2.5), .bool("invert", false),
                     .option("mode", ["free", "metric"], "metric"),
                     .float("separation", 0...4, 2.5), .float("focus", 0.3...3, 1.0),
                     .float("gain", 0...3, 2.5),
                     .bool("media", false)],   // set by the node's video/image button — loops baked media instead of live camera
            execution: .interpreterOp,
            description: "Runs a monocular depth MODEL live on the camera → point cloud, for phones with no back LiDAR (or to try MoGe-2 / Depth Anything on the back lenses). Pick MODEL + LENS. POSITION + Z are the same free/metric cloud outputs as the Depth node — wire them (or depth) into the patch to take over the feed; an unwired node does nothing.",
            emit: { b, _, node in
                let r = b.reg()
                b.emitPatched(PinInstruction(.loadDepth, dst: r,
                                             imm: [node.float("near", 0.1), node.float("far", 2.5), node.float("invert"), 0]),
                              key: "\(node.id).range", lanes: [0, 1, 2])
                b.addPatchKey("\(node.id).near", lane: 0)
                b.addPatchKey("\(node.id).far", lane: 1)
                b.addPatchKey("\(node.id).invert", lane: 2)
                let (xy, z) = b.emitCloud(node, depthReg: r)
                return [r, xy, z]
            }))

        registerSpec(NodeSpec(
            id: "still-image", name: "Still Image", family: .source,
            outputs: [PortSpec("depth", .fieldFloat)],
            params: [.float("near", 0.05...5, 0.1), .float("far", 0.2...8, 2.5), .bool("invert", false)],
            execution: .interpreterOp,
            description: "An imported photo's baked depth, per pin, remapped near→far to 1→0 — its presence takes over the depth feed — no wiring needed. Import a photo to fill it.",
            emit: { b, _, node in
                let r = b.reg()
                b.emitPatched(PinInstruction(.loadDepth, dst: r,
                                             imm: [node.float("near", 0.1), node.float("far", 2.5), node.float("invert"), 0]),
                              key: "\(node.id).range", lanes: [0, 1, 2])
                b.addPatchKey("\(node.id).near", lane: 0)
                b.addPatchKey("\(node.id).far", lane: 1)
                b.addPatchKey("\(node.id).invert", lane: 2)
                return [r]
            }))

        registerSpec(NodeSpec(
            id: "confidence", name: "Confidence", family: .source,
            outputs: [PortSpec("confidence", .fieldFloat)],
            params: [.float("floor", 0...1, 0)],
            execution: .interpreterOp,
            description: "Per-pin sensor confidence 0-1 (noisy edges score low). · Reads 1.0 until the confidence texture is bound.",
            emit: { b, _, _ in [b.constant([1, 1, 1, 1])] }))

        registerSpec(NodeSpec(
            id: "proximity", name: "Proximity", family: .source,
            outputs: [PortSpec("nearness", .signal), PortSpec("entered", .trigger)],
            params: [.float("near", 0.15...2, 0.4), .float("far", 0.5...6, 2.5),
                     .float("threshold", 0...1, 0.5)],
            execution: .control,
            description: "How close the nearest subject is, live from the depth sensor: NEARNESS reads 0 at FAR metres → 1 at NEAR. ENTERED pulses once when nearness crosses THRESHOLD upward — someone stepping close fires it. Wire nearness → Size.base to swell as people approach; entered → Shockwave.fire.",
            controlEvalStateful: { node, _, ctx, state in
                var nearness: Float = 0
                if ctx.proximity.y > 0.5 {
                    let near = node.float("near", 0.4)
                    let far = max(node.float("far", 2.5), near + 0.01)
                    nearness = min(max((far - ctx.proximity.x) / (far - near), 0), 1)
                }
                let th = node.float("threshold", 0.5)
                let entered: Float = nearness >= th && state.x < th ? 1 : 0
                state.x = nearness
                return [SIMD4(repeating: nearness), SIMD4(repeating: entered)]
            }))

        // MARK: - GRID (rest)

        registerSpec(NodeSpec(
            id: "domain", name: "Domain", family: .grid,
            inputs: [PortSpec("morph", .signal)],
            outputs: [PortSpec("pins", .domain)],
            params: [.option("topologyA", ["rect", "hex", "radial", "spiral", "scatter", "perspective"], "rect"),
                     .option("topologyB", ["rect", "hex", "radial", "spiral", "scatter", "perspective"], "radial"),
                     .float("morphAmount", 0...1, 0)],
            execution: .render,
            description: "The pin lattice: rect · hex · radial (rings) · spiral (sunflower) · scatter · perspective. MORPH blends topology A → B per pin — wire an LFO or Hand Openness into morph and the whole lattice reflows live. Depth/color sampling follows each pin to its new home. Pin COUNT lives in the render settings.",
            emit: { b, inputs, _ in [b.materialize(inputs.first ?? -1, default: .zero)] }))

        registerSpec(NodeSpec(
            id: "jitter", name: "Jitter", family: .grid,
            inputs: [PortSpec("amount", .fieldFloat)],
            outputs: [PortSpec("offset", .fieldVec3)],
            params: [.float("amount", 0...0.3, 0.05), .float("seed", 0...9999, 1)],
            execution: .interpreterOp,
            description: "Nudges each pin's home by a seeded random offset — breaks machine-perfect regularity.",
            emit: { b, inputs, node in
                let dir = b.reg()
                b.emitPatched(PinInstruction(.hash3, dst: dir, imm: [node.float("seed", 1) + 500, 0, 0, 0]),
                              key: "\(node.id).seed", lanes: [0])
                let amt = inputs[0] >= 0 ? inputs[0]
                    : b.paramConstant("\(node.id).amount", SIMD4(repeating: node.float("amount", 0.05)))
                b.emit(PinInstruction(.mul, dst: dir, a: dir, b: amt))
                return [dir]
            }))

        registerSpec(NodeSpec(
            id: "region-rect", name: "Rect Region", family: .grid,
            inputs: [PortSpec("center", .vec2, default: [0, 0, 0, 0])],
            outputs: [PortSpec("mask", .fieldFloat)],
            params: [.float("width", 0.1...3, 1.5), .float("height", 0.1...4, 2),
                     .float("feather", 0.01...1, 0.2), .bool("invert", false)],
            execution: .interpreterOp,
            description: "Soft rectangular mask in view space: 1 inside, 0 outside.",
            emit: { b, _, node in
                let d = b.reg()
                b.emitPatched(PinInstruction(.rectMask, dst: d,
                                             imm: [0, 0, node.float("width", 1.5) / 2, node.float("height", 2) / 2]),
                              key: "\(node.id).rect", lanes: [0, 1, 2, 3])
                let m = b.reg()
                let f = max(node.float("feather", 0.2), 0.01)
                let inv = node.float("invert") > 0.5
                b.emitPatched(PinInstruction(.smooth, dst: m, a: d,
                                             imm: inv ? [1, 1 + f, 0, 0] : [1 + f, 1, 0, 0]),
                              key: "\(node.id).edge", lanes: [0, 1])
                return [m]
            }))

        registerSpec(NodeSpec(
            id: "uv-transform", name: "UV Transform", family: .grid,
            params: [.float("offsetX", -1...1, 0), .float("offsetY", -1...1, 0),
                     .float("scale", 0.25...4, 1), .float("rotate", -0.5...0.5, 0)],
            execution: .render,
            description: "Pans (OFFSET), zooms (SCALE) and ROTATEs the camera image under the pins without moving them — the cloud stays put while the world slides through it. Just add the node; expose OFFSETX and wire an LFO for a slow drift."))
        registerSpec(NodeSpec(
            id: "edge-policy", name: "Edge Policy", family: .grid,
            params: [.option("mode", ["none", "fade", "clamp"], "fade"),
                     .float("margin", 0...0.3, 0.05)],
            execution: .render,
            description: "What happens when warps (Scatter, Twist, Orbit…) push pins past the frame border: FADE shrinks them away across MARGIN, CLAMP piles them up at the edge, NONE lets them fly out. Just add the node."))

        // MARK: - SHAPE (REAL geometry — feed Output.shape / .rotation / .stretch)

        registerSpec(NodeSpec(
            id: "shape", name: "Shape", family: .shape,
            outputs: [PortSpec("shape", .fieldFloat)],
            params: [.option("type", Self.shapeNames, "sphere")],
            execution: .interpreterOp,
            description: "Pin cap shape — sphere · cube · tube · slab · cone · ring · disc · spike · diamond. Wire shape → Output.shape and every pin takes that form (add Spin or Rotation to see the 3D silhouette move).",
            emit: { b, _, node in
                let idx = Self.shapeNames.firstIndex(of: node.option("type", "sphere")) ?? 0
                // pack targetIndex + morph(0.999 = full); sphere is the base → 0 (no morph)
                let v: Float = idx == 0 ? 0.0 : Float(idx) + 0.999
                return [b.constant(SIMD4<Float>(v, 0, 0, 0))]
            }))
        registerSpec(NodeSpec(
            id: "shape-morph", name: "Shape Morph", family: .shape,
            inputs: [PortSpec("blend", .fieldFloat)],
            outputs: [PortSpec("shape", .fieldFloat)],
            params: [.option("target", Self.shapeNames.filter { $0 != "sphere" }, "cube"),
                     .float("blend", 0...1, 0)],
            execution: .interpreterOp,
            description: "Morph the sphere TOWARD any target (cube/tube/cone…) by BLEND 0-1. Drive BLEND with audio/depth/gesture, or wire → Output.shape.",
            emit: { b, inputs, node in
                let ti = Self.shapeNames.firstIndex(of: node.option("target", "cube")) ?? 1
                if inputs[0] >= 0 {   // value = clamp(blendField,0,1)*0.999 + targetIndex
                    let r = b.reg()
                    b.emit(PinInstruction(.clampOp, dst: r, a: inputs[0], imm: [0, 1, 0, 0]))
                    b.emit(PinInstruction(.madd, dst: r, a: r, imm: [0.999, Float(ti), 0, 0]))
                    return [r]
                }
                let blend = min(node.float("blend", 0), 0.999)
                return [b.constant(SIMD4<Float>(Float(ti) + blend, 0, 0, 0))]
            }))
        registerSpec(NodeSpec(
            id: "noise", name: "Noise", family: .signal,
            inputs: [PortSpec("z", .fieldFloat)],
            outputs: [PortSpec("out", .fieldFloat), PortSpec("color", .fieldColor)],
            params: [.option("type", ["perlin", "simplex", "random", "sparse", "hermite", "harmonic"], "perlin"),
                     .option("map", ["mono"] + PaletteLUT.names, "mono"),
                     .float("seed", 0...9999, 1),
                     .float("period", 0.02...4, 0.5),
                     .float("harmonics", 1...6, 3),
                     .float("harmonicSpread", 1...4, 2),
                     .float("harmonicGain", 0...1, 0.5),
                     .float("roughness", 0...1, 0.5),
                     .float("exponent", 0.25...4, 1),
                     .float("amplitude", 0...4, 1),
                     .float("offset", -2...2, 0),
                     .option("moveAxis", ["x", "y", "z"], "z"),
                     .float("moveRate", -4...4, 0.3),
                     .option("timeScale", ["ms", "s", "min"], "s"),
                     .bool("moveNeg", false),
                     .bool("aspectCorrect", true)],
            execution: .interpreterOp,
            description: "Animated 3D noise field, per pin (TouchDesigner-style). TYPE perlin/simplex/random/sparse/hermite/harmonic · PERIOD = feature size · HARMONICS/SPREAD/GAIN/ROUGHNESS build fractal detail · EXPONENT/AMPLITUDE/OFFSET shape the output. MOVE it along X/Y/Z off time (Z morphs the field through a hidden plane, like it's breathing). Wire OUT → Displace / Size / Output.z; wire COLOR → Output.color and pick a MAP for colored noise (mono = greyscale). Optional Z input drives the sample plane from a Time/other field.",
            emit: { b, inputs, node in
                let types = ["perlin", "simplex", "random", "sparse", "hermite", "harmonic"]
                let ty = types.firstIndex(of: node.option("type", "perlin")) ?? 0
                let axisI = ["x", "y", "z"].firstIndex(of: node.option("moveAxis", "z")) ?? 2
                let aspect = node.float("aspectCorrect", 1) > 0.5 ? 1 : 0
                let packed = Float(ty + axisI * 10 + aspect * 100)
                let baseFreq = 1.0 / max(node.float("period", 0.5), 0.02)
                let tScale: Float = node.option("timeScale", "s") == "ms" ? 0.001
                                  : node.option("timeScale", "s") == "min" ? 60 : 1
                let move = node.float("moveRate", 0.3) * (node.float("moveNeg") > 0.5 ? -1 : 1) / max(tScale, 1e-4)
                let octs = max(1, min(Int(node.float("harmonics", 3)), 6))
                let gain0 = node.float("harmonicGain", 0.5)
                let persistence = gain0 + (1 - gain0) * node.float("roughness", 0.5)   // roughness → more high-freq energy
                let zreg = inputs[0] >= 0 ? inputs[0] : b.constant(.zero)
                let acc = b.reg(); let sc = b.reg(); let tmp = b.reg()
                var f = baseFreq; var g: Float = 1
                for i in 0..<octs {
                    b.emit(PinInstruction(.noise3, dst: sc, a: zreg,
                                          imm: [f, node.float("seed", 1) + Float(i) * 19, packed, move]))
                    if i == 0 {
                        b.emit(PinInstruction(.madd, dst: acc, a: sc, imm: [g, 0, 0, 0]))
                    } else {
                        b.emit(PinInstruction(.madd, dst: tmp, a: sc, imm: [g, 0, 0, 0]))
                        b.emit(PinInstruction(.add, dst: acc, a: acc, b: tmp))
                    }
                    f *= max(node.float("harmonicSpread", 2), 1)
                    g *= persistence
                }
                b.emit(PinInstruction(.madd, dst: acc, a: acc, imm: [0.5, 0.5, 0, 0]))   // [-1,1] → [0,1]
                let ex = node.float("exponent", 1)
                if abs(ex - 1) > 1e-4 { b.emit(PinInstruction(.powOp, dst: acc, a: acc, imm: [ex, 0, 0, 0])) }
                b.emit(PinInstruction(.madd, dst: acc, a: acc,
                                      imm: [node.float("amplitude", 1), node.float("offset", 0), 0, 0]))
                // COLOR output: the field through a palette row (MAP), or greyscale when MAP = mono.
                let mapName = node.option("map", "mono")
                var col = acc
                if mapName != "mono" {
                    let row = Float(PaletteLUT.names.firstIndex(of: mapName) ?? 0)
                    let c = b.reg()
                    b.emitPatched(PinInstruction(.palette, dst: c, a: acc, imm: [0, row, 0, 0]),
                                  key: "\(node.id).map", lanes: [1])
                    col = c
                }
                return [acc, col]
            }))
        registerSpec(NodeSpec(
            id: "stretch", name: "Stretch", family: .shape,
            outputs: [PortSpec("scale", .fieldVec3)],
            params: [.float("x", 0.1...4, 1), .float("y", 0.1...4, 1), .float("z", 0.1...4, 1)],
            execution: .interpreterOp,
            description: "Per-axis pin scale — tubes, needles, slabs. Wire → Output.stretch.",
            emit: { b, _, node in
                [b.paramConstant("\(node.id).stretch",
                                 SIMD4<Float>(node.float("x", 1), node.float("y", 1), node.float("z", 1), 0))]
            }))
        registerSpec(NodeSpec(
            id: "rotation", name: "Rotation", family: .shape,
            inputs: [PortSpec("turns", .fieldVec3)],
            outputs: [PortSpec("rot", .fieldVec3)],
            params: [.float("x", -0.5...0.5, 0), .float("y", -0.5...0.5, 0), .float("z", -0.5...0.5, 0)],
            execution: .interpreterOp,
            description: "Static per-pin orientation in turns. Wire → Output.rotation. (Use a non-sphere Shape to see it.)",
            emit: { b, inputs, node in
                let c = b.paramConstant("\(node.id).rot",
                                        SIMD4<Float>(node.float("x", 0), node.float("y", 0), node.float("z", 0), 0))
                if inputs[0] >= 0 { let r = b.reg(); b.emit(PinInstruction(.add, dst: r, a: c, b: inputs[0])); return [r] }
                return [c]
            }))
        registerSpec(NodeSpec(
            id: "spin", name: "Spin", family: .shape,
            outputs: [PortSpec("rot", .fieldVec3)],
            params: [.float("x", -2...2, 0), .float("y", -2...2, 0), .float("z", -2...2, 0.25)],
            execution: .interpreterOp,
            description: "Continuous spin (turns/sec per axis) from the clock. Wire → Output.rotation.",
            emit: { b, _, node in
                let r = b.reg()
                b.emit(PinInstruction(.spinTurns, dst: r,
                                      imm: SIMD4<Float>(node.float("x", 0), node.float("y", 0), node.float("z", 0.25), 0)))
                return [r]
            }))
        // Look At / Stem / Material are render-read sinks like Camera and Light: no wires,
        // the renderer reads the first node of each per frame.
        registerSpec(NodeSpec(
            id: "look-at", name: "Look At", family: .shape,
            params: [.float("x", -2...2, 0), .float("y", -2...2, 0), .float("z", 0...4, 2),
                     .float("amount", 0...1, 1)],
            execution: .render,
            description: "Orients every pin to face the X/Y/Z point — iron-filings tracking. Needs a non-sphere Shape (cube, slab, spike…) to be visible; AMOUNT blends the effect in. Expose X/Y and wire Hand Position to have the whole cloud track your hand."))
        registerSpec(NodeSpec(
            id: "stem", name: "Stem", family: .shape,
            params: [.option("profile", ["square", "round", "blade"], "square"),
                     .float("thickness", 0...1, 0.3), .float("taper", 0...1, 0.2)],
            execution: .render,
            description: "Styles the arms from the Z-wall to each cap (turn ARMS on in the Depth node to see them): PROFILE square/round/blade, THICKNESS scales their width, TAPER narrows them toward the cap. Just add the node."))
        registerSpec(NodeSpec(
            id: "material", name: "Material", family: .shape,
            params: [.option("shading", ["unlit", "lit", "matcap"], "lit"),
                     .float("roughness", 0...1, 0.5), .float("metallic", 0...1, 0)],
            execution: .render,
            description: "How pins are shaded: UNLIT = flat poster color, LIT = shaded by the Light nodes (or the default light) with ROUGHNESS/METALLIC speculars, MATCAP = a fixed studio look. Low ROUGHNESS = glossy highlights; METALLIC tints them with the pin's own color."))

        registerSpec(NodeSpec(
            id: "hide", name: "Hide", family: .shape,
            inputs: [PortSpec("mask", .fieldFloat, default: [1, 1, 1, 1])],
            outputs: [PortSpec("size", .fieldFloat)],
            params: [.option("mode", ["fade", "cutoff"], "fade"),
                     .float("threshold", 0...1, 0.5), .bool("invert", false)],
            execution: .interpreterOp,
            description: "Shows/hides pins by a mask: smooth fade or hard cutoff. Wire its output into Size.",
            emit: { b, inputs, node in
                var m = b.materialize(inputs[0], default: [1, 1, 1, 1])
                if node.float("invert") > 0.5 {
                    let inv = b.reg()
                    b.emit(PinInstruction(.madd, dst: inv, a: m, imm: [-1, 1, 0, 0]))
                    m = inv
                }
                if node.option("mode", "fade") == "cutoff" {
                    let c = b.reg()
                    b.emitPatched(PinInstruction(.stepOp, dst: c, a: m,
                                                 imm: [node.float("threshold", 0.5), 0, 0, 0]),
                                  key: "\(node.id).th", lanes: [0])
                    return [c]
                }
                return [m]
            }))

        // MARK: - MOVE (rest)

        registerSpec(NodeSpec(
            id: "displace", name: "Displace", family: .move,
            inputs: [PortSpec("offset", .fieldVec3)],
            outputs: [PortSpec("out", .fieldVec3)],
            params: [.float("amount", 0...4, 1)],
            execution: .interpreterOp,
            description: "Scales any vec3 field — the universal motion amount knob.",
            emit: { b, inputs, node in
                let x = b.materialize(inputs[0], default: .zero)
                let r = b.reg()
                b.emitPatched(PinInstruction(.madd, dst: r, a: x, imm: [node.float("amount", 1), 0, 0, 0]),
                              key: "\(node.id).amount", lanes: [0])
                return [r]
            }))

        registerSpec(NodeSpec(
            id: "velocity", name: "Velocity", family: .move,
            inputs: [PortSpec("in", .fieldFloat)],
            outputs: [PortSpec("speed", .fieldFloat)],
            params: [.float("gain", 0.1...40, 8)],
            statePerPin: 1, execution: .interpreterOp,
            description: "How fast a per-pin field is changing — movers light up, still areas read zero.",
            emit: { b, inputs, node in
                let x = b.materialize(inputs[0], default: .zero)
                let slot = b.allocState(1)
                let prev = b.reg(), d = b.reg()
                b.emit(PinInstruction(.loadState, dst: prev, imm: [Float(slot), 0, 0, 0]))
                b.emit(PinInstruction(.sub, dst: d, a: x, b: prev))
                b.emit(PinInstruction(.absOp, dst: d, a: d))
                b.emitPatched(PinInstruction(.madd, dst: d, a: d, imm: [node.float("gain", 8), 0, 0, 0]),
                              key: "\(node.id).gain", lanes: [0])
                b.emit(PinInstruction(.clampOp, dst: d, a: d, imm: [0, 1, 0, 0]))
                b.emit(PinInstruction(.storeState, a: x, imm: [Float(slot), 0, 0, 0]))
                return [d]
            }))

        registerSpec(NodeSpec(
            id: "echo", name: "Echo", family: .move,
            inputs: [PortSpec("in", .fieldFloat)],
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("delay", 0.05...2, 0.25), .float("feedback", 0...0.9, 0.3)],
            statePerPin: 2, execution: .interpreterOp,
            description: "A soft delayed copy with feedback — ghosts chasing the live motion.",
            emit: { b, inputs, node in
                let x = b.materialize(inputs[0], default: .zero)
                let s1Slot = b.allocState(1), s2Slot = b.allocState(1)
                let s1 = b.reg(), s2 = b.reg(), fed = b.reg()
                b.emit(PinInstruction(.loadState, dst: s1, imm: [Float(s1Slot), 0, 0, 0]))
                b.emit(PinInstruction(.loadState, dst: s2, imm: [Float(s2Slot), 0, 0, 0]))
                // input + feedback·out
                b.emitPatched(PinInstruction(.madd, dst: fed, a: s2, imm: [node.float("feedback", 0.3), 0, 0, 0]),
                              key: "\(node.id).fb", lanes: [0])
                b.emit(PinInstruction(.add, dst: fed, a: fed, b: x))
                // two cascaded smoothers; alpha patched per frame from delay
                b.emitPatched(PinInstruction(.mix, dst: s1, a: s1, b: fed, imm: [0.2, 0, 0, 0]),
                              key: "\(node.id).alpha", lanes: [0])
                b.emitPatched(PinInstruction(.mix, dst: s2, a: s2, b: s1, imm: [0.2, 0, 0, 0]),
                              key: "\(node.id).alpha2", lanes: [0])
                b.emit(PinInstruction(.storeState, a: s1, imm: [Float(s1Slot), 0, 0, 0]))
                b.emit(PinInstruction(.storeState, a: s2, imm: [Float(s2Slot), 0, 0, 0]))
                return [s2]
            }))

        registerSpec(NodeSpec(
            id: "wave", name: "Wave", family: .move,
            outputs: [PortSpec("height", .fieldFloat)],
            params: [.option("axis", ["x", "y", "diagonal"], "x"),
                     .float("frequency", 0.5...20, 4), .float("speed", -4...4, 1),
                     .float("amount", 0...1, 0.5)],
            execution: .interpreterOp,
            description: "A traveling sine sheet across the wall — the classic flag/water move.",
            emit: { b, _, node in
                let uv = b.reg(); b.emit(PinInstruction(.loadUV, dst: uv))
                let axis = node.option("axis", "x")
                let maskV: SIMD4<Float> = axis == "y" ? [0, 1, 0, 0]
                    : (axis == "diagonal" ? [0.5, 0.5, 0, 0] : [1, 0, 0, 0])
                let mask = b.constant(maskV)
                let t = b.reg()
                b.emit(PinInstruction(.mul, dst: t, a: uv, b: mask))
                let s = b.reg()
                b.emit(PinInstruction(.len, dst: s, a: t))   // masked lanes → scalar
                let w = b.reg()
                b.emitPatched(PinInstruction(.sinOp, dst: w, a: s,
                                             imm: [node.float("frequency", 4) * 6.283, 0,
                                                   0.5 * node.float("amount", 0.5), 0.5 * node.float("amount", 0.5)]),
                              key: "\(node.id).wave", lanes: [0, 1, 2, 3])
                return [w]
            }))

        // MARK: - COLOR (rest)

        registerSpec(NodeSpec(
            id: "pin-color", name: "Pin Color", family: .color,
            inputs: [PortSpec("color", .fieldColor, default: [0.78, 0.78, 0.78, 1])],
            outputs: [PortSpec("color", .fieldColor)],
            execution: .interpreterOp,
            description: "A pin color field — passes a color through (default soft grey); wire into Output.color.",
            emit: { b, inputs, _ in
                [b.materialize(inputs[0], default: [0.78, 0.78, 0.78, 1])]   // reachable color source (was an unconsumed .domain sink)
            }))

        registerSpec(NodeSpec(
            id: "tint", name: "Tint", family: .color,
            inputs: [PortSpec("color", .fieldColor, default: [1, 1, 1, 1])],
            outputs: [PortSpec("out", .fieldColor)],
            params: [.float("r", 0...2, 1), .float("g", 0...2, 1), .float("b", 0...2, 1)],
            execution: .interpreterOp,
            description: "Multiplies a color field by an RGB gain.",
            emit: { b, inputs, node in
                let c = b.materialize(inputs[0], default: [1, 1, 1, 1])
                let t = b.paramConstant("\(node.id).rgb",
                                        [node.float("r", 1), node.float("g", 1), node.float("b", 1), 1])
                let r = b.reg()
                b.emit(PinInstruction(.mul, dst: r, a: c, b: t))
                return [r]
            }))

        registerSpec(NodeSpec(
            id: "depth-gradient", name: "Depth Gradient", family: .color,
            inputs: [PortSpec("t", .fieldFloat, default: [0.5, 0.5, 0.5, 0.5])],
            outputs: [PortSpec("color", .fieldColor)],
            params: [.float("nearR", 0...1, 1), .float("nearG", 0...1, 0.9), .float("nearB", 0...1, 0.6),
                     .float("farR", 0...1, 0.05), .float("farG", 0...1, 0.1), .float("farB", 0...1, 0.3)],
            execution: .interpreterOp,
            description: "Two-color gradient by any 0-1 field — the hand-picked alternative to Palette.",
            emit: { b, inputs, node in
                let t = b.materialize(inputs[0], default: [0.5, 0.5, 0.5, 0.5])
                let far = b.paramConstant("\(node.id).far",
                                          [node.float("farR", 0.05), node.float("farG", 0.1), node.float("farB", 0.3), 1])
                let near = b.paramConstant("\(node.id).near",
                                           [node.float("nearR", 1), node.float("nearG", 0.9), node.float("nearB", 0.6), 1])
                let r = b.reg()
                b.emit(PinInstruction(.mixv, dst: r, a: far, b: near, imm: [0, 0, 0, Float(t)]))
                return [r]
            }))

        registerSpec(NodeSpec(
            id: "hsv-shift", name: "Hue Shift", family: .color,
            inputs: [PortSpec("color", .fieldColor, default: [1, 1, 1, 1])],
            outputs: [PortSpec("out", .fieldColor)],
            params: [.float("shift", -0.5...0.5, 0)],
            execution: .interpreterOp,
            description: "Rotates the hue of any color field (turns).",
            emit: { b, inputs, node in
                let c = b.materialize(inputs[0], default: [1, 1, 1, 1])
                let r = b.reg()
                b.emitPatched(PinInstruction(.hueShift, dst: r, a: c, imm: [node.float("shift"), 0, 0, 0]),
                              key: "\(node.id).shift", lanes: [0])
                return [r]
            }))

        registerSpec(NodeSpec(
            id: "velocity-color", name: "Velocity Color", family: .color,
            inputs: [PortSpec("speed", .fieldFloat)],
            outputs: [PortSpec("color", .fieldColor)],
            params: [.option("map", PaletteLUT.names, "fire")],
            execution: .interpreterOp,
            description: "Movers burn through a colormap; still pins stay at its cold end.",
            emit: { b, inputs, node in
                let s = b.materialize(inputs[0], default: .zero)
                let r = b.reg()
                let row = Float(PaletteLUT.names.firstIndex(of: node.option("map", "fire")) ?? 2)
                b.emitPatched(PinInstruction(.palette, dst: r, a: s, imm: [0, row, 0, 0]),
                              key: "\(node.id).map", lanes: [1])
                return [r]
            }))

        registerSpec(NodeSpec(
            id: "color-mix", name: "Color Mix", family: .color,
            inputs: [PortSpec("a", .fieldColor, default: [0, 0, 0, 1]),
                     PortSpec("b", .fieldColor, default: [1, 1, 1, 1]),
                     PortSpec("t", .fieldFloat, default: [0.5, 0.5, 0.5, 0.5])],
            outputs: [PortSpec("out", .fieldColor)],
            execution: .interpreterOp,
            description: "Crossfades two color fields by a third field.",
            emit: { b, inputs, _ in
                let a = b.materialize(inputs[0], default: [0, 0, 0, 1])
                let c = b.materialize(inputs[1], default: [1, 1, 1, 1])
                let t = b.materialize(inputs[2], default: [0.5, 0.5, 0.5, 0.5])
                let r = b.reg()
                b.emit(PinInstruction(.mixv, dst: r, a: a, b: c, imm: [0, 0, 0, Float(t)]))
                return [r]
            }))

        registerSpec(NodeSpec(
            id: "posterize", name: "Posterize", family: .color,
            inputs: [PortSpec("in", .fieldColor, default: [1, 1, 1, 1])],
            outputs: [PortSpec("out", .fieldColor)],
            params: [.float("levels", 2...12, 4)],
            execution: .interpreterOp,
            description: "Quantizes color into hard bands — print-poster look.",
            emit: { b, inputs, node in
                let c = b.materialize(inputs[0], default: [1, 1, 1, 1])
                let n = max(node.float("levels", 4), 2)
                let scaled = b.reg(), frac = b.reg()
                b.emitPatched(PinInstruction(.madd, dst: scaled, a: c, imm: [n, 0, 0, 0]),
                              key: "\(node.id).n", lanes: [0])
                b.emit(PinInstruction(.fractOp, dst: frac, a: scaled))
                b.emit(PinInstruction(.sub, dst: scaled, a: scaled, b: frac))   // floor
                let r = b.reg()
                b.emitPatched(PinInstruction(.madd, dst: r, a: scaled, imm: [1 / n, 0, 0, 0]),
                              key: "\(node.id).inv", lanes: [0])
                return [r]
            }))

        registerSpec(NodeSpec(
            id: "strobe-color", name: "Strobe Color", family: .color,
            inputs: [PortSpec("color", .fieldColor, default: [0.78, 0.78, 0.78, 1]),
                     PortSpec("flash", .signal)],
            outputs: [PortSpec("out", .fieldColor)],
            execution: .interpreterOp,
            description: "Flashes a color field to white when the flash signal is up — wire a beat in.",
            emit: { b, inputs, _ in
                let c = b.materialize(inputs[0], default: [0.78, 0.78, 0.78, 1])
                let f = b.materialize(inputs[1], default: .zero)
                let white = b.constant([1, 1, 1, 1])
                let r = b.reg()
                b.emit(PinInstruction(.mixv, dst: r, a: c, b: white, imm: [0, 0, 0, Float(f)]))
                return [r]
            }))

        registerSpec(NodeSpec(
            id: "brightness", name: "Brightness", family: .color,
            inputs: [PortSpec("color", .fieldColor, default: [1, 1, 1, 1])],
            outputs: [PortSpec("out", .fieldColor)],
            params: [.float("gain", 0...3, 1), .float("lift", -0.5...0.5, 0)],
            execution: .interpreterOp,
            description: "Gain + lift on any color field.",
            emit: { b, inputs, node in
                let c = b.materialize(inputs[0], default: [1, 1, 1, 1])
                let r = b.reg()
                b.emitPatched(PinInstruction(.madd, dst: r, a: c,
                                             imm: [node.float("gain", 1), node.float("lift"), 0, 0]),
                              key: "\(node.id).gl", lanes: [0, 1])
                return [r]
            }))

        // MARK: - SIGNAL math (rest) — field-rate, all real

        unary("power", "Power", desc: "in^exponent.", params: [.float("exponent", 0.1...8, 2)]) { b, x, node in
            let r = b.reg()
            b.emitPatched(PinInstruction(.powOp, dst: r, a: x, imm: [node.float("exponent", 2), 0, 0, 0]),
                          key: "\(node.id).exp", lanes: [0])
            return r
        }

        unary("negate", "Negate", desc: "−in.", params: []) { b, x, _ in
            let r = b.reg(); b.emit(PinInstruction(.madd, dst: r, a: x, imm: [-1, 0, 0, 0])); return r
        }

        unary("one-minus", "One Minus", desc: "1 − in: flips any 0-1 field.", params: []) { b, x, _ in
            let r = b.reg(); b.emit(PinInstruction(.madd, dst: r, a: x, imm: [-1, 1, 0, 0])); return r
        }

        unary("quantize", "Quantize", desc: "Snaps a field to N steps — terraced relief.",
              params: [.float("steps", 2...32, 6)]) { b, x, node in
            let n = max(node.float("steps", 6), 2)
            let s = b.reg(), f = b.reg(), r = b.reg()
            b.emitPatched(PinInstruction(.madd, dst: s, a: x, imm: [n, 0, 0, 0]), key: "\(node.id).n", lanes: [0])
            b.emit(PinInstruction(.fractOp, dst: f, a: s))
            b.emit(PinInstruction(.sub, dst: s, a: s, b: f))
            b.emitPatched(PinInstruction(.madd, dst: r, a: s, imm: [1 / n, 0, 0, 0]), key: "\(node.id).inv", lanes: [0])
            return r
        }

        unary("fract", "Fract", desc: "Fractional part — sawtooth wrapping.", params: []) { b, x, _ in
            let r = b.reg(); b.emit(PinInstruction(.fractOp, dst: r, a: x)); return r
        }

        unary("sqrt", "Square Root", desc: "√in — eases hot field tips.", params: []) { b, x, _ in
            let r = b.reg(); b.emit(PinInstruction(.sqrtOp, dst: r, a: x)); return r
        }

        registerSpec(NodeSpec(
            id: "compare", name: "Compare", family: .signal,
            inputs: [PortSpec("a", .fieldFloat), PortSpec("b", .fieldFloat)],
            outputs: [PortSpec("aGreater", .fieldFloat)],
            execution: .interpreterOp,
            description: "1 where a ≥ b, else 0 — per-pin comparison for building masks.",
            emit: { b, inputs, _ in
                let x = b.materialize(inputs[0], default: .zero)
                let y = b.materialize(inputs[1], default: .zero)
                let d = b.reg(), r = b.reg()
                b.emit(PinInstruction(.sub, dst: d, a: x, b: y))
                b.emit(PinInstruction(.stepOp, dst: r, a: d, imm: [0, 0, 0, 0]))
                return [r]
            }))

        registerSpec(NodeSpec(
            id: "switch", name: "Switch", family: .signal,
            inputs: [PortSpec("a", .fieldFloat), PortSpec("b", .fieldFloat),
                     PortSpec("pick", .signal)],
            outputs: [PortSpec("out", .fieldFloat)],
            execution: .interpreterOp,
            description: "Outputs a when pick < 0.5, b otherwise — hard switching for beat jumps.",
            emit: { b, inputs, _ in
                let x = b.materialize(inputs[0], default: .zero)
                let y = b.materialize(inputs[1], default: .zero)
                let p = b.materialize(inputs[2], default: .zero)
                let g = b.reg(), r = b.reg()
                b.emit(PinInstruction(.stepOp, dst: g, a: p, imm: [0.5, 0, 0, 0]))
                b.emit(PinInstruction(.mixv, dst: r, a: x, b: y, imm: [0, 0, 0, Float(g)]))
                return [r]
            }))

        // MARK: - SIGNAL modulate (stateful control — real)

        registerSpec(NodeSpec(
            id: "envelope", name: "Envelope", family: .signal,
            inputs: [PortSpec("trigger", .trigger)],
            outputs: [PortSpec("out", .signal)],
            params: [.float("attack", 0.005...2, 0.02), .float("release", 0.02...5, 0.5)],
            execution: .control,
            description: "Attack/release shaper: a 10ms drum hit becomes a visible swell and fall.",
            controlEvalStateful: { node, inputs, ctx, state in
                // state.x = value, state.y = rising flag
                let trig = (inputs.first?.x ?? 0) > 0.5
                if trig { state.y = 1 }
                if state.y > 0.5 {
                    state.x += ctx.dt / max(node.float("attack", 0.02), 0.005)
                    if state.x >= 1 { state.x = 1; state.y = 0 }
                } else {
                    state.x -= ctx.dt / max(node.float("release", 0.5), 0.02)
                    state.x = max(state.x, 0)
                }
                return [SIMD4(repeating: state.x)]
            }))

        registerSpec(NodeSpec(
            id: "wander", name: "Wander", family: .signal,
            outputs: [PortSpec("out", .signal)],
            params: [.float("speed", 0.05...4, 0.5), .float("range", 0...1, 1)],
            execution: .control,
            description: "A smooth random walk — organic drift for anything.",
            controlEvalStateful: { node, _, ctx, state in
                // state.x = value, state.y = velocity, state.z = time to next kick
                state.z -= ctx.dt
                if state.z <= 0 {
                    state.z = 0.3 / max(node.float("speed", 0.5), 0.05)
                    state.y = Float.random(in: -1...1) * node.float("speed", 0.5)
                }
                state.x += state.y * ctx.dt
                let range = node.float("range", 1)
                state.x = min(max(state.x, 0.5 - range / 2), 0.5 + range / 2)
                return [SIMD4(repeating: state.x)]
            }))

        registerSpec(NodeSpec(
            id: "sample-hold", name: "Sample & Hold", family: .signal,
            inputs: [PortSpec("in", .signal), PortSpec("trigger", .trigger)],
            outputs: [PortSpec("out", .signal)],
            execution: .control,
            description: "Freezes the input value each time the trigger fires — stepped randomness from smooth sources. Wire Wander.out → in and Clock.quarter → trigger for beat-locked jumps.",
            controlEvalStateful: { _, inputs, _, state in
                // Edge-triggered: sample once per rising edge (a held-high trigger must not track).
                let trig = (inputs.count > 1 ? inputs[1].x : 0) > 0.5
                if (trig && state.y < 0.5) || state.w < 0.5 { state.x = inputs.first?.x ?? 0; state.w = 1 }
                state.y = trig ? 1 : 0
                return [SIMD4(repeating: state.x)]
            }))

        registerSpec(NodeSpec(
            id: "chance", name: "Chance", family: .signal,
            inputs: [PortSpec("trigger", .trigger)],
            outputs: [PortSpec("out", .trigger)],
            params: [.float("probability", 0...1, 0.5)],
            execution: .control,
            description: "Passes each trigger with a probability — controlled unpredictability.",
            controlEvalStateful: { node, inputs, _, state in
                let trig = (inputs.first?.x ?? 0) > 0.5
                var fire: Float = 0
                if trig && state.x < 0.5 {   // rising edge
                    fire = Float.random(in: 0...1) < node.float("probability", 0.5) ? 1 : 0
                }
                state.x = trig ? 1 : 0
                return [SIMD4(repeating: fire)]
            }))

        registerSpec(NodeSpec(
            id: "slew", name: "Slew", family: .signal,
            inputs: [PortSpec("in", .signal)],
            outputs: [PortSpec("out", .signal)],
            params: [.float("up", 0.01...5, 0.1), .float("down", 0.01...5, 0.4)],
            execution: .control,
            description: "Limits how fast a control signal can rise and fall — de-zippers anything.",
            controlEvalStateful: { node, inputs, ctx, state in
                let target = inputs.first?.x ?? 0
                let rate = target > state.x ? ctx.dt / max(node.float("up", 0.1), 0.01)
                                            : ctx.dt / max(node.float("down", 0.4), 0.01)
                state.x += min(max(target - state.x, -rate), rate)
                return [SIMD4(repeating: state.x)]
            }))

        // MARK: - SIGNAL audio / MIDI / OSC (bus stubs — engines land next)

        stubControl("audio-levels", "Audio Levels", .signal,
                    [PortSpec("bass", .signal), PortSpec("mid", .signal),
                     PortSpec("high", .signal), PortSpec("rms", .signal)],
                    "LIVE mic band energies 0-1 (auto-gain keeps them usable at any volume). Wire bass → Size.size and the cloud breathes with the music.") { ctx in
            [SIMD4(repeating: ctx.audio.x), SIMD4(repeating: ctx.audio.y),
             SIMD4(repeating: ctx.audio.z), SIMD4(repeating: ctx.audio.w)]
        }
        stubControl("beat-trigger", "Beat Trigger", .signal,
                    [PortSpec("low", .trigger), PortSpec("mid", .trigger), PortSpec("high", .trigger)],
                    "LIVE drum onsets from the mic as trigger pulses (low = kick, mid = snare, high = hats). Wire low → Envelope.trigger or Shockwave.fire.") { ctx in
            [SIMD4(repeating: ctx.onsets.x), SIMD4(repeating: ctx.onsets.y), SIMD4(repeating: ctx.onsets.z)]
        }
        registerSpec(NodeSpec(
            id: "fft-band", name: "FFT Band", family: .signal,
            outputs: [PortSpec("level", .signal)],
            params: [.float("band", 1...20, 4)],
            execution: .control,
            description: "One of 20 log-spaced mic spectrum bands, auto-gained 0-1: BAND 1 ≈ 40 Hz sub-bass → 20 ≈ 8 kHz sparkle. One node per band isolates an instrument — level → Size.size follows just the bassline.",
            controlEval: { node, _, ctx in
                let i = min(max(Int(node.float("band", 4)) - 1, 0), 19)
                return [SIMD4(repeating: i < ctx.fftBands.count ? ctx.fftBands[i] : 0)]
            }))
        stubControl("audio-rms", "Mic Level", .signal, [PortSpec("rms", .signal)],
                    "LIVE overall mic loudness 0-1 (same auto-gained level as Audio Levels.rms).") { ctx in
            [SIMD4(repeating: ctx.audio.w)]
        }
        stubControl("burst", "Burst", .signal, [PortSpec("burst", .signal)],
                    "LIVE sudden-loudness pulse from the mic — spikes on hits and drops. Wire burst → Scatter.amount for sound-shattered pins.") { ctx in
            [SIMD4(repeating: ctx.onsets.w)]
        }
        stubControl("midi-cc", "MIDI CC", .signal, [PortSpec("value", .signal)],
                    "A MIDI control-change knob, 0-1 (last CC received). · Live: CoreMIDI + RTP network.") { ctx in
            [SIMD4(repeating: ctx.midi.x)]
        }
        stubControl("midi-note", "MIDI Note", .signal,
                    [PortSpec("gate", .signal), PortSpec("velocity", .signal)],
                    "Note gate (1 while held) + velocity 0-1. · Live: CoreMIDI + RTP network.") { ctx in
            [SIMD4(repeating: ctx.midi.y), SIMD4(repeating: ctx.midi.z)]
        }
        registerSpec(NodeSpec(
            id: "osc-in", name: "OSC In", family: .signal,
            outputs: [PortSpec("value", .signal)],
            params: [.float("slot", 1...8, 1)],
            execution: .control,
            description: "A float from the network, live: listens on UDP :9000 for /points/mod/1-8 (TouchDesigner, Max, TouchOSC…). Pick a SLOT; value carries whatever that address last sent, 0-1. One node per slot.",
            controlEval: { node, _, ctx in
                let i = min(max(Int(node.float("slot", 1)) - 1, 0), 7)
                return [SIMD4(repeating: i < ctx.osc.count ? ctx.osc[i] : 0)]
            }))
        registerSpec(NodeSpec(
            id: "osc-out", name: "OSC Out", family: .signal,
            inputs: [PortSpec("value", .signal)],
            outputs: [],
            params: [.float("slot", 1...8, 1)],
            execution: .control,
            description: "Sends the wired value to the network, live: broadcasts /points/out/SLOT on UDP :9001 (rate-limited, only when it changes). Wire Audio Levels.bass → value and drive lights elsewhere from the patch.",
            controlEval: { _, _, _ in [] }))

        // MARK: - BODY (bus stubs + real region placeholders)

        registerSpec(NodeSpec(
            id: "hand-position", name: "Hand Position", family: .body,
            outputs: [PortSpec("x", .signal), PortSpec("y", .signal)],
            params: Self.visionParams, execution: .control,
            description: "Wrist position 0-1 of whichever hand body tracking sees (prefers the left), SHAPED before it drives anything: GAIN · IN/OUT remap · DEADZONE · SMOOTHING · INVERT. Tune exactly how the hand moves things.",
            controlEvalStateful: { node, _, ctx, state in
                // Prefer the left wrist; fall back to the right so one raised hand always drives.
                let seen = ctx.bodyA.z != 0 || ctx.bodyA.w != 0
                let rawX = seen ? ctx.bodyA.z : ctx.bodyB.x
                let rawY = seen ? ctx.bodyA.w : ctx.bodyB.y
                var px = state.x, py = state.y
                let x = shapeVisionValue(rawX, node, ctx.dt, &px)
                let y = shapeVisionValue(rawY, node, ctx.dt, &py)
                state = SIMD4(px, py, 0, 0)
                return [SIMD4(repeating: x), SIMD4(repeating: y)]
            }))
        let pinchNote = " Driving an exposed 0-1 param? Lower OUTMAX to 1 first — at the default 10 the port saturates a tenth of the way into the spread."
        handPinchNode("pinch-amount", "Hand Pinch",
                      "Index-tip↔thumb-tip distance (0 touching → wide) for the FIRST hand seen, SHAPED: GAIN · remap · DEADZONE · SMOOTHING · INVERT. Drive Z, size…" + pinchNote) { $0.bodyB.z }
        handPinchNode("left-hand-pinch", "Left Hand Pinch",
                      "Pinch distance for the LEFT hand only (by chirality) — a right-hand pinch does nothing. SHAPED: GAIN · remap · DEADZONE · SMOOTHING · INVERT." + pinchNote) { $0.pinchLR.x }
        handPinchNode("right-hand-pinch", "Right Hand Pinch",
                      "Pinch distance for the RIGHT hand only (by chirality) — a left-hand pinch does nothing. SHAPED: GAIN · remap · DEADZONE · SMOOTHING · INVERT." + pinchNote) { $0.pinchLR.z }
        registerSpec(NodeSpec(
            id: "hand-openness", name: "Hand Openness", family: .body,
            outputs: [PortSpec("amount", .signal)],
            params: Self.visionParams, execution: .control,
            description: "Fist 0 → open palm 1, CONTINUOUS (mean finger extension, not a step count), SHAPED: GAIN · remap · DEADZONE · SMOOTHING · INVERT.",
            controlEvalStateful: { node, _, ctx, state in
                var p = state.x
                let a = shapeVisionValue(ctx.bodyB.w, node, ctx.dt, &p)
                state = SIMD4(p, 0, 0, 0)
                return [SIMD4(repeating: a)]
            }))
        registerSpec(NodeSpec(
            id: "head-pose", name: "Head Pose", family: .body,
            outputs: [PortSpec("x", .signal), PortSpec("y", .signal)],
            params: Self.visionParams, execution: .control,
            description: "Head position in frame 0-1, SHAPED: GAIN · remap · DEADZONE · SMOOTHING · INVERT.",
            controlEvalStateful: { node, _, ctx, state in
                var px = state.x, py = state.y
                let x = shapeVisionValue(ctx.bodyA.x, node, ctx.dt, &px)
                let y = shapeVisionValue(ctx.bodyA.y, node, ctx.dt, &py)
                state = SIMD4(px, py, 0, 0)
                return [SIMD4(repeating: x), SIMD4(repeating: y)]
            }))
        let gestureDesc = "Recognised hand shape — palm · fist · peace · point — held HIGH continuously while the gesture stays visible. HOLD lingers the output a moment after it drops (bridges brief mis-reads); SMOOTHING eases transitions between states."
        gestureShapeNode("hand-gesture", "Hand Gesture", gestureDesc + " Uses the first hand seen.") { $0.gestures }
        gestureShapeNode("left-hand-gesture", "Left Hand Gesture", gestureDesc + " LEFT hand only (by chirality).") { $0.gesturesL }
        gestureShapeNode("right-hand-gesture", "Right Hand Gesture", gestureDesc + " RIGHT hand only (by chirality).") { $0.gesturesR }
        stubControl("person-present", "Person Present", .body,
                    [PortSpec("present", .signal), PortSpec("entered", .trigger)],
                    "Someone in frame? PRESENT holds 1 while a body is tracked; ENTERED pulses once as they arrive. Needs a full body in view — a hand alone doesn't count.") { ctx in
            [SIMD4(repeating: ctx.present.x), SIMD4(repeating: ctx.present.y)]
        }
        registerSpec(NodeSpec(
            id: "joint", name: "Joint", family: .body,
            outputs: [PortSpec("x", .signal), PortSpec("y", .signal), PortSpec("speed", .signal)],
            params: [.option("joint", VisionEngine.jointOrder, "rightWrist")],
            execution: .control,
            description: "Any of the 19 tracked skeleton joints, live: X/Y 0-1 in frame (0,0 while unseen) and SPEED — how fast that joint is moving right now. Pick JOINT, wire x/y like Hand Position; speed → Size.size lights you up when you move. Add Slew after it for extra smoothing.",
            controlEvalStateful: { node, _, ctx, state in
                // state = (prevX, prevY, speedEMA, seen)
                let idx = VisionEngine.jointOrder.firstIndex(of: node.option("joint", "rightWrist")) ?? 0
                let p: SIMD2<Float> = idx < ctx.joints.count ? ctx.joints[idx] : .zero
                let seen = p.x != 0 || p.y != 0
                var inst: Float = 0
                if seen && state.w > 0.5 {
                    inst = min(simd_distance(p, SIMD2(state.x, state.y)) * 20, 1)
                }
                state.z += (inst - state.z) * min(ctx.dt * 10, 1)   // EMA over the 13 fps Vision cadence
                if seen { state.x = p.x; state.y = p.y }
                state.w = seen ? 1 : 0
                return [SIMD4(repeating: p.x), SIMD4(repeating: p.y), SIMD4(repeating: state.z)]
            }))

        registerSpec(NodeSpec(
            id: "body-region", name: "Body Region", family: .body,
            outputs: [PortSpec("mask", .fieldFloat)],
            params: [.option("region", ["person", "head", "torso", "armL", "armR", "hands", "background"], "person"),
                     .float("radius", 0.04...0.5, 0.15),
                     .float("range", 0.3...4, 1.6),
                     .float("feather", 0.01...0.3, 0.08)],
            execution: .interpreterOp,
            description: "Per-pin mask (1 inside, 0 outside) of a body part — confine any effect to the person, head, torso, arms or hands. PERSON/BACKGROUND cut by depth: anything nearer than RANGE metres counts as the person. Joint regions follow live body tracking (RADIUS sizes them, FEATHER softens the edge). Multiply the mask into any field, or wire it → Hide / Size.",
            emit: { b, _, node in
                let region = node.option("region", "person")
                let f = max(node.float("feather", 0.08), 0.01)
                if region == "person" || region == "background" {
                    // Depth cut: nearness ramps 1→0 across [RANGE, RANGE + feather·2 m].
                    let range = node.float("range", 1.6)
                    let d = b.reg()
                    b.emitPatched(PinInstruction(.loadDepth, dst: d, imm: [range, range + max(f * 2, 0.1), 0, 0]),
                                  key: "\(node.id).cut", lanes: [0, 1])
                    b.addPatchKey("\(node.id).range", lane: 0)
                    let m = b.reg()
                    let e: SIMD4<Float> = region == "background" ? [0.6, 0.1, 0, 0] : [0.1, 0.6, 0, 0]
                    b.emit(PinInstruction(.smooth, dst: m, a: d, imm: e))
                    return [m]
                }
                // Joint regions: soft circles around Vision joints, centres patched live each frame.
                let r0 = node.float("radius", 0.15)
                let uv = b.reg(); b.emit(PinInstruction(.loadUV, dst: uv))
                let d0 = b.reg()
                b.emitPatched(PinInstruction(.dist2, dst: d0, a: uv, imm: [99, 99, 0, 0]),
                              key: "\(node.id).c0", lanes: [0, 1])
                var d = d0
                if region == "hands" || region == "armL" || region == "armR" {
                    let d1 = b.reg()   // second joint (other wrist, or the elbow for arms)
                    b.emitPatched(PinInstruction(.dist2, dst: d1, a: uv, imm: [99, 99, 0, 0]),
                                  key: "\(node.id).c1", lanes: [0, 1])
                    let mn = b.reg(); b.emit(PinInstruction(.minOp, dst: mn, a: d0, b: d1)); d = mn
                }
                let m = b.reg()
                b.emitPatched(PinInstruction(.smooth, dst: m, a: d, imm: [r0 + f, r0, 0, 0]),
                              key: "\(node.id).edge", lanes: [0, 1])
                return [m]
            }))
        registerSpec(NodeSpec(
            id: "face-region", name: "Face Region", family: .body,
            outputs: [PortSpec("mask", .fieldFloat)],
            params: [.float("radius", 0.03...0.5, 0.14),
                     .float("feather", 0.01...0.3, 0.07),
                     .bool("invert", false)],
            execution: .interpreterOp,
            description: "Per-pin soft circle that FOLLOWS YOUR FACE (live body tracking): 1 on the face, 0 elsewhere; reads 0 while nobody is in frame. RADIUS sizes it, FEATHER softens the edge, INVERT flips it to everything-but-the-face. Multiply it into any field, or wire → Hide to show only the face.",
            emit: { b, _, node in
                let uv = b.reg(); b.emit(PinInstruction(.loadUV, dst: uv))
                let d = b.reg()
                b.emitPatched(PinInstruction(.dist2, dst: d, a: uv, imm: [99, 99, 0, 0]),
                              key: "\(node.id).center", lanes: [0, 1])
                let m = b.reg()
                let r0 = node.float("radius", 0.14), f = max(node.float("feather", 0.07), 0.01)
                let inv = node.float("invert") > 0.5
                b.emitPatched(PinInstruction(.smooth, dst: m, a: d,
                                             imm: inv ? [r0, r0 + f, 0, 0] : [r0 + f, r0, 0, 0]),
                              key: "\(node.id).edge", lanes: [0, 1])
                return [m]
            }))

        // MARK: - TIME (rest — real, stateful control)

        registerSpec(NodeSpec(
            id: "clock", name: "Clock", family: .time,
            outputs: [PortSpec("quarter", .trigger), PortSpec("eighth", .trigger), PortSpec("bar", .trigger)],
            execution: .control,
            description: "Beat-division triggers from the global BPM: 1/4s, 1/8s, and bars.",
            controlEvalStateful: { _, _, ctx, state in
                // state = last phases (quarter, eighth, bar)
                let beatsTotal = ctx.time * ctx.bpm / 60
                let q = beatsTotal.truncatingRemainder(dividingBy: 1)
                let e = (beatsTotal * 2).truncatingRemainder(dividingBy: 1)
                let bar = (beatsTotal / 4).truncatingRemainder(dividingBy: 1)
                let fq: Float = q < state.x ? 1 : 0
                let fe: Float = e < state.y ? 1 : 0
                let fb: Float = bar < state.z ? 1 : 0
                state.x = q; state.y = e; state.z = bar
                return [SIMD4(repeating: fq), SIMD4(repeating: fe), SIMD4(repeating: fb)]
            }))

        registerSpec(NodeSpec(
            id: "step-sequencer", name: "Step Sequencer", family: .time,
            inputs: [PortSpec("step", .trigger)],
            outputs: [PortSpec("value", .signal), PortSpec("stepIndex", .signal)],
            params: [.float("s1", 0...1, 1), .float("s2", 0...1, 0), .float("s3", 0...1, 0.6),
                     .float("s4", 0...1, 0), .float("s5", 0...1, 1), .float("s6", 0...1, 0.3),
                     .float("s7", 0...1, 0.8), .float("s8", 0...1, 0)],
            execution: .control,
            description: "An 8-step value sequence advanced by any trigger — wire Clock in and patterns emerge.",
            controlEvalStateful: { node, inputs, _, state in
                let trig = (inputs.first?.x ?? 0) > 0.5
                if trig && state.y < 0.5 { state.x = (state.x + 1).truncatingRemainder(dividingBy: 8) }
                state.y = trig ? 1 : 0
                let idx = Int(state.x)
                let v = node.float("s\(idx + 1)", 0)
                return [SIMD4(repeating: v), SIMD4(repeating: state.x / 7)]
            }))

        registerSpec(NodeSpec(
            id: "counter", name: "Counter", family: .time,
            inputs: [PortSpec("count", .trigger), PortSpec("reset", .trigger)],
            outputs: [PortSpec("value", .signal), PortSpec("count", .signal)],
            params: [.float("wrap", 1...64, 8)],
            execution: .control,
            description: "Counts incoming triggers: each pulse on COUNT steps it up by one, RESET returns it to zero, and it wraps back to 0 after WRAP steps. VALUE is the count scaled 0-1 (ready to drive any param); COUNT is the raw step number. Wire Clock.quarter → count for a ramp that climbs every beat; watch it with Value Display.",
            controlEvalStateful: { node, inputs, _, state in
                let trig = (inputs.first?.x ?? 0) > 0.5
                let reset = (inputs.count > 1 ? inputs[1].x : 0) > 0.5
                if reset { state.x = 0 }
                if trig && state.y < 0.5 { state.x += 1 }
                state.y = trig ? 1 : 0
                let wrap = max(node.float("wrap", 8), 1)
                if state.x >= wrap { state.x = 0 }
                return [SIMD4(repeating: state.x / max(wrap - 1, 1)),
                        SIMD4(repeating: state.x)]
            }))

        registerSpec(NodeSpec(
            id: "timer", name: "Timer", family: .time,
            inputs: [PortSpec("start", .trigger)],
            outputs: [PortSpec("elapsed", .signal), PortSpec("done", .trigger)],
            params: [.float("duration", 0.1...30, 2)],
            execution: .control,
            description: "Ramps 0→1 over a duration after each trigger, then fires done.",
            controlEvalStateful: { node, inputs, ctx, state in
                let trig = (inputs.first?.x ?? 0) > 0.5
                if trig { state.x = 0; state.y = 1 }
                var done: Float = 0
                if state.y > 0.5 {
                    state.x += ctx.dt / max(node.float("duration", 2), 0.1)
                    if state.x >= 1 { state.x = 1; state.y = 0; done = 1 }
                }
                return [SIMD4(repeating: state.x), SIMD4(repeating: done)]
            }))

        registerSpec(NodeSpec(
            id: "toggle", name: "Toggle", family: .time,
            inputs: [PortSpec("flip", .trigger)],
            outputs: [PortSpec("out", .signal)],
            execution: .control,
            description: "A latching on/off switch: OUT sits at 0 or 1 and FLIPS on every trigger pulse — turns momentary triggers (a beat, a fist) into a held state. Wire Hand Gesture.fist → flip and out → Gate.open: one fist mutes a lane, the next un-mutes it. Watch it with Binary Display.",
            controlEvalStateful: { _, inputs, _, state in
                let trig = (inputs.first?.x ?? 0) > 0.5
                if trig && state.y < 0.5 { state.x = state.x > 0.5 ? 0 : 1 }
                state.y = trig ? 1 : 0
                return [SIMD4(repeating: state.x)]
            }))

        registerSpec(NodeSpec(
            id: "gate", name: "Gate", family: .time,
            inputs: [PortSpec("in", .signal), PortSpec("open", .signal, default: [1, 1, 1, 1])],
            outputs: [PortSpec("out", .signal)],
            execution: .control,
            description: "Passes the input only while open — mute anything on demand.",
            controlEval: { _, inputs, _ in
                let v = inputs.first?.x ?? 0
                let open = (inputs.count > 1 ? inputs[1].x : 1) > 0.5
                return [SIMD4(repeating: open ? v : 0)]
            }))

        registerSpec(NodeSpec(
            id: "delay-trigger", name: "Trigger Delay", family: .time,
            inputs: [PortSpec("in", .trigger)],
            outputs: [PortSpec("out", .trigger)],
            params: [.float("delay", 0.05...4, 0.5)],
            execution: .control,
            description: "Repeats a trigger after a delay — pre-echo choreography.",
            controlEvalStateful: { node, inputs, ctx, state in
                let trig = (inputs.first?.x ?? 0) > 0.5
                if trig && state.y < 0.5 { state.x = node.float("delay", 0.5) }
                state.y = trig ? 1 : 0
                var fire: Float = 0
                if state.x > 0 {
                    state.x -= ctx.dt
                    if state.x <= 0 { fire = 1; state.x = 0 }
                }
                return [SIMD4(repeating: fire)]
            }))

        registerSpec(NodeSpec(
            id: "on-start", name: "On Start", family: .time,
            outputs: [PortSpec("fired", .trigger), PortSpec("seconds", .signal)],
            execution: .control,
            description: "Starts the moment you place it: FIRED pulses once (use it to reset a Counter or kick a Timer), and SECONDS counts up continuously from that moment. Wire seconds → Value Display to watch it climb, or → Sine / any param for a slow one-way evolve. Deleting and re-adding the node restarts the count.",
            controlEvalStateful: { _, _, ctx, state in
                state.y += ctx.dt
                if state.x < 0.5 {
                    state.x = 1
                    return [SIMD4(repeating: 1), SIMD4(repeating: state.y)]
                }
                return [.zero, SIMD4(repeating: state.y)]
            }))

        // MARK: - STAGE (rest)

        // Light + Background are REAL render-read sinks (like Camera): the renderer reads the
        // first node of each per frame — no wires needed, just add the node.
        registerSpec(NodeSpec(
            id: "light", name: "Light", family: .stage,
            params: [.option("type", ["point", "directional", "spot"], "point"),
                     .float("x", -2...2, 0.5), .float("y", -2...2, 0.8), .float("z", 0...4, 2),
                     .float("intensity", 0...3, 1), .float("falloff", 0...4, 1)],
            execution: .render,
            description: "A stage light replacing the built-in default light the moment you add it. POINT sits at X/Y/Z in front of the wall (FALLOFF dims with distance); DIRECTIONAL uses X/Y/Z as a direction only; SPOT is a soft cone aimed at the cloud centre. Drag X/Y while watching — pins shade toward the light. Delete the node to go back to the default."))
        registerSpec(NodeSpec(
            id: "background", name: "Background", family: .stage,
            params: [.float("r", 0...1, 0), .float("g", 0...1, 0), .float("b", 0...1, 0),
                     .float("gradient", 0...1, 0)],
            execution: .render,
            description: "The void behind the pins — set its R/G/B and the backdrop changes instantly (also behind NDI/Record frames unless ALPHA keys it out). GRADIENT fades the colour radially: bright centre, dark edges. No wires needed."))
        registerSpec(NodeSpec(
            id: "bloom", name: "Bloom", family: .stage,
            params: [.float("threshold", 0...1, 0.7), .float("intensity", 0...2, 0.4)],
            execution: .render,
            description: "Bright pins glow — the signature synth halo. THRESHOLD picks how bright a pin must be to bloom; INTENSITY sets the halo strength. Pairs beautifully with Palette's hot ends and Strobe Color flashes. Just add the node."))
        registerSpec(NodeSpec(
            id: "grain", name: "Grain", family: .stage,
            params: [.float("amount", 0...1, 0.2)],
            execution: .render,
            description: "Animated film grain over the final image — breaks up flat digital areas. AMOUNT 0.1-0.3 is subtle texture; 1 is full VHS. Just add the node."))
        registerSpec(NodeSpec(
            id: "vignette", name: "Vignette", family: .stage,
            params: [.float("amount", 0...1, 0.3)],
            execution: .render,
            description: "Darkens the frame corners, pulling the eye to the centre. AMOUNT sets how hard the edges fall off. Just add the node."))
        registerSpec(NodeSpec(
            id: "render-settings", name: "Render Settings", family: .stage,
            params: [.option("blend", ["solid", "ghost"], "solid")],
            execution: .render,
            description: "How pins draw: SOLID = opaque, depth-tested spheres. GHOST = additive glow blending with no depth test — overlapping pins add up to light, the classic point-cloud hologram look (try it with Bloom)."))

        // MARK: - TOOLS

        registerSpec(NodeSpec(
            id: "reroute", name: "Reroute", family: .tools,
            inputs: [PortSpec("in", .fieldFloat)], outputs: [PortSpec("out", .fieldFloat)],
            execution: .interpreterOp,
            description: "A wire elbow — passes its input through untouched.",
            emit: { b, inputs, _ in [b.materialize(inputs[0], default: .zero)] }))

        registerSpec(NodeSpec(
            id: "send", name: "Send", family: .tools,
            inputs: [PortSpec("in", .fieldFloat)], outputs: [],
            params: [.option("channel", ["A", "B", "C", "D"], "A")],
            execution: .interpreterOp,
            description: "Wireless wire: whatever you feed IN is broadcast to every Receive on the same CHANNEL — declutter long wires across the canvas.",
            emit: { _, _, _ in [] }))
        registerSpec(NodeSpec(
            id: "receive", name: "Receive", family: .tools,
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.option("channel", ["A", "B", "C", "D"], "A")],
            execution: .interpreterOp,
            description: "Wireless wire: OUT carries whatever feeds the matching Send channel (0 while that channel is empty or would loop).",
            emit: { b, _, _ in [b.constant(.zero)] }))   // compiler intercepts + pairs; this is the empty-channel fallback

        registerSpec(NodeSpec(
            id: "comment", name: "Annotations", family: .tools,
            execution: .render,
            description: "A background frame that groups part of your network — drag a corner to resize, drag the frame to move everything inside it with it. Type a label in the bar below. No ports, no effect on the render."))
        registerSpec(NodeSpec(
            id: "value-display", name: "Value Display", family: .tools,
            inputs: [PortSpec("in", .signal)], outputs: [PortSpec("out", .signal)],
            execution: .control,
            description: "Shows a live number on the canvas; passes the value through.",
            controlEval: { _, inputs, _ in [inputs.first ?? .zero] }))
        registerSpec(NodeSpec(
            id: "binary-display", name: "Binary Display", family: .tools,
            inputs: [PortSpec("in", .signal)], outputs: [PortSpec("out", .signal)],
            execution: .control,
            description: "Shows YES while the wired trigger/value is high (>0.5), NO while it's low — a quick check that a gesture actually fires. Passes a clean 0/1 through.",
            controlEval: { _, inputs, _ in
                [SIMD4<Float>((inputs.first ?? .zero).x > 0.5 ? 1 : 0, 0, 0, 0)]
            }))
        registerSpec(NodeSpec(
            id: "live-update", name: "Live Update", family: .tools,
            inputs: (1...10).map { PortSpec("in\($0)", .trigger) },
            outputs: [PortSpec("out", .signal)],
            params: [.float("hold", 0...3, 0.6)],
            execution: .control,
            description: "Wire several triggers in (e.g. every Hand Gesture output) and it shows the NAME of whichever input is active right now — palm→fist reads \"PALM\" then \"FIST\". HOLD keeps the last name up briefly so a momentary drop doesn't blank it to \"—\". Outputs the active input's index.",
            controlEvalStateful: { node, inputs, ctx, state in
                // state.x = held active index (−1 = none) · state.y = seconds since a real input was active.
                // Only latch on a genuine active input; hold the last one for HOLD s before clearing.
                var active = -1; var best: Float = 0.35
                for (i, v) in inputs.enumerated() where v.x > best { best = v.x; active = i }
                var idx = state.x, timer = state.y
                if active >= 0 { idx = Float(active); timer = 0 }
                else { timer += ctx.dt; if timer >= node.float("hold", 0.6) { idx = -1 } }
                state = SIMD4(idx, timer, 0, 0)
                return [SIMD4(idx, best, 0, 0)]
            }))
        registerSpec(NodeSpec(
            id: "macro", name: "Macro", family: .tools,
            execution: .render,
            description: "A group of nodes collapsed into one card: select several nodes and hit GROUP in the bar. Wires in and out keep flowing (grouping is visual — the network underneath never changes); drag the card to move the whole group. EXPAND or delete the card to spread them out again."))
    }

    // MARK: - tiny builders

    private func unary(_ id: String, _ name: String, desc: String, params: [ParamSpec],
                       _ body: @escaping @Sendable (inout PinProgramBuilder, Int32, GraphNode) -> Int32) {
        registerSpec(NodeSpec(
            id: id, name: name, family: .signal,
            inputs: [PortSpec("in", .fieldFloat)], outputs: [PortSpec("out", .fieldFloat)],
            params: params, execution: .interpreterOp, description: desc,
            emit: { b, inputs, node in
                let x = b.materialize(inputs[0], default: .zero)
                return [body(&b, x, node)]
            }))
    }
}

