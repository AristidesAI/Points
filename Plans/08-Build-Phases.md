# Points — Build Phases & Risk Register

Each phase ends with runnable, on-device-verifiable software. When a phase starts, generate its
detailed implementation plan (`docs/superpowers/plans/YYYY-MM-DD-phaseN-*.md`) in the
writing-plans task format (bite-sized TDD tasks), applying these skills at build time:
`/swift-best-practices` · `/metal-graphics` · `/metal-shader-expert` · `/ios-coding-best-practices`
· `/ios-26-platform` (+ `/axiom-camera-capture`, `/axiom-metal-migration`, `/activitykit`,
`/core-ml` references as relevant per phase).

**Global constraints (apply to every phase):**
- iOS 26 minimum, iPhone A17 Pro+; Swift 6 strict concurrency; portrait-locked.
- No allocation, locks, or ARC churn on render/control hot paths; triple-buffer publishes.
- Metal state textures follow pending-reset seed-from-live; Swift↔Metal structs field-order-locked
  via a shared generated header.
- Every stage 0-value = bit-exact bypass; all randomness project-seeded.
- Verification = build-gate + on-device run + Instruments capture per phase (no unit-test harness
  for GPU paths; graph/model code gets Swift Testing units).

---

## Phase 0 — Spikes (≈1.5 wk, parallelizable)
The five from [01 §8](01-Engine-Architecture.md) + [04 §6](04-Depth-Import-Pipeline.md):
interpreter benchmark · shape-morph mesh bake · VDA-S CoreML conversion · HEVC depth round-trip ·
Metal4 compile-under-recording. **Gates:** interpreter ≤4ms @307k×40ops; morphs read clean; VDA-S
converts or Fast-tier fallback invoked; depth codec artifacts acceptable on the pin grid.

## Phase 1 — Stage skeleton (≈1.5 wk)
Fixed camera + Domain (rect only) + TrueDepth live source + depth filter stack + instanced
sphere-only pins (no stems) + true-black 3:4 viewport + fps/pins HUD. Hardcoded params, no graph.
**Exit:** 30k→307k pins live from the front sensor, wobble-free, 60fps, Instruments-verified
zero per-pin CPU work.

## Phase 2 — Node engine core (≈2.5 wk)
Graph model + typed ports + control-rate interpreter (CPU) + pin-program interpreter kernel +
codegen/async-specialize/archive + state-slot allocator + generation-tagged swap protocol.
Debug-driven via a JSON graph loaded from disk (no editor yet). ~30 core nodes (SIGNAL math +
Modulate + Depth/Domain/Shape/Size/Color basics). **Exit:** edit graph JSON on the fly →
next-frame change, zero dropped frames while a specialize compiles (Metal System Trace proof).

## Phase 3 — Editor v1 (≈3 wk)
PATCH canvas (pan/zoom/minimap) + node rendering (focus model, family colors) + drag-snap wiring +
palette + inspector/scrub + undo + PLAY⇄PATCH + transparent background + dim slider. Lasso,
frames, stickies, reroutes, Send/Receive. Macros collapse/enter. **Exit:** build Tier-1 template
patches by hand on-device, comfortably.

## Phase 4 — Full render vocabulary (≈2 wk)
All 8 shapes + morph + stems + rotation + materials + 2 lights + shadow + Background + Bloom/Grain/
Vignette + RenderSettings ghost mode + Camera node presets/offsets + hex/radial/spiral/scatter/
perspective domains + morphing. **Exit:** every STAGE/GRID/SHAPE catalog node functional.

## Phase 5 — Inputs (≈2 wk)
Audio engine port + BPM transport + MIDI (USB/Network/BLE) + OSC in/out + Touch node + quick-map/
MIDI-learn + deck (5 control types, pinning, starter deck) + accordion. **Exit:** MIDI-rig and
audio-pulse template patches performable end-to-end.

## Phase 6 — Body context (≈1.5 wk)
Vision body/hand/face on the RGB stream (utility queue, adaptive rate) + region-mask rasterizer +
Joint/Gesture/Face nodes + LiDAR back source + source switching/fallback chain. **Exit:** Tier-3
templates (arm-fire, hand-magnet, head-spotlight, silhouette-cut) work live.

## Phase 7 — Media import (≈2.5 wk)
PHPicker + import sheet + bake pipeline (DAv2-S Fast tier first, VDA-S when spike lands) + polish
pass + chunked HEVC writer + manifest resume + Live Activity/Dynamic Island + BGContinuedProcessing
+ sequential playback engine + Source-node transport + MoGe-2 photos. **Exit:** import a 1-min
clip, background the app mid-bake, resume, loop it in a patch.

## Phase 8 — Outputs + projects (≈2 wk)
NDI (3:4 table, alpha-key) + recorder (up to 2880×3840@60, live-edit-while-recording) + project
browser (grid, thumbnails, copy-on-edit templates) + share codes + `.pointsproj` persistence +
permissions pre-prompts + thermal ladder + Marathon mode. **Exit:** full loop — create, patch,
perform, record, share code, reopen.

## Phase 9 — Catalog completion + templates + polish (≈3 wk)
Remaining catalog to ~110 + factory macros + 20 templates authored + node cards/live previews +
onboarding pass + haptics pass + Reduce Motion + light theme QA + App Store assets.
**Exit:** TestFlight.

Total ≈ 21 weeks solo-dev pace; phases 5/6 and 7/8 partially parallelizable.

---

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Interpreter too slow at 307k | Low-Med | Spike 0 gates it; op-set split light/medium variants; specialized path carries steady-state anyway |
| VDA-S temporal head resists CoreML | Med | Ship Fast tier (DAv2-S + polish — already proven parts); VDA-S lands v1.x; polish pass closes most of the visible gap |
| HEVC depth edge ringing on pin grid | Low-Med | Spike 3 harness; raise bitrate; per-title GOP tuning (sequential-only playback tolerates bigger GOP) |
| Shadow + 307k + bloom + record thermals | Med | Thermal ladder + Marathon mode; shadow LOD2-forced; budget table enforced per phase in Instruments |
| Editor UX complexity creep | Med | HTML mockup locks interactions before Swift; Tier-1-template usability test after Phase 3 |
| 110-node catalog QA surface | High | Catalog JSON is the single source of truth (codegen for node classes + docs cards + palette); per-node golden-image render tests driven from the JSON |
| Vision + capture + render contention | Low | Vision on utility queue at adaptive Hz; triple-buffer results; degrade Vision rate first in thermal ladder |
| Metal4 API churn (iOS 26.x) | Low | MTL4Compiler pathways wrapped behind one facade; Metal-3 fallbacks (`makeComputePipelineState` async) kept alive |

## Verification strategy

- **Per-phase Instruments gate:** Metal System Trace (no compile on frame path, budget table),
  Time Profiler (zero hot-path allocation), thermal soak (20-min NDI+record run at phase 8).
- **Graph engine:** Swift Testing units — type adapter matrix, topo-sort, state-slot alloc/reset,
  program codegen golden files vs interpreter parity (same graph → same numbers, CPU-evaluated
  reference at 16 pins).
- **Depth codec:** round-trip diff harness in-repo (95th/max code error thresholds as asserts).
- **Templates:** each template renders a golden thumbnail in CI-on-Mac (Metal offline) — drift
  alarm for engine regressions.
- **The two laws smoke test (every phase):** (1) static scene 60s → per-pin XY variance == 0,
  Z variance under threshold; (2) automated edit-storm script (add/wire/delete 5 ops/sec, 60s) →
  zero dropped frames recorded.
