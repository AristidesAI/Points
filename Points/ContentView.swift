import SwiftUI

/// ONE page. 3:4 viewport edge-to-edge below the Dynamic Island; the rest of the screen
/// is the control bar. Camera view: contextual deck (bottom-anchored, pads above the home
/// bar). Node view: tool strip (tool/+/undo/redo + always-on minimap) then the selected
/// node's settings — the bar grows with the node's parameter count.
/// Swipe left/right on the viewport fades the node editor in/out.
enum AppSheet: String, Identifiable {
    case importMedia, settings, record, ndi
    var id: String { rawValue }
}

struct ContentView: View {
    var template: String? = nil
    var signals: TutorialSignals? = nil
    var onBrowser: () -> Void = {}
    @State private var renderer = PinRenderer()
    @State private var runtime = GraphRuntime()
    @State private var audio = AudioEngine()
    @State private var sources: SourceManager?
    @State private var nodesOn = false
    @State private var selection: Set<String> = ["pd"]   // node ids in the live graph
    @State private var selectedWire: Wire?
    @State private var editorCamera = EditorCamera()
    @State private var menuOpen = false
    @State private var deckPage = 0
    @State private var deckDir = 1
    @State private var vpH: CGFloat = 0      // live viewer height (grid centres inside it)
    @State private var sheet: AppSheet?
    @State private var paletteOpen = false
    // A NEW wire pulled from an output and dropped on empty → open the palette filtered to
    // compatible inputs; the chosen node auto-connects to this source.
    @State private var pendingConnect: (from: String, port: String, type: PortType, world: SIMD2<Float>)?

    /// Enter/exit the node view. Entering always recenters the graph (clears `fitted`).
    private func setNodes(_ on: Bool) {
        if on { editorCamera.fitted = false; signals?.enteredNodes.toggle() }
        withAnimation(.easeInOut(duration: 0.25)) { nodesOn = on }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let gridH = w * 4 / 3                     // exact 3:4 pin grid — no black inside it
            VStack(spacing: 0) {
                // The viewer FILLS the space between the Dynamic Island and the bar (both modes).
                // The 3:4 render just centres inside it (the camera isn't bound to the viewer size).
                ZStack(alignment: .topLeading) {
                    MetalViewport(renderer: renderer)
                    NodeEditorView(runtime: runtime, camera: editorCamera,
                                   selection: $selection, selectedWire: $selectedWire,
                                   onDropOutput: { node, port, world in
                                       guard let t = NodeRegistry.shared.spec(runtime.graph.node(node)?.specID ?? "")?
                                           .outputs.first(where: { $0.name == port })?.type else { return }
                                       pendingConnect = (node, port, t, world)
                                       paletteOpen = true
                                   })
                        .opacity(nodesOn ? 1 : 0)
                        .allowsHitTesting(nodesOn)
                    if let sources {
                        if menuOpen {          // tap anywhere else closes the 4-circle menu
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { menuOpen = false }
                        }
                        CornerMenu(sources: sources, runtime: runtime,
                                   onSheet: { sheet = $0 }, onBrowser: onBrowser, open: $menuOpen)
                            .padding(.top, 10)
                            .padding(.leading, 10)
                        if sources.permissionDenied {
                            Text("Camera access needed — enable in Settings")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.black.opacity(0.7))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { vpH = $0 }
                .clipped()
                .background(Color.black)
                .contentShape(Rectangle())
                // Swipe handle: right edge (camera view) / left edge (node view). Tap switches too.
                .overlay(alignment: nodesOn ? .leading : .trailing) { edgeHandle }
                .overlay(alignment: .bottomLeading) {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text("\(renderer.fps) FPS")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55))
                            .padding(6)
                    }
                    .allowsHitTesting(false)
                }
                .simultaneousGesture(
                    // Camera view: swipe left anywhere → nodes. Node view: only a LEFT-EDGE
                    // swipe exits (the canvas owns every other gesture).
                    DragGesture(minimumDistance: 30).onEnded { g in
                        guard !nodesOn || g.startLocation.x < 28 else { return }
                        if !nodesOn, g.translation.width < -50 { setNodes(true) }
                        else if g.translation.width > 50 { setNodes(false) }
                    }
                )
                .simultaneousGesture(
                    // Viewport touch = node input (Touch node) + tap fires a shockwave.
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard !nodesOn else { return }
                            let gridTop = max((vpH - gridH) / 2, 0)   // grid centred in the viewer
                            runtime.setTouch(x: Float(g.location.x / w),
                                             y: Float((g.location.y - gridTop) / gridH), pressed: true)
                        }
                        .onEnded { g in
                            defer { runtime.setTouch(x: 0, y: 0, pressed: false) }
                            guard !nodesOn,
                                  abs(g.translation.width) < 12, abs(g.translation.height) < 12
                            else { return }
                            let gridTop = max((vpH - gridH) / 2, 0)
                            let u = Float(g.location.x / w)
                            let v = Float((g.location.y - gridTop) / gridH)
                            // view units: x ∈ [-1.5, 1.5], y ∈ [2, -2] top→bottom
                            runtime.fireShockwave(center: [(u - 0.5) * 3, (0.5 - v) * 4])
                        }
                )

                // ---- 1px separator + content-sized bottom bar (hugs the active bar) ----
                Rectangle().fill(Theme.line).frame(height: 1)
                Group {
                    if nodesOn {
                        // Tools strip on top, then either the WIRE bar (delete a selected wire) or
                        // the selected node's options. Bottom-anchored above the home-indicator gap.
                        VStack(spacing: 0) {
                            EditorToolStrip(runtime: runtime, camera: editorCamera,
                                            selection: $selection, onAdd: { paletteOpen = true })
                            if let w = selectedWire {
                                wireBar(w)
                            } else {
                                NodeSettingsBar(runtime: runtime, selection: $selection)
                            }
                        }
                        .padding(.bottom, 6)          // extra gap above the home-swipe area
                    } else if let sources {
                        CameraDeckBar(sources: sources, runtime: runtime, page: $deckPage,
                                      direction: deckDir, onPad: { signals?.tappedPad.toggle() })
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 25).onEnded { g in
                                    guard abs(g.translation.width) > abs(g.translation.height) * 1.5,
                                          abs(g.translation.width) > 50 else { return }
                                    deckDir = g.translation.width < 0 ? 1 : -1
                                    signals?.swipedDeck.toggle()
                                    withAnimation(.easeInOut(duration: 0.22)) { deckPage += deckDir }
                                }
                            )
                    }
                }
                .frame(maxWidth: .infinity)
                .background(Theme.bg)
            }
        }
        .background(Theme.bg)   // paints the home-indicator gap — bar keeps the normal bottom space
        .preferredColorScheme(.dark)
        .sheet(item: $sheet) { which in
            switch which {
            case .importMedia: ImportPlaceholderView()
            case .settings: SettingsPlaceholderView()
            case .record: RecordPlaceholderView()
            case .ndi: NDIPlaceholderView()
            }
        }
        // Full screen, square corners — the palette IS a screen, not a card.
        .fullScreenCover(isPresented: $paletteOpen, onDismiss: { pendingConnect = nil }) {
            NodePaletteView(acceptsType: pendingConnect?.type, onAdd: { spec in addNode(spec) })
        }
        .onChange(of: runtime.generation) {
            // Apple Depth Filter node ↔ capture layer (presence = on)
            sources?.setAppleDepthFiltering(runtime.appleDepthFilterOn)
            // Mic runs only while an audio node is in the graph (asks permission on first use).
            if runtime.usesAudioNodes { audio.start() } else { audio.stop() }
            // Vision runs only while a body/hand node is in the graph.
            sources?.vision.setRunning(runtime.usesBodyNodes)
        }
        .onAppear {
            if sources == nil {
                if let template { runtime.loadTemplate(template) }   // real per-template network
                let s = SourceManager(renderer: renderer)
                sources = s
                s.start()
                let rt = runtime
                renderer.programProvider = { rt.frameProgram() }
                let ae = audio
                runtime.audioSource = { ae.current() }
                if runtime.usesAudioNodes { audio.start() }
                let vis = s.vision
                runtime.bodySource = { vis.current() }
                s.vision.setRunning(runtime.usesBodyNodes)
            }
        }
    }

    // MARK: contextual wire bar (delete a selected wire)

    private func wireBar(_ w: Wire) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.text2).frame(width: 10, height: 10)
            Text("WIRE").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            Text("\(w.fromNode).\(w.fromPort) → \(w.toNode).\(w.toPort)")
                .font(.system(size: 9).monospaced()).foregroundStyle(Theme.text2).lineLimit(1)
            Spacer()
            Button {
                runtime.removeWire(w)
                selectedWire = nil
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "trash").font(.system(size: 11, weight: .medium))
                    Text("DELETE").font(.system(size: 6, weight: .semibold)).tracking(0.5)
                }
                .foregroundStyle(Theme.text)
                .frame(width: 46, height: 34)
                .background(Theme.panel)
                .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: edge swipe-indicator handle

    private var edgeHandle: some View {
        Rectangle()
            .fill(Theme.text2.opacity(0.55))
            .frame(width: 3, height: 44)
            .frame(width: 20, height: 90)            // wider invisible tap target
            .contentShape(Rectangle())
            .onTapGesture { setNodes(!nodesOn) }
    }

    // MARK: add node (with TouchDesigner-style insert on the selected wire)

    private func addNode(_ spec: NodeSpec) {
        defer { selectedWire = nil; pendingConnect = nil; paletteOpen = false }
        let reg = NodeRegistry.shared

        // Dropped a NEW wire from an output → place the node at the drop point and auto-connect
        // this source into its first compatible input.
        if let pc = pendingConnect, let ns = reg.spec(spec.id),
           let inPort = ns.inputs.first(where: { $0.type.accepts(pc.type) }) {
            if let id = runtime.addNode(spec.id, at: pc.world + [0, -Float(NodeMetrics.height(ns)) / 2]) {
                _ = runtime.connect(from: pc.from, fromPort: pc.port, to: id, toPort: inPort.name)
                selection = [id]
            }
            return
        }

        // If a wire is selected and the new node has a compatible in + out, splice it in-line.
        if let w = selectedWire, let ns = reg.spec(spec.id),
           let outType = reg.spec(runtime.graph.node(w.fromNode)?.specID ?? "")?
               .outputs.first(where: { $0.name == w.fromPort })?.type,
           let inType = reg.spec(runtime.graph.node(w.toNode)?.specID ?? "")?
               .inputs.first(where: { $0.name == w.toPort })?.type,
           let inPort = ns.inputs.first(where: { $0.type.accepts(outType) }),
           let outPort = ns.outputs.first(where: { inType.accepts($0.type) }) {
            let from = runtime.graph.node(w.fromNode)?.position ?? .zero
            let to = runtime.graph.node(w.toNode)?.position ?? .zero
            let at = (from + to) / 2 + [0, -30]
            if let id = runtime.addNode(spec.id, at: at) {
                runtime.removeWire(w)
                _ = runtime.connect(from: w.fromNode, fromPort: w.fromPort, to: id, toPort: inPort.name)
                _ = runtime.connect(from: id, fromPort: outPort.name, to: w.toNode, toPort: w.toPort)
                selection = [id]
            }
            return
        }

        // Otherwise drop into the middle of the current canvas, stepped so repeats fan out.
        let mid = editorCamera.toWorld(CGPoint(x: editorCamera.viewSize.width / 2,
                                               y: editorCamera.viewSize.height / 2))
        let n = Float(runtime.graph.nodes.count % 5)
        if let id = runtime.addNode(spec.id, at: mid + [-80 + n * 30, -60 + n * 34]) {
            selection = [id]
        }
    }
}

#Preview {
    ContentView()
}
