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

    private func passthrough(_ id: String, _ name: String, _ family: NodeFamily,
                             params: [ParamSpec], _ desc: String) {
        registerSpec(NodeSpec(
            id: id, name: name, family: family,
            inputs: [PortSpec("pins", .domain)], outputs: [PortSpec("pins", .domain)],
            params: params, execution: .render,
            description: desc + " · Takes effect when its render feature lands.",
            emit: { b, inputs, _ in [b.materialize(inputs.first ?? -1, default: .zero)] }))
    }

    private static let shapeNames = ["sphere", "cube", "tube", "slab", "cone", "ring", "disc", "spike"]

    /// Shared richer settings for continuous Vision nodes (Hand Position, Head Pose, Pinch, Openness).
    private static let visionParams: [ParamSpec] = [
        .float("gain", 0...4, 1), .float("inMin", 0...1, 0), .float("inMax", 0...1, 1),
        .float("outMin", 0...1, 0), .float("outMax", 0...1, 1),
        .float("deadzone", 0...0.5, 0), .float("smoothing", 0...1, 0), .bool("invert", false)]

    // MARK: - SOURCE (rest)

    func registerFullCatalog() {
        registerTriggerNodes()   // §13 v2 — control-rate trigger-layer nodes (nested triggerGraph)
        registerSpec(NodeSpec(
            id: "source", name: "Source", family: .source,
            outputs: [PortSpec("source", .source)],
            params: [.option("mode", ["auto", "trueDepth", "lidar", "media", "still"], "auto"),
                     .bool("mirror", true)],
            execution: .control,
            description: "The one live input: TrueDepth front, LiDAR back, an imported clip or a still. Auto picks the best available.",
            controlEval: { _, _, _ in [] }))

        registerSpec(NodeSpec(
            id: "clip-transport", name: "Clip Transport", family: .source,
            inputs: [PortSpec("speed", .signal, default: [1, 1, 1, 1]), PortSpec("restart", .trigger)],
            outputs: [PortSpec("position", .signal), PortSpec("looped", .trigger)],
            params: [.bool("playing", true), .bool("loop", true),
                     .float("loopStart", 0...1, 0), .float("loopEnd", 0...1, 1)],
            execution: .control,
            description: "Play/pause/speed/loop-range for imported depth clips. · Arrives with the media import engine.",
            controlEval: { _, _, _ in [.zero, .zero] }))

        registerSpec(NodeSpec(
            id: "still-image", name: "Still Image", family: .source,
            outputs: [PortSpec("source", .source)],
            params: [.option("fit", ["fill", "fit"], "fill")],
            execution: .control,
            description: "An imported photo with its baked depth as a static source. · Arrives with the media import engine.",
            controlEval: { _, _, _ in [] }))

        registerSpec(NodeSpec(
            id: "confidence", name: "Confidence", family: .source,
            outputs: [PortSpec("confidence", .fieldFloat)],
            params: [.float("floor", 0...1, 0)],
            execution: .interpreterOp,
            description: "Per-pin sensor confidence 0-1 (noisy edges score low). · Reads 1.0 until the confidence texture is bound.",
            emit: { b, _, _ in [b.constant([1, 1, 1, 1])] }))

        stubControl("proximity", "Proximity", .source,
                    [PortSpec("nearness", .signal), PortSpec("entered", .trigger)],
                    "How close the nearest subject is, 0-1, with a threshold trigger. · Arrives with the depth-stats pass.") { _ in [.zero, .zero] }

        // MARK: - GRID (rest)

        registerSpec(NodeSpec(
            id: "domain", name: "Domain", family: .grid,
            inputs: [PortSpec("morph", .signal)],
            outputs: [PortSpec("pins", .domain)],
            params: [.float("count", 64...307_200, 30_000, modSafe: false),
                     .option("topologyA", ["rect", "hex", "radial", "spiral", "scatter", "perspective"], "rect"),
                     .option("topologyB", ["rect", "hex", "radial", "spiral", "scatter", "perspective"], "radial"),
                     .float("morphAmount", 0...1, 0)],
            execution: .render,
            description: "The pin lattice: topology warps of one canonical grid, morphable per pin. · Rect is live; the warp family lands with the domain kernel.",
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

        passthrough("uv-transform", "UV Transform", .grid,
                    params: [.float("offsetX", -1...1, 0), .float("offsetY", -1...1, 0),
                             .float("scale", 0.25...4, 1), .float("rotate", -0.5...0.5, 0)],
                    "Pans/zooms/rotates the source image under the pins without moving them.")
        passthrough("edge-policy", "Edge Policy", .grid,
                    params: [.option("mode", ["none", "fade", "clamp"], "fade"),
                             .float("margin", 0...0.3, 0.05)],
                    "What happens when warps push pins past the frame border.")

        // MARK: - SHAPE (REAL geometry — feed Output.shape / .rotation / .stretch)

        registerSpec(NodeSpec(
            id: "shape", name: "Shape", family: .shape,
            outputs: [PortSpec("shape", .fieldFloat)],
            params: [.option("type", Self.shapeNames, "sphere")],
            execution: .interpreterOp,
            description: "Pin cap shape — sphere · cube · tube · slab · cone · ring · disc · spike. Wire → Output.shape.",
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
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.option("type", ["perlin", "simplex", "random", "sparse", "hermite", "harmonic"], "perlin"),
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
            description: "Animated 3D noise field, per pin (TouchDesigner-style). TYPE perlin/simplex/random/sparse/hermite/harmonic · PERIOD = feature size · HARMONICS/SPREAD/GAIN/ROUGHNESS build fractal detail · EXPONENT/AMPLITUDE/OFFSET shape the output. MOVE it along X/Y/Z off time (Z morphs the field through a hidden plane, like it's breathing). Wire OUT → Displace / Size / Palette / Output.z. Optional Z input drives the sample plane from a Time/other field.",
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
                return [acc]
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
        passthrough("look-at", "Look At", .shape,
                    params: [.float("amount", 0...1, 1)],
                    "Orients every pin to face a point — iron-filings tracking.")
        passthrough("stem", "Stem", .shape,
                    params: [.bool("enabled", true),
                             .option("profile", ["round", "square", "blade"], "square"),
                             .float("thickness", 0...1, 0.3), .float("taper", 0...1, 0.2)],
                    "The arm from the Z-origin wall to each cap — profile, thickness, taper.")
        passthrough("material", "Material", .shape,
                    params: [.option("shading", ["unlit", "lit", "matcap"], "lit"),
                             .float("roughness", 0...1, 0.5), .float("metallic", 0...1, 0)],
                    "How pins are shaded: flat, lit by Stage lights, or matcap studio looks.")

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
            description: "1 where a > b, else 0.",
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
            description: "Freezes the input value each time the trigger fires — stepped randomness from smooth sources.",
            controlEvalStateful: { _, inputs, _, state in
                let trig = (inputs.count > 1 ? inputs[1].x : 0) > 0.5
                if trig || state.w < 0.5 { state.x = inputs.first?.x ?? 0; state.w = 1 }
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
                    "Mic band energies 0-1. · Live when the audio engine lands.") { ctx in
            [SIMD4(repeating: ctx.audio.x), SIMD4(repeating: ctx.audio.y),
             SIMD4(repeating: ctx.audio.z), SIMD4(repeating: ctx.audio.w)]
        }
        stubControl("beat-trigger", "Beat Trigger", .signal,
                    [PortSpec("low", .trigger), PortSpec("mid", .trigger), PortSpec("high", .trigger)],
                    "Drum onsets as triggers. · Live when the audio engine lands.") { ctx in
            [SIMD4(repeating: ctx.onsets.x), SIMD4(repeating: ctx.onsets.y), SIMD4(repeating: ctx.onsets.z)]
        }
        stubControl("fft-band", "FFT Band", .signal, [PortSpec("level", .signal)],
                    "One of 20 spectrum bands. · Live when the audio engine lands.") { _ in [.zero] }
        stubControl("audio-rms", "Mic Level", .signal, [PortSpec("rms", .signal)],
                    "True mic loudness, no auto-gain. · Live when the audio engine lands.") { ctx in
            [SIMD4(repeating: ctx.audio.w)]
        }
        stubControl("burst", "Burst", .signal, [PortSpec("burst", .signal)],
                    "Sudden-loudness pulse. · Live when the audio engine lands.") { ctx in
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
        stubControl("osc-in", "OSC In", .signal, [PortSpec("value", .signal)],
                    "A float from the network (/points/mod/n). · Live when the OSC engine lands.") { _ in [.zero] }
        registerSpec(NodeSpec(
            id: "osc-out", name: "OSC Out", family: .signal,
            inputs: [PortSpec("value", .signal)],
            outputs: [],
            execution: .control,
            description: "Sends a value to the network. · Live when the OSC engine lands.",
            controlEval: { _, _, _ in [] }))

        // MARK: - BODY (bus stubs + real region placeholders)

        registerSpec(NodeSpec(
            id: "hand-position", name: "Hand Position", family: .body,
            outputs: [PortSpec("x", .signal), PortSpec("y", .signal)],
            params: Self.visionParams, execution: .control,
            description: "Wrist position 0-1, SHAPED before it drives anything: GAIN · IN/OUT remap · DEADZONE · SMOOTHING · INVERT. Tune exactly how the hand moves things.",
            controlEvalStateful: { node, _, ctx, state in
                var px = state.x, py = state.y
                let x = shapeVisionValue(ctx.bodyA.z, node, ctx.dt, &px)
                let y = shapeVisionValue(ctx.bodyA.w, node, ctx.dt, &py)
                state = SIMD4(px, py, 0, 0)
                return [SIMD4(repeating: x), SIMD4(repeating: y)]
            }))
        registerSpec(NodeSpec(
            id: "pinch-amount", name: "Hand Pinch", family: .body,
            outputs: [PortSpec("distance", .signal)],
            params: Self.visionParams, execution: .control,
            description: "Index-tip↔thumb-tip distance (0 touching → 1 wide) for the first hand seen, SHAPED: GAIN · remap · DEADZONE · SMOOTHING · INVERT. Drive Z, size…",
            controlEvalStateful: { node, _, ctx, state in
                var p = state.x
                let d = shapeVisionValue(ctx.bodyB.z, node, ctx.dt, &p)
                state = SIMD4(p, 0, 0, 0)
                return [SIMD4(repeating: d)]
            }))
        registerSpec(NodeSpec(
            id: "hand-openness", name: "Hand Openness", family: .body,
            outputs: [PortSpec("amount", .signal)],
            params: Self.visionParams, execution: .control,
            description: "Fist 0 → open palm 1, SHAPED: GAIN · remap · DEADZONE · SMOOTHING · INVERT.",
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
        registerSpec(NodeSpec(
            id: "hand-gesture", name: "Hand Gesture", family: .body,
            outputs: [PortSpec("palm", .trigger), PortSpec("fist", .trigger),
                      PortSpec("peace", .trigger), PortSpec("point", .trigger)],
            params: [.float("hold", 0...3, 0), .float("smoothing", 0...1, 0)],
            execution: .control,
            description: "Recognised hand shape — palm · fist · peace · point. HOLD keeps the output high (seconds) while you keep the gesture up, so a wired palette/effect STICKS instead of flashing; SMOOTHING eases the transition between states. HOLD 0 + SMOOTHING 0 = raw one-frame pulses.",
            controlEvalStateful: { node, _, ctx, state in
                let raw = SIMD4<Float>(ctx.gestures.x, ctx.gestures.y, ctx.gestures.z, ctx.gestures.w)
                let hold = node.float("hold", 0)
                let sm = node.float("smoothing", 0)
                let atk: Float = sm > 0.001 ? (1 - sm * 0.97) : 1               // how fast it rises to the gesture
                let rel: Float = hold > 0.001 ? (1 - exp(-ctx.dt / hold)) : 1    // linger ~HOLD seconds after it stops
                var s = state
                for i in 0..<4 {
                    let t = raw[i]
                    s[i] += (t - s[i]) * (t > s[i] ? atk : rel)
                }
                state = s
                return [SIMD4(repeating: s.x), SIMD4(repeating: s.y),
                        SIMD4(repeating: s.z), SIMD4(repeating: s.w)]
            }))
        stubControl("person-present", "Person Present", .body,
                    [PortSpec("present", .signal), PortSpec("entered", .trigger)],
                    "Someone in frame?") { ctx in
            [SIMD4(repeating: ctx.present.x), SIMD4(repeating: ctx.present.y)]
        }
        stubControl("joint", "Joint", .body,
                    [PortSpec("x", .signal), PortSpec("y", .signal), PortSpec("speed", .signal)],
                    "Any of 19 skeleton joints. · Live when body tracking lands.") { _ in [.zero, .zero, .zero] }

        registerSpec(NodeSpec(
            id: "body-region", name: "Body Region", family: .body,
            outputs: [PortSpec("mask", .fieldFloat)],
            params: [.option("region", ["person", "head", "torso", "armL", "armR", "hands", "background"], "person")],
            execution: .interpreterOp,
            description: "Per-pin mask of a body part — confine any effect to the arms, the head… · Reads 0 until body tracking lands.",
            emit: { b, _, _ in [b.constant(.zero)] }))
        registerSpec(NodeSpec(
            id: "face-region", name: "Face Region", family: .body,
            outputs: [PortSpec("mask", .fieldFloat)],
            execution: .interpreterOp,
            description: "Per-pin mask of the face. · Reads 0 until face tracking lands.",
            emit: { b, _, _ in [b.constant(.zero)] }))

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
            outputs: [PortSpec("value", .signal)],
            params: [.float("wrap", 1...64, 8)],
            execution: .control,
            description: "Counts triggers 0→wrap, normalized 0-1.",
            controlEvalStateful: { node, inputs, _, state in
                let trig = (inputs.first?.x ?? 0) > 0.5
                let reset = (inputs.count > 1 ? inputs[1].x : 0) > 0.5
                if reset { state.x = 0 }
                if trig && state.y < 0.5 { state.x += 1 }
                state.y = trig ? 1 : 0
                let wrap = max(node.float("wrap", 8), 1)
                if state.x >= wrap { state.x = 0 }
                return [SIMD4(repeating: state.x / max(wrap - 1, 1))]
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
            description: "Flips 0↔1 on every trigger — latching pads out of momentary ones.",
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
            outputs: [PortSpec("fired", .trigger)],
            execution: .control,
            description: "Fires exactly once when the patch starts running.",
            controlEvalStateful: { _, _, _, state in
                if state.x < 0.5 { state.x = 1; return [SIMD4(repeating: 1)] }
                return [.zero]
            }))

        // MARK: - STAGE (rest — placeholders until the render features land)

        for (id, name, params, desc) in [
            ("light", "Light", [ParamSpec.option("type", ["point", "directional", "spot"], "point"),
                                .float("x", -2...2, 0.5), .float("y", -2...2, 0.8), .float("z", 0...4, 2),
                                .float("intensity", 0...3, 1), .float("falloff", 0...4, 1)] as [ParamSpec],
             "A stage light on the pins — position drivable (head/hand follow)."),
            ("background", "Background", [.float("r", 0...1, 0), .float("g", 0...1, 0), .float("b", 0...1, 0),
                                          .float("gradient", 0...1, 0)],
             "The void behind the wall: color, gradient; alpha-key aware for NDI."),
            ("bloom", "Bloom", [.float("threshold", 0...1, 0.7), .float("intensity", 0...2, 0.4)],
             "Bright pins glow — the signature synth halo."),
            ("grain", "Grain", [.float("amount", 0...1, 0.2)], "Film grain over the final image."),
            ("vignette", "Vignette", [.float("amount", 0...1, 0.3)], "Darkens the frame corners."),
            ("render-settings", "Render Settings", [.option("blend", ["solid", "ghost"], "solid")] as [ParamSpec],
             "Solid depth-tested pins vs additive ghost blending (the classic cloud look)."),
        ] {
            registerSpec(NodeSpec(id: id, name: name, family: .stage, params: params,
                                  execution: .render,
                                  description: desc + " · Takes effect when its render stage lands."))
        }

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
            description: "Wireless wire: broadcasts to the matching Receive. · Pairing lands with the editor.",
            emit: { _, _, _ in [] }))
        registerSpec(NodeSpec(
            id: "receive", name: "Receive", family: .tools,
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.option("channel", ["A", "B", "C", "D"], "A")],
            execution: .interpreterOp,
            description: "Wireless wire: picks up the matching Send. · Pairing lands with the editor.",
            emit: { b, _, _ in [b.constant(.zero)] }))

        registerSpec(NodeSpec(
            id: "comment", name: "Sticky Note", family: .tools,
            execution: .render,
            description: "A teaching note pinned to the canvas — no ports, no effect."))
        registerSpec(NodeSpec(
            id: "value-display", name: "Value Display", family: .tools,
            inputs: [PortSpec("in", .signal)], outputs: [PortSpec("out", .signal)],
            execution: .control,
            description: "Shows a live number on the canvas; passes the value through.",
            controlEval: { _, inputs, _ in [inputs.first ?? .zero] }))
        registerSpec(NodeSpec(
            id: "macro", name: "Macro", family: .tools,
            execution: .render,
            description: "A reusable group of nodes collapsed into one. · Collapse/expand lands with the editor."))
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

