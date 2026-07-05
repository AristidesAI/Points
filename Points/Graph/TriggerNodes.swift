import Foundation
import simd

// Flat model — control-rate logic/shaping nodes. They register as normal Signal-family nodes (isControl)
// and live on the one canvas alongside everything else; wire them into a param's exposed port to drive it.
extension NodeRegistry {

    /// Node ids hidden from the palette. Only Drive Param — obsolete now that you wire straight to a port.
    static let triggerOnlyIDs: Set<String> = ["trigger-drive"]

    func registerTriggerNodes() {
        // SINK — "This Node" drive: routes a value into one of the host node's sliders.
        registerSpec(NodeSpec(
            id: "trigger-drive", name: "Drive Param", family: .tools,
            inputs: [PortSpec("value", .signal)],
            outputs: [PortSpec("out", .signal)],
            params: [.option("target", ["base", "gain", "separation", "size", "amount",
                                        "focus", "gamma", "wobble", "volume", "blend"], "base"),
                     .option("mode", ["offset", "replace", "multiply"], "offset"),
                     .float("amount", -4...4, 1)],
            execution: .control,
            description: "Drives one of the host node's sliders. TARGET = which param · MODE offset/replace/multiply · AMOUNT scales the incoming value. The sink of a node's trigger graph.",
            controlEval: { _, i, _ in [i[0]] }))

        // LOGIC — If / Then / Else
        registerSpec(NodeSpec(
            id: "t-if", name: "If / Then", family: .signal,
            inputs: [PortSpec("cond", .signal), PortSpec("a", .signal), PortSpec("b", .signal)],
            outputs: [PortSpec("out", .signal)],
            execution: .control, description: "If COND > 0.5 pass A, else B. The core if-this-then-that.",
            controlEval: { _, i, _ in [i[0].x > 0.5 ? i[1] : i[2]] }))
        registerSpec(NodeSpec(
            id: "t-and", name: "And", family: .signal,
            inputs: [PortSpec("a", .signal), PortSpec("b", .signal)], outputs: [PortSpec("out", .trigger)],
            execution: .control, description: "1 when A AND B are both > 0.5.",
            controlEval: { _, i, _ in [SIMD4(repeating: (i[0].x > 0.5 && i[1].x > 0.5) ? 1 : 0)] }))
        registerSpec(NodeSpec(
            id: "t-or", name: "Or", family: .signal,
            inputs: [PortSpec("a", .signal), PortSpec("b", .signal)], outputs: [PortSpec("out", .trigger)],
            execution: .control, description: "1 when A OR B is > 0.5.",
            controlEval: { _, i, _ in [SIMD4(repeating: (i[0].x > 0.5 || i[1].x > 0.5) ? 1 : 0)] }))
        registerSpec(NodeSpec(
            id: "t-not", name: "Not", family: .signal,
            inputs: [PortSpec("a", .signal)], outputs: [PortSpec("out", .signal)],
            execution: .control, description: "Inverts a gate: 1 − A.",
            controlEval: { _, i, _ in [SIMD4(repeating: i[0].x > 0.5 ? 0 : 1)] }))
        registerSpec(NodeSpec(
            id: "t-xor", name: "Xor", family: .signal,
            inputs: [PortSpec("a", .signal), PortSpec("b", .signal)], outputs: [PortSpec("out", .trigger)],
            execution: .control, description: "1 when exactly one of A/B is > 0.5.",
            controlEval: { _, i, _ in [SIMD4(repeating: ((i[0].x > 0.5) != (i[1].x > 0.5)) ? 1 : 0)] }))

        // Threshold — continuous level → clean event (Schmitt hysteresis + cooldown).
        registerSpec(NodeSpec(
            id: "t-threshold", name: "Threshold", family: .signal,
            inputs: [PortSpec("level", .signal)], outputs: [PortSpec("fired", .trigger)],
            params: [.float("rise", 0...1, 0.6), .float("fall", 0...1, 0.4), .float("cooldown", 0...2, 0.08)],
            execution: .control,
            description: "Fires when LEVEL crosses RISE; re-arms only below FALL (hysteresis); COOLDOWN blocks machine-gunning. Turns audio / hand-height into clean events.",
            controlEvalStateful: { node, i, ctx, s in
                let rise = node.float("rise", 0.6)
                let fall = min(node.float("fall", 0.4), rise - 0.02)
                let cd = node.float("cooldown", 0.08)
                var armed = s.x, since = s.y + ctx.dt
                var fired: Float = 0
                if armed > 0.5 && i[0].x >= rise && since >= cd { fired = 1; armed = 0; since = 0 }
                if armed < 0.5 && i[0].x <= fall { armed = 1 }
                s = SIMD4(armed, since, 0, 0)
                return [SIMD4(repeating: fired)]
            }))

        // Envelope — gate-aware AR: rises to 1 while TRIG is held (sticks), releases when it drops.
        registerSpec(NodeSpec(
            id: "t-envelope", name: "Envelope", family: .signal,
            inputs: [PortSpec("trig", .trigger)], outputs: [PortSpec("out", .signal)],
            params: [.float("attack", 0.001...3, 0.05), .float("release", 0.005...6, 0.35)],
            execution: .control,
            description: "Trigger → smooth 0-1. Rises over ATTACK while the trigger is held, falls over RELEASE when it drops. Feed a Curve node for shaped motion.",
            controlEvalStateful: { node, i, ctx, s in
                let target: Float = i[0].x > 0.5 ? 1 : 0
                let atk = max(node.float("attack", 0.05), 1e-4)
                let rel = max(node.float("release", 0.35), 1e-4)
                let rate = target > s.x ? ctx.dt / atk : ctx.dt / rel
                var v = s.x + (target - s.x) * min(rate, 1)
                if abs(v - target) < 5e-4 { v = target }
                s.x = v
                return [SIMD4(repeating: v)]
            }))

        // Curve — ease-shape a 0-1 value.
        registerSpec(NodeSpec(
            id: "t-curve", name: "Curve", family: .signal,
            inputs: [PortSpec("in", .signal)], outputs: [PortSpec("out", .signal)],
            params: [.option("curve", EasingCurve.allCases.map(\.rawValue), "quadOut")],
            execution: .control,
            description: "Reshapes a 0-1 value through an easing curve (cubic, back, bounce, elastic…).",
            controlEval: { node, i, _ in
                let c = EasingCurve(rawValue: node.option("curve", "quadOut")) ?? .quadOut
                return [SIMD4(repeating: c.apply(i[0].x))]
            }))

        // Spring — physical follow toward the input value.
        registerSpec(NodeSpec(
            id: "t-spring", name: "Spring", family: .signal,
            inputs: [PortSpec("target", .signal)], outputs: [PortSpec("out", .signal)],
            params: [.float("stiffness", 1...300, 120), .float("damping", 1...40, 18)],
            execution: .control,
            description: "Follows the target with physical overshoot/settle — organic pops.",
            controlEvalStateful: { node, i, ctx, s in
                let k = node.float("stiffness", 120), d = node.float("damping", 18)
                var value = s.x, vel = s.y
                let dt = min(ctx.dt, 1.0 / 60)
                let force = -k * (value - i[0].x) - d * vel
                vel += force * dt; value += vel * dt
                s = SIMD4(value, vel, 0, 0)
                return [SIMD4(repeating: value)]
            }))

        // Control-rate math (the GPU add/multiply are FIELD nodes, unusable in a control graph).
        registerSpec(NodeSpec(
            id: "t-add", name: "Add", family: .signal,
            inputs: [PortSpec("a", .signal), PortSpec("b", .signal)], outputs: [PortSpec("out", .signal)],
            execution: .control, description: "A + B (control-rate).",
            controlEval: { _, i, _ in [i[0] + i[1]] }))
        registerSpec(NodeSpec(
            id: "t-multiply", name: "Multiply", family: .signal,
            inputs: [PortSpec("a", .signal), PortSpec("b", .signal)], outputs: [PortSpec("out", .signal)],
            execution: .control, description: "A × B (control-rate).",
            controlEval: { _, i, _ in [i[0] * i[1]] }))
        registerSpec(NodeSpec(
            id: "t-remap", name: "Remap", family: .signal,
            inputs: [PortSpec("in", .signal)], outputs: [PortSpec("out", .signal)],
            params: [.float("inMin", -4...4, 0), .float("inMax", -4...4, 1),
                     .float("outMin", -4...4, 0), .float("outMax", -4...4, 1)],
            execution: .control, description: "Linear remap in→out range.",
            controlEval: { node, i, _ in
                let inMin = node.float("inMin", 0), inMax = node.float("inMax", 1)
                let t = (i[0].x - inMin) / max(inMax - inMin, 1e-4)
                let v = t * (node.float("outMax", 1) - node.float("outMin", 0)) + node.float("outMin", 0)
                return [SIMD4(repeating: v)]
            }))
    }
}
