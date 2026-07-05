# Plan — Depth-Video Import: Architecture Groundwork

**Status:** Building. **MoGe-2 now runs for real** on the ANE (photo + per-frame video) with a live
depth preview; background execution, Dynamic Island, and edge-loop UI are real. Front end of the
existing spec [`Plans/04-Depth-Import-Pipeline.md`](04-Depth-Import-Pipeline.md). Storage + looped
point-cloud playback are the remaining milestones.

## Goal (from the original vision)
RGB **video/photo in → one-time on-device metric-depth bake on the ANE → stored depth → infinite
looped point-cloud playback**. Live TrueDepth/LiDAR sensors NEVER use these models. Video is the
priority (Depth Anything Video, "no breathing by construction"), photos secondary (MoGe-2).

## What landed this session (`Points/DepthImport/`)
- **`EdgeLoopProgress.swift`** — `EdgeLoopShape` + `ScreenEdgeProgress`. The progress indicator is a
  rounded-rect that starts at **top-centre** and fills **clockwise** around the screen edge back to
  top-centre (`.trim(from:0,to:progress)`), not a flat bar. Full-screen, non-interactive overlay.
- **`DepthBakeManager.swift`** — the pipeline:
  - `DepthModel` protocol (`prepare()` warm-up + `bakeFrame(_:)`), and `StubDepthModel` that sleeps
    ≈ the real ANE per-frame budget so everything downstream is testable now.
  - `BakeOptions` (Indoor/Outdoor + Best/Fast) — the import sheet's choices.
  - `@Observable DepthBakeManager`: real frame count off the `AVAsset`, live `progress`/`fps`/`ETA`,
    cancel. Submits a **`BGContinuedProcessingTask`** (iOS 26) so the bake keeps running when
    backgrounded **and the system renders the Dynamic Island progress for free** — no widget
    extension needed. A `BakeSnapshot` (lock-guarded, `Sendable`) bridges the MainActor bake loop to
    the nonisolated task handler.
- **`VideoImportView.swift`** — PHPicker (video) → options → bake screen (big %, frame/fps/ETA,
  cancel) with the edge-loop overlay. Replaces `ImportPlaceholderView` on the corner-menu import
  button (`ContentView` `.importMedia`).
- **`PointsApp.init`** registers the background handler at launch.
- **`Info.plist`**: `BGTaskSchedulerPermittedIdentifiers` (`com.points.depthbake`),
  `UIBackgroundModes: processing`, `NSSupportsLiveActivities`.

## Manual Xcode step (once, not doable from a file edit)
- **Signing & Capabilities ▸ + ▸ Background Modes**, tick **Background processing** (the Info.plist
  key is already present; the capability makes the entitlement match). Background GPU is **not**
  needed — inference targets the ANE (`.cpuAndNeuralEngine`), which is background-legal.

## What is stubbed vs. real
| Piece | Now | Next |
|---|---|---|
| Import (PHPicker, options, temp copy) | **real** | soft-cap warning >5 min, trim |
| Progress / fps / ETA | **real** (off asset frame count) | frame thumbnails strip |
| Background continuation + Dynamic Island | **real** (BGContinuedProcessingTask) | on-device verify; thermal pacing |
| Edge-loop indicator | **real** | tune corner radius per device |
| Per-frame depth | **REAL — MoGe-2 on ANE**: photo → 1 bake, video → AVAssetReader BGRA decode (sampled ~6 fps) → per-frame MoGe-2, live grayscale depth preview | temporal-consistent video model; full-res / aspect-correct decode |
| Models | **MoGe-2 ViT-B (504) bundled + running** (`.cpuAndNeuralEngine`; direct `depth`+`metric_scale` outputs) | DAv2-S (Fast) + VDA-S (Best) still need their own CoreML conversion |
| Storage | none | PointsDepth v2 (quantized UInt16 + LZ4, mmap) — bake currently previews, doesn't persist |
| Playback | none | sequential looper (no AVPlayer) + `Clip Transport`/`Still Image` Source nodes (already in the catalog); bind baked depth as a Metal texture in the renderer |

**Model file:** `Points/DepthImport/MoGe2_ViTB_Normal_504.mlpackage` (202 MB) — **git-ignored**; must be
present locally to build (the generated `MoGe2_ViTB_Normal_504` class depends on it). Xcode auto-includes
it via the synchronized folder group.

**Known rough edges (groundwork):** input is squashed to 504² (no aspect letterbox yet); portrait video
frames ignore the track's `preferredTransform` so the depth preview may be rotated; video is sampled
~6 fps for a quick test, not the full bake.

## Slots that already exist (no new graph plumbing)
`Plans/03-Node-Catalog.json` / the registry already define **Source** (`mode: media/still`),
**Clip Transport** (loop/speed/restart/position/looped), **Still Image** — a `source`-typed port
threads baked media through the graph exactly like a live sensor. The bake just needs to produce a
stored depth source those nodes read.

## Next milestones (Phase 7 in `08-Build-Phases.md`)
1. **Spike:** run the bundled MoGe-2 mlpackage → map point-map to depth+FOV, measure ms on ANE.
2. **Spike:** convert VDA-S to CoreML (EnumeratedShapes, never RangeDim); DAv2-S Fast tier as the shipped fallback.
3. AVAssetReader decode → `DepthModel` → PointsDepth v2 chunked/resumable writer (manifest resume).
4. Polish pass (scale/shift align, motion-gated EMA, scene-cut resets) baked into stored depth.
5. Sequential playback engine + Source-node transport. **Exit:** import a 1-min clip, background
   mid-bake, resume, loop it in a patch.

## Verify on-device (couldn't from a build)
- Edge-loop fills **clockwise from top-centre** and reaches the true screen edges.
- Start a bake, background the app → **Dynamic Island shows progress** and the bake continues.
- Cancel stops it cleanly; Done returns.
