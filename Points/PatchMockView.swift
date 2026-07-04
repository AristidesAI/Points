import SwiftUI
import UIKit

// The node editor — REAL and editable. Blender-geometry-nodes reading of the live graph:
// every node shows its ports (one row per port), its parameter values, and a faint internal
// flow drawing (how inputs meet the output) behind them.
//
//   pan        ONE-finger drag on empty canvas (inertia on a flick; tap anywhere stops it)
//   zoom       pinch anywhere — pinch always wins over wire/node touches
//              (pinch over a SELECTED node resizes that node instead)
//   select     tap a node / tap a wire
//   move       hold a node ~¼s (white glow), drag — wires stretch; dragging to an edge
//              auto-scrolls the canvas (TouchDesigner style)
//   rewire     grab a wire near either end, drag to a compatible port (drop on nothing = delete)
//   new wire   drag straight out of any port square; snaps to the nearest compatible port
//   box select cursor tool in the bottom strip (white outline when armed) → drag a rectangle
//   add        + in the strip → full-screen palette → hold a ROW (or ADD on its card) for 1s
//   undo/redo  in the strip — parameter changes included (one step per slider gesture)
//   minimap    always visible in the strip (bottom bar)

// MARK: - Shared canvas camera (editor + bottom-strip minimap read the same state)

@Observable
final class EditorCamera {
    var offset = CGSize(width: 16, height: 40)
    var scale: CGFloat = 0.5
    var selectTool = false
    var viewSize = CGSize(width: 390, height: 520)
    var fitted = false

    func toScreen(_ w: SIMD2<Float>) -> CGPoint {
        CGPoint(x: CGFloat(w.x) * scale + offset.width, y: CGFloat(w.y) * scale + offset.height)
    }

    func toWorld(_ s: CGPoint) -> SIMD2<Float> {
        [Float((s.x - offset.width) / scale), Float((s.y - offset.height) / scale)]
    }
}

// MARK: - Shared card layout metrics (card view, wire anchors + hit tests all use these)

enum NodeMetrics {
    static let width: CGFloat = 168
    static let headerH: CGFloat = 24
    static let portRowH: CGFloat = 20
    static let paramRowH: CGFloat = 16
    static let maxParamRows = 5
    static let portDot: CGFloat = 14          // 2× the old 7, half proud of the edge

    static func paramRows(_ spec: NodeSpec) -> Int { min(spec.params.count, maxParamRows) }

    static func height(_ spec: NodeSpec) -> CGFloat {
        headerH + CGFloat(spec.inputs.count) * portRowH
            + CGFloat(paramRows(spec)) * paramRowH
            + CGFloat(spec.outputs.count) * portRowH + 8
    }

    /// Port anchor offsets from the card's top-left. Dots stick 3pt past the edge.
    static func inputAnchor(_ spec: NodeSpec, _ index: Int) -> CGPoint {
        CGPoint(x: -3, y: headerH + portRowH * (CGFloat(index) + 0.5))
    }

    static func outputAnchor(_ spec: NodeSpec, _ index: Int) -> CGPoint {
        let y = headerH + CGFloat(spec.inputs.count) * portRowH
            + CGFloat(paramRows(spec)) * paramRowH + portRowH * (CGFloat(index) + 0.5)
        return CGPoint(x: width + 3, y: y)
    }
}

// MARK: - Pinch host (zoom is UIKit so it ALWAYS wins; there is no 2-finger pan anymore)

private struct PinchHost: UIViewRepresentable {
    var onPinch: (CGFloat, CGPoint) -> Void      // incremental factor, center in view coords
    var onBegan: () -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = true
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = context.coordinator
        v.addGestureRecognizer(pinch)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPinch = onPinch
        context.coordinator.onBegan = onBegan
        context.coordinator.onEnded = onEnded
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPinch: onPinch, onBegan: onBegan, onEnded: onEnded)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPinch: (CGFloat, CGPoint) -> Void
        var onBegan: () -> Void
        var onEnded: () -> Void
        private var last: CGFloat = 1

        init(onPinch: @escaping (CGFloat, CGPoint) -> Void,
             onBegan: @escaping () -> Void, onEnded: @escaping () -> Void) {
            self.onPinch = onPinch; self.onBegan = onBegan; self.onEnded = onEnded
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began:
                last = g.scale
                onBegan()
            case .changed:
                let factor = g.scale / max(last, 0.001)
                last = g.scale
                onPinch(factor, g.location(in: g.view))
            default:
                onEnded()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

// MARK: - The editor canvas

struct NodeEditorView: View {
    let runtime: GraphRuntime
    @Bindable var camera: EditorCamera
    @Binding var selection: Set<String>
    @Binding var selectedWire: Wire?
    /// Pulling a NEW wire out of an OUTPUT and dropping on empty space → node creation,
    /// filtered to nodes that accept this port's type (source node, source port, drop world pos).
    var onDropOutput: ((String, String, SIMD2<Float>) -> Void)? = nil

    @AppStorage("wireStyle") private var wireStyle = 0   // 0 curved · 1 straight · 2 right-angle

    // Interaction state
    @State private var draggingNode: String?
    @State private var grabOffsets: [String: SIMD2<Float>] = [:]
    @State private var rubber: (start: CGPoint, current: CGPoint)?
    @State private var wireDrag: WireDragState?
    @State private var ghostFinger: CGPoint?
    @State private var dragActive = false
    @State private var dragMode: CanvasDragMode = .none
    @State private var lastPan: CGSize = .zero
    @State private var pinchActive = false
    @State private var inertia: Task<Void, Never>?
    @State private var selectedPort: PortRef?     // white-outlined port square
    @State private var portDraft: PortDraft?      // active port-column interaction

    private enum CanvasDragMode { case none, pan, rubber, wire, moveNode, port }

    struct PortRef: Equatable { let node: String; let isInput: Bool; let index: Int }

    private struct PortDraft {
        let node: String
        let isInput: Bool
        var index: Int
        let columnX: CGFloat
        var detached: Bool
    }

    private struct WireDragState {
        let original: Wire?           // nil = new wire pulled from a port
        let fixedNode: String         // the end that stays connected
        let fixedPort: String
        let fixedIndex: Int
        let fixedIsInput: Bool
        let seekInput: Bool           // true → hunting for an input port
    }

    private var registry: NodeRegistry { NodeRegistry.shared }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.45)
                PinchHost(
                    onPinch: { factor, center in
                        // Pinch ALWAYS zooms the canvas (node resize removed — it was inconsistent).
                        let newScale = min(max(camera.scale * factor, 0.2), 2.2)
                        let f = newScale / camera.scale
                        camera.offset.width = center.x - (center.x - camera.offset.width) * f
                        camera.offset.height = center.y - (center.y - camera.offset.height) * f
                        camera.scale = newScale
                    },
                    onBegan: {
                        // Pinch beats everything: drop any drag mid-flight, freeze pans.
                        pinchActive = true
                        stopInertia()
                        wireDrag = nil
                        ghostFinger = nil
                        portDraft = nil
                        draggingNode = nil
                        dragMode = .none
                    },
                    onEnded: { pinchActive = false }
                )
                wireCanvas
                    .allowsHitTesting(false)
                nodeLayer
                if let r = rubber {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .overlay(Rectangle().stroke(Color.white.opacity(0.7), lineWidth: 1))
                        .frame(width: abs(r.current.x - r.start.x), height: abs(r.current.y - r.start.y))
                        .offset(x: min(r.start.x, r.current.x), y: min(r.start.y, r.current.y))
                        .allowsHitTesting(false)
                }
                if let err = runtime.compileError {
                    Text(err)
                        .font(.system(size: 9)).foregroundStyle(.black)
                        .padding(6).background(Color(hex: 0xFFC24D))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .coordinateSpace(name: "canvas")
            .gesture(canvasDrag)
            .onAppear {
                camera.viewSize = geo.size
                if !camera.fitted { camera.fitted = true; fitGraph(in: geo.size) }
            }
            .onChange(of: geo.size) { camera.viewSize = geo.size }
            // ContentView clears `fitted` when the node view opens → refit (always recenter).
            .onChange(of: camera.fitted) {
                if !camera.fitted { fitGraph(in: camera.viewSize); camera.fitted = true }
            }
        }
        .clipped()
    }

    private func fitGraph(in size: CGSize) {
        let nodes = runtime.graph.nodes
        guard !nodes.isEmpty else { return }
        var minX = Float.greatestFiniteMagnitude, minY = minX, maxX = -minX, maxY = -minX
        for n in nodes {
            minX = min(minX, n.position.x); minY = min(minY, n.position.y)
            maxX = max(maxX, n.position.x + Float(NodeMetrics.width))
            maxY = max(maxY, n.position.y + 200)
        }
        let bw = CGFloat(maxX - minX), bh = CGFloat(maxY - minY)
        camera.scale = min(max(min(size.width / max(bw, 1), size.height / max(bh, 1)) * 0.9, 0.25), 1.1)
        camera.offset.width = (size.width - bw * camera.scale) / 2 - CGFloat(minX) * camera.scale
        camera.offset.height = (size.height - bh * camera.scale) / 2 - CGFloat(minY) * camera.scale
    }

    private func stopInertia() {
        inertia?.cancel()
        inertia = nil
    }

    private func startInertia(_ v: CGSize) {
        guard hypot(v.width, v.height) > 260 else { return }
        stopInertia()
        var vel = v
        inertia = Task { @MainActor in
            while !Task.isCancelled, hypot(vel.width, vel.height) > 14 {
                camera.offset.width += vel.width * 0.016
                camera.offset.height += vel.height * 0.016
                vel.width *= 0.93
                vel.height *= 0.93
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    // MARK: node cards

    private var nodeLayer: some View {
        // Cards are pure visuals — ALL interaction lives in canvasDrag, so tap/move/pan/wire
        // behave the same everywhere and a node above a wire never fights it.
        ForEach(runtime.graph.nodes, id: \.id) { node in
            if let spec = registry.spec(node.specID) {
                let sp = camera.toScreen(node.position)
                NodeCardView(node: node, spec: spec,
                             selected: selection.contains(node.id),
                             dragged: draggingNode == node.id,
                             wiredInputs: wiredInputNames(node.id),
                             highlightPort: portHighlight(for: node.id))
                    .frame(width: NodeMetrics.width, height: NodeMetrics.height(spec), alignment: .top)
                    .scaleEffect(camera.scale, anchor: .topLeading)
                    .offset(x: sp.x, y: sp.y)
                    .allowsHitTesting(false)
            }
        }
    }

    private func portHighlight(for nodeID: String) -> (isInput: Bool, index: Int)? {
        guard let p = selectedPort, p.node == nodeID else { return nil }
        return (p.isInput, p.index)
    }

    // MARK: wires

    private func wiredInputNames(_ nodeID: String) -> Set<String> {
        Set(runtime.graph.wires.filter { $0.toNode == nodeID }.map(\.toPort))
    }

    private func anchorScreen(_ nodeID: String, portIndex: Int, isInput: Bool) -> CGPoint {
        guard let node = runtime.graph.node(nodeID), let spec = registry.spec(node.specID) else { return .zero }
        let local = isInput ? NodeMetrics.inputAnchor(spec, portIndex)
                            : NodeMetrics.outputAnchor(spec, portIndex)
        let sp = camera.toScreen(node.position)
        return CGPoint(x: sp.x + local.x * camera.scale, y: sp.y + local.y * camera.scale)
    }

    private func wireEndpoints(_ w: Wire) -> (CGPoint, CGPoint)? {
        guard let from = runtime.graph.node(w.fromNode), let to = runtime.graph.node(w.toNode),
              let fs = registry.spec(from.specID), let ts = registry.spec(to.specID),
              let oi = fs.outputs.firstIndex(where: { $0.name == w.fromPort }),
              let ii = ts.inputs.firstIndex(where: { $0.name == w.toPort }) else { return nil }
        return (anchorScreen(w.fromNode, portIndex: oi, isInput: false),
                anchorScreen(w.toNode, portIndex: ii, isInput: true))
    }

    private var wireCanvas: some View {
        Canvas { ctx, _ in
            for w in runtime.graph.wires {
                if let dragging = wireDrag?.original, dragging == w { continue }
                guard let (a, b) = wireEndpoints(w) else { continue }
                let isSel = selectedWire == w
                let color = wireColor(w)   // matches the port square (by port TYPE)
                let p = wirePath(a, b)
                ctx.stroke(p, with: .color(isSel ? .white.opacity(0.35) : color.opacity(0.2)),
                           lineWidth: isSel ? 6 : 4)
                ctx.stroke(p, with: .color(isSel ? .white : color.opacity(0.9)),
                           lineWidth: isSel ? 2.2 : 1.6)
            }
            // Live ghost: the fixed anchor is recomputed every frame, so panning/zooming
            // mid-drag keeps the wire glued to its port AND to the holding finger.
            if let drag = wireDrag, let finger = ghostFinger {
                let fixed = anchorScreen(drag.fixedNode, portIndex: drag.fixedIndex,
                                         isInput: drag.fixedIsInput)
                let p = drag.seekInput ? wirePath(fixed, finger) : wirePath(finger, fixed)
                ctx.stroke(p, with: .color(.white.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1.8, dash: [5, 4]))
                ctx.fill(Path(ellipseIn: CGRect(x: finger.x - 5, y: finger.y - 5, width: 10, height: 10)),
                         with: .color(.white))
            }
        }
    }

    private func wirePath(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path()
        p.move(to: a)
        switch wireStyle {
        case 1:                                   // straight
            p.addLine(to: b)
        case 2:                                   // right-angle: horizontal → vertical → horizontal
            let midX = (a.x + b.x) / 2
            p.addLine(to: CGPoint(x: midX, y: a.y))
            p.addLine(to: CGPoint(x: midX, y: b.y))
            p.addLine(to: b)
        default:                                  // curved
            let dx = max(abs(b.x - a.x) * 0.5, 24)
            p.addCurve(to: b,
                       control1: CGPoint(x: a.x + dx, y: a.y),
                       control2: CGPoint(x: b.x - dx, y: b.y))
        }
        return p
    }

    private func specFamilyOf(_ nodeID: String) -> NodeFamily {
        guard let node = runtime.graph.node(nodeID),
              let spec = registry.spec(node.specID) else { return .tools }
        return spec.family
    }

    /// Wire colour = the colour of its source-output port square (by port TYPE), so wires
    /// and the squares they leave always match.
    private func wireColor(_ w: Wire) -> Color {
        guard let from = runtime.graph.node(w.fromNode),
              let fs = registry.spec(from.specID),
              let t = fs.outputs.first(where: { $0.name == w.fromPort })?.type else { return Theme.text2 }
        return portColor(t)
    }

    // MARK: canvas-level single-finger gesture: pan (hand) / box select (cursor) / wire ends

    // ONE consistent model:
    //  • tap a node        → select it (white). Node above a wire always wins.
    //  • tap a wire        → select it (white).
    //  • tap empty         → deselect.
    //  • tap a port square  → select the node + highlight that port.
    //  • drag a SELECTED node   → moves immediately (no hold).
    //  • drag a SELECTED wire's END → disconnects that end and rewires it.
    //  • drag off a port column → slide to pick the port, pull out a NEW wire (never grabs the old one).
    //  • drag anywhere else → pans the canvas (works over unselected nodes/wires too).
    private var canvasDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { g in
                if !dragActive {
                    dragActive = true
                    stopInertia()
                    if camera.selectTool {
                        dragMode = .rubber
                    } else if let pr = portColumnHit(at: g.startLocation) {
                        // start on a port column → pick / pull a NEW wire from that port
                        portDraft = PortDraft(node: pr.node, isInput: pr.isInput, index: pr.index,
                                              columnX: portColumnX(pr), detached: false)
                        selectedPort = pr
                        dragMode = .port
                    } else if let id = selectedNodeHit(at: g.startLocation) {
                        beginNodeMove(id, at: g.startLocation)   // a SELECTED node moves — no hold
                        dragMode = .moveNode
                    } else if let end = selectedWireEndHit(at: g.startLocation) {
                        pickUpWire(end.wire, seekInput: end.seekInput)   // rewire a SELECTED wire's end
                        dragMode = .wire
                    } else {
                        dragMode = .pan
                        lastPan = .zero
                    }
                }
                guard !pinchActive else { return }
                switch dragMode {
                case .pan:
                    camera.offset.width += g.translation.width - lastPan.width
                    camera.offset.height += g.translation.height - lastPan.height
                    lastPan = g.translation
                case .rubber:
                    rubber = (g.startLocation, g.location)
                case .wire:
                    ghostFinger = g.location
                case .moveNode:
                    moveHeldNodes(to: g.location)
                case .port:
                    updatePortDraft(to: g.location)
                case .none:
                    break
                }
            }
            .onEnded { g in
                defer { dragActive = false; dragMode = .none }
                let moved = hypot(g.translation.width, g.translation.height)
                switch dragMode {
                case .rubber:
                    if moved < 8 { tapSelect(at: g.startLocation) } else { applyRubberSelection() }
                    rubber = nil
                case .wire:
                    finishWireDrag(at: g.location)
                case .moveNode:
                    draggingNode = nil; grabOffsets = [:]
                case .port:
                    finishPortDraft(at: g.location)
                case .pan:
                    if moved < 8 { tapSelect(at: g.startLocation) } else { startInertia(g.velocity) }
                case .none:
                    if moved < 8 { tapSelect(at: g.startLocation) }
                }
            }
    }

    // MARK: selection + node move (new model)

    /// A tap: node over wire wins; falls through to wire, then to empty (deselect).
    private func tapSelect(at p: CGPoint) {
        stopInertia()
        if let id = nodeHit(at: p) {
            selectedWire = nil
            if camera.selectTool {
                if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            } else {
                selection = [id]
            }
            selectedPort = portColumnHit(at: p).map { PortRef(node: $0.node, isInput: $0.isInput, index: $0.index) }
        } else if let w = wirePathHit(at: p) {
            selectedWire = w; selection.removeAll(); selectedPort = nil
        } else {
            selection.removeAll(); selectedWire = nil; selectedPort = nil
        }
    }

    private func selectedNodeHit(at p: CGPoint) -> String? {
        guard let id = nodeHit(at: p), selection.contains(id) else { return nil }
        return id
    }

    private func beginNodeMove(_ id: String, at loc: CGPoint) {
        draggingNode = id
        stopInertia()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        runtime.pushUndo()
        let moving = selection.contains(id) ? selection : [id]
        grabOffsets = Dictionary(uniqueKeysWithValues:
            moving.compactMap { mid in
                runtime.graph.node(mid).map { (mid, $0.position - camera.toWorld(loc)) }
            })
    }

    private func moveHeldNodes(to loc: CGPoint) {
        // Edge auto-scroll only at the very border.
        let m: CGFloat = 20, speed: CGFloat = 8
        if loc.x < m { camera.offset.width += speed }
        if loc.x > camera.viewSize.width - m { camera.offset.width -= speed }
        if loc.y < m { camera.offset.height += speed }
        if loc.y > camera.viewSize.height - m { camera.offset.height -= speed }
        let base = camera.toWorld(loc)
        for (mid, off) in grabOffsets { runtime.moveNode(mid, to: base + off) }
    }

    // MARK: port column (slide-to-pick + pull a new wire)

    private func portColumnHit(at p: CGPoint) -> PortRef? {
        let cs = camera.scale
        for node in runtime.graph.nodes.reversed() {
            guard let spec = registry.spec(node.specID) else { continue }
            let sp = camera.toScreen(node.position)
            let cardH = NodeMetrics.height(spec) * cs
            guard p.y > sp.y - 10, p.y < sp.y + cardH + 10 else { continue }
            let leftX = sp.x, rightX = sp.x + NodeMetrics.width * cs
            if !spec.inputs.isEmpty, abs(p.x - leftX) < 28 {
                return PortRef(node: node.id, isInput: true, index: nearestPort(spec, node.id, true, p.y))
            }
            if !spec.outputs.isEmpty, abs(p.x - rightX) < 28 {
                return PortRef(node: node.id, isInput: false, index: nearestPort(spec, node.id, false, p.y))
            }
        }
        return nil
    }

    private func nearestPort(_ spec: NodeSpec, _ nodeID: String, _ isInput: Bool, _ y: CGFloat) -> Int {
        let count = isInput ? spec.inputs.count : spec.outputs.count
        var best = 0, bestD = CGFloat.greatestFiniteMagnitude
        for i in 0..<count {
            let d = abs(anchorScreen(nodeID, portIndex: i, isInput: isInput).y - y)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    private func portColumnX(_ pr: PortRef) -> CGFloat {
        guard let node = runtime.graph.node(pr.node) else { return 0 }
        let sp = camera.toScreen(node.position)
        return pr.isInput ? sp.x : sp.x + NodeMetrics.width * camera.scale
    }

    private func portName(_ nodeID: String, _ isInput: Bool, _ index: Int) -> String {
        guard let node = runtime.graph.node(nodeID), let spec = registry.spec(node.specID) else { return "" }
        let ports = isInput ? spec.inputs : spec.outputs
        return index < ports.count ? ports[index].name : ""
    }

    private func updatePortDraft(to p: CGPoint) {
        guard var d = portDraft else { return }
        if !d.detached {
            if abs(p.x - d.columnX) < 34 {
                // still hovering the column: slide vertically to choose the port
                if let pr = portColumnHit(at: p), pr.node == d.node, pr.isInput == d.isInput {
                    d.index = pr.index
                    selectedPort = pr
                }
            } else {
                // pulled away → start dragging a NEW wire from the chosen port
                d.detached = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let name = portName(d.node, d.isInput, d.index)
                wireDrag = WireDragState(original: nil, fixedNode: d.node, fixedPort: name,
                                         fixedIndex: d.index, fixedIsInput: d.isInput, seekInput: !d.isInput)
            }
        }
        if d.detached { ghostFinger = p }
        portDraft = d
    }

    private func finishPortDraft(at p: CGPoint) {
        let d = portDraft
        portDraft = nil
        guard let d else { return }
        if d.detached { finishWireDrag(at: p) }   // snaps to a port, or → node creation (output)
        else { tapSelect(at: p) }                 // a tap on the port: select node + highlight port
    }

    /// The SELECTED wire only: dragging ANYWHERE along it (except the midpoint) grabs the
    /// nearer end for rewiring — you just have to tap it white first.
    private func selectedWireEndHit(at p: CGPoint) -> (wire: Wire, seekInput: Bool)? {
        guard let w = selectedWire, let (a, b) = wireEndpoints(w) else { return nil }
        guard wireDistance(a, b, p) < 22 else { return nil }              // on the selected wire
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        guard hypot(mid.x - p.x, mid.y - p.y) > 26 else { return nil }    // midpoint is dead (ambiguous)
        let da = hypot(a.x - p.x, a.y - p.y), db = hypot(b.x - p.x, b.y - p.y)
        return db < da ? (w, true) : (w, false)   // nearer the input end → keep the output fixed
    }

    private func pickUpWire(_ w: Wire, seekInput: Bool) {
        guard let from = runtime.graph.node(w.fromNode), let to = runtime.graph.node(w.toNode),
              let fs = registry.spec(from.specID), let ts = registry.spec(to.specID),
              let oi = fs.outputs.firstIndex(where: { $0.name == w.fromPort }),
              let ii = ts.inputs.firstIndex(where: { $0.name == w.toPort }) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if seekInput {
            wireDrag = WireDragState(original: w, fixedNode: w.fromNode, fixedPort: w.fromPort,
                                     fixedIndex: oi, fixedIsInput: false, seekInput: true)
        } else {
            wireDrag = WireDragState(original: w, fixedNode: w.toNode, fixedPort: w.toPort,
                                     fixedIndex: ii, fixedIsInput: true, seekInput: false)
        }
        selectedWire = w
    }

    private func wirePathHit(at p: CGPoint) -> Wire? {
        for w in runtime.graph.wires {
            guard let (a, b) = wireEndpoints(w) else { continue }
            if wireDistance(a, b, p) < 14 { return w }
        }
        return nil
    }

    /// Nearest distance from `p` to the wire between `a` and `b`, matching the current style.
    private func wireDistance(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGFloat {
        switch wireStyle {
        case 1:
            return segDistance(a, b, p)
        case 2:
            let midX = (a.x + b.x) / 2
            let m1 = CGPoint(x: midX, y: a.y), m2 = CGPoint(x: midX, y: b.y)
            return min(segDistance(a, m1, p), min(segDistance(m1, m2, p), segDistance(m2, b, p)))
        default:
            let dx = max(abs(b.x - a.x) * 0.5, 24)
            let c1 = CGPoint(x: a.x + dx, y: a.y), c2 = CGPoint(x: b.x - dx, y: b.y)
            var best = CGFloat.greatestFiniteMagnitude
            for i in 0...24 {
                let q = cubicPoint(a, c1, c2, b, CGFloat(i) / 24)
                best = min(best, hypot(q.x - p.x, q.y - p.y))
            }
            return best
        }
    }

    private func segDistance(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func cubicPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
                            _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let x = u*u*u*p0.x + 3*u*u*t*p1.x + 3*u*t*t*p2.x + t*t*t*p3.x
        let y = u*u*u*p0.y + 3*u*u*t*p1.y + 3*u*t*t*p2.y + t*t*t*p3.y
        return CGPoint(x: x, y: y)
    }

    /// Drop the dragged wire end: snap to the nearest COMPATIBLE port in range,
    /// otherwise delete the original wire (dropping on nothing disconnects).
    private func finishWireDrag(at p: CGPoint) {
        defer { wireDrag = nil; ghostFinger = nil }
        guard let drag = wireDrag else { return }
        let snapRange: CGFloat = 48

        if drag.seekInput {
            guard let srcNode = runtime.graph.node(drag.fixedNode),
                  let srcSpec = registry.spec(srcNode.specID),
                  let outType = srcSpec.outputs.first(where: { $0.name == drag.fixedPort })?.type
            else { return }
            var best: (String, String)? = nil
            var bestD = snapRange
            for node in runtime.graph.nodes where node.id != drag.fixedNode {
                guard let spec = registry.spec(node.specID) else { continue }
                for (i, port) in spec.inputs.enumerated() where port.type.accepts(outType) {
                    let a = anchorScreen(node.id, portIndex: i, isInput: true)
                    let d = hypot(a.x - p.x, a.y - p.y)
                    if d < bestD { bestD = d; best = (node.id, port.name) }
                }
            }
            if let (toNode, toPort) = best {
                if let orig = drag.original, orig.toNode == toNode, orig.toPort == toPort { return }
                let ok = runtime.rewire(dropping: drag.original,
                                        from: drag.fixedNode, fromPort: drag.fixedPort,
                                        to: toNode, toPort: toPort)
                UIImpactFeedbackGenerator(style: ok ? .medium : .heavy).impactOccurred()
            } else if let orig = drag.original {
                runtime.removeWire(orig)
            } else {
                // NEW wire pulled from an OUTPUT, dropped on empty space → node creation,
                // filtered to nodes that accept this port's type, auto-connected on add.
                onDropOutput?(drag.fixedNode, drag.fixedPort, camera.toWorld(p))
            }
        } else {
            guard let dstNode = runtime.graph.node(drag.fixedNode),
                  let dstSpec = registry.spec(dstNode.specID),
                  let inType = dstSpec.inputs.first(where: { $0.name == drag.fixedPort })?.type
            else { return }
            var best: (String, String)? = nil
            var bestD = snapRange
            for node in runtime.graph.nodes where node.id != drag.fixedNode {
                guard let spec = registry.spec(node.specID) else { continue }
                for (i, port) in spec.outputs.enumerated() where inType.accepts(port.type) {
                    let a = anchorScreen(node.id, portIndex: i, isInput: false)
                    let d = hypot(a.x - p.x, a.y - p.y)
                    if d < bestD { bestD = d; best = (node.id, port.name) }
                }
            }
            if let (fromNode, fromPort) = best {
                let ok = runtime.rewire(dropping: drag.original,
                                        from: fromNode, fromPort: fromPort,
                                        to: drag.fixedNode, toPort: drag.fixedPort)
                UIImpactFeedbackGenerator(style: ok ? .medium : .heavy).impactOccurred()
            } else if let orig = drag.original {
                runtime.removeWire(orig)
            }
        }
    }

    private func applyRubberSelection() {
        guard let r = rubber else { return }
        let rect = CGRect(x: min(r.start.x, r.current.x), y: min(r.start.y, r.current.y),
                          width: abs(r.current.x - r.start.x), height: abs(r.current.y - r.start.y))
        var hit: Set<String> = []
        for node in runtime.graph.nodes {
            guard let spec = registry.spec(node.specID) else { continue }
            let sp = camera.toScreen(node.position)
            let frame = CGRect(x: sp.x, y: sp.y,
                               width: NodeMetrics.width * camera.scale,
                               height: NodeMetrics.height(spec) * camera.scale)
            if rect.intersects(frame) { hit.insert(node.id) }
        }
        if !hit.isEmpty { selection = hit }
    }

    private func nodeHit(at p: CGPoint) -> String? {
        for node in runtime.graph.nodes.reversed() {
            guard let spec = registry.spec(node.specID) else { continue }
            let sp = camera.toScreen(node.position)
            let frame = CGRect(x: sp.x, y: sp.y,
                               width: NodeMetrics.width * camera.scale,
                               height: NodeMetrics.height(spec) * camera.scale)
            if frame.contains(p) { return node.id }
        }
        return nil
    }
}

// MARK: - Bottom strip: tool · + · undo · redo (centered) + always-on minimap (right)

struct EditorToolStrip: View {
    let runtime: GraphRuntime
    @Bindable var camera: EditorCamera
    @Binding var selection: Set<String>
    var onAdd: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                stripButton(camera.selectTool ? "cursorarrow" : "hand.point.up.left",
                            highlighted: camera.selectTool, enabled: true) {
                    camera.selectTool.toggle()
                }
                stripButton("plus", enabled: true, action: onAdd)
                stripButton("arrow.uturn.backward", enabled: runtime.canUndo) { runtime.undo() }
                stripButton("arrow.uturn.forward", enabled: runtime.canRedo) { runtime.redo() }
            }
            Spacer(minLength: 8)
            MinimapView(runtime: runtime, camera: camera, selection: selection)
                .frame(width: 104, height: 56)
                .padding(.trailing, 10)
        }
        .frame(height: 64)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func stripButton(_ symbol: String, highlighted: Bool = false, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(enabled ? Theme.text : Theme.text2.opacity(0.4))
                .frame(width: 46, height: 40)
                .background(Theme.panel)
                .overlay(Rectangle().stroke(highlighted ? Color.white : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Always-visible graph overview: node rectangles + the current viewport window.
struct MinimapView: View {
    let runtime: GraphRuntime
    let camera: EditorCamera
    var selection: Set<String> = []

    /// World-space bounds of the graph, plus the minimap→world scale for a given size.
    private func bounds() -> (minX: Float, minY: Float, maxX: Float, maxY: Float) {
        let nodes = runtime.graph.nodes
        guard let f = nodes.first else { return (0, 0, 1, 1) }
        var minX = f.position.x, minY = f.position.y, maxX = minX + 1, maxY = minY + 1
        for n in nodes {
            minX = min(minX, n.position.x); minY = min(minY, n.position.y)
            maxX = max(maxX, n.position.x + Float(NodeMetrics.width))
            maxY = max(maxY, n.position.y + 180)
        }
        return (minX, minY, maxX, maxY)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let b = bounds()
                let s = min(size.width / CGFloat(max(b.maxX - b.minX, 1)),
                            size.height / CGFloat(max(b.maxY - b.minY, 1)))
                for n in runtime.graph.nodes {
                    let x = CGFloat(n.position.x - b.minX) * s
                    let y = CGFloat(n.position.y - b.minY) * s
                    let sel = selection.contains(n.id)
                    ctx.fill(Path(CGRect(x: x, y: y, width: 8, height: 5)),
                             with: .color(sel ? .white : Theme.text2.opacity(0.7)))
                }
                let tl = camera.toWorld(.zero)
                let br = camera.toWorld(CGPoint(x: camera.viewSize.width, y: camera.viewSize.height))
                let vx = CGFloat(tl.x - b.minX) * s, vy = CGFloat(tl.y - b.minY) * s
                let vw = CGFloat(br.x - tl.x) * s, vh = CGFloat(br.y - tl.y) * s
                ctx.stroke(Path(CGRect(x: vx, y: vy, width: vw, height: vh)),
                           with: .color(.white.opacity(0.8)), lineWidth: 1)
            }
            .contentShape(Rectangle())
            // Tap or drag anywhere on the minimap → jump the viewport there.
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in jump(to: g.location, in: geo.size) })
        }
        .background(Color.black.opacity(0.7))
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
    }

    private func jump(to p: CGPoint, in size: CGSize) {
        let b = bounds()
        let s = min(size.width / CGFloat(max(b.maxX - b.minX, 1)),
                    size.height / CGFloat(max(b.maxY - b.minY, 1)))
        guard s > 0 else { return }
        let wx = b.minX + Float(p.x / s)
        let wy = b.minY + Float(p.y / s)
        camera.offset.width = camera.viewSize.width / 2 - CGFloat(wx) * camera.scale
        camera.offset.height = camera.viewSize.height / 2 - CGFloat(wy) * camera.scale
    }
}

// MARK: - Blender-style node card: header, a row per port, values, and a faint
// internal flow drawing (inputs converging on the output with an op glyph) behind them.

struct NodeCardView: View {
    let node: GraphNode
    let spec: NodeSpec
    let selected: Bool
    let dragged: Bool
    let wiredInputs: Set<String>
    var highlightPort: (isInput: Bool, index: Int)? = nil

    /// White outline on the currently-picked port square (slide-to-select feedback).
    private func portHi(_ isInput: Bool, _ i: Int) -> Bool {
        highlightPort?.isInput == isInput && highlightPort?.index == i
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(spec.name)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(node.id).font(.system(size: 8.5).monospaced())
                    .foregroundStyle(.black.opacity(0.55))
            }
            .padding(.horizontal, 7)
            .frame(height: NodeMetrics.headerH)
            .background(familyColor(spec.family))

            ZStack(alignment: .topLeading) {
                flowCanvas   // internal wiring picture, behind the rows
                VStack(spacing: 0) {
                    ForEach(Array(spec.inputs.enumerated()), id: \.offset) { i, port in
                        HStack(spacing: 6) {
                            Rectangle().fill(portColor(port.type))
                                .frame(width: NodeMetrics.portDot, height: NodeMetrics.portDot)
                                .overlay(Rectangle().stroke(portHi(true, i) ? Color.white : .black.opacity(0.55),
                                                            lineWidth: portHi(true, i) ? 2 : 1))
                            Text(port.name).font(.system(size: 9.5)).foregroundStyle(Theme.text)
                            Spacer(minLength: 0)
                            if wiredInputs.contains(port.name) {
                                Rectangle().fill(Theme.text2).frame(width: 5, height: 5)
                            }
                        }
                        .padding(.leading, -NodeMetrics.portDot / 2 - 3)   // dot proud of the edge
                        .padding(.trailing, 7)
                        .frame(height: NodeMetrics.portRowH)
                    }
                    ForEach(spec.params.prefix(NodeMetrics.maxParamRows), id: \.name) { p in
                        HStack {
                            Text(p.name).font(.system(size: 9)).foregroundStyle(Theme.text2)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(paramDisplay(p))
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.text)
                        }
                        .padding(.horizontal, 7)
                        .frame(height: NodeMetrics.paramRowH)
                    }
                    ForEach(Array(spec.outputs.enumerated()), id: \.offset) { i, port in
                        HStack(spacing: 6) {
                            Spacer(minLength: 0)
                            Text(port.name).font(.system(size: 9.5)).foregroundStyle(Theme.text)
                            Rectangle().fill(portColor(port.type))
                                .frame(width: NodeMetrics.portDot, height: NodeMetrics.portDot)
                                .overlay(Rectangle().stroke(portHi(false, i) ? Color.white : .black.opacity(0.55),
                                                            lineWidth: portHi(false, i) ? 2 : 1))
                        }
                        .padding(.leading, 7)
                        .padding(.trailing, -NodeMetrics.portDot / 2 - 3)
                        .frame(height: NodeMetrics.portRowH)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: NodeMetrics.width)
        .background(Color(hex: 0x101010).opacity(0.96))
        .overlay(Rectangle().stroke(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.5 : 1))
        .opacity(selected || dragged ? 1.0 : 0.82)
        .shadow(color: dragged ? .white.opacity(0.55) : .clear, radius: dragged ? 10 : 0)
    }

    /// The node's internal picture: input rows flow to the output row. Multi-input nodes
    /// converge on an op glyph; 1-in-1-out draws a single line; sources draw nothing.
    private var flowCanvas: some View {
        Canvas { ctx, _ in
            let ins = spec.inputs.count, outs = spec.outputs.count
            guard ins >= 1, outs >= 1 else { return }
            // Row centers in this ZStack's space (which starts below the header).
            func inY(_ i: Int) -> CGFloat { NodeMetrics.portRowH * (CGFloat(i) + 0.5) }
            func outY(_ i: Int) -> CGFloat {
                CGFloat(ins) * NodeMetrics.portRowH
                    + CGFloat(NodeMetrics.paramRows(spec)) * NodeMetrics.paramRowH
                    + NodeMetrics.portRowH * (CGFloat(i) + 0.5)
            }
            let ax: CGFloat = 12
            let bx = NodeMetrics.width - 12
            let midY = (inY(0) + inY(ins - 1) + outY(0)) / 3
            let mid = CGPoint(x: NodeMetrics.width * 0.5, y: midY)
            let stroke = Color.white.opacity(0.13)
            var p = Path()
            for i in 0..<ins {
                p.move(to: CGPoint(x: ax, y: inY(i)))
                p.addQuadCurve(to: mid, control: CGPoint(x: mid.x * 0.7, y: inY(i)))
            }
            for o in 0..<outs {
                p.move(to: mid)
                p.addQuadCurve(to: CGPoint(x: bx, y: outY(o)),
                               control: CGPoint(x: (mid.x + bx) / 2, y: outY(o)))
            }
            ctx.stroke(p, with: .color(stroke), lineWidth: 2)
            if ins > 1 {
                ctx.draw(Text(glyph)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.3)),
                         at: mid)
            }
        }
        .allowsHitTesting(false)
    }

    private var glyph: String {
        switch spec.id {
        case "add": return "+"
        case "subtract": return "−"
        case "multiply": return "×"
        case "divide": return "÷"
        case "min": return "min"
        case "max": return "max"
        case "mix", "color-mix": return "mix"
        default: return "ƒ"
        }
    }

    private func paramDisplay(_ p: ParamSpec) -> String {
        switch node.params[p.name] ?? p.defaultValue {
        case .float(let f): return String(format: "%.2f", f)
        case .int(let i): return "\(i)"
        case .bool(let b): return b ? "ON" : "OFF"
        case .option(let s): return s.uppercased()
        }
    }
}

// MARK: - Node settings bar — actions + REAL params of the selection, live-editable.
// Sized by content (the node view bar grows with the selected node's parameter count).

struct NodeSettingsBar: View {
    let runtime: GraphRuntime
    @Binding var selection: Set<String>

    private var primaryID: String? { selection.count == 1 ? selection.first : nil }
    private var node: GraphNode? { primaryID.flatMap { runtime.graph.node($0) } }
    private var spec: NodeSpec? { node.flatMap { NodeRegistry.shared.spec($0.specID) } }

    var body: some View {
        VStack(spacing: 0) {
            if selection.isEmpty {
                Text("Tap a node to select it, then drag to move it")
                    .font(.system(size: 10)).foregroundStyle(Theme.text2)
                    .padding(.vertical, 14)
            } else {
                header
                if selection.count > 1 {
                    Text("\(selection.count) nodes selected — remove, duplicate or reset them together")
                        .font(.system(size: 10)).foregroundStyle(Theme.text2)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                } else if let spec, let node {
                    if spec.id == "camera" {
                        CamJogRow(runtime: runtime, label: "ORBIT",
                                  xParam: "orbitX", yParam: "orbitY", step: 0.12, limit: 0.9)
                        CamJogRow(runtime: runtime, label: "POSITION",
                                  xParam: "centerX", yParam: "centerY", step: 0.1, limit: 1.0)
                    }
                    let floats = spec.params.filter { $0.range != nil }
                    ForEach(floats, id: \.name) { p in     // ALL float params (was capped at 4)
                        ParamSliderRow(runtime: runtime, nodeID: node.id, param: p)
                    }
                    ForEach(spec.params.filter { $0.options != nil }, id: \.name) { p in
                        OptionSegmentRow(runtime: runtime, nodeID: node.id, param: p)
                    }
                    if floats.isEmpty && spec.params.allSatisfy({ $0.options == nil }) && spec.id != "camera" {
                        Text(spec.description)
                            .font(.system(size: 10)).foregroundStyle(Theme.text2)
                            .lineSpacing(3).padding(.horizontal, 16).padding(.vertical, 8)
                    }
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Rectangle().fill(familyColor(spec?.family ?? .tools)).frame(width: 10, height: 10)
            Text(selection.count > 1 ? "\(selection.count) NODES" : (spec?.name ?? ""))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            if let id = primaryID {
                Text(id).font(.system(size: 9).monospaced()).foregroundStyle(Theme.text2)
            }
            Spacer()
            actionButton("trash", "REMOVE") {
                runtime.removeNodes(selection)
                selection.removeAll()
            }
            actionButton("plus.square.on.square", "DUP") {
                let new = runtime.duplicateNodes(selection)
                if !new.isEmpty { selection = Set(new) }
            }
            actionButton("arrow.counterclockwise", "RESET") {
                runtime.resetNodeParams(selection)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func actionButton(_ symbol: String, _ caption: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(caption).font(.system(size: 6, weight: .semibold)).tracking(0.5)
            }
            .foregroundStyle(Theme.text)
            .frame(width: 42, height: 34)
            .background(Theme.panel)
            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Square-button jog pad for the Camera node. ORBIT walks the eye around the cloud
/// centre; POSITION slides the pivot itself (no re-centering). Scope = reset that pair.
struct CamJogRow: View {
    let runtime: GraphRuntime
    let label: String
    let xParam: String
    let yParam: String
    let step: Float
    let limit: Float

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 8, weight: .semibold)).tracking(1.1)
                .foregroundStyle(Theme.text2)
                .frame(width: 70, alignment: .leading)
            jog("chevron.up") { nudge(yParam, +step) }
            jog("chevron.down") { nudge(yParam, -step) }
            jog("chevron.left") { nudge(xParam, -step) }
            jog("chevron.right") { nudge(xParam, +step) }
            jog("scope") {
                runtime.pushUndo()
                runtime.setParam("cam", xParam, 0)
                runtime.setParam("cam", yParam, 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func nudge(_ name: String, _ delta: Float) {
        let v = runtime.nodeParam("cam", name, 0) + delta
        runtime.setParam("cam", name, min(max(v, -limit), limit))
    }

    private func jog(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 38, height: 30)
                .background(Theme.panel)
                .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(PadPressStyle())
    }
}

/// Flat horizontal slider bound to a live graph param — value centered on the handle.
/// The first movement of each drag pushes ONE undo step.
struct ParamSliderRow: View {
    let runtime: GraphRuntime
    let nodeID: String
    let param: ParamSpec
    @State private var value: Float = 0
    @State private var dragBegan = false

    private var range: ClosedRange<Float> { param.range ?? 0...1 }

    var body: some View {
        HStack(spacing: 10) {
            Text(param.name.uppercased())
                .font(.system(size: 8, weight: .semibold)).tracking(1.1)
                .foregroundStyle(Theme.text2)
                .frame(width: 70, alignment: .leading)
                .lineLimit(1)
            GeometryReader { g in
                let norm = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                let x = 22 + (g.size.width - 44) * min(max(norm, 0), 1)
                ZStack {
                    Rectangle().fill(Theme.line).frame(height: 2)
                    Text(String(format: "%.2f", value))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.text)
                        .frame(width: 44, height: 18)
                        .background(Theme.panel)
                        .overlay(Rectangle().stroke(Theme.text, lineWidth: 1))
                        .position(x: x, y: g.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gg in
                            if !dragBegan { dragBegan = true; runtime.pushUndo() }
                            let n = Float(min(max((gg.location.x - 22) / (g.size.width - 44), 0), 1))
                            value = range.lowerBound + n * (range.upperBound - range.lowerBound)
                            runtime.setParam(nodeID, param.name, value)
                        }
                        .onEnded { _ in dragBegan = false }
                )
            }
            .frame(height: 24)
        }
        .padding(.horizontal, 16)
        .onAppear { syncFromGraph() }
        .onChange(of: nodeID) { syncFromGraph() }
        .onChange(of: runtime.generation) { syncFromGraph() }   // undo/redo/reset refresh
    }

    private func syncFromGraph() {
        value = runtime.nodeParam(nodeID, param.name, param.defaultValue.floatValue)
    }
}

/// Flat segmented control for option params (e.g. Point Display FREE ↔ PINOUT).
struct OptionSegmentRow: View {
    let runtime: GraphRuntime
    let nodeID: String
    let param: ParamSpec

    var body: some View {
        let options = param.options ?? []
        let current = runtime.nodeOption(nodeID, param.name, defaultOption)
        HStack(spacing: 10) {
            Text(param.name.uppercased())
                .font(.system(size: 8, weight: .semibold)).tracking(1.1)
                .foregroundStyle(Theme.text2)
                .frame(width: 70, alignment: .leading)
            HStack(spacing: 1) {
                ForEach(options, id: \.self) { opt in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        runtime.setOption(nodeID, param.name, opt)
                    } label: {
                        Text(opt.uppercased())
                            .font(.system(size: 9, weight: .semibold)).tracking(0.8)
                            .foregroundStyle(current == opt ? Color.black : Theme.text2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(current == opt ? Theme.text : Theme.panel)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var defaultOption: String {
        if case .option(let s) = param.defaultValue { return s }
        return param.options?.first ?? ""
    }
}
