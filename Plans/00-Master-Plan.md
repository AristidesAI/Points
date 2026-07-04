# POINTS — Master Plan

**Status:** DESIGN PLAN v2 (2026-07-03). Supersedes `Notes/Points-App-Plan.md` (the TDLidar-port plan) — that document remains valid ONLY for the port-source references it catalogs (NDI integration checklist, capture-session gotchas, AudioAnalysisEngine, proven Metal disciplines). The app described here is a different product.

**Decision provenance:** 25 rounds of structured Q&A (2026-07-03) + two research workflows
(TDLidar code survey `w7lv877px`; models/deployment/storage/engine/topology research `wktdws96b`).
Machine-readable decision ledger: [07-Decisions.json](07-Decisions.json).

> **CORRECTIONS (2026-07-03b, override anything below that conflicts):**
> 1. **No HEVC anywhere.** Imported media: import → process once → store the processed depth/pin
>    data directly (custom binary, quantized UInt16 depth planes + LZ4, mmap — format finalized at
>    the import phase). No depth.mov/color.mov.
> 2. **Default setup = live front TrueDepth + back LiDAR** producing the default pinout: default
>    shape pushed forward + stem "arms" connecting each pin to the Z-origin wall; no-signal pins sit
>    at Z-origin. Normal timing.
> 3. **Navigation:** swipe LEFT on the right edge of the fullscreen PLAY view → node view; swipe
>    RIGHT on the left edge of the node view → back. (Not a PATCH-button-first model.)
> 4. **Import view is contextual** — appears only when tapping the source (Source node / source
>    badge), never a standalone destination.
> 5. **Node-view bottom settings bar is permanent** — always visible, not a collapsible sheet.
> 6. **MVP first:** TrueDepth + LiDAR live pinout working on a real phone (30k default, 307,200 max),
>    UI screens present even where non-functional. Node engine comes after the MVP is testable.
>
> **UPDATE (2026-07-03c) — two headline geometry nodes shipped in the MVP engine:**
> - **Camera node** (STAGE): fixed perspective always aimed at the exact middle of the pinout so
>   3D pins warp around that centre. Params: FOV (flat↔wide), ZOOM (frames the cloud; framing held
>   constant so pins never "zoom"), PARALLAX (pulls the camera in for stronger warp), DEPTH PUSH
>   (world-Z exaggeration), CENTRE X/Y (pivot nudge). Read straight by the renderer → viewProj +
>   `zWorldScale`; never gesture-driven.
> - **Point Display node** (GRID): the pinout↔cloud control. SEPARATION bunches/spreads the grid;
>   VOLUME opens pins outward with depth (point-cloud look); WOBBLE + STABILIZE trade a locked
>   pinout for TDLidar-style sensor wobble (STABILIZE drives the depth EMA — low = raw/wobbly,
>   high = locked); EDGE LOCK pins the outer ring to the 3:4 frame; GAIN/GAMMA/Z-FLATTEN shape the
>   push. **TDLidar cloud look** = VOLUME↑ + STABILIZE↓ + EDGE LOCK off; **locked pin-screen** =
>   VOLUME 0 + EDGE LOCK on. Emits new VM ops `pinFieldXY`/`pinFieldZ`.
> Both are in [03-Node-Catalog.json](03-Node-Catalog.json) and the live `NodeRegistry`.

---

## 1. What Points is

**A pin-screen visual synthesizer.** A fixed 3:4 stage of up to 307,200 real 3D pins (instanced
spheres/cubes/tubes/slabs/cones/rings/discs/spikes with optional extruded stems) resting on a flat
Z=0 wall. Depth — from the front TrueDepth sensor, the back LiDAR (Pro iPhones), or ML-baked
imported video/photos — pulls pins toward the camera. Everything about the pins (shape, size,
rotation, color, motion, topology) is programmed by the user in a **node graph** (Blender-geometry-nodes
× TouchDesigner heritage) and driven live by audio analysis, MIDI, OSC, touch, body pose, hand
gestures, and face tracking. Output: on-screen, NDI (clean feed, alpha-keyable), and GPU-direct
recording to Photos up to 4:3 4K60.

**Not** TDLidar's point cloud mode ported. The essence is kept (live depth → points, NDI, the FX
sensibility); the render model (pin grid, real geometry, fixed camera), the control model (node
graph), and the product shape (projects/templates/file browser) are new.

### Product pillars

1. **The grid never lies.** Pins have fixed XY identity; lateral wobble is impossible by
   construction. Depth-Z is temporally filtered (deadband + adaptive EMA as node-exposed filters).
   Holes retract pins flush to the Z=0 wall — signal loss is *visible mechanics*, not noise.
2. **Zero-stutter, always.** Any graph edit renders on the next frame (interpreter layer);
   optimized kernels swap in silently (async specialize + binary archive). No compile hitch, no
   loading states between effects, ever — including while recording 4K60.
3. **Everything is drivable.** Every param is a port. Audio, MIDI, OSC, touch, gestures, body
   regions, face, LFOs, envelopes, sequencers — one wiring vocabulary.
4. **Teach by patching.** 20 openable templates + openable factory macros + long-press node cards
   with live examples. No manual.

---

## 2. Locked decisions (summary)

### Platform / scope
| Decision | Value |
|---|---|
| Devices | **iPhone A17 Pro+ only, iOS 26 minimum** (Metal 4 compiler QoS, BGContinuedProcessingTask) |
| iPad | Runs scaled iPhone layout v1; real layout fast-follow |
| Price | **Free** (no paywall engineering; monetization revisit post-launch) |
| Sharing | Graph-only share codes (compact text/QR of graph JSON, no media) |
| Name | "Points" working title; `.pointsproj` bundles |
| Orientation | Portrait locked; 3:4 viewport pinned top |
| FPS | User-selectable 30/60/120 render target (editor UI may run 120 on ProMotion regardless) |
| Thermal | Auto-ladder (LOD → count → fps, HUD notice) + "Marathon mode" pre-cap (100k/30fps); recording resolution never changes mid-file |

### Sources
| Decision | Value |
|---|---|
| Live sources | Front TrueDepth (every project's default), back LiDAR (Pro). **Raw sensor depth only — no ML on live paths** |
| Imported media | RGB video/photo → one-time on-device ML bake → stored depth, replayed forever |
| Video model | **Metric-Video-Depth-Anything-Small** (Apache-2.0, video-native temporal consistency); DAv2-metric ViT-S as "Fast" tier. No DA3 |
| Photo model | **MoGe-2 ViT-B** — already converted: `/Users/ari/Downloads/MoGe2_ViTB_Normal_504.mlpackage` (202 MB, verified on disk) |
| Model delivery | **Bundle everything** in the app binary; warm/compile on first import ("Preparing engine…") |
| Domain (indoor/outdoor) | **Always ask** at import |
| Bake polish | Always-on: scale/shift alignment in inverse-depth + motion-gated EMA + scene-cut resets, baked into stored depth |
| Bake UX | Foreground with progress + **BGContinuedProcessingTask** continuation + **Live Activity ring in the Dynamic Island** (ActivityKit); bake completes before play (no partial playback); soft cap ~5 min with size/ETA preview |
| Storage | **Lossy HEVC only** ("files too big" — no lossless tier): depth.mov (Main10, GOP-compressed since playback is sequential-only, log-encoded luma + dither) + color.mov (960p HEVC) + depth.json sidecar. No pose bake for imported media (v1) |
| Playback | Simple sequential looper (VTDecompressionSession ring, no AVPlayer), **max 30fps, no interpolation** (space/simplicity), transport: play/pause/speed 0.25–2×/loop-range/restart trigger |
| Intrinsics | EXIF → MoGe-2 FOV estimate (photos) → 60° default; FOV exposed as Source-node param |
| Fallback | Graceful source substitution chain LiDAR→TrueDepth→bundled demo clip, badge on Source node |

### Render
| Decision | Value |
|---|---|
| Geometry | **GPU instancing + LOD** (2-3 tiers per shape), 8 shapes, **vertex-corresponded meshes → per-pin shape-morph field** |
| Pin anatomy | Cap (the shape) + optional **stem** extruded from Z=0 (profile/thickness/taper/color — all fields) |
| Rotation | Per-pin rotation field (quat in instance buffer) |
| Z semantics | Z=0 wall; near pulls toward camera; holes retract to 0; gain/curve via nodes |
| Shading | Node-editable: unlit/lit/matcap; **2 Light nodes** (full params: position/color/intensity/falloff/cone; positions drivable — head/hand follow); **1 cheap shadow map** on light #1 |
| Depth/blend | Depth buffer + opaque-first default; ghost (painter's alpha) mode via RenderSettings node |
| Background | Background node (color/gradient/vignette, drivable; NDI alpha-key aware) |
| Post | Bloom + Grain + Vignette nodes |
| Camera | **Fixed**; Camera node = framing presets (Front/¾L/¾R/High/Low/Side) + FOV + dolly + ±15° drivable offsets, spring-smoothed, never gesture-driven |
| Topology | **Domain node**: rect (default, corners pinned)/hex/radial/spiral/scatter/perspective as warps of one canonical lattice; count 1k–307,200; **morph blend + hard-switch, any trigger type**; perspective mode has `xyStabilize` (off/filtered/latch/quantize) param |
| Upsampling | Edge-aware bicubic from real-sample neighbors (children driven by parents) |
| Budget defaults | 30k pins all sources ("1 IR dot = 1 pin" story); ceiling 307,200 |

### Engine
| Decision | Value |
|---|---|
| Graph model | Data-flow DAG, dirty-flagged, evaluated per frame |
| Execution | **Hybrid**: per-pin chains → generated Metal kernels (async-compiled, binary-archive cached) with an **always-resident interpreter kernel** covering every edit next-frame (Dolphin hybrid-ubershader pattern); control-rate nodes interpreted on CPU (allocation-free, triple-buffered publish) |
| v1 restriction | **Per-pin ops only** — no neighbor/blur/propagation nodes (analytic radial effects allowed) |
| State | State-slot allocator from a preallocated per-pin pool (~32 floats × 307k ceiling, UI memory meter); pending-reset seed-from-live discipline |
| Typing | Typed ports + auto-adapt (signal→field broadcast, float→vec3 splat, color↔vec3) |
| Abstractions | Fields (per-pin) + operator families both, **own family names** (no TOPS/CHOPs): SOURCE · GRID · SHAPE · MOVE · COLOR · SIGNAL · BODY · TIME · STAGE · TOOLS |
| Catalog | **~110 nodes at launch**, balanced spread; signature effects = **openable macros** |

### Tracking (silent context)
| Decision | Value |
|---|---|
| Stack | Vision 2D on RGB frames: body pose (19 joints) + hand pose (21×2) + face landmarks (76) + yaw/pitch/roll. **No ARKit face session** (conflicts with TrueDepth depth stream) |
| Regions | GPU region-mask field (head/torso/arms/hands/legs/background, soft edges) **and** raw Joint nodes |
| Gestures | 6 core: pinch, open palm, fist, point, peace, thumbs-up + continuous pinch-distance/openness |

### I/O
| Decision | Value |
|---|---|
| MIDI | USB + Network + BLE (CoreMIDI), CC/note nodes, MIDI-learn via quick-map; clock v2 |
| OSC | Receive **and** send nodes |
| Audio | Ported TDLidar engine: bass/mid/high, 3 onset triggers, burst, 20-band FFT, true RMS; mic + USB picker |
| Clock | Global BPM transport + tap tempo; sync divisions on LFO/Sequencer |
| Recording | One-tap → auto-Photos; GPU-direct HEVC up to 4:3 4K60 (2880×3840); live graph editing while recording |
| NDI | Clean 3:4 feed, res picker (810×1080/1080×1440/1620×2160), 30/60, optional alpha-key |

### UI
| Decision | Value |
|---|---|
| Views | **PLAY** (3:4 output top + transport strip + pinned-param deck) ⇄ **PATCH** (fullscreen node canvas over live output) via PATCH button + swipe |
| Editor transparency | Focus-driven: selected nodes solid, unselected ~40% translucent (Blender-like), persistent background dim slider, tap-empty peek |
| Theme | **Dual gray, Blender-like**: dark #474646 / light #BCBCBC themes; node family colors + 1px outlines define nodes and wires |
| Font | Open — shortlist Inter / Space Grotesk / Archivo (grotesque, tiny-size legible, tabular numerals); pick during HTML mockup |
| Node look | Solid header+body when selected/focused; translucent otherwise; 14pt type-colored ports, 44pt hit areas; wires pulse with signal |
| Add node | Double-tap canvas → searchable palette at point (+ drag-wire-to-empty pre-filtered) |
| Params | Tap node → bottom-sheet inspector; collapsed strip + horizontal scrub-anywhere |
| Organization | Lasso select, frames, align, comment stickies, reroute dots, wireless Send/Receive pairs, **macros v1** (collapse to reusable node) |
| Undo | Full history, param coalescing, 2-finger tap undo / 3-finger redo |
| Deck | 5 control types (knob/fader/pad/XY/picker), swipeable 4×2 pages, long-press rearrange; **smart starter deck** (Count/Size/Depth Gain/Shape Morph/Palette/Bloom); pin-to-deck via long-press any param |
| Viewport touch | Touch = node input only (3-slot Touch node), never camera |
| Top-right | Vertical pill-stack accordion: NDI, Record, Switch Cam, settings…; status dots collapsed |
| Browser | Launch = square-grid project browser, live thumbnails, long-press menu; templates shelf; **copy-on-edit** semantics for templates |
| Docs | Long-press node → card + live mini-preview |

---

## 3. Document map

| Doc | Contents |
|---|---|
| [01-Engine-Architecture.md](01-Engine-Architecture.md) | Metal engine: domain system, instanced pin renderer, hybrid compile, state pool, swap protocol, lights/post, perf budgets |
| [02-Node-System-and-Editor.md](02-Node-System-and-Editor.md) | Graph semantics, type system, families, editor UX spec, macros, quick-map, deck |
| [03-Node-Catalog.json](03-Node-Catalog.json) | ~110 node definitions (ports, params, state, execution class) |
| [04-Depth-Import-Pipeline.md](04-Depth-Import-Pipeline.md) | Models, bake pipeline, Live Activity, storage format, playback engine |
| [05-UI-Theme-and-Screens.md](05-UI-Theme-and-Screens.md) | Visual theme, typography shortlist, screen-by-screen spec, mockup checklist |
| [06-Templates.json](06-Templates.json) | 20 starter templates: graphs, decks, teaching stickies |
| [07-Decisions.json](07-Decisions.json) | Full Q&A decision ledger (machine-readable) |
| [08-Build-Phases.md](08-Build-Phases.md) | Phasing, spikes, risks, skill references, verification strategy |

## 4. Next actions

1. ~~Q&A rounds + research~~ ✅
2. ~~This plan set~~ ✅ (this document)
3. **HTML/CSS mockup** of Browser / PLAY / PATCH / Import screens — iterate on theme + font there before any Swift.
4. Engineering spikes (from [08-Build-Phases.md](08-Build-Phases.md)): interpreter-vs-specialized benchmark, VDA-S CoreML conversion, HEVC depth encode/decode harness, instanced-morph shape renderer.
5. Per-phase implementation plans in `docs/superpowers/plans/` using the writing-plans task format, applying `/swift-best-practices` `/metal-graphics` `/metal-shader-expert` `/ios-coding-best-practices` `/ios-26-platform` skills at build time.
