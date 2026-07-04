import Foundation

// Graph core types — Plans/02 §1. The Swift registry is the engine's source of truth;
// Plans/03-Node-Catalog.json is the design catalog it grows toward.

// MARK: - Port types + auto-adapt

enum PortType: String, Codable, Sendable {
    case signal          // control-rate float
    case vec2, vec3      // control-rate vectors
    case color           // control-rate RGBA
    case trigger         // event pulse
    case fieldFloat = "field.float"   // per-pin float (GPU)
    case fieldVec3 = "field.vec3"     // per-pin vec3 (GPU)
    case fieldColor = "field.color"   // per-pin color (GPU)
    case domain          // pin-set handle
    case source          // depth+color stream bundle

    var isField: Bool {
        self == .fieldFloat || self == .fieldVec3 || self == .fieldColor
    }

    /// Auto-adapt rules (Plans/02): broadcast, splat, color<->vec3.
    func accepts(_ from: PortType) -> Bool {
        if self == from { return true }
        switch (from, self) {
        case (.signal, .fieldFloat),                       // broadcast
             (.signal, .fieldVec3), (.signal, .vec3),      // splat
             (.vec3, .color), (.color, .vec3),
             (.fieldFloat, .fieldVec3),                    // splat
             (.fieldVec3, .fieldFloat),                    // take .x (VM is lane-parallel)
             (.fieldVec3, .fieldColor), (.fieldColor, .fieldVec3),
             (.fieldFloat, .fieldColor),
             (.vec3, .fieldVec3), (.color, .fieldColor),   // broadcast vectors
             (.signal, .trigger):                          // rising-edge coercion
            return true
        default:
            return false
        }
    }
}

enum NodeFamily: String, Codable, CaseIterable, Sendable {
    case source = "SOURCE", grid = "GRID", filter = "FILTER", shape = "SHAPE", move = "MOVE"
    case color = "COLOR", signal = "SIGNAL", body = "BODY", time = "TIME", stage = "STAGE"
    case tools = "TOOLS"
}

// MARK: - Params

enum ParamValue: Codable, Equatable, Sendable {
    case float(Float)
    case int(Int)
    case bool(Bool)
    case option(String)

    var floatValue: Float {
        switch self {
        case .float(let f): return f
        case .int(let i): return Float(i)
        case .bool(let b): return b ? 1 : 0
        case .option: return 0
        }
    }
}

struct ParamSpec: Sendable {
    let name: String
    let range: ClosedRange<Float>?
    let options: [String]?
    let defaultValue: ParamValue
    let modSafe: Bool

    static func float(_ name: String, _ range: ClosedRange<Float>, _ def: Float, modSafe: Bool = true) -> ParamSpec {
        ParamSpec(name: name, range: range, options: nil, defaultValue: .float(def), modSafe: modSafe)
    }
    static func bool(_ name: String, _ def: Bool) -> ParamSpec {
        ParamSpec(name: name, range: nil, options: nil, defaultValue: .bool(def), modSafe: true)
    }
    static func option(_ name: String, _ options: [String], _ def: String) -> ParamSpec {
        ParamSpec(name: name, range: nil, options: options, defaultValue: .option(def), modSafe: false)
    }
}

// MARK: - Ports

struct PortSpec: Sendable {
    let name: String
    let type: PortType
    /// Default used when the input port is unwired (fields fall back to a constant).
    let defaultValue: SIMD4<Float>

    init(_ name: String, _ type: PortType, default def: SIMD4<Float> = .zero) {
        self.name = name; self.type = type; self.defaultValue = def
    }
}

// MARK: - Node spec

enum ExecutionClass: Sendable {
    case control        // CPU control-rate eval
    case interpreterOp  // emits pin-program ops
    case kernelPass     // fixed precompiled pass (domain gen, etc.)
    case render         // consumed by the render stage (material/stem/output)
}

/// One catalog entry. `emit` builds pin-program ops; `controlEval` runs at control rate.
struct NodeSpec: Sendable {
    let id: String
    let name: String
    let family: NodeFamily
    let inputs: [PortSpec]
    let outputs: [PortSpec]
    let params: [ParamSpec]
    let statePerPin: Int
    let execution: ExecutionClass
    let description: String

    /// Pin-rate: emit VM ops. Receives resolved input registers (one per input port,
    /// -1 = unwired) and must return output registers (one per output port).
    let emit: (@Sendable (inout PinProgramBuilder, _ inputs: [Int32], _ node: GraphNode) -> [Int32])?

    /// Control-rate: produce this node's output values for the frame.
    let controlEval: (@Sendable (_ node: GraphNode, _ inputs: [SIMD4<Float>], _ ctx: ControlContext) -> [SIMD4<Float>])?

    /// Stateful control-rate variant (envelopes, counters, S&H…): `state` persists per node
    /// instance across frames (zeroed on graph rebuild).
    let controlEvalStateful: (@Sendable (_ node: GraphNode, _ inputs: [SIMD4<Float>], _ ctx: ControlContext, _ state: inout SIMD4<Float>) -> [SIMD4<Float>])?

    init(id: String, name: String, family: NodeFamily,
         inputs: [PortSpec] = [], outputs: [PortSpec] = [],
         params: [ParamSpec] = [], statePerPin: Int = 0,
         execution: ExecutionClass,
         description: String = "",
         emit: (@Sendable (inout PinProgramBuilder, [Int32], GraphNode) -> [Int32])? = nil,
         controlEval: (@Sendable (GraphNode, [SIMD4<Float>], ControlContext) -> [SIMD4<Float>])? = nil,
         controlEvalStateful: (@Sendable (GraphNode, [SIMD4<Float>], ControlContext, inout SIMD4<Float>) -> [SIMD4<Float>])? = nil) {
        self.id = id; self.name = name; self.family = family
        self.inputs = inputs; self.outputs = outputs; self.params = params
        self.statePerPin = statePerPin; self.execution = execution
        self.description = description
        self.emit = emit; self.controlEval = controlEval
        self.controlEvalStateful = controlEvalStateful
    }

    var isControl: Bool { controlEval != nil || controlEvalStateful != nil }
}

/// Per-frame context handed to control-rate nodes.
struct ControlContext: Sendable {
    var time: Float = 0        // seconds since patch start
    var dt: Float = 1 / 60
    var beatPhase: Float = 0   // 0-1 within the current beat (global BPM transport)
    var bpm: Float = 120
    var frame: UInt64 = 0
    var touch: SIMD4<Float> = .zero   // x 0-1, y 0-1 (top-left origin), pressed 0/1, unused

    // Live-input buses — zeros until their engines land (audio / MIDI / Vision body).
    var audio: SIMD4<Float> = .zero    // bass, mid, high, rms (0-1)
    var onsets: SIMD4<Float> = .zero   // drumLow, drumMid, drumHigh, burst (pulse 0/1)
    var midi: SIMD4<Float> = .zero     // last CC value, last note, velocity, bend
    var bodyA: SIMD4<Float> = .zero    // headX, headY, handLX, handLY (0-1)
    var bodyB: SIMD4<Float> = .zero    // handRX, handRY, pinchAmount, handOpenness
    var gestures: SIMD4<Float> = .zero // palm, fist, peace, point (hand-gesture triggers)
    var present: SIMD4<Float> = .zero  // personPresent, entered-pulse, _, _
}
