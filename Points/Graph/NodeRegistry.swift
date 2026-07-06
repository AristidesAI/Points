import Foundation
import simd

/// The engine's node catalog — the compilable subset of Plans/03-Node-Catalog.json.
/// Each spec carries its pin-program emitter and/or control-rate evaluator.
final class NodeRegistry: @unchecked Sendable {
    static let shared = NodeRegistry()

    private var specs: [String: NodeSpec] = [:]
    func spec(_ id: String) -> NodeSpec? { specs[id] }
    var allSpecs: [NodeSpec] { Array(specs.values) }

    private func register(_ s: NodeSpec) { specs[s.id] = s }
    /// Extension registration point (NodeRegistryFull.swift).
    func registerSpec(_ s: NodeSpec) { specs[s.id] = s }

    private init() {
        registerSources()
        registerGrid()
        registerCleanup()
        registerShape()
        registerMove()
        registerColor()
        registerSignalMath()
        registerModulate()
        registerTouch()
        registerTime()
        registerStage()
        registerFullCatalog()   // the rest of the Plans/03 catalog
    }

    // MARK: SOURCE

    private func registerSources() {
        register(NodeSpec(
            id: "depth", name: "Depth", family: .source,
            inputs: [], outputs: [PortSpec("depth", .fieldFloat)],
            // near 0.1: TrueDepth reads down to ~10 cm — a higher floor plateaus close
            // surfaces into a flat cap (the "goes flat when close" bug)
            params: [.float("near", 0.05...5, 0.1), .float("far", 0.2...8, 2.5), .bool("invert", false)],
            execution: .interpreterOp,
            description: "Raw sensor depth per pin, remapped near→far to 1→0 nearness.",
            emit: { b, _, node in
                let r = b.reg()
                // Kernel computes nearness with imm = (near, far, invert, 0); holes → 0.
                b.emitPatched(PinInstruction(.loadDepth, dst: r,
                                             imm: [node.float("near", 0.25), node.float("far", 2.5),
                                                   node.float("invert"), 0]),
                              key: "\(node.id).range", lanes: [0, 1, 2])
                b.addPatchKey("\(node.id).near", lane: 0)   // §13 — per-param keys so nested triggers can drive each
                b.addPatchKey("\(node.id).far", lane: 1)
                b.addPatchKey("\(node.id).invert", lane: 2)
                return [r]
            }))

        register(NodeSpec(
            id: "video-color", name: "Video Color", family: .source,
            inputs: [], outputs: [PortSpec("color", .fieldColor)],
            params: [.float("exposure", -2...2, 0)],
            execution: .interpreterOp,
            description: "Camera color sampled at each pin.",
            emit: { b, _, node in
                let r = b.reg()
                b.emitPatched(PinInstruction(.loadColor, dst: r,
                                             imm: [pow(2, node.float("exposure")), 0, 0, 0]),
                              key: "\(node.id).exposure", lanes: [0])
                return [r]
            }))
    }

    // MARK: GRID

    private func registerGrid() {
        register(NodeSpec(
            id: "grid-info", name: "Grid Info", family: .grid,
            inputs: [],
            outputs: [PortSpec("uv", .fieldVec3), PortSpec("index", .fieldFloat),
                      PortSpec("hash", .fieldFloat), PortSpec("centerDist", .fieldFloat)],
            execution: .interpreterOp,
            description: "Per-pin constants: uv, normalized index, stable hash, distance from center.",
            emit: { b, _, _ in
                let uv = b.reg(); b.emit(PinInstruction(.loadUV, dst: uv))
                let idx = b.reg(); b.emit(PinInstruction(.loadIndex, dst: idx))   // normIndex in .x
                // hash/centerDist need their value in .x (consumers read .x), so derive each into its own reg.
                let hsh = b.reg(); b.emit(PinInstruction(.hash1, dst: hsh, a: idx, imm: [1, 0, 0, 0]))
                let cd = b.reg(); b.emit(PinInstruction(.dist2, dst: cd, a: uv, imm: [0.5, 0.5, 0, 0]))
                return [uv, idx, hsh, cd]
            }))

        register(NodeSpec(
            id: "point-display", name: "Point Display", family: .grid,
            inputs: [PortSpec("depth", .fieldFloat)],
            outputs: [PortSpec("position", .fieldVec3), PortSpec("z", .fieldFloat)],
            params: [.float("separation", 0...3, 1), .float("volume", 0...2, 0),
                     .float("wobble", 0...0.5, 0), .float("gain", 0...3, 1.2),
                     .option("mode", ["free", "pinout", "metric"], "free"),
                     .bool("arms", false),
                     .float("focus", 0.3...3, 1.0),
                     .float("gamma", 0.25...4, 1), .float("zFlatten", 0...1, 1),
                     .bool("edgeLock", true)],
            execution: .interpreterOp,
            description: "How the pins hold together. FREE = the TDLidar TrueDepth point cloud: pixels fan into a real frustum; FOCUS is the depth that stays put. PINOUT locks XY to the fixed grid (EDGE LOCK pins the outer ring). ARMS pull every point back to its Z-origin pin (off = freestanding cloud). SEPARATION spreads, VOLUME opens with depth, WOBBLE adds sensor life; GAIN/GAMMA/Z-FLATTEN shape the forward push. Cleanup (grazing cull, EMA, hole fill…) lives in red FILTER nodes between Depth and here.",
            emit: { b, inputs, node in
                let d = b.materialize(inputs[0], default: .zero)
                let mode = node.option("mode", "free")
                // METRIC: real camera-intrinsics unprojection to metric XYZ — objects keep true size,
                // so moving away shrinks them (TDLidar 1:1). SEPARATION = metres→view scale, FOCUS =
                // reference depth (sits at the wall). Needs DEPTHPUSH ≥ 1 (multiplies the metric Z).
                if mode == "metric" {
                    let scale = node.float("separation", 1), zRef = node.float("focus", 1)
                    let mxy = b.reg(), mz = b.reg()
                    b.emitPatched(PinInstruction(.unprojectXY, dst: mxy, a: d, imm: [scale, 0, 0, 0]),
                                  key: "\(node.id).xy", lanes: [0])
                    b.addPatchKey("\(node.id).separation", lane: 0)
                    b.emitPatched(PinInstruction(.unprojectZ, dst: mz, a: d, imm: [scale, zRef, 0, 0]),
                                  key: "\(node.id).z", lanes: [0, 1])
                    b.addPatchKey("\(node.id).separation", lane: 0)
                    b.addPatchKey("\(node.id).focus", lane: 1)
                    return [mxy, mz]
                }
                let free = mode == "free"
                let edge: Float = (!free && node.float("edgeLock") > 0.5) ? 1 : 0
                let xy = b.reg()
                if free {
                    b.emitPatched(PinInstruction(.freeXY, dst: xy, a: d,
                                                 imm: [node.float("separation", 1), node.float("focus", 1), 0, 0]),
                                  key: "\(node.id).xy", lanes: [0, 1])
                    b.addPatchKey("\(node.id).separation", lane: 0)   // §13 per-param keys (free mode)
                    b.addPatchKey("\(node.id).focus", lane: 1)
                } else {
                    b.emitPatched(PinInstruction(.pinFieldXY, dst: xy, a: d,
                                                 imm: [node.float("separation", 1), node.float("volume", 0),
                                                       node.float("wobble", 0), edge]),
                                  key: "\(node.id).xy", lanes: [0, 1, 2])
                    b.addPatchKey("\(node.id).separation", lane: 0)   // §13 per-param keys (pinout mode)
                    b.addPatchKey("\(node.id).volume", lane: 1)
                    b.addPatchKey("\(node.id).wobble", lane: 2)
                }
                let z = b.reg()
                b.emitPatched(PinInstruction(.pinFieldZ, dst: z, a: d,
                                             imm: [node.float("gain", 1.2), node.float("gamma", 1),
                                                   node.float("zFlatten", 1), edge]),
                              key: "\(node.id).z", lanes: [0, 1, 2])
                b.addPatchKey("\(node.id).gain", lane: 0)   // §13 per-param keys
                b.addPatchKey("\(node.id).gamma", lane: 1)
                b.addPatchKey("\(node.id).zFlatten", lane: 2)
                return [xy, z]
            }))

        register(NodeSpec(
            id: "region-ellipse", name: "Ellipse Region", family: .grid,
            inputs: [PortSpec("center", .vec2, default: [0.5, 0.5, 0, 0])],
            outputs: [PortSpec("mask", .fieldFloat)],
            params: [.float("radius", 0.02...1, 0.3), .float("feather", 0...0.5, 0.12), .bool("invert", false)],
            execution: .interpreterOp,
            description: "Soft circular mask in view space: 1 inside, 0 outside.",
            emit: { b, _, node in
                let uv = b.reg(); b.emit(PinInstruction(.loadUV, dst: uv))
                let d = b.reg()
                b.emitPatched(PinInstruction(.dist2, dst: d, a: uv, imm: [0.5, 0.5, 0, 0]),
                              key: "\(node.id).center", lanes: [0, 1])
                let m = b.reg()
                let r0 = node.float("radius", 0.3), f = node.float("feather", 0.12)
                let inv = node.float("invert")
                // smoothstep(r+f, r, d) → 1 inside; invert flips edges
                b.emitPatched(PinInstruction(.smooth, dst: m, a: d,
                                             imm: inv > 0.5 ? [r0, r0 + f, 0, 0] : [r0 + f, r0, 0, 0]),
                              key: "\(node.id).edge", lanes: [0, 1])
                return [m]
            }))
    }

    // MARK: FILTER — depth cleanup (TDLidar's cleanup settings, each its own red node).
    // Insert between Depth and Point Display. Grazing Cull is a real GPU pass; Apple
    // Depth Filter / EMA / Fill Holes configure the capture + temporal filter by presence
    // (the depth field passes through their wire untouched).

    private func registerCleanup() {
        register(NodeSpec(
            id: "grazing-cull", name: "Grazing Cull", family: .filter,
            inputs: [PortSpec("depth", .fieldFloat)], outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("cull", 0...1, 0.25), .float("edge", 0...0.4, 0.10)],
            execution: .interpreterOp,
            description: "TDLidar cleanup A1: rejects grazing-angle ToF returns (CULL, 0 = off) and silhouette flying-pixel fringes (EDGE, metres of neighbour spread). Culled points disappear.",
            emit: { b, inputs, node in
                let d = b.materialize(inputs[0], default: .zero)
                let r = b.reg()
                b.emitPatched(PinInstruction(.grazeCull, dst: r, a: d,
                                             imm: [node.float("cull", 0.25), node.float("edge", 0.10), 0, 0]),
                              key: "\(node.id).cull", lanes: [0, 1])
                return [r]
            }))

        func passFilter(_ id: String, _ name: String, _ params: [ParamSpec], _ desc: String) {
            register(NodeSpec(
                id: id, name: name, family: .filter,
                inputs: [PortSpec("depth", .fieldFloat)], outputs: [PortSpec("out", .fieldFloat)],
                params: params, execution: .interpreterOp,
                description: desc,
                emit: { b, inputs, _ in [b.materialize(inputs[0], default: .zero)] }))
        }

        passFilter("apple-depth-filter", "Apple Depth Filter",
                   [.bool("enabled", true)],
                   "Apple's built-in AVFoundation depth smoothing (front camera). OFF by default app-wide — add this node to turn it on. It fills holes and steadies depth but smears silhouettes at range.")
        passFilter("ema-smooth", "EMA Smooth",
                   [.float("amount", 0...1, 0.3)],
                   "TDLidar temporal EMA: deadband hysteresis hold (zero static jitter) + velocity-adaptive alpha (motion never lags). 0 = raw sensor, 1 = statue. Without this node depth is raw.")
        passFilter("fill-holes", "Fill Holes",
                   [.bool("persist", true)],
                   "Dropout persistence: points keep their last good depth through sensor holes instead of blinking out (pinout: instead of retracting).")
        passFilter("accumulate", "Accumulate",
                   [.float("frames", 1...30, 8)],
                   "Blends ~FRAMES frames of depth into a denser, calmer cloud (temporal average; holes keep the accumulated depth). Higher = smoother but laggier on motion. Runs while the node exists — the wire passes depth through.")
        passFilter("smooth-surface", "Smooth Surface",
                   [.float("radius", 0...4, 1)],
                   "Bilateral surface smoothing: flattens sensor noise on surfaces WITHOUT bleeding across silhouette edges. RADIUS in pixels (0 = off). Runs while the node exists — the wire passes depth through.")
        passFilter("despeckle-voxel", "Despeckle Voxel",
                   [.float("size", 0...0.1, 0.02)],
                   "Removes isolated speckle returns: a point survives only with enough neighbours within SIZE metres of its depth. Kills floating dust around silhouettes. Runs while the node exists — the wire passes depth through.")
        passFilter("detail-upsample", "Detail Upsample",
                   [.float("factor", 1...4, 2)],
                   "Joint bilateral depth upsample (TDLidar JBU): depth is resampled at FACTOR× resolution with edges snapped to the RGB image, so silhouettes sharpen. Needs the camera color feed. Runs while the node exists — the wire passes depth through.")
    }

    // MARK: SHAPE

    private func registerShape() {
        register(NodeSpec(
            id: "size", name: "Size", family: .shape,
            inputs: [PortSpec("size", .fieldFloat, default: [1, 1, 1, 1])],
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("base", 0...4, 1), .float("min", 0...2, 0), .float("max", 0.1...6, 3)],
            execution: .interpreterOp,
            description: "Final size = base × input, clamped. Size 0 hides a pin.",
            emit: { b, inputs, node in
                let x = b.materialize(inputs[0], default: [1, 1, 1, 1])
                let s = b.reg()
                b.emitPatched(PinInstruction(.madd, dst: s, a: x, imm: [node.float("base", 1), 0, 0, 0]),
                              key: "\(node.id).base", lanes: [0])
                let c = b.reg()
                b.emitPatched(PinInstruction(.clampOp, dst: c, a: s,
                                             imm: [node.float("min", 0), node.float("max", 3), 0, 0]),
                              key: "\(node.id).clamp", lanes: [0, 1])
                b.addPatchKey("\(node.id).min", lane: 0)   // §13 per-param keys (base already keyed)
                b.addPatchKey("\(node.id).max", lane: 1)
                return [c]
            }))
    }

    // MARK: MOVE

    private func registerMove() {
        register(NodeSpec(
            id: "depth-drive", name: "Depth Drive", family: .move,
            inputs: [PortSpec("depth", .fieldFloat)],
            outputs: [PortSpec("z", .fieldFloat)],
            params: [.float("gain", 0...3, 1.2), .float("gamma", 0.25...4, 1)],
            execution: .interpreterOp,
            description: "Pulls pins off the wall toward the camera: z = depth^gamma × gain.",
            emit: { b, inputs, node in
                let d = b.materialize(inputs[0], default: .zero)
                let p = b.reg()
                b.emitPatched(PinInstruction(.powOp, dst: p, a: d, imm: [node.float("gamma", 1), 0, 0, 0]),
                              key: "\(node.id).gamma", lanes: [0])
                let z = b.reg()
                b.emitPatched(PinInstruction(.madd, dst: z, a: p, imm: [node.float("gain", 1.2), 0, 0, 0]),
                              key: "\(node.id).gain", lanes: [0])
                return [z]
            }))

        register(NodeSpec(
            id: "lag", name: "Lag", family: .move,
            inputs: [PortSpec("in", .fieldFloat)],
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("halfLife", 0...5, 0)],   // 0 = passthrough (effect off)
            statePerPin: 1, execution: .interpreterOp,
            description: "Exponential smoothing over time — one float of state per pin.",
            emit: { b, inputs, node in
                let x = b.materialize(inputs[0], default: .zero)
                let slot = b.allocState(1)
                let s = b.reg()
                b.emit(PinInstruction(.loadState, dst: s, imm: [Float(slot), 0, 0, 0]))
                let o = b.reg()
                // alpha patched per frame: 1 - exp(-dt/halfLife)
                b.emitPatched(PinInstruction(.mix, dst: o, a: s, b: x, imm: [0.3, 0, 0, 0]),
                              key: "\(node.id).alpha", lanes: [0])
                b.emit(PinInstruction(.storeState, a: o, imm: [Float(slot), 0, 0, 0]))
                return [o]
            }))

        register(NodeSpec(
            id: "trail", name: "Trail", family: .move,
            inputs: [PortSpec("in", .fieldFloat)],
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("decay", 0...10, 1.5)],   // 0 = instant decay (effect off)
            statePerPin: 1, execution: .interpreterOp,
            description: "Peak-hold with decay: rises instantly, falls slowly — glowing afterimages.",
            emit: { b, inputs, node in
                let x = b.materialize(inputs[0], default: .zero)
                let slot = b.allocState(1)
                let s = b.reg()
                b.emit(PinInstruction(.loadState, dst: s, imm: [Float(slot), 0, 0, 0]))
                let dec = b.reg()
                // decayStep patched per frame: value/decaySeconds * dt
                b.emitPatched(PinInstruction(.madd, dst: dec, a: s, imm: [1, -0.02, 0, 0]),
                              key: "\(node.id).step", lanes: [1])
                let o = b.reg()
                b.emit(PinInstruction(.maxOp, dst: o, a: dec, b: x))
                b.emit(PinInstruction(.storeState, a: o, imm: [Float(slot), 0, 0, 0]))
                return [o]
            }))

        register(NodeSpec(
            id: "radial-ripple", name: "Ripple", family: .move,
            inputs: [PortSpec("amplitude", .signal, default: [1, 1, 1, 1])],
            outputs: [PortSpec("height", .fieldFloat)],
            params: [.float("amp", 0...1, 0), .float("wavelength", 0.02...1, 0.15),
                     .float("speed", -4...4, 0.5), .float("falloff", 0...8, 2),
                     .float("centerX", 0...1, 0.5), .float("centerY", 0...1, 0.5)],
            execution: .interpreterOp,
            description: "Analytic rings radiating from CENTERX/CENTERY (0-1 view space) — pure per-pin math, zero state. Raise AMP (or wire a signal into amplitude) to see it; WAVELENGTH sizes the rings, SPEED travels them, FALLOFF fades them outward. Expose CENTERX/CENTERY and wire Hand Position to carry the ripple in your hand.",
            emit: { b, inputs, node in
                let uv = b.reg(); b.emit(PinInstruction(.loadUV, dst: uv))
                let d = b.reg()
                b.emitPatched(PinInstruction(.dist2, dst: d, a: uv,
                                             imm: [node.float("centerX", 0.5), node.float("centerY", 0.5), 0, 0]),
                              key: "\(node.id).center", lanes: [0, 1])
                b.addPatchKey("\(node.id).centerX", lane: 0)
                b.addPatchKey("\(node.id).centerY", lane: 1)
                let w = b.reg()
                // sin(d·k + phase)·0.5 + 0.5 — k from wavelength, phase patched per frame
                let k = 2 * Float.pi / max(node.float("wavelength", 0.15), 0.01)
                b.emitPatched(PinInstruction(.sinOp, dst: w, a: d, imm: [k, 0, 0.5, 0.5]),
                              key: "\(node.id).wave", lanes: [0, 1])
                // falloff: (1 - d·f/2) clamped, in place on d
                b.emitPatched(PinInstruction(.madd, dst: d, a: d, imm: [-node.float("falloff", 2) * 0.5, 1, 0, 0]),
                              key: "\(node.id).falloff", lanes: [0])
                b.emit(PinInstruction(.clampOp, dst: d, a: d, imm: [0, 1, 0, 0]))
                b.emit(PinInstruction(.mul, dst: w, a: w, b: d))
                // amplitude: wired input or the amp param
                let amp = inputs[0] >= 0 ? inputs[0]
                    : b.paramConstant("\(node.id).amp", SIMD4(repeating: node.float("amp", 0)))
                b.emit(PinInstruction(.mul, dst: w, a: w, b: amp))
                return [w]
            }))

        register(NodeSpec(
            id: "spring", name: "Spring", family: .move,
            inputs: [PortSpec("target", .fieldFloat)],
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("stiffness", 0...40, 0), .float("damping", 0...2, 0.7)],
            statePerPin: 2, execution: .interpreterOp,
            description: "Physically springs each pin toward its target with overshoot and wobble. Stiffness 0 = OFF (direct follow). Two floats of state per pin (position + velocity).",
            emit: { b, inputs, node in
                let target = b.materialize(inputs[0], default: .zero)
                // 0 stiffness = bypass entirely — pins follow the target with zero lag
                guard node.float("stiffness", 0) > 0.001 else { return [target] }
                let pSlot = b.allocState(1), vSlot = b.allocState(1)
                let pos = b.reg(), vel = b.reg(), d = b.reg()
                b.emit(PinInstruction(.loadState, dst: pos, imm: [Float(pSlot), 0, 0, 0]))
                b.emit(PinInstruction(.loadState, dst: vel, imm: [Float(vSlot), 0, 0, 0]))
                b.emit(PinInstruction(.sub, dst: d, a: target, b: pos))
                b.emitPatched(PinInstruction(.madd, dst: d, a: d, imm: [0.2, 0, 0, 0]),
                              key: "\(node.id).kdt", lanes: [0])          // d *= k·dt
                b.emit(PinInstruction(.add, dst: vel, a: vel, b: d))
                b.emitPatched(PinInstruction(.madd, dst: vel, a: vel, imm: [0.9, 0, 0, 0]),
                              key: "\(node.id).dmp", lanes: [0])          // vel *= exp(-c·dt)
                b.emitPatched(PinInstruction(.madd, dst: d, a: vel, imm: [1.0 / 60, 0, 0, 0]),
                              key: "\(node.id).vdt", lanes: [0])          // d = vel·dt
                b.emit(PinInstruction(.add, dst: pos, a: pos, b: d))
                b.emit(PinInstruction(.storeState, a: pos, imm: [Float(pSlot), 0, 0, 0]))
                b.emit(PinInstruction(.storeState, a: vel, imm: [Float(vSlot), 0, 0, 0]))
                return [pos]
            }))

        register(NodeSpec(
            id: "scatter", name: "Scatter", family: .move,
            inputs: [PortSpec("amount", .fieldFloat)],
            outputs: [PortSpec("offset", .fieldVec3)],
            params: [.float("amount", 0...1, 0), .float("seed", 0...9999, 3)],
            execution: .interpreterOp,
            description: "Throws each pin along its own seeded random direction. Amount 0 returns every pin exactly home — stateless.",
            emit: { b, inputs, node in
                let dir = b.reg()
                b.emitPatched(PinInstruction(.hash3, dst: dir, imm: [node.float("seed", 3), 0, 0, 0]),
                              key: "\(node.id).seed", lanes: [0])
                let amt = inputs[0] >= 0 ? inputs[0]
                    : b.paramConstant("\(node.id).amount", SIMD4(repeating: node.float("amount", 0)))
                b.emit(PinInstruction(.mul, dst: dir, a: dir, b: amt))
                return [dir]
            }))

        register(NodeSpec(
            id: "twist", name: "Twist", family: .move,
            inputs: [PortSpec("angle", .fieldFloat)],
            outputs: [PortSpec("offset", .fieldVec3)],
            params: [.float("angle", -0.5...0.5, 0), .float("falloff", 0...4, 0.8)],
            execution: .interpreterOp,
            description: "Whirlpools pin positions around the view center; angle in turns, falloff by radius.",
            emit: { b, inputs, node in
                let ang = inputs[0] >= 0 ? inputs[0]
                    : b.paramConstant("\(node.id).angle", SIMD4(repeating: node.float("angle", 0)))
                let o = b.reg()
                b.emitPatched(PinInstruction(.twistOp, dst: o, a: ang,
                                             imm: [0, 0, node.float("falloff", 0.8), 0]),
                              key: "\(node.id).cf", lanes: [0, 1, 2])
                return [o]
            }))

        register(NodeSpec(
            id: "shockwave", name: "Shockwave", family: .move,
            inputs: [PortSpec("fire", .trigger)],
            outputs: [PortSpec("pulse", .fieldFloat)],
            params: [.float("speed", 0...4, 1.2), .float("width", 0...0.6, 0.12),
                     .float("damping", 0...6, 1.2)],
            execution: .interpreterOp,
            description: "Expanding rings fired by triggers (up to 4 alive) — analytic, zero per-pin state.",
            emit: { b, _, node in
                let r = b.reg()
                b.emitPatched(PinInstruction(.shockwave, dst: r,
                                             imm: [node.float("speed", 1.2), node.float("width", 0.12),
                                                   node.float("damping", 1.2), 0]),
                              key: "\(node.id).wave", lanes: [0, 1, 2])
                return [r]
            }))

        register(NodeSpec(
            id: "freeze", name: "Freeze", family: .move,
            inputs: [PortSpec("in", .fieldFloat)],
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("hold", 0...1, 0)],
            statePerPin: 1, execution: .interpreterOp,
            description: "While hold is up, each pin keeps its captured value; release melts back to live.",
            emit: { b, inputs, node in
                let live = b.materialize(inputs[0], default: .zero)
                let slot = b.allocState(1)
                let s = b.reg(), o = b.reg()
                b.emit(PinInstruction(.loadState, dst: s, imm: [Float(slot), 0, 0, 0]))
                // out = mix(live, held, hold) — hold patched live (no recompile on pad press)
                b.emitPatched(PinInstruction(.mix, dst: o, a: live, b: s,
                                             imm: [node.float("hold", 0), 0, 0, 0]),
                              key: "\(node.id).hold", lanes: [0])
                b.emit(PinInstruction(.storeState, a: o, imm: [Float(slot), 0, 0, 0]))
                return [o]
            }))
    }

    // MARK: COLOR

    private func registerColor() {
        register(NodeSpec(
            id: "palette", name: "Palette", family: .color,
            inputs: [PortSpec("t", .fieldFloat, default: [0.5, 0.5, 0.5, 0.5])],
            outputs: [PortSpec("color", .fieldColor)],
            params: [.option("map", PaletteLUT.names, "thermal"), .float("shift", -1...1, 0)],
            execution: .interpreterOp,
            description: "Maps any 0-1 field through a colormap.",
            emit: { b, inputs, node in
                let t = b.materialize(inputs[0], default: [0.5, 0.5, 0.5, 0.5])
                let r = b.reg()
                let row = Float(PaletteLUT.names.firstIndex(of: node.option("map", "thermal")) ?? 0)
                b.emitPatched(PinInstruction(.palette, dst: r, a: t,
                                             imm: [0, row, node.float("shift"), 0]),
                              key: "\(node.id).map", lanes: [1, 2])
                return [r]
            }))
    }

    // MARK: SIGNAL — math (field-rate; control versions come with the control graph)

    private func registerSignalMath() {
        func binary(_ id: String, _ name: String, _ op: PinOp) {
            register(NodeSpec(
                id: id, name: name, family: .signal,
                inputs: [PortSpec("a", .fieldFloat), PortSpec("b", .fieldFloat)],
                outputs: [PortSpec("out", .fieldFloat)],
                execution: .interpreterOp,
                emit: { b, inputs, _ in
                    let x = b.materialize(inputs[0], default: .zero)
                    let y = b.materialize(inputs[1], default: .zero)
                    let r = b.reg()
                    b.emit(PinInstruction(op, dst: r, a: x, b: y))
                    return [r]
                }))
        }
        binary("add", "Add", .add)
        binary("subtract", "Subtract", .sub)
        binary("multiply", "Multiply", .mul)
        binary("divide", "Divide", .div)
        binary("min", "Min", .minOp)
        binary("max", "Max", .maxOp)

        register(NodeSpec(
            id: "mix", name: "Mix", family: .signal,
            inputs: [PortSpec("a", .fieldFloat), PortSpec("b", .fieldFloat)],
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("t", 0...1, 0.5)],
            execution: .interpreterOp,
            emit: { b, inputs, node in
                let x = b.materialize(inputs[0], default: .zero)
                let y = b.materialize(inputs[1], default: .zero)
                let r = b.reg()
                b.emitPatched(PinInstruction(.mix, dst: r, a: x, b: y, imm: [node.float("t", 0.5), 0, 0, 0]),
                              key: "\(node.id).t", lanes: [0])
                return [r]
            }))

        register(NodeSpec(
            id: "clamp", name: "Clamp", family: .signal,
            inputs: [PortSpec("in", .fieldFloat)],
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("min", -4...4, 0), .float("max", -4...4, 1)],
            execution: .interpreterOp,
            emit: { b, inputs, node in
                let x = b.materialize(inputs[0], default: .zero)
                let r = b.reg()
                b.emitPatched(PinInstruction(.clampOp, dst: r, a: x,
                                             imm: [node.float("min"), node.float("max", 1), 0, 0]),
                              key: "\(node.id).range", lanes: [0, 1])
                return [r]
            }))

        register(NodeSpec(
            id: "remap", name: "Remap", family: .signal,
            inputs: [PortSpec("in", .fieldFloat)],
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("inMin", -4...4, 0), .float("inMax", -4...4, 1),
                     .float("outMin", -4...4, 0), .float("outMax", -4...4, 1)],
            execution: .interpreterOp,
            emit: { b, inputs, node in
                let x = b.materialize(inputs[0], default: .zero)
                let r = b.reg()
                b.emitPatched(PinInstruction(.remap, dst: r, a: x,
                                             imm: [node.float("inMin"), node.float("inMax", 1),
                                                   node.float("outMin"), node.float("outMax", 1)]),
                              key: "\(node.id).range", lanes: [0, 1, 2, 3])
                return [r]
            }))

        register(NodeSpec(
            id: "abs", name: "Abs", family: .signal,
            inputs: [PortSpec("in", .fieldFloat)], outputs: [PortSpec("out", .fieldFloat)],
            execution: .interpreterOp,
            emit: { b, inputs, _ in
                let x = b.materialize(inputs[0], default: .zero)
                let r = b.reg(); b.emit(PinInstruction(.absOp, dst: r, a: x)); return [r]
            }))

        register(NodeSpec(
            id: "sine", name: "Sine", family: .signal,
            inputs: [PortSpec("in", .fieldFloat)], outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("frequency", 0...40, 6), .float("phase", -6.283...6.283, 0)],
            execution: .interpreterOp,
            description: "sin(in × freq + phase), 0-1 normalized.",
            emit: { b, inputs, node in
                let x = b.materialize(inputs[0], default: .zero)
                let r = b.reg()
                b.emitPatched(PinInstruction(.sinOp, dst: r, a: x,
                                             imm: [node.float("frequency", 6), node.float("phase"), 0.5, 0.5]),
                              key: "\(node.id).wave", lanes: [0, 1])
                return [r]
            }))

        register(NodeSpec(
            id: "smoothstep", name: "Smoothstep", family: .signal,
            inputs: [PortSpec("in", .fieldFloat)], outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("edge0", -2...2, 0), .float("edge1", -2...2, 1)],
            execution: .interpreterOp,
            emit: { b, inputs, node in
                let x = b.materialize(inputs[0], default: .zero)
                let r = b.reg()
                b.emitPatched(PinInstruction(.smooth, dst: r, a: x,
                                             imm: [node.float("edge0"), node.float("edge1", 1), 0, 0]),
                              key: "\(node.id).edges", lanes: [0, 1])
                return [r]
            }))

        register(NodeSpec(
            id: "threshold", name: "Threshold", family: .signal,
            inputs: [PortSpec("in", .fieldFloat)], outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("level", 0...1, 0.5)],
            execution: .interpreterOp,
            emit: { b, inputs, node in
                let x = b.materialize(inputs[0], default: .zero)
                let r = b.reg()
                b.emitPatched(PinInstruction(.stepOp, dst: r, a: x, imm: [node.float("level", 0.5), 0, 0, 0]),
                              key: "\(node.id).level", lanes: [0])
                return [r]
            }))

        register(NodeSpec(
            id: "constant", name: "Constant", family: .signal,
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("value", -4...4, 1)],
            execution: .interpreterOp,
            emit: { b, _, node in
                let v = node.float("value", 1)
                return [b.paramConstant("\(node.id).value", [v, v, v, v])]
            },
            controlEval: { node, _, _ in
                let v = node.float("value", 1)
                return [[v, v, v, v]]
            }))

        register(NodeSpec(
            id: "random", name: "Random", family: .signal,
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("seed", 0...9999, 1),
                     .float("contrast", 0.25...4, 1),   // >1 biases toward 0, <1 toward 1 (gamma on the noise)
                     .float("amount", 0...1, 1)],        // spread of the randomness around 0.5 (0 = flat 0.5)
            execution: .interpreterOp,
            description: "Stable per-pin random 0-1 — same every frame until reseeded. CONTRAST shapes the distribution, AMOUNT dials how far it spreads from 0.5. Seed sweeps the whole field (0-9999).",
            emit: { b, _, node in
                let idx = b.reg(); b.emit(PinInstruction(.loadIndex, dst: idx))
                let r = b.reg()
                b.emitPatched(PinInstruction(.hash1, dst: r, a: idx, imm: [1, node.float("seed", 1), 0, 0]),
                              key: "\(node.id).seed", lanes: [1])
                let c = node.float("contrast", 1)
                if abs(c - 1) > 1e-4 {
                    b.emit(PinInstruction(.powOp, dst: r, a: r, imm: [c, 0, 0, 0]))
                }
                let a = node.float("amount", 1)
                if abs(a - 1) > 1e-4 {   // r = (r - 0.5)*a + 0.5  →  madd a·r + (0.5 - 0.5a)
                    b.emit(PinInstruction(.madd, dst: r, a: r, imm: [a, 0.5 - 0.5 * a, 0, 0]))
                }
                return [r]
            }))
    }

    // MARK: SIGNAL — modulate (control-rate)

    private func registerModulate() {
        register(NodeSpec(
            id: "lfo", name: "LFO", family: .signal,
            outputs: [PortSpec("out", .signal)],
            params: [.float("rate", 0...20, 0.5),
                     .option("shape", ["sine", "triangle", "square", "saw"], "sine"),
                     .float("depth", 0...1, 1), .float("offset", -1...1, 0)],
            execution: .control,
            description: "A free-running oscillator, 0-1.",
            controlEval: { node, _, ctx in
                let phase = (ctx.time * node.float("rate", 0.5)).truncatingRemainder(dividingBy: 1)
                let p = phase < 0 ? phase + 1 : phase
                let raw: Float
                switch node.option("shape", "sine") {
                case "triangle": raw = p < 0.5 ? p * 2 : 2 - p * 2
                case "square": raw = p < 0.5 ? 1 : 0
                case "saw": raw = p
                default: raw = 0.5 + 0.5 * sin(p * 2 * .pi)
                }
                let v = raw * node.float("depth", 1) + node.float("offset")
                return [[v, v, v, v]]
            }))
    }

    // MARK: BODY / TOUCH

    private func registerTouch() {
        register(NodeSpec(
            id: "touch", name: "Touch", family: .body,
            outputs: [PortSpec("x", .signal), PortSpec("y", .signal), PortSpec("pressed", .signal)],
            execution: .control,
            description: "Finger on the viewport: x/y 0-1 (top-left origin) and pressed 0/1.",
            controlEval: { _, _, ctx in
                [SIMD4(repeating: ctx.touch.x),
                 SIMD4(repeating: ctx.touch.y),
                 SIMD4(repeating: ctx.touch.z)]
            }))
    }

    // MARK: TIME

    private func registerTime() {
        register(NodeSpec(
            id: "transport", name: "Transport", family: .time,
            outputs: [PortSpec("time", .signal), PortSpec("beat", .signal)],
            execution: .control,
            description: "Patch clock: seconds since start + beat phase from the global BPM.",
            controlEval: { _, _, ctx in
                [[ctx.time, ctx.time, ctx.time, ctx.time],
                 [ctx.beatPhase, ctx.beatPhase, ctx.beatPhase, ctx.beatPhase]]
            }))
    }

    // MARK: STAGE

    private func registerStage() {
        register(NodeSpec(
            id: "camera", name: "Camera", family: .stage,
            params: [.float("fov", 15...110, 55), .float("zoom", 0.5...2, 1),
                     .float("parallax", 0...1, 0.5), .float("depthPush", 0...3, 1),
                     .float("centerX", -1...1, 0), .float("centerY", -1...1, 0),
                     .float("orbitX", -0.9...0.9, 0), .float("orbitY", -0.9...0.9, 0)],
            execution: .render,
            description: "The camera, always orbiting the middle of the cloud so the 3D pins warp around that centre. FOV flat↔wide, ZOOM frames the cloud, PARALLAX dials perspective warp, DEPTH PUSH exaggerates how far pins travel, CENTRE nudges the pivot, ORBIT steps the view angle (joystick). Read straight by the renderer — not part of the per-pin chain."))

        register(NodeSpec(
            id: "output", name: "Output", family: .stage,
            inputs: [PortSpec("position", .fieldVec3),
                     PortSpec("z", .fieldFloat),
                     PortSpec("size", .fieldFloat),
                     PortSpec("color", .fieldColor),
                     PortSpec("rotation", .fieldVec3),
                     PortSpec("shape", .fieldFloat),
                     PortSpec("stretch", .fieldVec3, default: [1, 1, 1, 0])],
            outputs: [PortSpec("image", .source)],   // the composited frame — tap for NDI / Record
            execution: .render,
            description: "The render sink: position offset, wall Z, size, colour, plus per-pin rotation (turns), shape morph (0 sphere → 1 cube) and stretch (per-axis scale). Its IMAGE output is the finished frame — wire it to an NDI or Record node to stream/capture.",
            emit: { b, inputs, _ in
                if inputs[0] >= 0 { b.emit(PinInstruction(.writePos, a: inputs[0])) }
                if inputs[1] >= 0 { b.emit(PinInstruction(.writeZ, a: inputs[1])) }
                if inputs[2] >= 0 { b.emit(PinInstruction(.writeSize, a: inputs[2])) }
                if inputs[3] >= 0 { b.emit(PinInstruction(.writeColor, a: inputs[3])) }
                if inputs[4] >= 0 { b.emit(PinInstruction(.writeRot, a: inputs[4])) }
                if inputs[5] >= 0 { b.emit(PinInstruction(.writeShape, a: inputs[5])) }
                if inputs[6] >= 0 { b.emit(PinInstruction(.writeStretch, a: inputs[6])) }
                return [0]
            }))

        // NDI network output — a global sink downstream of Output. Presence + params drive the
        // renderer's NDI pass (not part of the per-pin chain, like Camera). All-option params so
        // they render as segments in the node settings bar.
        register(NodeSpec(
            id: "ndi-out", name: "NDI Out", family: .output,
            inputs: [PortSpec("image", .source)],
            params: [.option("stream", ["STOP", "START"], "STOP"),
                     .option("name", ["Points", "Points1", "Points2", "Points3", "Points4",
                                      "Points5", "Points6", "Points7", "Points8", "Points9"], "Points"),
                     .option("resolution",
                             ["810x1080", "945x1260", "1080x1440", "1350x1800", "1620x2160"], "1080x1440"),
                     .option("orientation", ["3:4", "4:3"], "3:4"),
                     .option("alpha", ["OFF", "ON"], "OFF"),
                     .option("fps", ["30", "60"], "30"),
                     .option("wired", ["OFF", "ON"], "OFF")],
            execution: .render,
            description: "Streams the finished render as an NDI® source named \"Points\" on the local network (OBS, TouchDesigner, NDI Studio Monitor). RESOLUTION + ORIENTATION set the frame; ALPHA keys out the background; FPS caps the rate; WIRED hints a USB-tether. Wire Output.image → here, or hit the NDI button in the menu."))

        // Record — an image sink, like NDI. Takes ONE image wire, no output. Wire it from
        // Output.image (or any node that outputs an image) so it can capture at different points
        // in a multi-output network. Presence + RECORD=ON drive the renderer's capture pass.
        register(NodeSpec(
            id: "record", name: "Record", family: .output,
            inputs: [PortSpec("image", .source)],
            params: [.option("record", ["STOP", "START"], "STOP"),
                     .option("resolution",
                             ["810x1080", "1080x1440", "1350x1800", "1620x2160", "2160x2880"], "1080x1440"),
                     .option("orientation", ["3:4", "4:3"], "3:4"),
                     .option("alpha", ["OFF", "ON"], "OFF"),
                     .option("fps", ["30", "60"], "60")],
            execution: .render,
            description: "Records the finished render to a video and saves it to Photos. RESOLUTION + ORIENTATION set the frame; ALPHA records a transparent background (HEVC-with-alpha); FPS sets the capture rate. Wire Output.image → here (one Record node per patch — the first one wins). RECORD=START begins, STOP saves."))
    }
}

// MARK: - Palette LUT data (generated rows, sampled by the `palette` op)

nonisolated enum PaletteLUT {
    static let names = ["thermal", "ice", "fire", "ocean", "neon", "mono", "candy", "forest"]

    /// 8 rows × 256 RGBA8 — simple multi-stop gradients per row.
    static func generate() -> [UInt8] {
        let stops: [[SIMD3<Float>]] = [
            [[0.05, 0.03, 0.25], [0.45, 0.0, 0.5], [0.9, 0.25, 0.1], [1.0, 0.85, 0.2], [1, 1, 1]],   // thermal
            [[0.0, 0.02, 0.1], [0.05, 0.25, 0.5], [0.3, 0.65, 0.9], [0.8, 0.95, 1.0]],               // ice
            [[0.02, 0, 0], [0.45, 0.02, 0], [0.9, 0.35, 0.02], [1, 0.8, 0.3], [1, 1, 0.85]],         // fire
            [[0.0, 0.05, 0.12], [0.0, 0.25, 0.35], [0.1, 0.55, 0.6], [0.55, 0.9, 0.85]],             // ocean
            [[0.15, 0, 0.35], [0.7, 0, 0.9], [0.2, 0.6, 1], [0.2, 1, 0.9]],                          // neon
            [[0.02, 0.02, 0.02], [0.5, 0.5, 0.5], [1, 1, 1]],                                        // mono
            [[0.9, 0.3, 0.5], [1, 0.7, 0.4], [0.7, 0.9, 1], [0.9, 0.6, 1]],                          // candy
            [[0.02, 0.08, 0.03], [0.1, 0.35, 0.12], [0.45, 0.7, 0.25], [0.9, 0.95, 0.6]],            // forest
        ]
        var data = [UInt8]()
        data.reserveCapacity(stops.count * 256 * 4)
        for row in stops {
            for i in 0..<256 {
                let t = Float(i) / 255 * Float(row.count - 1)
                let lo = min(Int(t), row.count - 2)
                let c = simd_mix(row[lo], row[lo + 1], SIMD3(repeating: t - Float(lo)))
                data.append(UInt8(max(0, min(255, c.x * 255))))
                data.append(UInt8(max(0, min(255, c.y * 255))))
                data.append(UInt8(max(0, min(255, c.z * 255))))
                data.append(255)
            }
        }
        return data
    }
}
