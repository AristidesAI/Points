import Foundation
import QuartzCore
import Observation
import simd

/// Camera node → renderer. The renderer builds viewProj + world Z scale from this.
struct CameraFrame {
    var fov: Float = 55        // degrees; low = flat, high = wide/warpy
    var zoom: Float = 1        // frames the pinout tighter/wider
    var parallax: Float = 0.5  // 0 = weak perspective, 1 = strong warp around centre
    var depthPush: Float = 1   // world-space Z exaggeration (zWorldScale)
    var centerX: Float = 0     // pivot offset (view units)
    var centerY: Float = 0
    var orbitX: Float = 0      // yaw around the pivot (radians) — joystick
    var orbitY: Float = 0      // pitch around the pivot (radians)
}

/// One frame's program snapshot handed to the renderer.
struct ProgramFrame {
    var instructions: [PinInstruction]
    var stateStride: Int
    var generation: Int
    var time: Float
    var beatPhase: Float
    var dt: Float
    var waveT: SIMD4<Float> = SIMD4(repeating: -1e6)
    var waveCA: SIMD4<Float> = .zero
    var waveCB: SIMD4<Float> = .zero
    var camera = CameraFrame()
    var depthStabilize: Float = 0     // EMA Smooth node amount (no node = raw depth)
    var holePersist = false           // Fill Holes node present + on
    var stems = false                 // Point Display "arms" — pull points back to their Z pins
}

/// Owns the live graph: compiles it to a pin program, evaluates control-rate nodes,
/// and patches dynamic immediate lanes per frame. Param edits recompile (µs at MVP
/// graph sizes) and publish next frame; state layout is stable across edits so
/// spring/lag/trail/freeze memory survives slider drags.
///
/// Structural edits (editor + pads) mutate the CURRENT graph incrementally — user
/// wiring is never thrown away. Every structural edit and each slider gesture pushes
/// an undo snapshot (graph is a value type: snapshot = copy).
@Observable
final class GraphRuntime {
    enum ColorMode: String { case none, video, palette }

    private(set) var graph: Graph
    private(set) var compileError: String?
    private(set) var generation = 0
    var bpm: Float = 120

    // Feature flags (pads / menu) — incremental graph edits, not rebuilds.
    private(set) var colorMode: ColorMode = .none
    private(set) var strobeOn = false
    private(set) var invertOn = false

    private let registry = NodeRegistry.shared
    private var compiled: CompiledPinProgram = .empty
    private var workingInstructions: [PinInstruction] = [PinInstruction(.halt)]

    // Undo/redo — whole-graph snapshots (Graph is Codable + value semantics).
    private var undoStack: [Graph] = []
    private var redoStack: [Graph] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private enum DynamicKind {
        case lagAlpha, trailStep, rippleWave, springKdt, springDmp, springVdt, freezeHold
        case controlPort(String)
    }
    private var dynamicKeys: [(key: String, nodeID: String, kind: DynamicKind)] = []

    // Shockwave ring (4 waves) — times in the frameProgram clock.
    private var waveBirths: [(t: Float, c: SIMD2<Float>)] = []

    // Touch (viewport finger) — feeds the Touch control node.
    private var touchValue: SIMD4<Float> = .zero

    // Live mic bands/onsets, supplied by ContentView's AudioEngine while an audio node exists.
    @ObservationIgnored var audioSource: (@Sendable () -> (bands: SIMD4<Float>, onsets: SIMD4<Float>))?
    private static let audioIDs: Set<String> = ["audio-levels", "beat-trigger", "fft-band", "audio-rms", "burst"]
    var usesAudioNodes: Bool { graph.nodes.contains { Self.audioIDs.contains($0.specID) } }

    // Live body/hand tracking (Vision), supplied by ContentView while a body node exists.
    @ObservationIgnored var bodySource: (@Sendable () -> (bodyA: SIMD4<Float>, bodyB: SIMD4<Float>, gestures: SIMD4<Float>, present: SIMD4<Float>))?
    private static let bodyFamily: Set<String> = ["hand-position", "pinch-amount", "hand-openness",
        "head-pose", "hand-gesture", "person-present", "joint", "body-region", "face-region"]
    var usesBodyNodes: Bool { graph.nodes.contains { Self.bodyFamily.contains($0.specID) } }

    // Control-graph evaluation: topo order over control nodes, per-frame value memo,
    // and persistent per-node state (envelopes/counters/S&H).
    private var controlOrder: [GraphNode] = []
    private var controlValues: [String: SIMD4<Float>] = [:]   // "nodeID.port" → value
    private var controlState: [String: SIMD4<Float>] = [:]

    private let startTime = CACurrentMediaTime()
    private var lastTime: CFTimeInterval
    private var nextNodeNumber = 1

    init() {
        graph = Graph()
        lastTime = startTime
        graph = Self.defaultGraph()
        recompile()
    }

    // MARK: - The default patch — THE SIMPLEST possible network, zero preset effects.
    //
    //  cam Camera (render-read)
    //  d1 Depth → pd PointDisplay → out.position / out.z
    //  sz Size → out.size
    //
    //  Everything else (freeze, shockwave, cleanup, color…) is added by the user —
    //  or auto-inserted the first time a pad/tap needs it.

    private static func defaultGraph() -> Graph {
        var g = Graph()
        func n(_ id: String, _ spec: String, _ x: Float, _ y: Float,
               _ params: [String: ParamValue] = [:]) -> GraphNode {
            var node = GraphNode(id: id, specID: spec, params: params)
            node.position = [x, y]
            return node
        }
        g.nodes = [
            n("cam", "camera", 40, 40),
            n("d1", "depth", 40, 280),
            n("pd", "point-display", 330, 160),
            n("sz", "size", 330, 480),
            n("out", "output", 620, 280),
        ]
        g.wires = [
            Wire(fromNode: "d1", fromPort: "depth", toNode: "pd", toPort: "depth"),
            Wire(fromNode: "pd", fromPort: "position", toNode: "out", toPort: "position"),
            Wire(fromNode: "pd", fromPort: "z", toNode: "out", toPort: "z"),
            Wire(fromNode: "sz", fromPort: "out", toNode: "out", toPort: "size"),
        ]
        return g
    }

    /// Load a browser template as a REAL, distinct graph (default + a small verified add-on).
    /// Validates first — a bad template can never crash, it just falls back to the default.
    func loadTemplate(_ name: String) {
        var g = Self.defaultGraph()
        func node(_ id: String, _ spec: String, _ x: Float, _ y: Float, _ p: [String: ParamValue] = [:]) {
            var nd = GraphNode(id: id, specID: spec, params: p); nd.position = [x, y]; g.nodes.append(nd)
        }
        func wire(_ fn: String, _ fp: String, _ tn: String, _ tp: String) {
            g.wires.removeAll { $0.toNode == tn && $0.toPort == tp }   // one wire per input
            g.wires.append(Wire(fromNode: fn, fromPort: fp, toNode: tn, toPort: tp))
        }
        switch name {
        case "Comet Trails":                                   // peak-hold afterimages on Z
            node("tr", "trail", 470, 300, ["decay": .float(3)])
            wire("pd", "z", "tr", "in"); wire("tr", "out", "out", "z")
        case "Arm Fire":                                       // stems ON + fire palette by depth
            if let i = g.nodes.firstIndex(where: { $0.id == "pd" }) { g.nodes[i].params["arms"] = .bool(true) }
            node("pl", "palette", 470, 60, ["map": .option("fire")])
            wire("pd", "z", "pl", "t"); wire("pl", "color", "out", "color")
        case "Beat Strobe":                                    // 8 Hz square LFO → size
            node("lf", "lfo", 90, 560, ["rate": .float(8), "shape": .option("square")])
            wire("lf", "out", "sz", "size")
        case "Kick Shatter":                                   // depth-driven scatter of the grid
            node("sc", "scatter", 470, 380, ["amount": .float(0.5), "seed": .float(5)])
            wire("pd", "z", "sc", "amount"); wire("sc", "offset", "out", "position")
        default:                                               // "Pure Pins" / unknown → default
            break
        }
        if (try? g.validate(registry: registry)) != nil {
            graph = g
        }
        recompile()
    }

    // MARK: - Param edits

    /// Slider path: apply + recompile (state layout is stable → memory survives).
    func setParam(_ nodeID: String, _ name: String, _ value: Float) {
        guard graph.node(nodeID) != nil else { return }
        graph.setParam(nodeID, name, .float(value))
        recompile()
    }

    /// Option/segment path (e.g. Point Display FREE ↔ PINOUT).
    func setOption(_ nodeID: String, _ name: String, _ value: String) {
        guard graph.node(nodeID) != nil else { return }
        pushUndo()
        graph.setParam(nodeID, name, .option(value))
        // Switching Point Display mode reshapes the whole look: PINOUT = flat/locked/telephoto,
        // FREE = the registry cloud defaults. (One undo step covers the preset.)
        if graph.node(nodeID)?.specID == "point-display", name == "mode" {
            applyDisplayMode(nodeID, value)
        }
        recompile()
    }

    private func applyDisplayMode(_ pdID: String, _ mode: String) {
        func p(_ id: String, _ k: String, _ v: Float) { graph.setParam(id, k, .float(v)) }
        let hasCam = graph.node("cam") != nil
        if mode == "pinout" {
            p(pdID, "separation", 0.5); p(pdID, "volume", 0); p(pdID, "wobble", 0)
            p(pdID, "gain", 0.34); p(pdID, "focus", 1); p(pdID, "gamma", 1); p(pdID, "zFlatten", 1)
            if hasCam {
                p("cam", "fov", 15); p("cam", "zoom", 2); p("cam", "parallax", 1); p("cam", "depthPush", 3)
                p("cam", "centerX", 0); p("cam", "centerY", 0); p("cam", "orbitX", 0); p("cam", "orbitY", 0)
            }
        } else {   // free = registry defaults
            p(pdID, "separation", 1); p(pdID, "volume", 0); p(pdID, "wobble", 0)
            p(pdID, "gain", 1.2); p(pdID, "focus", 1); p(pdID, "gamma", 1); p(pdID, "zFlatten", 1)
            if hasCam {
                p("cam", "fov", 55); p("cam", "zoom", 1); p("cam", "parallax", 0.5); p("cam", "depthPush", 1)
                p("cam", "centerX", 0); p("cam", "centerY", 0); p("cam", "orbitX", 0); p("cam", "orbitY", 0)
            }
        }
    }

    func setBool(_ nodeID: String, _ name: String, _ value: Bool) {
        guard graph.node(nodeID) != nil else { return }
        graph.setParam(nodeID, name, .bool(value))
        recompile()
    }

    /// Live path for dynamic lanes (freeze hold): no recompile at all.
    func setParamLive(_ nodeID: String, _ name: String, _ value: Float) {
        graph.setParam(nodeID, name, .float(value))
    }

    func nodeParam(_ nodeID: String, _ name: String, _ fallback: Float) -> Float {
        graph.node(nodeID)?.float(name, fallback) ?? fallback
    }

    func nodeOption(_ nodeID: String, _ name: String, _ fallback: String) -> String {
        graph.node(nodeID)?.option(name, fallback) ?? fallback
    }

    // MARK: - Pads (incremental graph edits — user wiring survives)

    func setStrobe(_ on: Bool) {
        strobeOn = on
        if on, graph.node("lf") == nil, let sz = graph.nodes.first(where: { $0.id == "sz" }) {
            var lf = GraphNode(id: "lf", specID: "lfo",
                               params: ["rate": .float(8), "shape": .option("square")])
            lf.position = sz.position + [-250, 60]
            graph.nodes.append(lf)
            graph.wires.append(Wire(fromNode: "lf", fromPort: "out", toNode: "sz", toPort: "size"))
        } else if !on {
            removeNodeInternal("lf")
        }
        recompile()
    }

    func setInvert(_ on: Bool) {
        invertOn = on
        guard graph.node("d1") != nil else { return }
        graph.setParam("d1", "invert", .bool(on))
        recompile()
    }

    func setColorMode(_ mode: ColorMode) {
        guard mode != colorMode else { return }
        colorMode = mode
        removeNodeInternal("vc")
        removeNodeInternal("pal")
        let outPos = graph.node("out")?.position ?? [790, 380]
        switch mode {
        case .video:
            var vc = GraphNode(id: "vc", specID: "video-color", params: [:])
            vc.position = outPos + [0, 220]
            graph.nodes.append(vc)
            graph.wires.append(Wire(fromNode: "vc", fromPort: "color", toNode: "out", toPort: "color"))
        case .palette:
            // shift -0.25 pulls the map off its white tip: closest = red-hot, TDLidar thermal look
            var pal = GraphNode(id: "pal", specID: "palette", params: ["shift": .float(-0.25)])
            pal.position = outPos + [0, 220]
            graph.nodes.append(pal)
            if graph.node("d1") != nil {
                graph.wires.append(Wire(fromNode: "d1", fromPort: "depth", toNode: "pal", toPort: "t"))
            }
            graph.wires.append(Wire(fromNode: "pal", fromPort: "color", toNode: "out", toPort: "color"))
        case .none:
            break
        }
        recompile()
    }

    func setFreezeHold(_ on: Bool) {
        if on {
            let inserted = ensureFreeze()
            if inserted {
                // let one frame seed the freeze state from live before holding
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                    self?.setParamLive("fz", "hold", 1)
                }
            } else {
                setParamLive("fz", "hold", 1)
            }
        } else {
            setParamLive("fz", "hold", 0)
        }
    }

    func fireShockwave(center: SIMD2<Float>) {
        ensureShockwave()   // the minimal default patch has no shockwave until first use
        let t = Float(CACurrentMediaTime() - startTime)
        waveBirths.append((t, center))
        if waveBirths.count > 4 { waveBirths.removeFirst(waveBirths.count - 4) }
    }

    /// The wire currently feeding out.z (whatever the user has built).
    private func zFeed() -> Wire? { graph.wireInto("out", "z") }

    /// Insert a Freeze node in-line on the out.z feed. Returns true if it was created now.
    @discardableResult
    private func ensureFreeze() -> Bool {
        guard graph.node("fz") == nil else { return false }
        pushUndo()
        var fz = GraphNode(id: "fz", specID: "freeze", params: [:])
        let outPos = graph.node("out")?.position ?? [620, 280]
        fz.position = outPos + [-220, -160]
        graph.nodes.append(fz)
        if let w = zFeed() {
            graph.wires.removeAll { $0 == w }
            graph.wires.append(Wire(fromNode: w.fromNode, fromPort: w.fromPort, toNode: "fz", toPort: "in"))
        }
        graph.wires.append(Wire(fromNode: "fz", fromPort: "out", toNode: "out", toPort: "z"))
        recompile()
        return true
    }

    /// Insert Shockwave + an Add summing it into the out.z feed (first 💥 / viewport tap).
    private func ensureShockwave() {
        guard graph.node("sw") == nil else { return }
        pushUndo()
        let outPos = graph.node("out")?.position ?? [620, 280]
        var sw = GraphNode(id: "sw", specID: "shockwave", params: [:])
        sw.position = outPos + [-220, 180]
        graph.nodes.append(sw)
        if let w = zFeed() {
            var adder = GraphNode(id: "swa", specID: "add", params: [:])
            adder.position = outPos + [-110, 40]
            graph.nodes.append(adder)
            graph.wires.removeAll { $0 == w }
            graph.wires.append(Wire(fromNode: w.fromNode, fromPort: w.fromPort, toNode: "swa", toPort: "a"))
            graph.wires.append(Wire(fromNode: "sw", fromPort: "pulse", toNode: "swa", toPort: "b"))
            graph.wires.append(Wire(fromNode: "swa", fromPort: "out", toNode: "out", toPort: "z"))
        } else {
            graph.wires.append(Wire(fromNode: "sw", fromPort: "pulse", toNode: "out", toPort: "z"))
        }
        recompile()
    }

    /// x/y normalized 0-1 in viewport space (top-left origin).
    func setTouch(x: Float, y: Float, pressed: Bool) {
        touchValue = SIMD4(x, y, pressed ? 1 : 0, 0)
    }

    // MARK: - Editor mutations (all undoable)

    func pushUndo() {
        undoStack.append(graph)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let g = undoStack.popLast() else { return }
        redoStack.append(graph)
        graph = g
        recompile()
    }

    func redo() {
        guard let g = redoStack.popLast() else { return }
        undoStack.append(graph)
        graph = g
        recompile()
    }

    /// Add a node from the palette. Returns the new node's id.
    @discardableResult
    func addNode(_ specID: String, at position: SIMD2<Float>) -> String? {
        guard registry.spec(specID) != nil else { return nil }
        pushUndo()
        var id = shortID(specID)
        while graph.node(id) != nil { id = shortID(specID) }
        var node = GraphNode(id: id, specID: specID, params: [:])
        node.position = position
        graph.nodes.append(node)
        recompile()
        return id
    }

    func removeNodes(_ ids: Set<String>) {
        let removable = ids.filter { $0 != "out" }   // the Output sink must survive
        guard !removable.isEmpty else { return }
        pushUndo()
        for id in removable { removeNodeInternal(id) }
        recompile()
    }

    @discardableResult
    func duplicateNodes(_ ids: Set<String>) -> [String] {
        let sources = graph.nodes.filter { ids.contains($0.id) && $0.specID != "output" }
        guard !sources.isEmpty else { return [] }
        pushUndo()
        var newIDs: [String] = []
        for src in sources {
            var id = shortID(src.specID)
            while graph.node(id) != nil { id = shortID(src.specID) }
            var copy = GraphNode(id: id, specID: src.specID, params: src.params)
            copy.position = src.position + [40, 40]
            graph.nodes.append(copy)
            newIDs.append(id)
        }
        recompile()
        return newIDs
    }

    func resetNodeParams(_ ids: Set<String>) {
        pushUndo()
        for i in graph.nodes.indices where ids.contains(graph.nodes[i].id) {
            graph.nodes[i].params = [:]
        }
        recompile()
    }

    /// Position-only — no recompile, no undo (drag pushes undo once at gesture start).
    func moveNode(_ id: String, to p: SIMD2<Float>) {
        guard let i = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        graph.nodes[i].position = p
    }

    /// Wire (from.fromPort → to.toPort). Replaces whatever fed that input. Validates the
    /// whole graph first — on type mismatch or cycle the edit is rolled back.
    @discardableResult
    func connect(from: String, fromPort: String, to: String, toPort: String) -> Bool {
        let candidate = Wire(fromNode: from, fromPort: fromPort, toNode: to, toPort: toPort)
        let before = graph
        pushUndo()
        graph.wires.removeAll { $0.toNode == to && $0.toPort == toPort }
        graph.wires.append(candidate)
        do {
            try graph.validate(registry: registry)
            recompile()
            return true
        } catch {
            graph = before
            _ = undoStack.popLast()   // failed edit leaves no undo entry
            return false
        }
    }

    func removeWire(_ w: Wire) {
        guard graph.wires.contains(w) else { return }
        pushUndo()
        graph.wires.removeAll { $0 == w }
        recompile()
    }

    /// Re-route in ONE undo step: optionally drop `original`, then wire from → to.
    @discardableResult
    func rewire(dropping original: Wire?, from: String, fromPort: String,
                to: String, toPort: String) -> Bool {
        let before = graph
        pushUndo()
        if let original { graph.wires.removeAll { $0 == original } }
        graph.wires.removeAll { $0.toNode == to && $0.toPort == toPort }
        graph.wires.append(Wire(fromNode: from, fromPort: fromPort, toNode: to, toPort: toPort))
        do {
            try graph.validate(registry: registry)
            recompile()
            return true
        } catch {
            graph = before
            _ = undoStack.popLast()
            return false
        }
    }

    private func removeNodeInternal(_ id: String) {
        graph.nodes.removeAll { $0.id == id }
        graph.wires.removeAll { $0.fromNode == id || $0.toNode == id }
    }

    private func shortID(_ specID: String) -> String {
        defer { nextNodeNumber += 1 }
        let prefix = specID.split(separator: "-").compactMap(\.first).map(String.init).joined()
        return "\(prefix)\(nextNodeNumber)"
    }

    // MARK: - Compile

    private func recompile() {
        do {
            let program = try PinProgramCompiler(registry: registry).compile(graph)
            compiled = program
            workingInstructions = program.instructions
            classifyDynamicKeys()
            controlOrder = (try? graph.topoOrder().filter { registry.spec($0.specID)?.isControl == true }) ?? []
            controlState.removeAll()
            compileError = nil
            generation += 1
        } catch {
            compileError = "\(error)"   // last good program keeps rendering
        }
    }

    /// Evaluate every control-rate node in topological order; control→control wires flow
    /// through the memo, so envelopes can follow beat triggers, S&H can sample LFOs, etc.
    private func evaluateControlGraph(_ ctx: ControlContext) {
        controlValues.removeAll(keepingCapacity: true)
        for node in controlOrder {
            guard let spec = registry.spec(node.specID) else { continue }
            let inputs = spec.inputs.map { port -> SIMD4<Float> in
                guard let wire = graph.wireInto(node.id, port.name) else { return port.defaultValue }
                return controlValues["\(wire.fromNode).\(wire.fromPort)"] ?? port.defaultValue
            }
            let outs: [SIMD4<Float>]
            if let stateful = spec.controlEvalStateful {
                var s = controlState[node.id] ?? .zero
                outs = stateful(node, inputs, ctx, &s)
                controlState[node.id] = s
            } else if let eval = spec.controlEval {
                outs = eval(node, inputs, ctx)
            } else {
                continue
            }
            for (i, out) in outs.enumerated() where i < spec.outputs.count {
                controlValues["\(node.id).\(spec.outputs[i].name)"] = out
            }
        }
    }

    private func classifyDynamicKeys() {
        dynamicKeys = compiled.patches.keys.compactMap { key in
            let parts = key.split(separator: ".", maxSplits: 1)
            guard parts.count == 2, let node = graph.node(String(parts[0])) else { return nil }
            let suffix = String(parts[1])
            switch (node.specID, suffix) {
            case ("lag", "alpha"): return (key, node.id, .lagAlpha)
            case ("trail", "step"): return (key, node.id, .trailStep)
            case ("radial-ripple", "wave"): return (key, node.id, .rippleWave)
            case ("spring", "kdt"): return (key, node.id, .springKdt)
            case ("spring", "dmp"): return (key, node.id, .springDmp)
            case ("spring", "vdt"): return (key, node.id, .springVdt)
            case ("freeze", "hold"): return (key, node.id, .freezeHold)
            default:
                if let spec = registry.spec(node.specID), spec.isControl,
                   spec.outputs.contains(where: { $0.name == suffix }) {
                    return (key, node.id, .controlPort(suffix))
                }
                return nil
            }
        }
    }

    // MARK: - Per-frame tick (render thread — main)

    func frameProgram() -> ProgramFrame {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastTime, 0.1))
        lastTime = now
        let time = Float(now - startTime)
        let beat = (time * bpm / 60).truncatingRemainder(dividingBy: 1)
        var ctx = ControlContext(time: time, dt: dt, beatPhase: beat, bpm: bpm, touch: touchValue)
        if let a = audioSource?() { ctx.audio = a.bands; ctx.onsets = a.onsets }   // live mic
        if let b = bodySource?() {                                                 // live Vision
            ctx.bodyA = b.bodyA; ctx.bodyB = b.bodyB; ctx.gestures = b.gestures; ctx.present = b.present
        }
        evaluateControlGraph(ctx)

        for (key, nodeID, kind) in dynamicKeys {
            guard let refs = compiled.patches[key], let node = graph.node(nodeID) else { continue }
            var lanes: [Int: Float] = [:]
            switch kind {
            case .lagAlpha:
                let hl = max(node.float("halfLife", 0), 0.005)
                lanes[0] = 1 - exp(-0.6931 * dt / hl)
            case .trailStep:
                lanes[1] = -dt / max(node.float("decay", 1.5), 0.05)
            case .rippleWave:
                let k = 2 * Float.pi / max(node.float("wavelength", 0.15), 0.01)
                lanes[0] = k
                lanes[1] = -time * node.float("speed", 0.5) * k
            case .springKdt:
                lanes[0] = node.float("stiffness", 12) * dt
            case .springDmp:
                lanes[0] = exp(-node.float("damping", 0.7) * 8 * dt)
            case .springVdt:
                lanes[0] = dt
            case .freezeHold:
                lanes[0] = node.float("hold", 0)
            case .controlPort(let port):
                let v = controlValues["\(nodeID).\(port)"] ?? .zero
                lanes = [0: v.x, 1: v.y, 2: v.z, 3: v.w]
            }
            for ref in refs {
                guard workingInstructions.indices.contains(ref.instruction),
                      let v = lanes[ref.lane] else { continue }
                switch ref.lane {
                case 0: workingInstructions[ref.instruction].imm.x = v
                case 1: workingInstructions[ref.instruction].imm.y = v
                case 2: workingInstructions[ref.instruction].imm.z = v
                default: workingInstructions[ref.instruction].imm.w = v
                }
            }
        }

        // Shockwave uniforms (expired waves pruned lazily)
        waveBirths.removeAll { time - $0.t > 6 }
        var wt = SIMD4<Float>(repeating: -1e6)
        var ca = SIMD4<Float>.zero, cb = SIMD4<Float>.zero
        for (i, w) in waveBirths.prefix(4).enumerated() {
            wt[i] = w.t
            switch i {
            case 0: ca.x = w.c.x; ca.y = w.c.y
            case 1: ca.z = w.c.x; ca.w = w.c.y
            case 2: cb.x = w.c.x; cb.y = w.c.y
            default: cb.z = w.c.x; cb.w = w.c.y
            }
        }

        // Camera node → renderer (read directly; camera isn't part of the pin-op chain).
        var cam = CameraFrame()
        if let c = graph.node("cam") {
            cam.fov = c.float("fov", 55); cam.zoom = c.float("zoom", 1)
            cam.parallax = c.float("parallax", 0.5); cam.depthPush = c.float("depthPush", 1)
            cam.centerX = c.float("centerX", 0); cam.centerY = c.float("centerY", 0)
            cam.orbitX = c.float("orbitX", 0); cam.orbitY = c.float("orbitY", 0)
        }
        // FILTER nodes configure capture/EMA by presence (their wires pass depth through).
        let ema = graph.nodes.first { $0.specID == "ema-smooth" }
        let fill = graph.nodes.first { $0.specID == "fill-holes" }
        let stems = graph.node("pd")?.float("arms", 0) ?? 0

        return ProgramFrame(instructions: workingInstructions,
                            stateStride: compiled.stateFloatsPerPin,
                            generation: generation,
                            time: time, beatPhase: beat, dt: dt,
                            waveT: wt, waveCA: ca, waveCB: cb,
                            camera: cam,
                            depthStabilize: ema?.float("amount", 0.3) ?? 0,
                            holePersist: fill.map { $0.float("persist", 1) > 0.5 } ?? false,
                            stems: stems > 0.5)
    }

    /// Apple's AVFoundation depth filtering — driven by the Apple Depth Filter node's
    /// presence (OFF app-wide without it). Read by the camera layer on graph changes.
    var appleDepthFilterOn: Bool {
        graph.nodes.first { $0.specID == "apple-depth-filter" }
            .map { $0.float("enabled", 1) > 0.5 } ?? false
    }
}
