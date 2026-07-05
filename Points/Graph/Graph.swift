import Foundation

// Graph document model: nodes + wires, validation, topological order, persistence.

nonisolated struct GraphNode: Identifiable, Codable, Sendable {
    let id: String                       // instance id, unique per graph
    let specID: String                   // NodeRegistry key
    var params: [String: ParamValue]
    var position: SIMD2<Float> = .zero   // canvas placement (editor)
    // Flat model — folded params (Depth near/far, Size min/max, Point Display's 7, options…) that the
    // user has "exposed" as real input ports on this card. Wire a Signal node into one → it drives that
    // param. Decodes to [] when the key is absent (old graphs). Undo covered by whole-Graph snapshots.
    var exposedParams: [String] = []
    // Dormant: the old nested trigger subgraph. Flattened to exposedParams; field kept so old saves decode.
    // ponytail: remove in a later cleanup once no serialized graphs carry it.
    var triggerGraph: Graph? = nil

    /// True when this node carries authored trigger logic (drives the port's filled/pulsing state).
    var hasTriggers: Bool { !(triggerGraph?.nodes.isEmpty ?? true) }

    func param(_ name: String) -> ParamValue? { params[name] }
    func float(_ name: String, _ fallback: Float = 0) -> Float {
        params[name]?.floatValue ?? fallback
    }
    func option(_ name: String, _ fallback: String = "") -> String {
        if case .option(let s)? = params[name] { return s }
        return fallback
    }
}

struct Wire: Codable, Hashable, Sendable {
    let fromNode: String
    let fromPort: String
    let toNode: String
    let toPort: String
}

struct Graph: Codable, Sendable {
    var schemaVersion = 1
    var nodes: [GraphNode] = []
    var wires: [Wire] = []
    var seed: UInt32 = 7

    func node(_ id: String) -> GraphNode? { nodes.first { $0.id == id } }

    /// The wire feeding (node, port), if any. One wire max per input port.
    func wireInto(_ nodeID: String, _ port: String) -> Wire? {
        wires.first { $0.toNode == nodeID && $0.toPort == port }
    }

    mutating func setParam(_ nodeID: String, _ name: String, _ value: ParamValue) {
        guard let i = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        nodes[i].params[name] = value
    }

    // MARK: Validation

    enum GraphError: Error, CustomStringConvertible {
        case unknownSpec(String)
        case unknownNode(String)
        case badPort(String)
        case typeMismatch(String)
        case cycle(String)

        var description: String {
            switch self {
            case .unknownSpec(let s): return "unknown node type '\(s)'"
            case .unknownNode(let s): return "wire references missing node '\(s)'"
            case .badPort(let s): return "no such port: \(s)"
            case .typeMismatch(let s): return "incompatible wire: \(s)"
            case .cycle(let s): return "graph has a cycle through '\(s)'"
            }
        }
    }

    func validate(registry: NodeRegistry) throws {
        for n in nodes where registry.spec(n.specID) == nil {
            throw GraphError.unknownSpec(n.specID)
        }
        for w in wires {
            guard let from = node(w.fromNode) else { throw GraphError.unknownNode(w.fromNode) }
            guard let to = node(w.toNode) else { throw GraphError.unknownNode(w.toNode) }
            guard let outSpec = registry.spec(from.specID)?.outputs.first(where: { $0.name == w.fromPort })
            else { throw GraphError.badPort("\(w.fromNode).\(w.fromPort)") }
            guard let inSpec = registry.spec(to.specID)?.inputs.first(where: { $0.name == w.toPort })
            else { throw GraphError.badPort("\(w.toNode).\(w.toPort)") }
            guard inSpec.type.accepts(outSpec.type) else {
                throw GraphError.typeMismatch("\(outSpec.type.rawValue) → \(inSpec.type.rawValue) at \(w.toNode).\(w.toPort)")
            }
        }
        _ = try topoOrder()
    }

    /// Kahn topological sort over wire dependencies.
    func topoOrder() throws -> [GraphNode] {
        var incoming: [String: Int] = [:]
        var downstream: [String: [String]] = [:]
        for n in nodes { incoming[n.id] = 0 }
        for w in wires {
            incoming[w.toNode, default: 0] += 1
            downstream[w.fromNode, default: []].append(w.toNode)
        }
        var queue = nodes.filter { incoming[$0.id] == 0 }.map(\.id)
        var order: [String] = []
        while let id = queue.popLast() {
            order.append(id)
            for d in downstream[id] ?? [] {
                incoming[d]! -= 1
                if incoming[d] == 0 { queue.append(d) }
            }
        }
        guard order.count == nodes.count else {
            let stuck = nodes.first { !order.contains($0.id) }?.id ?? "?"
            throw GraphError.cycle(stuck)
        }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return order.compactMap { byID[$0] }
    }
}

