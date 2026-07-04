# Points — Imported-Media Depth Pipeline

> **CORRECTION (2026-07-03b): NO HEVC.** §4/§5 below are superseded: imported media stores the
> processed depth directly as a custom binary (quantized UInt16 depth planes + LZ4 block
> compression, memory-mapped playback; color stored as quantized RGB planes in the same container
> or re-sampled at pin sites). Sizing/format finalized during the import build phase. Models,
> bake flow, polish pass, Live Activity, and transport sections remain valid.

RGB video/photo in → one-time on-device ML bake → stored depth → infinite node-driven playback.
Live sensors NEVER use these models (raw TrueDepth/LiDAR only). Research provenance: workflow
`wktdws96b` (models/deployment/storage agents, July 2026 web survey).

---

## 1. Models (all bundled in the app binary)

| Role | Model | License | Size | Notes |
|---|---|---|---|---|
| **Video (default)** | Metric-Video-Depth-Anything-**Small** | Apache-2.0 (HF card + repo verified) | 28.4M ≈ 57MB fp16 | Video-NATIVE temporal consistency: 32-frame windows, 8 overlap + 2 keyframes, one scale/shift across the whole video — no breathing by construction. 518-class input. **We convert to CoreML ourselves** (no public port; backbone per-frame on ANE + temporal head per-window on GPU) |
| **Video "Fast" tier** | Depth Anything V2 metric ViT-S (Hypersim indoor / VKITTI outdoor) | Apache-2.0 (Small only) | 47MB each | Already converted + proven (17-34ms/frame ANE, MLMultiArray out, per prior TDLidar plans). Per-frame → relies on the polish pass |
| **Photos** | MoGe-2 ViT-B Normal | MIT | 202MB | **Already converted:** `/Users/ari/Downloads/MoGe2_ViTB_Normal_504.mlpackage` (verified on disk) → vendor into repo. Metric point maps + FOV recovery (feeds the intrinsics chain) |

Rejected (license/size): Apple Depth Pro (apple-amlr research-only weights), DA3 (user call: no),
DepthCrafter/UniDepth/UniK3D/Metric3D (non-commercial), diffusion video models (phone-infeasible).

**Warm-up:** models compile on-device at first import ("Preparing engine…" one-time state, 10-60s);
keep `MLModel` alive for the whole batch; `computeUnits = .cpuAndNeuralEngine` (ANE is background-legal,
GPU is not).

## 2. Import flow

1. PHPicker → video/photo (soft cap warning >5 min with bake-time + size estimate before commit).
2. Import sheet: **Indoor / Outdoor** (always ask), quality tier (Best = VDA-S / Fast = DAv2-S),
   optional trim.
3. **Bake** (foreground-first):
   - AVAssetReader decodes BGRA at model resolution, 2-3 frames read-ahead; frames sampled at
     min(source fps, 30).
   - Async prediction, exactly 2 in flight (pipelines pre/post with ANE).
   - VDA-S: backbone per frame → temporal head per 32-frame window; window stitching per the paper
     (linear blend over 8 overlap frames).
   - **Polish pass (always-on, into stored depth):** per-frame scale/shift alignment in
     inverse-depth vs keyframes → motion-gated EMA in metres → scene-cut detection resets. GPU
     kernels at bake time; stored depth is final (playback does zero stabilization).
   - Encode incrementally (chunked writer, resumable manifest) — §4.
4. **Progress surfaces:** in-app progress screen (fps, ETA, frame thumbnails) + **ActivityKit Live
   Activity** → Dynamic Island compact ring around the camera (AirDrop/Timer-style) + lock-screen
   card + **BGContinuedProcessingTask** (iOS 26; ANE keeps running in background; progress
   reporting mandatory or the system expires the task). Thermal pacing: `.serious` halves rate,
   `.critical` checkpoints + pauses.
5. Bake completes → project opens (**no partial playback** — decision). No preview gate: user
   judges in the editor; re-import to change domain/tier.

**Photos:** single MoGe-2 inference → 1-frame project; FOV estimate recorded.

## 3. Intrinsics chain (Perspective domain only; grid domains are Z-only)

EXIF/QuickTime camera metadata → MoGe-2 FOV estimate (photos) → 60° default. Exposed as an `fov`
param on the Source node (drivable like everything else).

## 4. Storage — "PointsDepth v2" (lean per user decision: lossy only, small files)

```
depth.mov   HEVC Main10, GOP compression (keyframe ~every 30 + at loop start),
            log-encoded depth in luma: code = round(1023·ln(d/near)/ln(far/near)),
            near/far from 1st/99th percentile stats pass, ±0.5 LSB blue-noise dither
            (kills pin banding), chroma constant. ~10-15 MB/min @ ~2Mbps.
color.mov   960p HEVC of the source (self-contained if user deletes original). ~60 MB/min.
depth.json  {near, far, curve:"log", fps, frameCount, resolution, model, domain, fov,
             schemaVersion}
```

- GOP (not all-intra) is safe because playback is **sequential-only** (decision: simple looper, no
  scrubbing) — loop restart lands on the first keyframe, no mid-GOP seeks ever.
- Precision: 10-bit log over 0.3-20m = 0.41%/step (4mm @1m) — 20-50× below model error; dither
  covers banding. No lossless tier (decision).
- Chunked manifest during bake → resume after kill; files `isExcludedFromBackup`.
- No pose bake for imported media in v1 (decision) — BODY nodes are live-camera features.

## 5. Playback engine

Sequential looper, no AVPlayer: dedicated decode thread → VTDecompressionSession →
4-8 decoded-frame ring → luma plane wrapped zero-copy as `r16Unorm` MTLTexture
(CVMetalTextureCache). Pin kernel reconstructs metres: `d = near·exp(code·K)`. Playback ≤30fps
(decision — pins step; graph motion still animates at render rate). Transport (Source node):
play/pause (trigger-drivable), speed 0.25–2× (frame hold/skip), loop in/out, restart trigger.
Decode cost ~0.5ms/frame hardware — invisible next to the render budget.

## 6. Spike list (pre-implementation)

1. **VDA-S CoreML conversion** (the one real R&D item): export backbone fixed-shape 518-class fp16
   (EnumeratedShapes for portrait/landscape — never RangeDim, which silently falls off ANE);
   temporal head as a second model over stacked features; measure ms/frame + op residency (Xcode
   CoreML report) on A17 Pro. Fallback if the head resists conversion: ship Fast tier (DAv2-S +
   polish pass) and land VDA-S in v1.x.
2. **Polish-pass quality harness:** bake handheld/indoor/outdoor/cut-heavy clips with DAv2-S raw vs
   polished vs VDA-S; eyeball on the pin grid at high depth gain.
3. **HEVC depth round-trip:** encode/decode diff (95th/max code error), silhouette flying-pixel
   check, loop-restart seamlessness, GOP size tuning (~2Mbps target).
4. **MoGe-2 wiring:** run the existing mlpackage, map point-map output → depth+FOV, measure ms.
5. **Live Activity + BGContinuedProcessingTask:** ring UI in Dynamic Island, expiration behavior,
   resume-from-manifest path.
