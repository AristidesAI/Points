# Plan — Modulation System (FLAT model, shipped)

**Status:** Implemented 2026-07. Commits: `7b2efef` (flatten), `b0ef178` (recent/favourites), `67dc9a4` (UI polish).
**This supersedes the entire nested "trigger view" design** (old §3, §7, and the §13 nested-TOX architecture). There is no separate trigger view, no "dive into a node," no trigger square, no Drive-Param sink node. If you are reading an older revision of this file in git history, it describes a design that was built, tested, and then replaced. The reasons are in the History section at the bottom.

---

## 1. What it is

Parameter modulation happens on **one flat canvas** — the same node editor you build the visual pipeline in. This matches the two tools the project takes after: TouchDesigner (export a CHOP channel onto a parameter) and Blender geometry nodes (wire into a named input). Neither makes you descend into a node to automate its own knobs, and neither do we.

The core idea: **any parameter can be exposed as a real input port on its node, on demand.** Wire a control-rate (Signal-family) node into that port and it drives the parameter live.

## 2. The problem it solves

Most field/render nodes have parameters that are *folded* — they have no input port because they're packed into one GPU instruction (Depth's near/far live in one `loadDepth` op; Point Display's seven sliders are packed across `pinFieldXY`/`pinFieldZ`/`freeXY`; Size's min/max are one `clampOp`). You can't drag a wire to "near" because there's no "near" port.

Exposing a param mints that port and routes a driver into it, reusing the per-param patch keys (`addPatchKey`, e.g. `d1.near`) already registered on the packed ops. The GPU program is untouched — only the immediate lane the param occupies gets written each frame.

## 3. Data model

`GraphNode.exposedParams: [String]` — the param names the user has exposed as ports on that node. Decodes to `[]` when absent (old saves). Undo is covered by the whole-`Graph` snapshot.

The card's input ports = `spec.inputs + node.exposedParams` (see `NodeSpec.inputPortNames(_:)`). Exposed ports render after the declared inputs, with an amber dot.

(Dormant: `GraphNode.triggerGraph`, `GraphRuntime.nestedOrders`, `nestedControlState` — leftover from the nested design, kept only so older serialized graphs decode. Remove in a cleanup pass.)

## 4. Runtime — the per-frame pass

`GraphRuntime.applyExposedParams()` (replaced `applyNestedTriggers`), called at the end of `frameProgram()` after the dynamic-lane loop, so driven values sit on top of baked/control values:

1. **Float ports.** For each exposed param with a wire into its port, read the source's control value (`controlValues["from.port"]`), map it, and write it into the param's patch lane(s). Default map: source treated as `0..1` across the param's full range, so a raw `0..1` source (pinch, audio level, gesture) sweeps the whole slider out of the box. Bipolar/other ranges: put a **Remap** node before the port. This is a *replace* (the wire drives the param; the slider is the value only when unwired), matching a TD export.

2. **Option ports.** Options can't be offset-patched (they recompile). So an exposed option (e.g. Point Display `mode` = free/pinout) flips **only when the wired signal crosses a bucket boundary** — `driveOption(...)` sets the param and recompiles, never per frame. Gathered first, applied after the read loop, so a flip rebuilds fresh instructions for the float pass.

`toggleExposed(nodeID, param)` / `isExposed(...)` are the editor actions; un-exposing also drops any wire into that port.

## 5. UI

- **Expose toggle** — a small ◇ (`ExposeToggle`) next to every float slider and generic option row in the settings bar. Filled amber when exposed. Arm/NDI rows are excluded (not meaningful to drive).
- **Card ports** — exposed params appear as amber input ports on the node card; the value is no longer repeated in the card's param-value list (dedup).
- **Logic nodes** — If / Then, And, Or, Not, Xor, Threshold, Envelope, Curve, Spring, Add, Multiply, Remap are normal **Signal-family** nodes in the palette (they were only ever hidden by `triggerOnlyIDs`, now just `["trigger-drive"]`). `If / Then` = if-this-then-that in one node. Drop a **Value Display** node on a wire to watch the live 0/1 as logic fires.
- **Palette** — Recent (last 6 added, any family) and Favourites strips at the top of the list; grid mode has a fixed ★ Recent+Favourites tab plus an infinitely-looping family strip. Star toggle sits left of ADD in the node detail card.

## 6. The pinch → Depth example (end to end)

1. Select Depth → tap the ◇ next to **near** in the settings bar → a `near` port appears on the Depth card.
2. Add **Hand Pinch**, wire `distance → near`.
3. `applyExposedParams` maps pinch `0..1` across near's range each frame → pinching sweeps the near plane. One canvas, no diving.

## 7. Known limits

- **Options only flip, they don't blend** — a wired option is a discrete mode change on threshold crossing (a one-frame recompile). Fine for free↔pinout; not a smooth crossfade. Upgrade path: dual-branch mux in the shader if glitch-free flips are ever needed.
- **Point Display is mode-split** — `focus` only has a patch key in FREE, `volume`/`wobble` only in PINOUT (that's how the GPU emit branches). All seven expose; each drives only in its active mode.
- **Loop family bar isn't truly infinite** — tripled + centered, ~1 copy of runway each way. Plenty for ~12 families; add edge-recenter only if it ever matters.

## 8. Deferred — beginner macro-knob layer

A no-graph path: assignable knobs/pads in the camera control bar mapped straight to params (see the separate macro-knob explanation). Deferred because the expose-and-wire path is now simple enough to be the primary path; build the macro layer only if that still feels too graph-y in testing.

---

## History (why the nested design was dropped)

The first design (§3/§7 in git history) added a **third view** and per-node **trigger squares**. The §13 revision turned it into a **nested per-node subgraph** (TouchDesigner TOX/COMP model): dive into a node, get auto-seeded per-param "Drive Param" sinks, wire modulators inside.

It was built and tested. Problems:
- The trigger square on every card looked like a port but wired to nothing in node view — the single most confusing element.
- It diverged from TD/Blender, which are *flat* for parameter modulation. Diving is for building sub-networks, not automating a node's own knobs.
- Two canvases to teach instead of one.

The user chose to flatten. The flatten reused the one genuinely useful piece of the nested work — the per-param patch keys (`addPatchKey`) — and deleted the rest (dive/exit, pull-tab, back-chip, breadcrumb, Drive-Param seeding, the mandatory inbox row, the greyed-palette split).
