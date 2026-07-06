import Foundation
import simd

// Visual Pack — 20 new field-transform nodes (color / depth / shape). Every node is a PURE transform:
// it takes field inputs and returns a field output, which you wire into the pipeline (Output.color /
// .size / .shape / .position …). No write-ops and no scalar→color broadcast, so they compose safely on
// the existing VM ops. Registered from registerFullCatalog().
extension NodeRegistry {

    func registerVisualPack() {
        let palettes = PaletteLUT.names

        // ─────────────────────────────  COLOR  ─────────────────────────────

        // 1. Light Gradient — scene brightness → colormap. RGB-driven "light" gradient.
        registerSpec(NodeSpec(
            id: "light-gradient", name: "Light Gradient", family: .color,
            inputs: [PortSpec("color", .fieldColor, default: [0.7, 0.7, 0.7, 1])],
            outputs: [PortSpec("color", .fieldColor)],
            params: [.option("map", palettes, "thermal"), .float("intensity", 0...3, 1)],
            execution: .interpreterOp,
            description: "Maps how BRIGHT each pin's camera color is onto a colormap — light becomes a gradient. Wire Video Color in, Output.color out.",
            emit: { b, inputs, node in
                let c = b.materialize(inputs[0], default: [0.7, 0.7, 0.7, 1])
                let lum = b.reg(); b.emit(PinInstruction(.len, dst: lum, a: c))       // length(rgb) ≈ brightness
                let t = b.reg()
                b.emitPatched(PinInstruction(.madd, dst: t, a: lum, imm: [0.577 * node.float("intensity", 1), 0, 0, 0]),
                              key: "\(node.id).intensity", lanes: [0])
                let row = Float(palettes.firstIndex(of: node.option("map", "thermal")) ?? 0)
                let r = b.reg()
                b.emitPatched(PinInstruction(.palette, dst: r, a: t, imm: [0, row, 0, 0]),
                              key: "\(node.id).map", lanes: [1])
                return [r]
            }))

        // 2. Duotone — brightness crossfades between two colors.
        registerSpec(NodeSpec(
            id: "duotone", name: "Duotone", family: .color,
            inputs: [PortSpec("color", .fieldColor, default: [0.7, 0.7, 0.7, 1])],
            outputs: [PortSpec("color", .fieldColor)],
            params: [.float("shadowR", 0...1, 0.1), .float("shadowG", 0...1, 0.05), .float("shadowB", 0...1, 0.3),
                     .float("lightR", 0...1, 1), .float("lightG", 0...1, 0.85), .float("lightB", 0...1, 0.4)],
            execution: .interpreterOp,
            description: "Two-tone remap: dark pins take the SHADOW color, bright pins the LIGHT color. Classic risograph look.",
            emit: { b, inputs, node in
                let c = b.materialize(inputs[0], default: [0.7, 0.7, 0.7, 1])
                let lum = b.reg(); b.emit(PinInstruction(.len, dst: lum, a: c))
                let t = b.reg(); b.emit(PinInstruction(.madd, dst: t, a: lum, imm: [0.577, 0, 0, 0]))
                let lo = b.paramConstant("\(node.id).shadow",
                                         [node.float("shadowR", 0.1), node.float("shadowG", 0.05), node.float("shadowB", 0.3), 1])
                let hi = b.paramConstant("\(node.id).light",
                                         [node.float("lightR", 1), node.float("lightG", 0.85), node.float("lightB", 0.4), 1])
                let r = b.reg()
                b.emit(PinInstruction(.mixv, dst: r, a: lo, b: hi, imm: [0, 0, 0, Float(t)]))
                return [r]
            }))

        // 3. Contrast — pivot around 0.5 (pivot stays fixed even when AMOUNT is driven).
        registerSpec(NodeSpec(
            id: "contrast", name: "Contrast", family: .color,
            inputs: [PortSpec("color", .fieldColor, default: [0.7, 0.7, 0.7, 1])],
            outputs: [PortSpec("out", .fieldColor)],
            params: [.float("amount", 0...3, 1.4)],
            execution: .interpreterOp,
            description: "Pushes colors away from mid-grey. AMOUNT 1 = unchanged, >1 crunchier, <1 flatter.",
            emit: { b, inputs, node in
                let c = b.materialize(inputs[0], default: [0.7, 0.7, 0.7, 1])
                let half = b.constant([0.5, 0.5, 0.5, 0.5])
                let d = b.reg(); b.emit(PinInstruction(.sub, dst: d, a: c, b: half))
                let k = node.float("amount", 1.4)
                let kreg = b.paramConstant("\(node.id).amount", [k, k, k, 1])
                let scaled = b.reg(); b.emit(PinInstruction(.mul, dst: scaled, a: d, b: kreg))
                let r = b.reg(); b.emit(PinInstruction(.add, dst: r, a: scaled, b: half))
                return [r]
            }))

        // 4. Color Invert — negative image (amount crossfades to the negative).
        registerSpec(NodeSpec(
            id: "color-invert", name: "Color Invert", family: .color,
            inputs: [PortSpec("color", .fieldColor, default: [0.7, 0.7, 0.7, 1])],
            outputs: [PortSpec("out", .fieldColor)],
            params: [.float("amount", 0...1, 1)],
            execution: .interpreterOp,
            description: "Photographic negative. AMOUNT crossfades between the original and inverted color.",
            emit: { b, inputs, node in
                let c = b.materialize(inputs[0], default: [0.7, 0.7, 0.7, 1])
                let one = b.constant([1, 1, 1, 1])
                let inv = b.reg(); b.emit(PinInstruction(.sub, dst: inv, a: one, b: c))
                let amt = b.paramConstant("\(node.id).amount", [node.float("amount", 1), 0, 0, 0])
                let r = b.reg()
                b.emit(PinInstruction(.mixv, dst: r, a: c, b: inv, imm: [0, 0, 0, Float(amt)]))
                return [r]
            }))

        // 5. Color Gamma — per-channel gamma curve.
        registerSpec(NodeSpec(
            id: "color-gamma", name: "Color Gamma", family: .color,
            inputs: [PortSpec("color", .fieldColor, default: [0.7, 0.7, 0.7, 1])],
            outputs: [PortSpec("out", .fieldColor)],
            params: [.float("gamma", 0.2...4, 1)],
            execution: .interpreterOp,
            description: "Raises color to a power — <1 lifts shadows, >1 deepens them.",
            emit: { b, inputs, node in
                let c = b.materialize(inputs[0], default: [0.7, 0.7, 0.7, 1])
                let r = b.reg()
                b.emitPatched(PinInstruction(.powOp, dst: r, a: c, imm: [node.float("gamma", 1), 0, 0, 0]),
                              key: "\(node.id).gamma", lanes: [0])
                return [r]
            }))

        // 6. Threshold Color — hard two-color cut at a brightness level.
        registerSpec(NodeSpec(
            id: "threshold-color", name: "Threshold Color", family: .color,
            inputs: [PortSpec("color", .fieldColor, default: [0.7, 0.7, 0.7, 1])],
            outputs: [PortSpec("color", .fieldColor)],
            params: [.float("level", 0...1, 0.5),
                     .float("darkR", 0...1, 0), .float("darkG", 0...1, 0), .float("darkB", 0...1, 0.15),
                     .float("liteR", 0...1, 1), .float("liteG", 0...1, 0.95), .float("liteB", 0...1, 0.8)],
            execution: .interpreterOp,
            description: "Two flat colors split at a brightness LEVEL — high-contrast poster / duochrome.",
            emit: { b, inputs, node in
                let c = b.materialize(inputs[0], default: [0.7, 0.7, 0.7, 1])
                let lum = b.reg(); b.emit(PinInstruction(.len, dst: lum, a: c))
                let t = b.reg(); b.emit(PinInstruction(.madd, dst: t, a: lum, imm: [0.577, 0, 0, 0]))
                let s = b.reg()
                b.emitPatched(PinInstruction(.stepOp, dst: s, a: t, imm: [node.float("level", 0.5), 0, 0, 0]),
                              key: "\(node.id).level", lanes: [0])
                let dark = b.paramConstant("\(node.id).dark",
                                           [node.float("darkR", 0), node.float("darkG", 0), node.float("darkB", 0.15), 1])
                let lite = b.paramConstant("\(node.id).lite",
                                           [node.float("liteR", 1), node.float("liteG", 0.95), node.float("liteB", 0.8), 1])
                let r = b.reg()
                b.emit(PinInstruction(.mixv, dst: r, a: dark, b: lite, imm: [0, 0, 0, Float(s)]))
                return [r]
            }))

        // 7. Color Levels — gamma then gain+lift, one node.
        registerSpec(NodeSpec(
            id: "color-levels", name: "Color Levels", family: .color,
            inputs: [PortSpec("color", .fieldColor, default: [0.7, 0.7, 0.7, 1])],
            outputs: [PortSpec("out", .fieldColor)],
            params: [.float("gamma", 0.2...4, 1), .float("gain", 0...3, 1), .float("lift", -0.5...0.5, 0)],
            execution: .interpreterOp,
            description: "Full tone control: GAMMA curve, then GAIN (multiply) and LIFT (add).",
            emit: { b, inputs, node in
                let c = b.materialize(inputs[0], default: [0.7, 0.7, 0.7, 1])
                let g = b.reg()
                b.emitPatched(PinInstruction(.powOp, dst: g, a: c, imm: [node.float("gamma", 1), 0, 0, 0]),
                              key: "\(node.id).gamma", lanes: [0])
                let r = b.reg()
                b.emitPatched(PinInstruction(.madd, dst: r, a: g, imm: [node.float("gain", 1), node.float("lift", 0), 0, 0]),
                              key: "\(node.id).gainlift", lanes: [0, 1])
                return [r]
            }))

        // 8. Color Clamp — crush blacks / clip whites.
        registerSpec(NodeSpec(
            id: "color-clamp", name: "Color Clamp", family: .color,
            inputs: [PortSpec("color", .fieldColor, default: [0.7, 0.7, 0.7, 1])],
            outputs: [PortSpec("out", .fieldColor)],
            params: [.float("low", 0...1, 0), .float("high", 0...1, 1)],
            execution: .interpreterOp,
            description: "Clips every channel to [LOW, HIGH] — crush blacks, clamp highlights.",
            emit: { b, inputs, node in
                let c = b.materialize(inputs[0], default: [0.7, 0.7, 0.7, 1])
                let r = b.reg()
                b.emitPatched(PinInstruction(.clampOp, dst: r, a: c, imm: [node.float("low", 0), node.float("high", 1), 0, 0]),
                              key: "\(node.id).range", lanes: [0, 1])
                return [r]
            }))

        // 9. Screen Blend — additive-ish blend of two color fields (lightens).
        registerSpec(NodeSpec(
            id: "color-screen", name: "Screen Blend", family: .color,
            inputs: [PortSpec("a", .fieldColor, default: [0, 0, 0, 1]), PortSpec("b", .fieldColor, default: [0, 0, 0, 1])],
            outputs: [PortSpec("out", .fieldColor)],
            execution: .interpreterOp,
            description: "Screen blend of two colors: 1-(1-a)(1-b). Only ever brightens — great for glow layers.",
            emit: { b, inputs, _ in
                let a = b.materialize(inputs[0], default: [0, 0, 0, 1])
                let c = b.materialize(inputs[1], default: [0, 0, 0, 1])
                let one = b.constant([1, 1, 1, 1])
                let ia = b.reg(); b.emit(PinInstruction(.sub, dst: ia, a: one, b: a))
                let ib = b.reg(); b.emit(PinInstruction(.sub, dst: ib, a: one, b: c))
                let prod = b.reg(); b.emit(PinInstruction(.mul, dst: prod, a: ia, b: ib))
                let r = b.reg(); b.emit(PinInstruction(.sub, dst: r, a: one, b: prod))
                return [r]
            }))

        // ─────────────────────────────  DEPTH  ─────────────────────────────

        // 10. Depth Bands — posterize depth into hard steps (contour terraces).
        registerSpec(NodeSpec(
            id: "depth-bands", name: "Depth Bands", family: .grid,
            inputs: [PortSpec("depth", .fieldFloat, default: [0.5, 0.5, 0.5, 0.5])],
            outputs: [PortSpec("stepped", .fieldFloat)],
            params: [.float("bands", 2...20, 6)],
            execution: .interpreterOp,
            description: "Quantizes a 0-1 depth field into hard terraces — topographic steps. Feed Depth in.",
            emit: { b, inputs, node in
                let d = b.materialize(inputs[0], default: [0.5, 0.5, 0.5, 0.5])
                let n = max(node.float("bands", 6), 2)
                let scaled = b.reg(), frac = b.reg()
                b.emitPatched(PinInstruction(.madd, dst: scaled, a: d, imm: [n, 0, 0, 0]),
                              key: "\(node.id).n", lanes: [0])
                b.emit(PinInstruction(.fractOp, dst: frac, a: scaled))
                b.emit(PinInstruction(.sub, dst: scaled, a: scaled, b: frac))
                let r = b.reg()
                b.emitPatched(PinInstruction(.madd, dst: r, a: scaled, imm: [1 / n, 0, 0, 0]),
                              key: "\(node.id).inv", lanes: [0])
                return [r]
            }))

        // 11. Depth Fog — fade a color toward a fog color with distance.
        registerSpec(NodeSpec(
            id: "depth-fog", name: "Depth Fog", family: .color,
            inputs: [PortSpec("color", .fieldColor, default: [0.8, 0.8, 0.8, 1]),
                     PortSpec("depth", .fieldFloat, default: [0.5, 0.5, 0.5, 0.5])],
            outputs: [PortSpec("color", .fieldColor)],
            params: [.float("fogR", 0...1, 0.05), .float("fogG", 0...1, 0.06), .float("fogB", 0...1, 0.1),
                     .float("density", 0...1, 0.6)],
            execution: .interpreterOp,
            description: "Blends pins toward a FOG color as they get FARTHER — atmospheric depth cue.",
            emit: { b, inputs, node in
                let c = b.materialize(inputs[0], default: [0.8, 0.8, 0.8, 1])
                let d = b.materialize(inputs[1], default: [0.5, 0.5, 0.5, 0.5])
                let amt = b.reg()   // fog rises with (1-nearness)·density
                let one = b.constant([1, 1, 1, 1])
                b.emit(PinInstruction(.sub, dst: amt, a: one, b: d))
                b.emitPatched(PinInstruction(.madd, dst: amt, a: amt, imm: [node.float("density", 0.6), 0, 0, 0]),
                              key: "\(node.id).density", lanes: [0])
                let fog = b.paramConstant("\(node.id).fog",
                                          [node.float("fogR", 0.05), node.float("fogG", 0.06), node.float("fogB", 0.1), 1])
                let r = b.reg()
                b.emit(PinInstruction(.mixv, dst: r, a: c, b: fog, imm: [0, 0, 0, Float(amt)]))
                return [r]
            }))

        // 12. Depth Rings — sinusoidal contour lines through depth.
        registerSpec(NodeSpec(
            id: "depth-rings", name: "Depth Rings", family: .grid,
            inputs: [PortSpec("depth", .fieldFloat, default: [0.5, 0.5, 0.5, 0.5])],
            outputs: [PortSpec("rings", .fieldFloat)],
            params: [.float("frequency", 1...60, 18), .float("sharpness", 1...8, 2)],
            execution: .interpreterOp,
            description: "0-1 contour bands rippling through depth — wire to Size or a color for topo lines.",
            emit: { b, inputs, node in
                let d = b.materialize(inputs[0], default: [0.5, 0.5, 0.5, 0.5])
                let s = b.reg()   // sin → 0..1
                b.emitPatched(PinInstruction(.sinOp, dst: s, a: d, imm: [6.2831 * node.float("frequency", 18), 0, 0.5, 0.5]),
                              key: "\(node.id).freq", lanes: [0])
                let r = b.reg()
                b.emitPatched(PinInstruction(.powOp, dst: r, a: s, imm: [node.float("sharpness", 2), 0, 0, 0]),
                              key: "\(node.id).sharp", lanes: [0])
                return [r]
            }))

        // 13. Depth Slice — 0-1 mask keeping a near..far band; multiply into Size to hide the rest.
        registerSpec(NodeSpec(
            id: "depth-slice", name: "Depth Slice", family: .grid,
            inputs: [PortSpec("depth", .fieldFloat, default: [0.5, 0.5, 0.5, 0.5])],
            outputs: [PortSpec("mask", .fieldFloat)],
            params: [.float("near", 0...1, 0.3), .float("far", 0...1, 0.7), .float("feather", 0...0.3, 0.05)],
            execution: .interpreterOp,
            description: "1 inside a depth slab (NEAR…FAR), 0 outside, FEATHERed edges. Multiply into Size to reveal only a slice.",
            emit: { b, inputs, node in
                let d = b.materialize(inputs[0], default: [0.5, 0.5, 0.5, 0.5])
                let near = node.float("near", 0.3), far = node.float("far", 0.7), f = max(node.float("feather", 0.05), 0.001)
                let lo = b.reg()
                b.emitPatched(PinInstruction(.smooth, dst: lo, a: d, imm: [near - f, near + f, 0, 0]),
                              key: "\(node.id).lo", lanes: [0, 1])
                let hi = b.reg()
                b.emitPatched(PinInstruction(.smooth, dst: hi, a: d, imm: [far + f, far - f, 0, 0]),
                              key: "\(node.id).hi", lanes: [0, 1])
                let r = b.reg(); b.emit(PinInstruction(.mul, dst: r, a: lo, b: hi))
                return [r]
            }))

        // 14. Size by Depth — remap depth to a size multiplier (near bigger / smaller).
        registerSpec(NodeSpec(
            id: "size-by-depth", name: "Size by Depth", family: .shape,
            inputs: [PortSpec("depth", .fieldFloat, default: [0.5, 0.5, 0.5, 0.5])],
            outputs: [PortSpec("size", .fieldFloat)],
            params: [.float("nearSize", 0...4, 2), .float("farSize", 0...4, 0.4)],
            execution: .interpreterOp,
            description: "Maps depth to a size multiplier — near pins one size, far pins another. Wire into Size.",
            emit: { b, inputs, node in
                let d = b.materialize(inputs[0], default: [0.5, 0.5, 0.5, 0.5])
                let r = b.reg()   // nearness 0..1 → far..near
                b.emitPatched(PinInstruction(.remap, dst: r, a: d,
                                             imm: [0, 1, node.float("farSize", 0.4), node.float("nearSize", 2)]),
                              key: "\(node.id).range", lanes: [2, 3])
                return [r]
            }))

        // 15. Depth Invert — flip near/far of a 0-1 depth field.
        registerSpec(NodeSpec(
            id: "depth-invert", name: "Depth Invert", family: .grid,
            inputs: [PortSpec("depth", .fieldFloat, default: [0.5, 0.5, 0.5, 0.5])],
            outputs: [PortSpec("out", .fieldFloat)],
            execution: .interpreterOp,
            description: "1 − depth: swap what counts as near and far for any downstream effect.",
            emit: { b, inputs, _ in
                let d = b.materialize(inputs[0], default: [0.5, 0.5, 0.5, 0.5])
                let r = b.reg(); b.emit(PinInstruction(.madd, dst: r, a: d, imm: [-1, 1, 0, 0]))
                return [r]
            }))

        // ────────────────────────  SHAPE / FIELD  ────────────────────────

        // Output.shape encoding: value = targetShapeIndex + morphAmount(0…0.999). A bare 0-1 value
        // decodes as target 0 = sphere (no visible change), so these nodes bake a TARGET index in.
        let shapeTargets = ["cube", "tube", "slab", "cone", "ring", "disc", "spike", "diamond"]
        func shapeTargetIndex(_ name: String) -> Float {
            Float((shapeTargets.firstIndex(of: name) ?? 0) + 1)   // sphere is 0 → targets start at 1
        }

        // 16. Shape Blend — drive the sphere↔TARGET morph from any 0-1 field. Wire into Output.shape.
        registerSpec(NodeSpec(
            id: "shape-blend", name: "Shape Blend", family: .shape,
            inputs: [PortSpec("amount", .fieldFloat, default: [0, 0, 0, 0])],
            outputs: [PortSpec("shape", .fieldFloat)],
            params: [.option("target", shapeTargets, "cube")],
            execution: .interpreterOp,
            description: "Morphs every pin from sphere toward the TARGET shape by a 0-1 field, per pin. Wire depth / Noise.out / audio → amount and shape → Output.shape: hot areas grow cubes (or spikes, rings…).",
            emit: { b, inputs, node in
                let a = b.materialize(inputs[0], default: .zero)
                let r = b.reg()
                b.emit(PinInstruction(.clampOp, dst: r, a: a, imm: [0, 0.999, 0, 0]))
                b.emit(PinInstruction(.madd, dst: r, a: r,
                                      imm: [1, shapeTargetIndex(node.option("target", "cube")), 0, 0]))
                return [r]
            }))

        // 17. Shape by Depth — near pins one amount of the TARGET shape, far pins another.
        registerSpec(NodeSpec(
            id: "shape-by-depth", name: "Shape by Depth", family: .shape,
            inputs: [PortSpec("depth", .fieldFloat, default: [0.5, 0.5, 0.5, 0.5])],
            outputs: [PortSpec("shape", .fieldFloat)],
            params: [.option("target", shapeTargets, "cube"),
                     .float("nearMorph", 0...1, 0), .float("farMorph", 0...1, 1)],
            execution: .interpreterOp,
            description: "Morphs pins toward the TARGET shape by depth — near pins NEARMORPH of the way there, far pins FARMORPH. Wire Depth.depth → depth and shape → Output.shape: spheres up close dissolve into cubes at distance.",
            emit: { b, inputs, node in
                let d = b.materialize(inputs[0], default: [0.5, 0.5, 0.5, 0.5])
                let r = b.reg()
                b.emitPatched(PinInstruction(.remap, dst: r, a: d,
                                             imm: [0, 1, node.float("farMorph", 1), node.float("nearMorph", 0)]),
                              key: "\(node.id).range", lanes: [2, 3])
                b.emit(PinInstruction(.clampOp, dst: r, a: r, imm: [0, 0.999, 0, 0]))
                b.emit(PinInstruction(.madd, dst: r, a: r,
                                      imm: [1, shapeTargetIndex(node.option("target", "cube")), 0, 0]))
                return [r]
            }))

        // 18. Field Curve — generic easing/gamma on any 0-1 field (shape signals before use).
        registerSpec(NodeSpec(
            id: "field-curve", name: "Field Curve", family: .signal,
            inputs: [PortSpec("in", .fieldFloat, default: [0, 0, 0, 0])],
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("curve", 0.15...6, 1)],
            execution: .interpreterOp,
            description: "Bends a 0-1 field through a power curve — ease any per-pin signal before it drives something.",
            emit: { b, inputs, node in
                let a = b.materialize(inputs[0], default: .zero)
                let r = b.reg()
                b.emitPatched(PinInstruction(.powOp, dst: r, a: a, imm: [node.float("curve", 1), 0, 0, 0]),
                              key: "\(node.id).curve", lanes: [0])
                return [r]
            }))

        // 19. Field Fold — fold a 0-1 field around its centre (V shape), tunable pivot.
        registerSpec(NodeSpec(
            id: "field-fold", name: "Field Fold", family: .signal,
            inputs: [PortSpec("in", .fieldFloat, default: [0.5, 0.5, 0.5, 0.5])],
            outputs: [PortSpec("out", .fieldFloat)],
            params: [.float("pivot", 0...1, 0.5), .float("gain", 0...4, 2)],
            execution: .interpreterOp,
            description: "abs(in − PIVOT)·GAIN — turns a ramp into a symmetric V. Great for centre-out gradients.",
            emit: { b, inputs, node in
                let a = b.materialize(inputs[0], default: [0.5, 0.5, 0.5, 0.5])
                let piv = b.paramConstant("\(node.id).pivot", [node.float("pivot", 0.5), 0, 0, 0])
                let d = b.reg(); b.emit(PinInstruction(.sub, dst: d, a: a, b: piv))
                let ab = b.reg(); b.emit(PinInstruction(.absOp, dst: ab, a: d))
                let r = b.reg()
                b.emitPatched(PinInstruction(.madd, dst: r, a: ab, imm: [node.float("gain", 2), 0, 0, 0]),
                              key: "\(node.id).gain", lanes: [0])
                return [r]
            }))

        // 20. Orbit — swirl the pins around the frame centre by a continuous angle.
        registerSpec(NodeSpec(
            id: "orbit", name: "Orbit", family: .move,
            inputs: [PortSpec("angle", .fieldFloat, default: [0, 0, 0, 0])],
            outputs: [PortSpec("offset", .fieldVec3)],
            params: [.float("falloff", 0...4, 1)],
            execution: .interpreterOp,
            description: "Rotates every pin around the frame centre by ANGLE turns (wire an LFO / time in), FALLOFF fades it toward the centre. Wire into Output.position.",
            emit: { b, inputs, node in
                let ang = b.materialize(inputs[0], default: .zero)
                let r = b.reg()
                // centre = (0,0): twistOp works in view units (wall spans ±extX/±extY), not uv
                b.emitPatched(PinInstruction(.twistOp, dst: r, a: ang, imm: [0, 0, node.float("falloff", 1), 0]),
                              key: "\(node.id).falloff", lanes: [2])
                return [r]
            }))
    }
}
