# Node Engine Groundwork — Implemented (2026-07-03, extended overnight + rounds 2–4 2026-07-04)

> **Round-4 fixes (2026-07-04 PM, from Ari's Node-view/settings notes):** editor gestures
> reworked — single-finger pan works starting over a node/wire (node only moves on hold-drag,
> guarded so pan+move never fight), hold-pickup teleport fixed (grab waits for the real finger
> location; edge auto-scroll only within 20 px of the border), new wires need a 0.45 s hold on the
> port box. Node view recenters on every entry (ContentView clears `EditorCamera.fitted`). Edge
> swipe-handles (tap to switch modes) on the camera-view right / node-view left. Insert-on-wire
> (select wire → + → splice a compatible node in-line). Minimap tap/drag-to-jump. Corner menu
> closes on outside tap (`open` lifted to a `@Binding`). Bottom bar bottom-anchored + content-sized
> (tools strip over node options); viewport no longer pinned to 3:4 — fills more, `buildCamera`
> takes the live drawable aspect so the grid renders 1:1 (centred, black margins, never stretched).
> Palette ADD works on tap, row-hold 0.55 s; node-detail sheet content-sized (`.height`, was
> `.medium`); Node-wires setting cycles CURVED/STRAIGHT/RIGHT-ANGLE (`wireStyle` Int). Grazing Cull
> cosThresh sweep widened to 0.85 so the CULL slider bites visibly. Accumulate stays a passthrough
> stub (real temporal-accumulate GPU pass is the cleanup engine phase, not this UI round).

> **Round-3 additions (2026-07-04 PM, from Ari's Further/Node-View notes):**
> - **FILTER family (red)** — cleanup as nodes: Grazing Cull (op 45: edge-reject + grazing-normal,
>   moved OUT of freeXY), Apple Depth Filter (capture `isFilteringEnabled`, now OFF app-wide by
>   default, node presence toggles it live), EMA Smooth (stabilize moved off Point Display),
>   Fill Holes (EMA holePersist), + Accumulate/Smooth Surface/Despeckle Voxel/Detail Upsample
>   passthrough stubs.
> - **Minimal default graph** (cam/d1/pd/sz/out, zero preset effects); ❄/💥/viewport-tap
>   self-plumb Freeze / Shockwave+Add into the z feed on first use.
> - **Contextual deck** — camera-view slider pages are generated from the graph (one page per
>   node with float params, name+id header); `VParamSlider` binds deck sliders to live params.
> - Depth near default 0.25→0.1 (flat-cap fix); palette op clamps instead of wrapping + pal pad
>   ships shift −0.25 (closest = red); ARMS is a Point Display bool (default off, menu cube
>   drives it, renderer reads `frame.stems`).
> - **Editor gestures v2** — 1-finger pan + inertia (tap stops), 2-finger pan removed, UIKit
>   pinch always wins (cancels wire drags), live ghost anchors (pan/zoom mid-drag stays glued),
>   TouchDesigner edge auto-scroll while dragging nodes, grab-offset multi-move.
> - **Editor chrome v2** — `EditorCamera` @Observable shared state; bottom-strip
>   (hand/cursor · + · undo · redo centered, always-on `MinimapView` right) fills the old dead
>   gap; corner menu restored in node view; settings bar is content-sized; camera node gets
>   ORBIT + POSITION jog rows (`CamJogRow`).
> - **Cards v2** — 168 wide, fonts +2, port squares 14pt proud of the edge, faint internal
>   flow drawing behind params (inputs converge on +/−/×/÷/ƒ glyph → outputs).
> - Palette is a full-screen cover (square corners), hold-a-row-1s adds instantly; Settings
>   gains a STRAIGHT/CURVED wire toggle (`@AppStorage("wireStraight")`).

> **Round-2 additions (2026-07-04, from Ari's MYNOTES in TESTING.md):**
> - **FREE mode (default)** — TDLidar front point cloud ported from its real code: `freeXY` op 44
>   (frustum fan via z/focus, intrinsic-free), silhouette edge-reject (0.10 m spread), grazing-normal
>   cull (mix 0→0.6 cos threshold), kernel `keep` flag → size. PINOUT is the optional mode
>   (Point Display → mode option, FREE/PINOUT segments in the settings bar).
> - **TDLidar `temporalDepthEMA` port** — rg32Float ping-pong (emaZ + velocity), deadband
>   hysteresis hold, velocity-adaptive alpha (motionAdapt 5), hole persist (FREE) vs retract
>   (pinout). Constants: alpha=1−0.9s, deadband=0.008s+0.012s/m. Fixes tracking lag + ripples;
>   lag/spring default to 0 (spring emitter bypasses at stiffness 0).
> - **4:3 video format** on the TrueDepth session (was 16:9 default) — kills the vertical squash.
> - **Node editor v1 (real)** — PatchMockView.swift rewritten: Blender-style cards (port rows +
>   live param values, height by port count), pan (2-finger UIKit host) + pinch zoom, hold-drag
>   move with glow, wire end pick-up/rewire/delete with compatible-port snapping, drag-from-port
>   new wires, box-select tool (cursor toggle, white outline), minimap while dragging/panning,
>   per-node pinch resize, palette hold-ADD insertion, REMOVE/DUP/RESET, undo/redo incl. one
>   step per slider gesture.
> - **GraphRuntime editor API** — addNode/removeNodes/duplicateNodes/resetNodeParams/moveNode/
>   connect/removeWire/rewire + snapshot undo/redo; pads now edit the live graph incrementally
>   (user wiring survives) instead of rebuilding the default patch; node positions live in the
>   graph (default layout in `defaultGraph()`).
> - **Camera orbit** — CameraFrame orbitX/orbitY (turntable eye around the pivot), ORBIT jog row
>   (UP/DOWN/LEFT/RIGHT/reset) on the Camera node's settings bar.
> - Chrome: fps chip visible, corner menu hidden in node view, bottom bars bottom-anchored (pads
>   above the home bar), pad press physicality + haptics, slider minimums zeroed, tutorial SF
>   symbols + 4-circle menu icon.

> **Overnight additions (2026-07-04):**
> - **Full catalog registered (~115 specs)** — `Graph/NodeRegistryFull.swift`: every Plans/03
>   family populated. Real emitters where the pipeline supports them (displace, velocity, echo,
>   wave, jitter, hide, region-rect, tint, hue-shift op43, depth-gradient, velocity-color,
>   posterize, strobe-color, color-mix, brightness, power/negate/one-minus/quantize/fract/sqrt/
>   compare/switch, reroute); stateful control nodes (envelope, wander, sample-hold, chance,
>   slew, clock, step-sequencer, counter, timer, toggle, gate, trigger-delay, on-start); bus
>   stubs reading zeros until their engines land (audio/MIDI/OSC/body); passthrough placeholders
>   for renderer features (shape/material/lights/post/domain warps).
> - **Control-graph evaluator** — topo-ordered per-frame evaluation with a value memo, so
>   control→control wiring works (Clock→Sequencer→anything); persistent per-node control state.
> - **Node view is real** — overlay renders the live graph (nodes + wires from `runtime.graph`,
>   plumbing adders collapsed); tapping a node exposes its actual float params as live sliders
>   in the permanent bottom bar (`ParamSliderRow` → `runtime.setParam`).
> - **App shell** — Browser launch screen, corner-menu second row (Record/NDI/Import/Settings/
>   Browser), placeholder pages for every planned function, registry-driven Node Palette with
>   spec cards, 7-step first-launch tutorial (replayable from Settings).
> - Camera + Point Display nodes (Ari's additions) wired through `ProgramFrame` (ops 41/42).

What exists in code now (all under `Points/Points/Graph/` + renderer/shader changes), vs
[01-Engine-Architecture.md](01-Engine-Architecture.md) / [02-Node-System-and-Editor.md](02-Node-System-and-Editor.md).

## Built

| Piece | File | Notes |
|---|---|---|
| Port types + auto-adapt matrix | `Graph/NodeSpec.swift` | signal/vec/color/trigger/field.*/domain/source; broadcast/splat/color↔vec3 rules |
| NodeSpec (ports, params, state, execution class, emit + controlEval closures) | `Graph/NodeSpec.swift` | The Swift registry is the engine's source of truth; Plans/03 JSON remains the design target |
| Graph model (nodes/wires, Codable, validation, Kahn topo sort) | `Graph/Graph.swift` | Type-checked wiring, cycle detection — ready for the editor + `.pointsproj` persistence |
| Pin-program VM: 36-op instruction set, 32B instructions, register builder (12 regs), patch table, state-slot allocator | `Graph/PinProgram.swift` | Ops mirror `pin_program` kernel switch exactly |
| Compiler: DAG → instruction stream, memoized recursive emit, lazy default materialization, control-wired inputs become patchable broadcast constants | `Graph/PinProgram.swift` | Register overflow → error → last good program keeps rendering |
| Node registry, 24 v1 specs | `Graph/NodeRegistry.swift` | depth, video-color, grid-info, region-ellipse, size, depth-drive, **lag/trail (stateful)**, ripple, palette (8 LUT rows), add/sub/mul/div/min/max/mix/clamp/remap/abs/sine/smoothstep/threshold/constant/random, lfo, transport, output |
| Runtime: default graph, recompile-on-edit, per-frame dynamic patch lanes (lag alpha, trail step, ripple phase, control-node broadcasts), BPM/beat clock | `Graph/GraphRuntime.swift` | Param edit = recompile (µs at this scale) → next-frame swap; compile failure never breaks render |
| GPU interpreter kernel (Layer A): float4 register VM, broadcast instruction stream, zero divergence, writes instance buffer | `Shaders.metal` `pin_program` | Depth/color/palette textures + state pool bound; neutral defaults when program writes nothing |
| Renderer integration: interpreter dispatch each frame, instance-buffer-driven instanced draws (caps + stems), state pool with zero-fill on program change, setBytes program upload (≤128 instrs) | `PinRenderer.swift` | EMA depth filter unchanged upstream; fixed ortho camera unchanged |
| Deck → graph: DEPTH/SIZE/GAMMA/FAR sliders are live node params (`dd.gain`, `sz.base`, `dd.gamma`, `d1.far`); color toggle rewires Video Color → Output | `PlayView.swift`, `ContentView.swift` | First real "everything is drivable" path |

## Default patch (in code)

`Depth(d1) → DepthDrive(dd) → Output.z` · `Size(sz) → Output.size` · [+ `VideoColor(vc) → Output.color` when color enabled]

## Deliberate v1 simplifications (ponytail ledger)

- Recompile-on-param-edit instead of full patch-only updates — µs at MVP graph sizes; patch table already carries the per-frame time-driven lanes (the part that must not recompile).
- State pool zero-fills on any program change (not seed-from-live yet); Layer B (async specialized kernels) + Layer C (binary archive) not started — interpreter IS the render path, which is the correct first milestone per the Dolphin pattern.
- Program capped at 128 instructions (setBytes 4KB); move to a ring MTLBuffer when graphs outgrow it.
- Echo spec (true frame-delay) omitted; Trail is the peak-hold variant. Spring/Freeze/Shockwave/Scatter/UV-Transform/Stretch/Rotation/Spin specs pending (emitters straightforward on this foundation).
- No editor yet — graphs are code-built; the deck proves the param path.

## Next steps

1. Remaining MOVE/SHAPE/GRID emitters (spring vec3 state, scatter, twist, shockwave w/ trigger timestamps, rotation/spin fields feeding the instance quat — needs instance-buffer extension).
2. Touch node (viewport 3-slot input → control values → already-working broadcast path).
3. Editor v1 reads the same `Graph` model (nodes/wires already Codable).
4. Interpreter benchmark @307k (Spike 1) — instrument `pin_program` in Xcode GPU profiler.
5. Audio engine port → `audio-*` control nodes (same controlEval pattern as LFO).
