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
    var dolly: Float = 0       // −1 further … +1 closer (Orbit Cube Z); scales the eye distance
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
    var stems = false                 // Depth node "arms" — pull points back to their Z pins
    var background: SIMD4<Float> = [0, 0, 0, 0]   // Background node: rgb + gradient amount
    var lights: [(SIMD4<Float>, SIMD4<Float>)] = []   // Light nodes (≤4): (pos+type, intensity/falloff/enabled)
    var post: SIMD4<Float> = .zero                // bloomThreshold, bloomIntensity, grain, vignette
    var ghost = false                             // Render Settings: additive ghost blending
    var material: SIMD4<Float> = [1, 1, 0, 0]     // Material node: mode, roughness, metallic, lightCount
    var lookAt: SIMD4<Float> = .zero              // Look At node: target xyz + amount
    var stem: SIMD4<Float> = [0, 0, 1, 0]         // Stem node: profile, taper, thickness×
    var uvTransform: SIMD4<Float> = [0, 0, 1, 0]  // UV Transform node: offset, scale, rotate
    var edgePolicy: SIMD4<Float> = .zero          // Edge Policy node: mode, margin
    var domain: SIMD4<Float> = .zero              // Domain node: topoA, topoB, morph
    var despeckleGap: Float = 0                   // Despeckle Voxel node (0 = off)
    var smoothRadius: Float = 0                   // Smooth Surface node (0 = off)
    var accumFrames: Float = 0                    // Accumulate node (≤1 = off)
    var jbuFactor: Float = 0                      // Detail Upsample node (≤1 = off)
    var showGizmo = false                         // Orbit Cube node present → draw the orbit-pivot cube
    var gizmoPos: SIMD3<Float> = .zero            // world position of the Orbit Cube handle (moves with its joystick)
    // Exposed tuning params (previously hardcoded constants) — defaults match the old values.
    var edgeReject: Float = 0.06                  // Depth node EDGECULL — built-in flying-pixel reject (m)
    var emaDeadband: Float = 0.008                // EMA Smooth DEADBAND — hold threshold (m, × amount)
    var emaAdapt: Float = 5                       // EMA Smooth ADAPT — motion → alpha boost
    var fillRadius: Float = 3                     // Fill Holes RADIUS (px, 0 = off; default even w/o node)
    var fillGap: Float = 0.08                     // Fill Holes GAP — foreground-only band (m)
    var despeckleSupport: Float = 4               // Despeckle SUPPORT — required neighbours
    var smoothSigma: Float = 0.05                 // Smooth Surface SIGMA — range sigma (m)
    var jbuEdge: Float = 0.08                     // Detail Upsample EDGE — luma sigma
    var bloomSigma: Float = 6                     // Bloom RADIUS — gaussian sigma (px)

    func light(_ i: Int) -> (SIMD4<Float>, SIMD4<Float>) {
        i < lights.count ? lights[i] : (.zero, .zero)
    }
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
        case lagAlpha, trailStep, rippleWave, springKdt, springDmp, springVdt, freezeHold, echoAlpha
        case controlPort(String)
        case regionCenter(Int)   // Face/Body Region mask centres (c0/c1) fed from Vision each frame
        case wavePhase           // Wave node: phase lane advanced by SPEED per frame
    }
    private var dynamicKeys: [(key: String, nodeID: String, kind: DynamicKind)] = []

    // Shockwave ring (4 waves) — times in the frameProgram clock.
    private var waveBirths: [(t: Float, c: SIMD2<Float>)] = []
    private var shockLatch: [String: Bool] = [:]   // per-node rising-edge latch for wired FIRE triggers

    // Touch (viewport finger) — feeds the Touch control node.
    private var touchValue: SIMD4<Float> = .zero

    // Live mic bands/onsets, supplied by ContentView's AudioEngine while an audio node exists.
    @ObservationIgnored var audioSource: (@Sendable () -> (bands: SIMD4<Float>, onsets: SIMD4<Float>, fft: [Float]))?
    private static let audioIDs: Set<String> = ["audio-levels", "beat-trigger", "fft-band", "audio-rms", "burst"]
    var usesAudioNodes: Bool { graph.nodes.contains { Self.audioIDs.contains($0.specID) } }

    // Live MIDI (CoreMIDI), supplied by ContentView while a MIDI node exists.
    @ObservationIgnored var midiSource: (@Sendable () -> SIMD4<Float>)?
    private static let midiIDs: Set<String> = ["midi-cc", "midi-note"]
    var usesMidiNodes: Bool { graph.nodes.contains { Self.midiIDs.contains($0.specID) } }

    // OSC over UDP (OSCEngine), supplied by ContentView while an OSC node exists.
    @ObservationIgnored var oscSource: (@Sendable () -> [Float])?
    @ObservationIgnored var oscSend: (@Sendable (Int, Float) -> Void)?
    private static let oscIDs: Set<String> = ["osc-in", "osc-out"]
    var usesOSCNodes: Bool { graph.nodes.contains { Self.oscIDs.contains($0.specID) } }

    // Nearest-subject depth (sparse CPU scan in PinRenderer.ingest) → the Proximity node.
    @ObservationIgnored var proximitySource: (@Sendable () -> Float)?

    // Live body/hand tracking (Vision), supplied by ContentView while a body node exists.
    @ObservationIgnored var bodySource: (@Sendable () -> (bodyA: SIMD4<Float>, bodyB: SIMD4<Float>, gestures: SIMD4<Float>, present: SIMD4<Float>, pinchLR: SIMD4<Float>, gesturesL: SIMD4<Float>, gesturesR: SIMD4<Float>, bodyC: SIMD4<Float>, bodyD: SIMD4<Float>, joints: [SIMD2<Float>]))?
    private static let bodyFamily: Set<String> = ["hand-position", "pinch-amount", "hand-openness",
        "head-pose", "hand-gesture", "person-present", "joint", "body-region", "face-region",
        "left-hand-pinch", "right-hand-pinch", "left-hand-gesture", "right-hand-gesture"]
    var usesBodyNodes: Bool { graph.nodes.contains { Self.bodyFamily.contains($0.specID) } }

    // Imported media (photo/video) baked-depth playback, driven by ContentView's DepthPlayer while a
    // Still Image / Video Source node exists in the graph.
    /// Live Depth node "video/image" button → ContentView presents the import for that node id.
    @ObservationIgnored var requestMedia: ((String) -> Void)?
    /// The Vision Model node that owns the depth feed, or nil. WIRE-driven: it takes over only
    /// once ANY of its outputs is wired into the patch — a parked, unwired node does nothing.
    var visionModelNode: GraphNode? {
        graph.nodes.first { n in
            n.specID == "vision-model" && graph.wires.contains { $0.fromNode == n.id }
        }
    }

    /// Factory reset: the graph back to the fresh-install default file. Callers also clear imported
    /// media, renderer state and app defaults (ContentView.factoryReset).
    func resetToDefault() {
        stopNDIStreaming()
        graph = Self.defaultGraph()
        recompile()
    }

    // Control-graph evaluation: topo order over control nodes, per-frame value memo,
    // and persistent per-node state (envelopes/counters/S&H).
    private var controlOrder: [GraphNode] = []
    private var controlValues: [String: SIMD4<Float>] = [:]   // "nodeID.port" → value
    private var controlState: [String: SIMD4<Float>] = [:]
    private var camEase = SIMD4<Float>(0, 0, 0, 0)            // smoothed orbitX, orbitY, centerX, centerY
    private var dollyEase: Float = 0                          // smoothed dolly (Camera SMOOTH)
    // §13 v2 — per-host nested trigger subgraphs: cached control order + persistent per-host state.
    private var nestedOrders: [String: [GraphNode]] = [:]                       // hostID → nested control order
    private var nestedControlState: [String: [String: SIMD4<Float>]] = [:]      // hostID → nestedID → state

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
        // Clean left→right flow, evenly spaced; Camera sits ABOVE Output (its render target),
        // never overlapping. Self-plumbed nodes (shockwave/freeze) are placed clear at runtime.
        g.nodes = [
            n("d1", "depth", 60, 130),
            n("sz", "size", 330, 410),
            n("cam", "camera", 620, 60),
            n("out", "output", 620, 320),
        ]
        g.wires = [
            Wire(fromNode: "d1", fromPort: "position", toNode: "out", toPort: "position"),
            Wire(fromNode: "d1", fromPort: "z", toNode: "out", toPort: "z"),
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
            wire("d1", "z", "tr", "in"); wire("tr", "out", "out", "z")
        case "Arm Fire":                                       // stems ON + fire palette by depth
            if let i = g.nodes.firstIndex(where: { $0.id == "d1" }) { g.nodes[i].params["arms"] = .bool(true) }
            node("pl", "palette", 470, 60, ["map": .option("fire")])
            wire("d1", "z", "pl", "t"); wire("pl", "color", "out", "color")
        case "Beat Strobe":                                    // 8 Hz square LFO → size
            node("lf", "lfo", 90, 560, ["rate": .float(8), "shape": .option("square")])
            wire("lf", "out", "sz", "size")
        case "Kick Shatter":                                   // depth-driven scatter of the grid
            node("sc", "scatter", 470, 380, ["amount": .float(0.5), "seed": .float(5)])
            wire("d1", "z", "sc", "amount"); wire("sc", "offset", "out", "position")
        case "Device Test":                                    // on-device checklist — Sticky Notes narrate each check
            func note(_ id: String, _ x: Float, _ y: Float, _ text: String) {
                node(id, "comment", x, y, ["text": .option(text)])
            }
            // depth cleanup chain: Grazing Cull culls via its op (wired through the palette tap);
            // Despeckle / EMA act on the depth texture by presence.
            node("gz", "grazing-cull", 60, 300, ["cull": .float(0.25), "edge": .float(0.1)])
            node("ds", "despeckle-voxel", 60, 430)
            node("em", "ema-smooth", 60, 560, ["amount": .float(0.3)])
            wire("d1", "depth", "gz", "depth"); wire("gz", "out", "ds", "depth")
            wire("ds", "out", "em", "depth")
            note("n1", 60, 700, "1 DEPTH: cleanup chain live. Check no dust around your silhouette (Despeckle) and no shimmer (EMA). Free mode should match TDLidar.")

            // colour: thermal palette by depth
            node("pl", "palette", 330, 560, ["map": .option("thermal"), "shift": .float(-0.25)])
            wire("em", "out", "pl", "t"); wire("pl", "color", "out", "color")

            // shapes: spinning diamonds
            node("shp", "shape", 330, 700, ["type": .option("diamond")])
            node("spn", "spin", 330, 830, ["z": .float(0.12)])
            wire("shp", "shape", "out", "shape"); wire("spn", "rot", "out", "rotation")
            note("n2", 330, 950, "2 SHAPES: pins are spinning diamonds. Flip Shape through ring / disc / spike / slab — each silhouette must read distinct.")

            // stage: background gradient + light + material + post stack
            node("bg", "background", 620, 560, ["r": .float(0.01), "g": .float(0.01), "b": .float(0.07), "gradient": .float(0.6)])
            node("lt", "light", 620, 700, ["intensity": .float(1.5)])
            node("mat", "material", 620, 830, ["roughness": .float(0.25)])
            node("blm", "bloom", 850, 560, ["intensity": .float(0.8)])
            node("vg", "vignette", 850, 690)
            node("gr", "grain", 850, 800, ["amount": .float(0.12)])
            node("rs", "render-settings", 850, 910)
            note("n3", 620, 950, "3 STAGE: drag Light X/Y — shading + speculars track it (orbit the Camera too). Bloom halos hot palette tips; Render Settings GHOST = hologram; Background GRADIENT glows.")

            // body: face mask grows the pins on your face
            node("fr", "face-region", 60, 830, ["radius": .float(0.16)])
            node("rm", "remap", 230, 830, ["inMin": .float(0), "inMax": .float(1),
                                           "outMin": .float(0.5), "outMax": .float(1.8)])
            wire("fr", "mask", "rm", "in"); wire("rm", "out", "sz", "size")
            note("n4", 60, 1080, "4 BODY: pins on your FACE grow (Face Region → Remap → Size). Check the circle tracks you. Also try Left/Right Hand Pinch — verify chirality isn't swapped.")

            // proximity readout
            node("prox", "proximity", 850, 300)
            node("vd", "value-display", 850, 430)
            wire("prox", "nearness", "vd", "in")
            note("n5", 850, 1050, "5 PROXIMITY: the readout above rises as you walk toward the camera; step inside THRESHOLD and it can fire triggers. Watch FPS in the HUD with everything on.")
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
        guard activeGraph.node(nodeID) != nil else { return }
        editActive { $0.setParam(nodeID, name, .float(value)) }
    }

    /// Option/segment path (e.g. Depth FREE ↔ METRIC).
    func setOption(_ nodeID: String, _ name: String, _ value: String) {
        guard activeGraph.node(nodeID) != nil else { return }
        pushUndo()
        editActive(recompileAfter: false) { $0.setParam(nodeID, name, .option(value)) }
        // Depth-node cloud mode is a root-scope preset (it also nudges the shared camera).
        if editScopeNodeID == nil, graph.node(nodeID)?.specID == "depth", name == "mode" {
            applyDisplayMode(nodeID, value)
        }
        recompile()
    }

    private func applyDisplayMode(_ pdID: String, _ mode: String) {
        func p(_ id: String, _ k: String, _ v: Float) { graph.setParam(id, k, .float(v)) }
        let hasCam = graph.node("cam") != nil
        if mode == "free" {
            // Intrinsic-free TDLidar fan: sep 1 = the classic framing, gain 2.5 keeps the Z
            // recession uniform with the lateral scale so perspective still reads true.
            p(pdID, "separation", 1); p(pdID, "gain", 2.5); p(pdID, "focus", 1)
            if hasCam {
                p("cam", "fov", 60); p("cam", "zoom", 1); p("cam", "parallax", 0.5); p("cam", "depthPush", 1)
                p("cam", "centerX", 0); p("cam", "centerY", 0); p("cam", "orbitX", 0); p("cam", "orbitY", 0)
            }
        } else {   // metric — the registry defaults (TDLidar 1:1)
            // SEPARATION = metres→view scale (2.5 ≈ TDLidar framing), FOCUS = reference depth at
            // the wall. DEPTHPUSH must stay 1 — any other value stretches Z only and breaks the
            // uniform metric geometry. FOV 60 = the TDLidar viewer lens.
            p(pdID, "separation", 2.5); p(pdID, "focus", 1)
            if hasCam {
                p("cam", "fov", 60); p("cam", "zoom", 1); p("cam", "parallax", 0.3); p("cam", "depthPush", 1)
                p("cam", "centerX", 0); p("cam", "centerY", 0); p("cam", "orbitX", 0); p("cam", "orbitY", 0)
            }
        }
    }

    func setBool(_ nodeID: String, _ name: String, _ value: Bool) {
        guard activeGraph.node(nodeID) != nil else { return }
        pushUndo()                        // a discrete toggle → one undo step
        editActive { $0.setParam(nodeID, name, .bool(value)) }
    }

    /// Flat model — toggle a param's exposed input port on the card. Un-exposing drops any wire into it.
    func toggleExposed(_ nodeID: String, _ param: String) {
        pushUndo()
        editActive { g in
            guard let i = g.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            if let j = g.nodes[i].exposedParams.firstIndex(of: param) {
                g.nodes[i].exposedParams.remove(at: j)
                g.wires.removeAll { $0.toNode == nodeID && $0.toPort == param }
            } else {
                g.nodes[i].exposedParams.append(param)
            }
        }
    }

    func isExposed(_ nodeID: String, _ param: String) -> Bool {
        activeGraph.node(nodeID)?.exposedParams.contains(param) ?? false
    }

    /// Sticky Note corner resize (live drag). No recompile — the note is inert. Caller pushes one
    /// undo step at drag start.
    func setNoteSize(_ id: String, _ size: SIMD2<Float>) {
        editActive(recompileAfter: false) { g in
            if let i = g.nodes.firstIndex(where: { $0.id == id }) { g.nodes[i].noteSize = size }
        }
    }

    /// Node ids whose top-left sits within an Annotation's rectangle — the nodes a drag of that
    /// Annotation carries with it (TD-style). Other annotations are excluded.
    func nodesInside(_ noteID: String) -> Set<String> {
        guard let note = activeGraph.node(noteID), note.specID == "comment" else { return [] }
        let size = note.noteSize ?? [200, 120]
        let lo = note.position, hi = note.position + size
        return Set(activeGraph.nodes.filter {
            $0.id != noteID && $0.specID != "comment"
                && $0.position.x >= lo.x && $0.position.x <= hi.x
                && $0.position.y >= lo.y && $0.position.y <= hi.y
        }.map(\.id))
    }

    /// Live path for dynamic lanes (freeze hold): no recompile at all.
    func setParamLive(_ nodeID: String, _ name: String, _ value: Float) {
        editActive(recompileAfter: false) { $0.setParam(nodeID, name, .float(value)) }
    }

    /// Sticky Note text (per keystroke — no recompile, no undo spam).
    func setTextLive(_ nodeID: String, _ name: String, _ value: String) {
        editActive(recompileAfter: false) { $0.setParam(nodeID, name, .option(value)) }
    }

    func nodeParam(_ nodeID: String, _ name: String, _ fallback: Float) -> Float {
        activeGraph.node(nodeID)?.float(name, fallback) ?? fallback
    }

    func nodeOption(_ nodeID: String, _ name: String, _ fallback: String) -> String {
        activeGraph.node(nodeID)?.option(name, fallback) ?? fallback
    }

    /// Live control-rate value of a node's output port this frame (Value Display / body-node readout).
    func liveControlValue(_ nodeID: String, _ port: String) -> Float {
        controlValues["\(nodeID).\(port)"]?.x ?? 0
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
        pushUndo()                        // structural (adds/removes the colour node) → undoable
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
        fz.position = clearPosition(outPos + [-220, -160], specID: "freeze")
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
        sw.position = clearPosition(outPos + [-220, 180], specID: "shockwave")
        graph.nodes.append(sw)
        if let w = zFeed() {
            var adder = GraphNode(id: "swa", specID: "add", params: [:])
            adder.position = clearPosition(outPos + [-110, 40], specID: "add")
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

    // MARK: - NDI output (global sink, presence + START drive the renderer's NDI pass)

    /// The NDI node's live config, or nil when there's no node or streaming is stopped.
    /// The renderer only does its offscreen pass while this is non-nil.
    func ndiRenderConfig() -> NDIRenderConfig? {
        guard let n = graph.nodes.first(where: { $0.specID == "ndi-out" }),
              nodeOption(n.id, "stream", "STOP") == "START" else { return nil }
        let base: (Int, Int)
        switch nodeOption(n.id, "resolution", "1080x1440") {
        case "810x1080": base = (810, 1080)
        case "945x1260": base = (945, 1260)
        case "1350x1800": base = (1350, 1800)
        case "1620x2160": base = (1620, 2160)
        default: base = (1080, 1440)
        }
        let landscape = nodeOption(n.id, "orientation", "3:4") == "4:3"
        let w = landscape ? base.1 : base.0
        let h = landscape ? base.0 : base.1
        let fps60 = nodeOption(n.id, "fps", "30") == "60"
        return NDIRenderConfig(width: w, height: h,
                               alpha: nodeOption(n.id, "alpha", "OFF") == "ON",
                               fpsN: fps60 ? 60_000 : 30_000, fpsD: 1_000,
                               name: nodeOption(n.id, "name", "Points"),
                               wired: nodeOption(n.id, "wired", "OFF") == "ON")
    }

    var hasNDINode: Bool { graph.nodes.contains { $0.specID == "ndi-out" } }
    var ndiStreaming: Bool { ndiRenderConfig() != nil }

    /// Menu NDI button: create the NDI node (stopped) wired from Output.image, or select the
    /// existing one. The user hits START in its settings.
    @discardableResult
    func ensureNDIOut() -> String {
        if let existing = graph.nodes.first(where: { $0.specID == "ndi-out" }) { return existing.id }
        pushUndo()
        var id = shortID("ndi-out")
        while graph.node(id) != nil { id = shortID("ndi-out") }
        var node = GraphNode(id: id, specID: "ndi-out", params: [:])
        let outPos = graph.node("out")?.position ?? [620, 320]
        node.position = clearPosition(outPos + [260, 0], specID: "ndi-out")
        graph.nodes.append(node)
        if graph.node("out") != nil {
            graph.wires.append(Wire(fromNode: "out", fromPort: "image", toNode: id, toPort: "image"))
        }
        recompile()
        return id
    }

    /// Lifecycle guard (background / lock / call / alarm): force streaming off so it never
    /// runs unattended and does not auto-resume on return (sets the node's own STOP state).
    func stopNDIStreaming() {
        guard let n = graph.nodes.first(where: { $0.specID == "ndi-out" }),
              nodeOption(n.id, "stream", "STOP") == "START" else { return }
        setOption(n.id, "stream", "STOP")
    }

    // MARK: - Record output (image sink, like NDI: presence + RECORD=START drive the capture pass)

    /// The Record node's live config, or nil when there's no node or it's stopped.
    /// The renderer records only while this is non-nil (and finalizes when it goes nil).
    func recordRenderConfig() -> RecordConfig? {
        guard let n = graph.nodes.first(where: { $0.specID == "record" }),
              nodeOption(n.id, "record", "STOP") == "START" else { return nil }
        let parts = nodeOption(n.id, "resolution", "1080x1440").split(separator: "x").compactMap { Int($0) }
        let pw = parts.first ?? 1080, ph = parts.count > 1 ? parts[1] : 1440
        let landscape = nodeOption(n.id, "orientation", "3:4") == "4:3"
        let fps60 = nodeOption(n.id, "fps", "60") == "60"
        return RecordConfig(width: landscape ? ph : pw, height: landscape ? pw : ph,
                            alpha: nodeOption(n.id, "alpha", "OFF") == "ON",
                            fpsN: fps60 ? 60_000 : 30_000, fpsD: 1_000)
    }

    var hasRecordNode: Bool { graph.nodes.contains { $0.specID == "record" } }

    /// Menu Record button: create the Record node (stopped) wired from Output.image, or select
    /// the existing one. The user hits START in its settings.
    @discardableResult
    func ensureRecord() -> String {
        if let existing = graph.nodes.first(where: { $0.specID == "record" }) { return existing.id }
        pushUndo()
        var id = shortID("record")
        while graph.node(id) != nil { id = shortID("record") }
        var node = GraphNode(id: id, specID: "record", params: [:])
        let outPos = graph.node("out")?.position ?? [620, 320]
        node.position = clearPosition(outPos + [260, 140], specID: "record")
        graph.nodes.append(node)
        if graph.node("out") != nil {
            graph.wires.append(Wire(fromNode: "out", fromPort: "image", toNode: id, toPort: "image"))
        }
        recompile()
        return id
    }

    /// Lifecycle guard (background / lock / call): force recording off so it never runs
    /// unattended (saves the current take) and does not auto-resume on return.
    func stopRecording() {
        guard let n = graph.nodes.first(where: { $0.specID == "record" }),
              nodeOption(n.id, "record", "STOP") == "START" else { return }
        setOption(n.id, "record", "STOP")
    }

    /// x/y normalized 0-1 in viewport space (top-left origin).
    func setTouch(x: Float, y: Float, pressed: Bool) {
        touchValue = SIMD4(x, y, pressed ? 1 : 0, 0)
    }

    // MARK: - Editor scope (§13 v2 — nested trigger subgraphs)

    /// nil = editing the root graph; else a node's nested trigger subgraph (TOX, one level down).
    var editScopeNodeID: String?

    /// The graph the editor currently acts on (root, or a node's triggerGraph). Read by the subviews.
    var activeGraph: Graph {
        guard let s = editScopeNodeID, graph.node(s) != nil else { return graph }
        return graph.node(s)?.triggerGraph ?? Graph()   // empty = a fresh nested canvas
    }

    /// Host node's display name while a nested trigger graph is open (for the breadcrumb).
    var editScopeName: String? {
        guard let s = editScopeNodeID, let n = graph.node(s) else { return nil }
        return registry.spec(n.specID)?.name ?? n.specID
    }

    /// Mutate the scoped graph in place, then recompile the root (which also rebuilds nested orders).
    private func editActive(recompileAfter: Bool = true, _ body: (inout Graph) -> Void) {
        if let s = editScopeNodeID, let i = graph.nodes.firstIndex(where: { $0.id == s }) {
            var g = graph.nodes[i].triggerGraph ?? Graph()
            body(&g)
            graph.nodes[i].triggerGraph = g
        } else {
            body(&graph)
        }
        if recompileAfter { recompile() }
    }

    /// Commit a fully-formed scoped graph (connect/rewire, after validation).
    private func setActiveGraph(_ g: Graph) {
        if let s = editScopeNodeID, let i = graph.nodes.firstIndex(where: { $0.id == s }) {
            graph.nodes[i].triggerGraph = g
        } else {
            graph = g
        }
        recompile()
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

    // MARK: - Non-overlap placement (nodes never stack on top of each other)

    /// Rough card size from the spec — mirrors NodeMetrics (headerH 24, portRow 24, paramRow 16, +8)
    /// without importing the UI layer. Exposed params add a port row and drop their value row.
    private func estimatedSize(_ specID: String, exposed: Int = 0) -> SIMD2<Float> {
        guard let s = registry.spec(specID) else { return [170, 120] }
        let portRows = s.inputs.count + exposed + s.outputs.count
        let paramRows = max(min(s.params.count - exposed, 5), 0)
        return [170, 24 + Float(portRows) * 24 + Float(paramRows) * 16 + 8]
    }

    /// pad > 0 enforces a gap (new-node placement); pad < 0 tolerates that much edge overlap (drag).
    private func overlapsAny(_ pos: SIMD2<Float>, _ size: SIMD2<Float>, ignoring: Set<String>, pad: Float = 14) -> Bool {
        for nn in activeGraph.nodes where !ignoring.contains(nn.id) {
            let s2 = estimatedSize(nn.specID, exposed: nn.exposedParams.count)
            if pos.x < nn.position.x + s2.x + pad, pos.x + size.x + pad > nn.position.x,
               pos.y < nn.position.y + s2.y + pad, pos.y + size.y + pad > nn.position.y {
                return true
            }
        }
        return false
    }

    /// Nudge `desired` down (then across) until it clears every existing node.
    private func clearPosition(_ desired: SIMD2<Float>, specID: String, exposed: Int = 0,
                               ignoring: Set<String> = [], pad: Float = 14) -> SIMD2<Float> {
        let size = estimatedSize(specID, exposed: exposed)
        var p = desired
        var tries = 0
        while overlapsAny(p, size, ignoring: ignoring, pad: pad), tries < 60 {
            tries += 1
            p = [desired.x, desired.y + Float(tries) * 40]
            if tries % 8 == 0 { p = [desired.x + Float(tries / 8) * 210, desired.y] }
        }
        return p
    }

    /// After a drag, nudge dropped nodes out of overlap — up to 5px edge overlap is tolerated.
    func resolveOverlaps(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var fixes: [String: SIMD2<Float>] = [:]
        for id in ids {
            guard let n = activeGraph.node(id) else { continue }
            let cleared = clearPosition(n.position, specID: n.specID, exposed: n.exposedParams.count,
                                        ignoring: ids, pad: -5)
            if cleared != n.position { fixes[id] = cleared }
        }
        guard !fixes.isEmpty else { return }
        editActive { g in
            for (id, pos) in fixes where g.nodes.contains(where: { $0.id == id }) {
                g.nodes[g.nodes.firstIndex(where: { $0.id == id })!].position = pos
            }
        }
    }

    /// Add a node from the palette. Returns the new node's id.
    @discardableResult
    func addNode(_ specID: String, at position: SIMD2<Float>) -> String? {
        guard registry.spec(specID) != nil else { return nil }
        let g0 = activeGraph
        pushUndo()
        var id = shortID(specID)
        while g0.node(id) != nil { id = shortID(specID) }
        var node = GraphNode(id: id, specID: specID, params: [:])
        node.position = clearPosition(position, specID: specID)
        editActive { $0.nodes.append(node) }
        return id
    }

    func removeNodes(_ ids: Set<String>) {
        let removable = ids.filter { $0 != "out" && activeGraph.node($0)?.specID != "trigger-drive" }   // Output + trigger sinks survive
        guard !removable.isEmpty else { return }
        pushUndo()
        editActive { g in
            for id in removable {
                g.nodes.removeAll { $0.id == id }
                g.wires.removeAll { $0.fromNode == id || $0.toNode == id }
            }
        }
    }

    @discardableResult
    func duplicateNodes(_ ids: Set<String>) -> [String] {
        let sources = activeGraph.nodes.filter { ids.contains($0.id) && $0.specID != "output" && $0.specID != "trigger-drive" }
        guard !sources.isEmpty else { return [] }
        pushUndo()
        var newIDs: [String] = []
        editActive { g in
            for src in sources {
                var id = self.shortID(src.specID)
                while g.node(id) != nil { id = self.shortID(src.specID) }
                var copy = GraphNode(id: id, specID: src.specID, params: src.params)
                copy.position = src.position + [40, 40]
                g.nodes.append(copy)
                newIDs.append(id)
            }
        }
        return newIDs
    }

    func resetNodeParams(_ ids: Set<String>) {
        pushUndo()
        editActive { g in
            for i in g.nodes.indices where ids.contains(g.nodes[i].id) { g.nodes[i].params = [:] }
        }
    }

    /// Position-only — no recompile, no undo (drag pushes undo once at gesture start).
    /// Dragging a macro card carries its hidden members along.
    func moveNode(_ id: String, to p: SIMD2<Float>) {
        editActive(recompileAfter: false) { g in
            guard let i = g.nodes.firstIndex(where: { $0.id == id }) else { return }
            let delta = p - g.nodes[i].position
            g.nodes[i].position = p
            for m in g.nodes[i].macroMembers {
                if let j = g.nodes.firstIndex(where: { $0.id == m }) { g.nodes[j].position += delta }
            }
        }
    }

    // MARK: - Macro grouping (visual collapse — the compiled network never changes)

    /// Node ids hidden inside a collapsed macro.
    var hiddenNodeIDs: Set<String> { Set(activeGraph.nodes.flatMap(\.macroMembers)) }

    /// The macro card hiding `id`, if any.
    func macroHosting(_ id: String) -> GraphNode? {
        activeGraph.nodes.first { $0.macroMembers.contains(id) }
    }

    /// Collapse a selection into one macro card. Output/Camera and other macros stay visible.
    @discardableResult
    func groupNodes(_ ids: Set<String>) -> String? {
        let g0 = activeGraph
        let members = g0.nodes.filter {
            ids.contains($0.id) && $0.specID != "output" && $0.specID != "camera" && $0.macroMembers.isEmpty
        }
        guard members.count >= 2 else { return nil }
        pushUndo()
        var id = shortID("macro")
        while g0.node(id) != nil { id = shortID("macro") }
        var node = GraphNode(id: id, specID: "macro", params: [:])
        let cx = members.map(\.position.x).reduce(0, +) / Float(members.count)
        let cy = members.map(\.position.y).reduce(0, +) / Float(members.count)
        node.position = [cx, cy]
        node.macroMembers = members.map(\.id)
        editActive { $0.nodes.append(node) }
        return id
    }

    /// Expand a macro: drop the card, members reappear (deleting the card does the same).
    func ungroupMacro(_ id: String) {
        guard activeGraph.node(id)?.macroMembers.isEmpty == false else { return }
        pushUndo()
        editActive { g in g.nodes.removeAll { $0.id == id } }
    }

    /// Wire (from.fromPort → to.toPort). Replaces whatever fed that input. Validates the
    /// whole graph first — on type mismatch or cycle the edit is rolled back.
    @discardableResult
    func connect(from: String, fromPort: String, to: String, toPort: String) -> Bool {
        var g = activeGraph
        g.wires.removeAll { $0.toNode == to && $0.toPort == toPort }
        g.wires.append(Wire(fromNode: from, fromPort: fromPort, toNode: to, toPort: toPort))
        guard (try? g.validate(registry: registry)) != nil else { return false }   // mismatch/cycle → no-op
        pushUndo()
        setActiveGraph(g)
        return true
    }

    func removeWire(_ w: Wire) {
        guard activeGraph.wires.contains(w) else { return }
        pushUndo()
        editActive { $0.wires.removeAll { $0 == w } }
    }

    /// Re-route in ONE undo step: optionally drop `original`, then wire from → to.
    @discardableResult
    func rewire(dropping original: Wire?, from: String, fromPort: String,
                to: String, toPort: String) -> Bool {
        var g = activeGraph
        if let original { g.wires.removeAll { $0 == original } }
        g.wires.removeAll { $0.toNode == to && $0.toPort == toPort }
        g.wires.append(Wire(fromNode: from, fromPort: fromPort, toNode: to, toPort: toPort))
        guard (try? g.validate(registry: registry)) != nil else { return false }
        pushUndo()
        setActiveGraph(g)
        return true
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
            nestedOrders.removeAll(keepingCapacity: true)   // §13 v2 — cache each node's nested control order
            for n in graph.nodes {
                guard let tg = n.triggerGraph, !tg.nodes.isEmpty else { continue }
                nestedOrders[n.id] = (try? tg.topoOrder().filter { registry.spec($0.specID)?.isControl == true }) ?? []
            }
            // Keep control state across recompiles (slider drags recompile every tick — wiping
            // here reset Counter/Toggle/Envelope/On Start mid-performance). Prune removed nodes only.
            let liveIDs = Set(graph.nodes.map(\.id))
            controlState = controlState.filter { liveIDs.contains($0.key) }
            nestedControlState = nestedControlState.filter { liveIDs.contains($0.key) }
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
        Self.evalControl(graph, order: controlOrder, ctx: ctx,
                         values: &controlValues, state: &controlState, registry: registry)
    }

    /// Pure control-rate evaluator over ANY graph — reused for the host and nested trigger graphs (§13E).
    static func evalControl(_ g: Graph, order: [GraphNode], ctx: ControlContext,
                            values: inout [String: SIMD4<Float>],
                            state: inout [String: SIMD4<Float>], registry: NodeRegistry) {
        for node in order {
            guard let spec = registry.spec(node.specID) else { continue }
            let inputs = spec.inputs.map { port -> SIMD4<Float> in
                guard let wire = g.wireInto(node.id, port.name) else { return port.defaultValue }
                return values["\(wire.fromNode).\(wire.fromPort)"] ?? port.defaultValue
            }
            let outs: [SIMD4<Float>]
            if let stateful = spec.controlEvalStateful {
                var s = state[node.id] ?? .zero
                outs = stateful(node, inputs, ctx, &s)
                state[node.id] = s
            } else if let eval = spec.controlEval {
                outs = eval(node, inputs, ctx)
            } else { continue }
            for (i, out) in outs.enumerated() where i < spec.outputs.count {
                values["\(node.id).\(spec.outputs[i].name)"] = out
            }
        }
    }

    /// Flat model — drive exposed params from the Signal node wired into each param's port. Runs AFTER
    /// the dynamic-lane loop so driven values sit on top of baked/control values. Float params write their
    /// patch lane directly (no recompile); option params flip the selection only when the index changes.
    private func applyExposedParams() {
        // 1. Option ports — flip when the wired signal crosses a bucket boundary. Recompiles, so it's rare:
        //    gather flips first, apply after. // ponytail: one-frame revert of other driven lanes on a flip
        //    (recompile rebakes them); invisible for a discrete mode change, self-corrects next frame.
        var flips: [(node: String, param: String, value: String)] = []
        for node in graph.nodes where !node.exposedParams.isEmpty {
            guard let spec = registry.spec(node.specID) else { continue }
            for param in node.exposedParams {
                guard let ps = spec.params.first(where: { $0.name == param }), let opts = ps.options, opts.count > 1,
                      let w = graph.wires.first(where: { $0.toNode == node.id && $0.toPort == param }) else { continue }
                let raw = (controlValues["\(w.fromNode).\(w.fromPort)"] ?? .zero).x
                let idx = min(max(Int(min(max(raw, 0), 0.9999) * Float(opts.count)), 0), opts.count - 1)
                if opts[idx] != node.option(param) { flips.append((node.id, param, opts[idx])) }
            }
        }
        for f in flips { driveOption(f.node, f.param, f.value) }

        // 2. Float ports — write the driven value into the param's patch lane(s).
        for node in graph.nodes where !node.exposedParams.isEmpty {
            guard let spec = registry.spec(node.specID) else { continue }
            for param in node.exposedParams {
                let key = "\(node.id).\(param)"
                guard let refs = compiled.patches[key],
                      let w = graph.wires.first(where: { $0.toNode == node.id && $0.toPort == param }) else { continue }
                let raw = (controlValues["\(w.fromNode).\(w.fromPort)"] ?? .zero).x
                // Beginner default: map the source as 0..1 across the param's full range, so a raw
                // 0..1 source (pinch, audio level, gesture) sweeps the whole slider out of the box.
                // Bipolar/other ranges: insert a Remap node before the port.
                var value = raw
                if let range = spec.params.first(where: { $0.name == param })?.range {
                    let t = min(max(raw, 0), 1)
                    value = range.lowerBound + (range.upperBound - range.lowerBound) * t
                }
                for ref in refs where workingInstructions.indices.contains(ref.instruction) {
                    switch ref.lane {
                    case 0: workingInstructions[ref.instruction].imm.x = value
                    case 1: workingInstructions[ref.instruction].imm.y = value
                    case 2: workingInstructions[ref.instruction].imm.z = value
                    default: workingInstructions[ref.instruction].imm.w = value
                    }
                }
            }
        }
    }

    /// Set an option param + recompile without pushing undo — used by option-port driving each flip frame.
    private func driveOption(_ nodeID: String, _ param: String, _ value: String) {
        graph.setParam(nodeID, param, .option(value))
        if graph.node(nodeID)?.specID == "depth", param == "mode" { applyDisplayMode(nodeID, value) }
        recompile()
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
            case ("echo", "alpha"), ("echo", "alpha2"): return (key, node.id, .echoAlpha)
            case ("face-region", "center"), ("body-region", "c0"): return (key, node.id, .regionCenter(0))
            case ("body-region", "c1"): return (key, node.id, .regionCenter(1))
            case ("wave", "wave"): return (key, node.id, .wavePhase)
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
        if let a = audioSource?() { ctx.audio = a.bands; ctx.onsets = a.onsets; ctx.fftBands = a.fft }
        if let m = midiSource?() { ctx.midi = m }                                  // live MIDI
        if let o = oscSource?() { ctx.osc = o }                                    // live OSC in
        if let p = proximitySource?() { ctx.proximity = [p, p > 0.05 ? 1 : 0, 0, 0] }
        if let b = bodySource?() {                                                 // live Vision
            ctx.bodyA = b.bodyA; ctx.bodyB = b.bodyB; ctx.gestures = b.gestures; ctx.present = b.present
            ctx.pinchLR = b.pinchLR; ctx.gesturesL = b.gesturesL; ctx.gesturesR = b.gesturesR
            ctx.bodyC = b.bodyC; ctx.bodyD = b.bodyD; ctx.joints = b.joints
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
            case .echoAlpha:
                // Longer DELAY → smaller follow coefficient → longer ghost tail.
                lanes[0] = 1 - exp(-dt / max(node.float("delay", 0.25), 0.02))
            case .controlPort(let port):
                let v = controlValues["\(nodeID).\(port)"] ?? .zero
                lanes = [0: v.x, 1: v.y, 2: v.z, 3: v.w]
            case .regionCenter(let which):
                let c = Self.regionCenter(node, which, ctx)
                lanes = [0: c.x, 1: c.y]
            case .wavePhase:
                // sin(pos·k + phase): march the phase so the sheet actually travels at SPEED
                let k = node.float("frequency", 4) * 6.283
                lanes[1] = -time * node.float("speed", 1) * k
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

        applyExposedParams()   // flat model — wired Signal nodes drive exposed params (on top of baked/control)

        // OSC Out: push each node's wired value to the network (the engine rate-limits).
        if let send = oscSend {
            for node in graph.nodes where node.specID == "osc-out" {
                guard let w = graph.wireInto(node.id, "value") else { continue }
                let v = (controlValues["\(w.fromNode).\(w.fromPort)"] ?? .zero).x
                send(Int(node.float("slot", 1)), v)
            }
        }

        // Shockwave.fire: a wired trigger (Beat Trigger, Clock, gestures…) births a wave at the
        // frame centre on its rising edge. Viewport taps / the pad still fire positioned waves.
        for node in graph.nodes where node.specID == "shockwave" {
            guard let w = graph.wireInto(node.id, "fire") else { continue }
            let high = (controlValues["\(w.fromNode).\(w.fromPort)"] ?? .zero).x > 0.5
            if high && !(shockLatch[node.id] ?? false) {
                waveBirths.append((time, SIMD2(0, 0)))
            }
            shockLatch[node.id] = high
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
        // First camera in the graph wins — palette-added Cameras work, not just the default "cam".
        var cam = CameraFrame()
        if let c = graph.node("cam") ?? graph.nodes.first(where: { $0.specID == "camera" }) {
            // Each camera param can be DRIVEN by a control node wired into its exposed ◇ (e.g. Orbit
            // Cube → orbitX/orbitY for an auto-turntable); else the static slider value.
            func p(_ name: String, _ fb: Float) -> Float {
                if let w = graph.wireInto(c.id, name) { return (controlValues["\(w.fromNode).\(w.fromPort)"] ?? .zero).x }
                return c.float(name, fb)
            }
            cam.fov = p("fov", 55); cam.zoom = p("zoom", 1)
            cam.parallax = p("parallax", 0.5); cam.depthPush = p("depthPush", 1)
            cam.centerX = p("centerX", 0); cam.centerY = p("centerY", 0)
            // ORBIT ◇: one wire from an Orbit Cube carries yaw/pitch/dolly in x/y/z. Else the static jog value.
            if let w = graph.wireInto(c.id, "orbit") {
                let o = controlValues["\(w.fromNode).\(w.fromPort)"] ?? .zero
                cam.orbitX = o.x; cam.orbitY = o.y; cam.dolly = o.z
            } else {
                cam.orbitX = p("orbitX", 0); cam.orbitY = p("orbitY", 0)
            }
            // SMOOTH: ease the view toward its target so jog/joystick moves glide instead of snapping.
            let smooth = c.float("smooth", 0)
            if smooth > 0.001 {
                let a = min(1, dt / max(smooth * 0.5, dt))         // dt-scaled ease, time constant ≤0.5s
                camEase.x += (cam.orbitX - camEase.x) * a; camEase.y += (cam.orbitY - camEase.y) * a
                camEase.z += (cam.centerX - camEase.z) * a; camEase.w += (cam.centerY - camEase.w) * a
                dollyEase += (cam.dolly - dollyEase) * a
                cam.orbitX = camEase.x; cam.orbitY = camEase.y
                cam.centerX = camEase.z; cam.centerY = camEase.w; cam.dolly = dollyEase
            } else {
                camEase = [cam.orbitX, cam.orbitY, cam.centerX, cam.centerY]; dollyEase = cam.dolly
            }
        }
        // FILTER nodes configure capture/EMA by presence (their wires pass depth through).
        let ema = graph.nodes.first { $0.specID == "ema-smooth" }
        let depthNode = graph.nodes.first { $0.specID == "depth" }
        let stems = depthNode?.float("arms", 0) ?? 0
        let despeckleNode = graph.nodes.first { $0.specID == "despeckle-voxel" }
        let despeckle = despeckleNode?.float("size", 0.02) ?? 0
        let smoothNode = graph.nodes.first { $0.specID == "smooth-surface" }
        let smoothR = smoothNode?.float("radius", 1) ?? 0
        let accum = graph.nodes.first { $0.specID == "accumulate" }?.float("frames", 8) ?? 0
        let jbuNode = graph.nodes.first { $0.specID == "detail-upsample" }
        let jbu = jbuNode?.float("factor", 2) ?? 0
        let fillNode = graph.nodes.first { $0.specID == "fill-holes" }

        // STAGE sinks read by the renderer (like Camera): Background, Light, and the post stack.
        var bg = SIMD4<Float>(0, 0, 0, 0)
        if let b = graph.nodes.first(where: { $0.specID == "background" }) {
            bg = [b.float("r", 0), b.float("g", 0), b.float("b", 0), b.float("gradient", 0)]
        }
        var lights: [(SIMD4<Float>, SIMD4<Float>)] = []
        for l in graph.nodes.filter({ $0.specID == "light" }).prefix(4) {
            let type: Float = l.option("type", "point") == "directional" ? 1
                            : l.option("type", "point") == "spot" ? 2 : 0
            lights.append(([l.float("x", 0.5), l.float("y", 0.8), l.float("z", 2), type],
                           [l.float("intensity", 1), l.float("falloff", 1), 1, 0]))
        }
        var material = SIMD4<Float>(1, 1, 0, Float(lights.count))   // default = current lit look
        if let m = graph.nodes.first(where: { $0.specID == "material" }) {
            let mode: Float = m.option("shading", "lit") == "unlit" ? 0
                            : m.option("shading", "lit") == "matcap" ? 2 : 1
            material = [mode, m.float("roughness", 0.5), m.float("metallic", 0), Float(lights.count)]
        }
        var lookAt = SIMD4<Float>.zero
        if let la = graph.nodes.first(where: { $0.specID == "look-at" }) {
            lookAt = [la.float("x", 0), la.float("y", 0), la.float("z", 2), la.float("amount", 1)]
        }
        var stem = SIMD4<Float>(0, 0, 1, 0)
        if let s = graph.nodes.first(where: { $0.specID == "stem" }) {
            let profile: Float = s.option("profile", "square") == "round" ? 1
                               : s.option("profile", "square") == "blade" ? 2 : 0
            // thickness param 0-1, default 0.3 → 1× the base pitch-derived thickness
            stem = [profile, s.float("taper", 0.2), s.float("thickness", 0.3) / 0.3, 0]
        }
        var uvT = SIMD4<Float>(0, 0, 1, 0)
        if let t = graph.nodes.first(where: { $0.specID == "uv-transform" }) {
            uvT = [t.float("offsetX", 0), t.float("offsetY", 0), t.float("scale", 1), t.float("rotate", 0)]
        }
        var edge = SIMD4<Float>.zero
        if let e = graph.nodes.first(where: { $0.specID == "edge-policy" }) {
            let mode: Float = e.option("mode", "fade") == "clamp" ? 2
                            : e.option("mode", "fade") == "none" ? 0 : 1
            edge = [mode, e.float("margin", 0.05), 0, 0]
        }
        var domain = SIMD4<Float>.zero
        if let d = graph.nodes.first(where: { $0.specID == "domain" }) {
            let names = ["rect", "hex", "radial", "spiral", "scatter", "perspective"]
            domain.x = Float(names.firstIndex(of: d.option("topologyA", "rect")) ?? 0)
            domain.y = Float(names.firstIndex(of: d.option("topologyB", "radial")) ?? 2)
            var m = d.float("morphAmount", 0)
            if let w = graph.wireInto(d.id, "morph") {   // wired control drives the morph live
                m = (controlValues["\(w.fromNode).\(w.fromPort)"] ?? .zero).x
            }
            domain.z = min(max(m, 0), 1)
        }
        var post = SIMD4<Float>.zero   // (bloomThreshold, bloomIntensity, grain, vignette)
        if let n = graph.nodes.first(where: { $0.specID == "bloom" }) {
            post.x = n.float("threshold", 0.7); post.y = n.float("intensity", 0.4)
        }
        if let n = graph.nodes.first(where: { $0.specID == "grain" }) { post.z = n.float("amount", 0.2) }
        if let n = graph.nodes.first(where: { $0.specID == "vignette" }) { post.w = n.float("amount", 0.3) }
        let ghost = graph.nodes.first { $0.specID == "render-settings" }
            .map { $0.option("blend", "solid") == "ghost" } ?? false

        // Orbit Cube handle → gizmo world position (moves with its joystick, so you see where it sits).
        // x/y are orbit turns/pitch, z is dolly; scale into the cloud so the cube reads on-screen.
        var gizmo = SIMD3<Float>.zero
        let hasCube = graph.nodes.contains { $0.specID == "orbit-cube" }
        if let cube = graph.nodes.first(where: { $0.specID == "orbit-cube" }) {
            let yaw = (time * cube.float("spin", 0) + cube.float("x", 0)) * 2 * .pi
            gizmo = [sin(yaw) * 0.9, min(max(cube.float("y", 0), -1), 1) * 0.9,
                     min(max(cube.float("z", 0), -1), 1) * 0.6]
        }

        return ProgramFrame(instructions: workingInstructions,
                            stateStride: compiled.stateFloatsPerPin,
                            generation: generation,
                            time: time, beatPhase: beat, dt: dt,
                            waveT: wt, waveCA: ca, waveCB: cb,
                            camera: cam,
                            depthStabilize: ema?.float("amount", 0.3) ?? 0,
                            // Holes persist only while EMA Smooth is active (points shouldn't
                            // blink under smoothing). RAW mode (no node) matches TDLidar's
                            // bit-exact bypass — holes stay holes, so a moving edge's IR shadow
                            // can't leave trailing "aftereffect" strands of stale depth.
                            holePersist: (ema?.float("amount", 0.3) ?? 0) > 0.001,
                            stems: stems > 0.5,
                            background: bg,
                            lights: lights,
                            post: post, ghost: ghost,
                            material: material, lookAt: lookAt, stem: stem,
                            uvTransform: uvT, edgePolicy: edge, domain: domain,
                            despeckleGap: despeckle, smoothRadius: smoothR, accumFrames: accum,
                            jbuFactor: jbu,
                            showGizmo: hasCube, gizmoPos: gizmo,
                            edgeReject: depthNode?.float("edgeCull", 0.06) ?? 0.06,
                            emaDeadband: ema?.float("deadband", 0.008) ?? 0.008,
                            emaAdapt: ema?.float("adapt", 5) ?? 5,
                            fillRadius: fillNode?.float("radius", 3) ?? 3,
                            fillGap: fillNode?.float("gap", 0.08) ?? 0.08,
                            despeckleSupport: despeckleNode?.float("support", 4) ?? 4,
                            smoothSigma: smoothNode?.float("sigma", 0.05) ?? 0.05,
                            jbuEdge: jbuNode?.float("edge", 0.08) ?? 0.08,
                            bloomSigma: graph.nodes.first(where: { $0.specID == "bloom" })?.float("radius", 6) ?? 6)
    }

    /// Face/Body Region mask centre for patch lane c0/c1 this frame, in view UV space.
    /// A joint Vision hasn't seen reads (0,0) → parked far offscreen so its mask reads 0.
    private static func regionCenter(_ node: GraphNode, _ which: Int, _ ctx: ControlContext) -> SIMD2<Float> {
        func pt(_ x: Float, _ y: Float) -> SIMD2<Float> {
            (x == 0 && y == 0) ? SIMD2(99, 99) : SIMD2(x, y)
        }
        if node.specID == "face-region" { return pt(ctx.bodyA.x, ctx.bodyA.y) }
        switch node.option("region", "person") {
        case "head": return pt(ctx.bodyA.x, ctx.bodyA.y)
        case "torso":
            let n = pt(ctx.bodyD.x, ctx.bodyD.y), r = pt(ctx.bodyD.z, ctx.bodyD.w)
            if n.x > 90 { return r }
            if r.x > 90 { return n }
            return (n + r) * 0.5
        case "armL": return which == 0 ? pt(ctx.bodyA.z, ctx.bodyA.w) : pt(ctx.bodyC.x, ctx.bodyC.y)
        case "armR": return which == 0 ? pt(ctx.bodyB.x, ctx.bodyB.y) : pt(ctx.bodyC.z, ctx.bodyC.w)
        case "hands": return which == 0 ? pt(ctx.bodyA.z, ctx.bodyA.w) : pt(ctx.bodyB.x, ctx.bodyB.y)
        default: return SIMD2(99, 99)   // person/background are depth-based, no centre
        }
    }

    /// Apple's AVFoundation depth filtering — driven by the Apple Depth Filter node's
    /// presence (OFF app-wide without it). Read by the camera layer on graph changes.
    var appleDepthFilterOn: Bool {
        graph.nodes.first { $0.specID == "apple-depth-filter" }
            .map { $0.float("enabled", 1) > 0.5 } ?? false
    }
}
