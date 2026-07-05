# Plan — Controller Nodes, Output Diamonds & the MIDI-Pad Setup Screen

**Status:** Plan only. Nothing built. Written 2026-07 against the FLAT model ([PLAN-Trigger-System.md](PLAN-Trigger-System.md)). Prereq already done: `runtime.midiSource` is now wired, so MIDI input reaches the graph.

This covers three linked pieces:
1. **Output diamonds** — a ◇ on a node's *output* side, mirroring the input expose ◇.
2. **Controller nodes** — Game Controller + MIDI Controller, which have far too many outputs to show at once.
3. **The custom MIDI-pad setup screen** — arrange virtual pads/knobs/sliders/switches to match your physical hardware.

---

## 1. The problem

The input ◇ exposes a folded *param* as a drivable input port. Controllers are the mirror image: a game controller has ~20 buttons + 6 axes + 2 triggers; a MIDI pad has dozens of pads/knobs/CCs. Showing every output port always would bury the canvas. **We want the node to surface only the outputs you actually use** — press a button / turn a knob, and *that* output sprouts a port you can wire out.

So the input model (`exposedParams`, ◇ on the left, "expose a knob to be driven") gets a symmetric partner on the output side.

## 2. Output diamonds — the model

Mirror of the input mechanism:

- **Data:** add `GraphNode.exposedOutputs: [String]` — the control ids the user has surfaced as output ports (e.g. `"button.a"`, `"axis.leftX"`, `"cc.74"`, `"note.36"`). Decodes to `[]` for old graphs; undo via the whole-Graph snapshot. Symmetric with `exposedParams`.
- **Card:** output ports shown = the node's *declared* outputs + `exposedOutputs`. Each exposed output renders as an amber ◇ port on the RIGHT edge (same styling as the input port dots, right-aligned). Wire it out like any output.
- **Settings bar:** for a controller node, instead of the param ◇ column, a **control list** — each hardware control with a ◇ toggle to surface/hide it as an output. Plus a **Learn** button: arm it, press the physical control, and the one that moved auto-surfaces (MIDI-learn / GC-learn).
- **Runtime:** the controller node is control-rate. Its `controlEval`-equivalent reads the hardware snapshot and writes each surfaced control's value into `controlValues["nodeID.controlId"]`. Downstream reads them exactly like any control-node output. Because only surfaced controls produce ports, only they need values — but reading all is cheap, so the gate is purely visual.

**Geometry reuse:** `NodeMetrics.outputAnchor` already takes an `exposed:` count (added for inputs). Generalize: output rows = `spec.outputs.count + exposedOutputs.count`; anchors and hit-testing extend the same way the input side already does. `NodeSpec.outputPortNames(_:)` mirrors `inputPortNames(_:)`.

**Why "only in use":** a controller node with nothing surfaced shows just a small header + Learn hint. As you use controls, ports appear. A "clear unused" action prunes surfaced-but-unwired ports.

## 3. Controller nodes

### 3a. Game Controller (`game-controller`, family BODY or a new CONTROL family)
- Backed by Apple's **GameController framework** (`GCController`) — a new `GameControllerEngine` shaped like `MIDIEngine`/`VisionEngine`: connect/disconnect notifications, poll `extendedGamepad` each frame, publish a snapshot under a lock; `runtime.controllerSource = { gc.current() }` wired in `ContentView.onAppear` next to the others.
- Control catalog: buttons A/B/X/Y, D-pad ×4, shoulders L1/R1, triggers L2/R2 (analog), thumbstick L/R (x,y), menu/options. Buttons → `.trigger` (0/1 + press pulse), triggers/sticks → `.signal` (analog).
- Surfaced per output diamond; wire `button.a → Threshold → drive anything`, `axis.leftX → exposed Depth.near`, etc.

### 3b. MIDI Controller (`midi-controller`)
- Backed by the existing `MIDIEngine`, extended from a single last-CC snapshot to a **per-control map** (`[controlId: value]`) so multiple pads/knobs are independent (today it collapses to one CC — see §5).
- Controls come from the **pad-setup layout** (§4) when one exists, else raw CC/note ids. Each surfaced control = an output port.
- Pads → `.trigger`, knobs/sliders → `.signal`, switches → `.trigger` (latched).

### 3c. Relationship to the old single-value MIDI nodes
`midi-cc` / `midi-note` (now working after the source fix) stay as the simple "one CC / one note" path. `midi-controller` is the rich, multi-control node for real hardware.

## 4. The custom MIDI-pad setup screen

A full-screen layout editor where you **rebuild your physical device on screen** so the controller node's ports match your hardware.

- **Canvas:** drag on virtual widgets — **Pad** (square, momentary/latch), **Knob** (rotary), **Slider** (fader), **Switch** (binary), **XY pad**. Move/resize/label each until the on-screen layout matches your box. Grid-snap; the app's flat black/white style.
- **Assign:** tap a widget → **Learn** → move the physical control → it binds to that CC/note/channel. (Same MIDI-learn used by the output diamonds.)
- **Save:** a layout = a named **Controller Profile** (`[Widget{id, kind, rect, label, midiBinding}]`), persisted (JSON in app support / `@AppStorage`), selectable per project.
- **Use:** the `midi-controller` node adopts the active profile — its control list (and thus its output diamonds) is the profile's widgets, by your labels ("Pad 3", "Filter Knob"), not raw CC numbers.
- **Live feedback:** widgets light up as you hit the hardware, so you can confirm the mapping while arranging.

This screen is reachable from the corner menu ("Controllers") and from the `midi-controller` node's settings ("Edit layout ▸").

## 5. Engine work required

- **MIDIEngine:** expand `_midi: SIMD4` → a small `[UInt16: Float]` map keyed by `(channel<<8 | cc/note)` under the lock, plus press-pulse tracking for pads. Keep `current()` for the legacy nodes (returns last-CC) and add `snapshot()` for the controller node. Add the MIDI-learn hook (report the last-moved control id).
- **New `GameControllerEngine`** (GameController framework) as above.
- **Runtime:** `controllerSource` / richer `midiSource`; a generic `controlValues["nodeID.controlId"]` population path for surfaced controls (no per-control node needed).

## 6. Phasing

1. **Output-diamond geometry** — `exposedOutputs`, card/anchor/hit-test symmetry, settings-bar control list + ◇. (Pure UI/model; testable with a stub controller.)
2. **MIDI multi-control** — engine map + `midi-controller` node + MIDI-learn. Wire to output diamonds.
3. **Pad-setup screen** — layout editor + Controller Profiles; bind the `midi-controller` node to the active profile.
4. **Game Controller** — `GameControllerEngine` + `game-controller` node (reuses the same output-diamond UI).

Each phase builds + is testable alone. 1 is the keystone (everything else hangs off the output-diamond port model).

## 7. Open questions (resolve before building)
1. **New CONTROL family** for these nodes, or reuse BODY/SIGNAL? (Lean: a new `CONTROL` family — they're a distinct concept.)
2. **Learn UX:** arm-then-press per control, or a global learn mode that keeps surfacing whatever you touch until you stop? (Lean: global learn mode — fastest for setting up 20 pads.)
3. **Profiles:** per project, or a global library shared across projects (like real hardware)? (Lean: global library, selectable per project.)
4. **Pad-setup fidelity:** free-form drag/resize, or snap to a few preset grid templates (4×4 pads, 8 knobs…)? (Lean: free-form with optional snap, since hardware varies.)
5. **Output diamonds on other nodes too?** The mechanism is generic — any node could surface extra outputs. Start controller-only; generalize later if useful.
