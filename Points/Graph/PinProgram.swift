import Foundation
import simd

// Pin program: the register-VM instruction stream executed per pin by the Metal
// interpreter kernel (Layer A of the hybrid engine — Plans/01 §4). Ops MUST mirror
// the switch in Shaders.metal `pin_program`.

enum PinOp: UInt32 {
    case halt = 0
    case constant = 1      // dst = imm
    case loadDepth = 2     // dst = (nearness01, valid, rawMeters, 0)
    case loadUV = 3        // dst = (u, v, baseX, baseY)
    case loadIndex = 4     // dst = (normIndex, hash01, centerDist, 0)
    case loadColor = 5     // dst = camera color at uv
    case loadTime = 6      // dst = (time, beatPhase, dt, 0)
    case add = 7, sub = 8, mul = 9, div = 10   // dst = a ⊕ b
    case madd = 11         // dst = a * imm.x + imm.y
    case mix = 12          // dst = mix(a, b, imm.x)
    case mixv = 13         // dst = mix(a, b, reg[imm.w].x)
    case clampOp = 14      // dst = clamp(a, imm.x, imm.y)
    case remap = 15        // dst = (a-imm.x)/(imm.y-imm.x)*(imm.w-imm.z)+imm.z
    case absOp = 16, minOp = 17, maxOp = 18
    case powOp = 19        // dst = pow(max(a,0), imm.x)
    case sinOp = 20        // dst = sin(a*imm.x + imm.y)*imm.z + imm.w
    case fractOp = 21, sqrtOp = 22
    case smooth = 23       // dst = smoothstep(imm.x, imm.y, a)
    case stepOp = 24       // dst = step(imm.x, a)
    case len = 25          // dst = length(a.xyz)
    case dist2 = 26        // dst = distance(a.xy, imm.xy)
    case hash1 = 27        // dst = hash01(a.x*imm.x + imm.y)
    case palette = 28      // dst = paletteLUT(row imm.y, t = a.x + imm.z)
    case loadState = 29    // dst.x = state[imm.x]
    case storeState = 30   // state[imm.x] = a.x
    case loadState3 = 31   // dst.xyz = state[imm.x ..< +3]
    case storeState3 = 32  // state[imm.x ..< +3] = a.xyz
    case writeZ = 33       // out.posOffset.z += a.x
    case writePos = 34     // out.posOffset += a.xyz
    case writeSize = 35    // out.size *= max(a.x, 0)
    case writeColor = 36   // out.color = a
    case hash3 = 37        // dst = per-pin unit-ish random vec3 in [-1,1], seeded imm.x
    case twistOp = 38      // dst = xy offset rotating baseXY around imm.xy by a.x turns, falloff imm.z
    case shockwave = 39    // dst = pulse from active waves (VMParams.waveT/C), imm=(speed,width,damping)
    case rectMask = 40     // dst = normalized box distance to rect imm=(cx,cy,hw,hh); 1 at edge
    // Point Display (a = depth nearness 0..1):
    case pinFieldXY = 41   // dst = XY spread/volume/wobble offset; imm=(separation, volume, wobble, edgeLock)
    case pinFieldZ = 42    // dst = Z push; imm=(gain, gamma, zFlatten, edgeLock)
    case hueShift = 43     // dst = a with hue rotated by imm.x turns (YIQ approx)
    case freeXY = 44       // dst = TDLidar free-cloud XY offset; imm=(separation, focusM, 0, 0); holes hide via keep flag
    case grazeCull = 45    // dst = a (passthrough); imm=(grazing01, edgeThreshM, 0, 0); culls via kernel keep flag
    case noise3 = 46       // dst = 3D noise [-1,1]; a.x optional z-drive; imm=(freq, seed, packed[ty+axis*10+aspect*100], timeMove)
    // Point Display METRIC mode — real camera-intrinsics unprojection (U.camIntrin = fx_n,fy_n,cx_n,cy_n):
    case unprojectXY = 47  // dst = metric XY offset = (u-cx)/fx·z, (v-cy)/fy·z (metres × imm.x scale); holes hide via keep
    case unprojectZ = 48   // dst = metric Z = (imm.y zRef − z)·imm.x scale → farther recedes (true perspective size)
    case writeRot = 55     // rotAcc += a.xyz (euler turns) — Rotation/Spin → Output.rotation
    case writeStretch = 56 // stretchAcc *= a.xyz — Stretch → Output.stretch
    case writeShape = 57   // shapeMorph = a.x (0 sphere → 1 cube) — Shape/Shape Morph → Output.shape
    case spinTurns = 58    // dst = time × imm.xyz (continuous spin turns)
}

/// 32 bytes; field order mirrors `PinInstr` in Shaders.metal.
struct PinInstruction {
    var op: UInt32
    var dst: UInt32
    var a: UInt32
    var b: UInt32
    var imm: SIMD4<Float>

    init(_ op: PinOp, dst: Int32 = 0, a: Int32 = 0, b: Int32 = 0, imm: SIMD4<Float> = .zero) {
        self.op = op.rawValue
        self.dst = UInt32(max(dst, 0)); self.a = UInt32(max(a, 0)); self.b = UInt32(max(b, 0))
        self.imm = imm
    }
}

/// A patchable immediate lane: runtime writes live values here without recompiling.
struct PatchRef: Hashable, Sendable {
    let instruction: Int
    let lane: Int    // 0-3 → imm.x..w
}

struct CompiledPinProgram: @unchecked Sendable {
    var instructions: [PinInstruction]
    /// "nodeID.paramName" or "nodeID.portName" → imm lanes to patch with live values.
    var patches: [String: [PatchRef]]
    var stateFloatsPerPin: Int
    var registerCount: Int

    static let empty = CompiledPinProgram(instructions: [PinInstruction(.halt)],
                                          patches: [:], stateFloatsPerPin: 0, registerCount: 0)
}

// MARK: - Builder (used by NodeSpec.emit closures)

struct PinProgramBuilder {
    // ponytail: generous ceiling instead of register reuse — 32×float4 = 512B/thread.
    // Occupancy cost measured in the Spike-1 benchmark; linear-scan reuse is the upgrade path.
    static let maxRegisters = 32

    private(set) var instructions: [PinInstruction] = []
    private(set) var patches: [String: [PatchRef]] = [:]
    private(set) var stateFloats = 0
    private var nextRegister: Int32 = 0
    var overflowed = false

    mutating func reg() -> Int32 {
        if nextRegister >= Int32(Self.maxRegisters) { overflowed = true; return Int32(Self.maxRegisters - 1) }
        defer { nextRegister += 1 }
        return nextRegister
    }
    var registerCount: Int { Int(nextRegister) }

    mutating func emit(_ i: PinInstruction) { instructions.append(i) }

    /// Emit with a runtime-patchable immediate lane bound to `key`.
    mutating func emitPatched(_ i: PinInstruction, key: String, lanes: [Int]) {
        for l in lanes { patches[key, default: []].append(PatchRef(instruction: instructions.count, lane: l)) }
        instructions.append(i)
    }

    /// Register an EXTRA patch key for the MOST-RECENTLY-emitted instruction — used to expose each
    /// param of a packed op under its own key (`d1.near`, `pd.separation`…) so nested triggers can
    /// drive them individually (§13). Additive: the packed key stays for the existing machinery.
    mutating func addPatchKey(_ key: String, lane: Int) {
        guard !instructions.isEmpty else { return }
        patches[key, default: []].append(PatchRef(instruction: instructions.count - 1, lane: lane))
    }

    /// Constant into a fresh register.
    mutating func constant(_ v: SIMD4<Float>) -> Int32 {
        let r = reg()
        emit(PinInstruction(.constant, dst: r, imm: v))
        return r
    }

    /// Patchable constant (param-driven): value updates land without recompiling.
    mutating func paramConstant(_ key: String, _ v: SIMD4<Float>) -> Int32 {
        let r = reg()
        emitPatched(PinInstruction(.constant, dst: r, imm: v), key: key, lanes: [0, 1, 2, 3])
        return r
    }

    /// Resolve a possibly-unwired input (-1) into a register, materializing a default lazily.
    mutating func materialize(_ r: Int32, default v: SIMD4<Float>) -> Int32 {
        r >= 0 ? r : constant(v)
    }

    mutating func allocState(_ floats: Int) -> Int {
        defer { stateFloats += floats }
        return stateFloats
    }

    func build() -> CompiledPinProgram {
        var instrs = instructions
        instrs.append(PinInstruction(.halt))
        return CompiledPinProgram(instructions: instrs, patches: patches,
                                  stateFloatsPerPin: stateFloats, registerCount: registerCount)
    }
}

// MARK: - Compiler (graph → program)

enum PinCompileError: Error, CustomStringConvertible {
    case noOutput
    case registerOverflow
    case unsupportedNode(String)

    var description: String {
        switch self {
        case .noOutput: return "graph has no Output node"
        case .registerOverflow: return "pin program exceeds \(PinProgramBuilder.maxRegisters) registers"
        case .unsupportedNode(let s): return "node '\(s)' has no pin-rate emitter"
        }
    }
}

struct PinProgramCompiler {
    let registry: NodeRegistry

    /// Compiles the pin-rate portion of the graph, rooted at the Output node.
    func compile(_ graph: Graph) throws -> CompiledPinProgram {
        guard let output = graph.nodes.first(where: { $0.specID == "output" }) else {
            throw PinCompileError.noOutput
        }
        var builder = PinProgramBuilder()
        var memo: [String: Int32] = [:]   // "nodeID.port" → register
        var resolvingReceives: Set<String> = []   // cycle guard for Send/Receive pairing

        func emitNode(_ node: GraphNode, port: String) throws -> Int32 {
            let memoKey = "\(node.id).\(port)"
            if let r = memo[memoKey] { return r }
            // Send/Receive: a Receive compiles as whatever feeds the matching Send channel —
            // the "wireless wire". A channel loop (Receive feeding its own Send) reads 0.
            if node.specID == "receive" {
                guard !resolvingReceives.contains(node.id) else { return builder.constant(.zero) }
                resolvingReceives.insert(node.id)
                defer { resolvingReceives.remove(node.id) }
                let chan = node.option("channel", "A")
                if let send = graph.nodes.first(where: { $0.specID == "send" && $0.option("channel", "A") == chan }),
                   let w = graph.wireInto(send.id, "in"),
                   let upstream = graph.node(w.fromNode),
                   registry.spec(upstream.specID)?.emit != nil {
                    let r = try emitNode(upstream, port: w.fromPort)
                    memo[memoKey] = r
                    return r
                }
                let z = builder.constant(.zero)
                memo[memoKey] = z
                return z
            }
            guard let spec = registry.spec(node.specID) else {
                throw PinCompileError.unsupportedNode(node.specID)
            }
            guard let emitter = spec.emit else {
                throw PinCompileError.unsupportedNode(node.specID)
            }
            // Resolve inputs first (recursion bottoms out at generators). -1 = unwired.
            // Selector nodes (N-way Switch) compile ONLY their active input's branch — inactive
            // branches are left unwired so they cost no ops/registers (recompile-on-switch).
            let activeIdx: Int? = spec.selectorParam.map { max(0, (Int(node.option($0, "1")) ?? 1) - 1) }
            var inputRegs: [Int32] = []
            for (i, input) in spec.inputs.enumerated() {
                if let a = activeIdx, i != a { inputRegs.append(-1); continue }
                if let wire = graph.wireInto(node.id, input.name) {
                    if let upstream = graph.node(wire.fromNode),
                       registry.spec(upstream.specID)?.emit != nil {
                        inputRegs.append(try emitNode(upstream, port: wire.fromPort))
                    } else {
                        // Wired from a control-rate node: patchable broadcast constant.
                        let key = "\(wire.fromNode).\(wire.fromPort)"
                        inputRegs.append(builder.paramConstant(key, input.defaultValue))
                    }
                } else {
                    inputRegs.append(-1)
                }
            }
            let outs = emitter(&builder, inputRegs, node)
            for (i, out) in outs.enumerated() where i < spec.outputs.count {
                memo["\(node.id).\(spec.outputs[i].name)"] = out
            }
            guard let r = memo[memoKey] ?? outs.first else {
                throw PinCompileError.unsupportedNode(node.specID)
            }
            return r
        }

        _ = try emitNode(output, port: "done")
        if builder.overflowed { throw PinCompileError.registerOverflow }
        return builder.build()
    }
}
