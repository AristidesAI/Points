# Points — Engine Architecture

Companion to [00-Master-Plan.md](00-Master-Plan.md). Everything here honors the two hard laws:
**pins never wobble laterally** and **no edit ever stutters the render**.

---

## 1. Frame anatomy (60fps reference; 30/120 selectable)

```
CPU (per frame, allocation-free)                    GPU (one command buffer)
─────────────────────────────────                   ─────────────────────────────────
1. Pull inputs: audio frame, MIDI,     ┌──────►     5. [dirty] Domain generator pass
   OSC, touch, Vision results,         │               (sites: uv, baseXY, aux — §2)
   transport/BPM phase                 │            6. Depth upload/decode → filter
2. Evaluate control-rate graph         │               stack passes (deadband+EMA,
   (flat sorted array over            uniforms        node-exposed) → depthTex
   preallocated state pool)            │            7. PIN PROGRAM: per-pin chains
3. Pack uniform block + pin-program    │               (interpreter kernel OR
   buffer (triple-buffered)            │               specialized kernel — §4)
4. Encode command buffer   ────────────┘               writes instance buffer
                                                    8. Instanced draws: stems batch +
                                                       cap batch per shape × LOD
                                                       (depth-tested, opaque-first)
                                                    9. [ghost mode] transparent pass
                                                   10. Post: bloom → grain → vignette
                                                   11. Composite → screen / NDI tex /
                                                       recorder tex
```

Sensor depth arrives at 30fps; the FX/graph clock advances every render frame, so motion nodes
(LFO/spring/trail) stay fluid at 60/120 between depth updates. Media depth is 30fps sequential
(no interpolation — pins step, by decision).

**Vision cadence:** body/hand/face requests run on the RGB stream on a utility queue at ~15-30Hz
(adaptive); results land in a triple buffer the control graph reads. Never on the render thread.

---

## 2. Domain system (grid topologies)

One canonical enumeration: row-major rect lattice at max 307,200 sites (= 480×640, the rotated
depth resolution; exactly 3:4). Every topology is a **warp function** of that lattice, so site
identity = index forever, and all topology changes are uniform writes + one generator dispatch
(~0.1ms), zero allocation.

**Site buffer (SoA, preallocated once, ~7.4MB + optional state):**

```
uv        float2   // depth-texture sample coord
baseXY    float2   // rest position on the Z=0 plane, view units
aux       float2   // stable hash(i) + topology aux (hex axial / ring index / spiral t)
zHeld     float    // perspective-mode XY stabilization state (lazily used)
```

**Warps (v1):**

| Topology | Warp |
|---|---|
| `rect` | identity; cols = round(√(N·¾)), corners exactly on the 3:4 frame |
| `hex` | odd-row half-cell shear + 1.5·s row pitch (pointy/flat param); corners = bounding box pinned, edge policy clamp/overflow |
| `radial` / `spiral` | Shirley-Chow concentric square→disc map (identity-preserving); spiral adds θ+=k·r; phyllotaxis variant (Vogel) as a param |
| `scatter` | uv0 + jitter: hash tier (instant) or baked blue-noise offset texture (CC0 asset) |
| `perspective` | XY = unproject(uv, z) — the TDLidar look. **Wobble control** `xyStabilize`: off / filtered (EMA'd z for XY) / latch (re-target only when Δz > 2-3%, 120ms slew) / quantize (Schmitt-triggered depth planes) |

**Morph:** Domain holds topologyA + topologyB + `blend` (0-1, any driver). Both warps evaluate,
positions lerp per site. At blend==1, B promotes to A (synth-style retarget). Hard switches =
`blend` stepped by a trigger through a Switch node — same mechanism, no special case.

**Count:** drives `dispatchThreads`/`instanceCount` only. Snap to exact cols×rows for rect
(corner-pinning); other topologies take raw count.

**Depth sampling:** a fixed pipeline stage (not user nodes): sample depthTex at site.uv —
hardware bilinear default, 4-tap Catmull-Rom "quality" toggle; **edge-aware**: reject interpolation
across gaps > threshold (silhouettes stay crisp). Confidence-gated: invalid → depth=far → pin
retracts flush to Z=0 (hole policy per Domain: retract/hold/hide/fill).

**Upsampling (count > native samples):** child sites' Z comes from the same bicubic surface of
real samples — "neighbors drive the in-betweens" is inherent; a `childLag` param (0-1) lets
children trail the surface for the elastic-mesh feel.

---

## 3. Pin renderer (real 3D geometry)

### 3.1 Instancing + LOD

- 8 cap shapes: **sphere, cube, tube, slab, cone, ring, disc, spike**. All built with **identical
  vertex count + topology per LOD tier** (T0 ≈ 320 verts, T1 ≈ 96, T2 ≈ 24; exact counts fixed in
  the shape-bake spike) → **shape morph = per-vertex lerp between two shape's corresponding
  vertices** in the vertex shader, driven by per-pin `shapeA/shapeB/morph` from the instance buffer.
- Stems: second instance batch; a unit prism extruded Z=0→cap, profile (match-cap/cylinder/blade),
  per-pin thickness/taper; positioned/scaled in the vertex shader from the same instance data.
- Draw organization: pins bucket by (shapeA, LOD tier) via a GPU counting pass into per-bucket
  index ranges (prefix-sum, precompiled) → one `drawIndexedPrimitives(instanceCount:)` per
  non-empty bucket. Worst case 8 shapes × 3 LODs + stems ≈ 25 draws. LOD picked by projected size.
- Instance buffer (written by the pin program, §4): `pos float3 · scale half · rotation half4(quat)
  · color rgba8 · shapeA/B uint8 · morph half · stemParams half2 · flags uint8` ≈ 32B × 307k ≈ 10MB,
  double-buffered.

### 3.2 Z semantics

`z = clamp((far − depth) · gain, 0, zMax)` with gain/curve/near/far as MOVE-family node params
(Depth Remap node). Rest = flush wall at Z=0. All Z motion happens pin-locally; XY only moves if
a MOVE node explicitly displaces it (or perspective domain).

### 3.3 Shading

- Material node modes: **unlit/emissive** (synth glow, feeds bloom), **lit** (Lambert + rim,
  per-pixel normal from the real mesh — cubes read as cubes), **matcap** (baked sphere-capture
  texture lookup, cheap + stylish).
- **2 Light nodes max** (engine slots): type point/directional/spot, position (drivable fields →
  head/hand-follow works through BODY nodes), color, intensity, falloff, cone. Light #1 may own a
  **shadow map**: single 1024² depth-only pass of the instanced pins (LOD2 forced), PCF 2×2 —
  pins-on-pins shadowing on the wall is the payoff. Shadow pass is skipped entirely when unused.
- Background node: color/vertical gradient/vignette; flags itself for NDI alpha-key.
- Post: Bloom (threshold+intensity, half-res chain), Grain (hash), Vignette — one composite pass.

### 3.4 Depth/blend

Depth buffer ON by default (opaque pins, hardware z-order). RenderSettings node can switch a
branch to **ghost mode**: no depth write, additive/alpha painter's blend (the TDLidar look). Both
pipeline states prebuilt at launch.

---

## 4. Node execution engine (zero-stutter core)

Three layers, per the Dolphin hybrid-ubershader pattern (research-validated):

### Layer A — resident interpreter (always ready)
One compute kernel: a register VM (float4 registers in thread memory, ~50-80 compact ops) walking
a **pin program** — instruction stream + params in a constant-address buffer (every thread reads
the same broadcast stream → zero divergence). Any graph edit = rebuild the pin program on the UI
thread (µs) → triple-buffer publish → **next frame renders the new graph**. Compiled once at first
launch, stored in an MTLBinaryArchive.

Interpreter op-set covers per-pin math: arithmetic, mix/clamp/remap/curve, trig, hash/noise(value,
simplex-lite), field reads (depth, aux, region masks, touch distance), state reads/writes (slot
pool), instance-buffer writes. **Heavy texture ops (depth sampling with Catmull-Rom, region-mask
rasterization) are fixed pre-passes, not interpreter ops** — they write field buffers the
interpreter reads.

### Layer B — async specialization
Each distinct pin-program hash → generated MSL source (v1; `MTLFunctionStitchingGraph` evaluated
later only if compile latency warrants) → `makeComputePipelineState(descriptor:options:completionHandler:)`
on an `MTL4Compiler` queue at `.utility` QoS. Generation-tagged: stale results (user edited again)
are dropped. On completion → staged; render thread adopts at the next frame boundary; old PSO
retires after in-flight buffers complete. Math is bit-identical to Layer A → handover is invisible,
no crossfade needed.

### Layer C — binary archive cache
Keyed by canonical hash (subgraph topology + node types + codegen version). Undo/redo, preset
flips, template opens = archive hit = instant specialized pipeline. Harvest via
`MTL4PipelineDataSetSerializer`. Every lookup fallible → falls back to B (with A covering).

**While recording:** compiler queue drops to `.background`, max 1 concurrent compile. Layer A
guarantees correctness regardless.

### CPU control graph
Flat topologically-sorted array over a preallocated node-state pool. No locks, no malloc, no ARC
traffic per tick (structs + unmanaged storage). Edits rebuild the array off-thread → atomic swap.
Param changes from UI/deck/MIDI → triple-buffered snapshot. (Real-time-audio discipline.)

### State-slot allocator
Stateful pin nodes (Spring 4f, Trail 2f, Echo 2f, Velocity 2f, Lag 1f…) declare floats/pin.
Allocator hands slots from a preallocated pool (**32 floats × 307,200 = ~39MB ceiling**; UI shows
a memory meter). Add/remove never allocates mid-frame. Every slot follows the **pending-reset
seed-from-live** discipline (Metal private storage is undefined at alloc — proven TDLidar gotcha).
Slot-owning params that would reset history are marked `modSafe:false` in the catalog (bar-settable,
not continuously drivable).

### v1 restriction
**Per-pin only.** No neighbor reads, no cross-pin scatter/gather, no propagation sims. Analytic
radial effects (ripple/shockwave = f(distance to point, t)) are per-pin and allowed. Neighbor-pass
infrastructure (flocking, wave equations, blur) is a v2 engine extension — the pass-graph seam is
already in the architecture (fixed pre-passes prove the shape).

---

## 5. Live sources

- **Front TrueDepth:** AVCaptureSession, depth-master synchronizer, DepthFloat32, 3ms-tolerant
  30fps throttle, per-frame autoreleasepool (port from TDLidar `CaptureManager` skeleton, Camera
  Control + Photos priming stripped).
- **Back LiDAR:** ARKit `.sceneDepth` + pin-screen conditioning kernel (median-3 + confidence gate),
  `MainActor.assumeIsolated` sync frame handling (port `BackLiDARDepthRenderer`, Env branch deleted).
- **Session exclusivity:** one camera owner; mode transitions sequence through
  `stop(completion:)` handoff (the documented ARKit/AVCapture race). Source switch hides behind a
  240ms output crossfade.
- **Vision context:** runs on the same RGB frames; never owns a session.

## 6. Outputs

- **NDI:** port `NDISource` + `PointCloudNDIManager` + `ViewportCapture` (async
  `addCompletedHandler` variant — never `waitUntilCompleted` on main). 3:4 table:
  810×1080 / 1080×1440 (default) / 1620×2160 @30 or 60. vImage alpha-key honoring the Background
  node's transparency flag. Bridging header/`libndi_ios.a`/Bonjour plist per the checklist in
  `Notes/Points-App-Plan.md §2.5`.
- **Recorder:** GPU-direct AVAssetWriter (port `PointCloudVideoRecorder` pattern): offscreen render
  at 1080×1440 / 1620×2160 / 2880×3840 (4:3 "4K") @30/60, HEVC, sequential PTS, 60-min ceiling,
  background-interruption finalize, auto-save to Photos (add-only). Resolution locked while
  recording.

## 7. Performance budget (A17 Pro, 60fps = 16.6ms GPU)

| Stage | Budget |
|---|---|
| Domain generator (dirty only) | 0.1ms |
| Depth decode/filter chain | 0.4ms |
| Pin program (interpreter worst case, 307k × ~40 ops) | ≤4ms (spike to verify; specialized ≈ ≤1.5ms) |
| Bucket count + prefix sum | 0.3ms |
| Shadow pass (when lit+shadow) | ~1.5ms |
| Instanced draws 307k (caps+stems, depth-tested) | ~4ms |
| Post chain | ~1ms |
| NDI/record offscreen (amortized @30) | ~1ms |
| **Headroom** | **~4ms** |

CPU/frame: graph eval + uniform pack only; zero per-pin loops anywhere.
Memory: sites 7.4MB + instances 2×10MB + state pool ≤39MB + depth ring ~5MB + shapes/LUTs ≈ **~75MB GPU**.

## 8. Engine spikes (before implementation plans)

1. **Interpreter benchmark** — VM kernel with 40-op program @307k on A17 Pro; measure vs
   hand-fused equivalent. Go/no-go on "interpreter-only could ship v1".
2. **Shape-morph bake** — build the 8 corresponded meshes (script in-repo), verify morphs read
   cleanly at all LODs.
3. **VDA-S CoreML conversion** — backbone per-frame + temporal head per-window; measure ms/frame
   ANE (see [04](04-Depth-Import-Pipeline.md) §6).
4. **HEVC depth harness** — bake 30s, decode, diff vs source (95th/max code error, silhouette
   check), confirm GOP-seek-free sequential loop restart.
5. **Metal 4 compile QoS** — measure background-compile latency while encoding 4K60.
