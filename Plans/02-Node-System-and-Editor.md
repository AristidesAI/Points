# Points — Node System & Editor

Companion to [01-Engine-Architecture.md](01-Engine-Architecture.md). Catalog:
[03-Node-Catalog.json](03-Node-Catalog.json).

---

## 1. Graph semantics

- **Data-flow DAG.** Everything is a value flowing through wires; the whole graph re-evaluates per
  frame with dirty-flagging. No execution wires — triggers are a *data type* (event pulses), so
  "gesture fires → envelope opens → size pops" is ordinary wiring.
- **Two rates, one mental model:**
  - `control` rate — one value per frame (CPU-interpreted): signals, triggers, transport, MIDI…
  - `pin` rate — one value per pin (GPU): fields. A field port IS a per-pin function, Blender-style.
- **Auto-adapt typing:** connecting `signal → field.float` broadcasts; `float → vec3` splats;
  `color ↔ vec3` converts; `field.float → field.vec3` splats. Incompatible ports refuse with a
  toast naming the fix ("needs a Color — add a Palette node?").
- **Port types / wire colors:**

| Type | Color role | Notes |
|---|---|---|
| `signal` | white | control-rate float |
| `vec2` / `vec3` | slate | control-rate vectors |
| `color` | per-value swatch | RGBA |
| `trigger` | amber | event pulses; wires flash on fire |
| `field.float` | teal | per-pin float |
| `field.vec3` | blue | per-pin vector |
| `field.color` | magenta | per-pin color |
| `domain` | orange | site-set handle (Domain → consumers) |
| `source` | red | depth+color stream bundle |

- **Families (palette tabs, header colors):** SOURCE · GRID · SHAPE · MOVE · COLOR · SIGNAL
  (subfamilies Math/Modulate/Audio/MIDI/OSC) · BODY · TIME · STAGE · TOOLS.
- **Every param is a port.** Inspector sliders and input ports are the same value; wiring a port
  overrides (and grays out) its slider, showing the live incoming value.
- **Determinism:** all randomness seeded per project; Reseed trigger reshuffles live. Same patch +
  same inputs = same output (templates depend on this).

## 2. Macros

- Select nodes → **Collapse to Macro**: boundary wires become exposed ports (auto-named, renameable);
  macro gets a name, family color, and lives in the user library (project-independent).
- Double-tap a macro → enter (breadcrumb bar shows depth; background render still live).
- Factory signature effects ship as **openable macros** — users unpack the wiring. Only stateful
  primitives (Spring, Trail, Echo…) are native.
- Macros nest (2 levels max v1). Share codes include macro definitions inline.

## 3. Editor UX spec (PATCH view)

**Canvas:** infinite pan (2-finger) / pinch zoom (0.25–2×), minimap top-left corner (tap-jump),
double-tap-empty → **add palette** at point (search field, family tabs, recents row); drag a wire
into empty canvas → same palette pre-filtered to compatible nodes, auto-connects on pick.

**Nodes:** solid category-colored header (icon + name) + body; **selected/focused = solid,
unselected = ~40% translucent** with 1px outline + header color staying crisp (Blender-like focus
model). Body shows up to 3 key values live. 44pt minimum touch targets throughout; ports render
14pt, hit 44pt.

**Wires:** bézier, type-colored, 1px core + glow; **activity pulse** (brightness follows signal,
triggers flash). Tap a wire → highlight full path, dim rest, show floating mini-scope (60fps
waveform, pinnable). Double-tap wire → reroute dot. Long wires → convert to named **Send/Receive**
pill pairs.

**Connect:** drag from port with magnetic snap (compatible ports enlarge + attract within ~44pt;
release on node body = best-port auto-pick). Tap-tap connect as fallback (tap port arms it, tap
destination).

**Inspector:** tap node → bottom sheet (params, port list, node card link). Collapsed mode = thin
strip with selected param; **drag anywhere on screen horizontally to scrub the value** while the
output plays unobstructed. Long-press any param → **Map…** (quick-map: tap a live source from a
meter list, or wiggle a MIDI knob = learn) → engine inserts node+wire behind the scenes; **Pin to
Deck** lives in the same menu.

**Organization:** two-finger-hold lasso; selection toolbar (move/duplicate/delete/align/distribute/
collapse-to-macro); colored titled **Frames**; comment **stickies** (used heavily by templates).

**Undo:** full history (structural + params, drags coalesced), 2-finger tap = undo, 3-finger = redo,
buttons in the toolbar. History survives view switches; archive cache makes structural undo instant.

**Background:** live output renders behind the canvas; persistent **dim slider** (edge control,
0–100%); tap-empty-canvas **peek** (nodes fade to outlines 2s). Selected-node solidity per above.

**Node docs:** long-press node (palette or canvas) → card: one-liner, ports, params, and a **live
mini-preview** (node applied to a built-in sphere-grid sample loop).

## 4. PLAY view

```
┌────────────────────────┐
│  3:4 OUTPUT (top)      │  ← touch = Touch-node input ONLY (3 slots xy/force/taps)
│  status pills top-L    │  ← fps/pins/thermal · REC dot · NDI dot
│  accordion top-R       │  ← collapsed pill → NDI / Record / Switch Cam / Settings…
├────────────────────────┤
│ TRANSPORT STRIP        │  ← PATCH btn · source badge (tap=switch) · BPM/tap · page dots
├────────────────────────┤
│ DECK (swipeable pages) │  ← 4×2 grid of pinned controls:
│                        │     knob · fader · pad (momentary/latch) · XY (2×2) · picker
└────────────────────────┘
```

- **Smart starter deck** on new projects: Pin Count, Pin Size, Depth Gain, Shape Morph, Palette,
  Bloom. All replaceable (long-press → rearrange/unpin).
- Deck controls are views onto graph params — bidirectional (graph drives show live).
- PATCH button + swipe-up on the strip → editor slides over; swipe-down/PLAY returns.

## 5. Project browser (launch)

Square-grid of project cards (live-captured thumbnail, title, duration-since-edit). Top: New
Project + **Templates shelf** (5 tiers × 4, tier-labeled). Long-press card → rename / duplicate /
delete / share code. Templates open instantly and **copy-on-edit** (first change forks "My Beat
Strobe" into projects; originals immutable).

**Share codes:** graph JSON (+ macro defs, deck layout) → compressed base64 / QR. No media payload;
media-source projects arrive pointing at the demo clip with a badge.

## 6. Persistence

`.pointsproj` bundle (Documents, Files-app visible):

```
graph.json        // nodes, wires, macros, deck, seeds, schemaVersion
meta.json         // name, created/modified, source type, thumbnail ref
thumbnail.png
depth.mov         // media projects only (lossy HEVC Main10, log luma)
color.mov         // media projects only (960p HEVC)
depth.json        // sidecar: near/far, curve, fps, frameCount, model, fov
```

`schemaVersion` + forward-migration table from day one. Depth/color marked
`isExcludedFromBackup`.
