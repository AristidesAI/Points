# POINTS — Point-Cloud Visual Synth — Master Plan

**Status:** PLAN (2026-07-02). Nothing built. Grounded in a 7-way codebase survey of
`/Users/ari/Documents/XcodeProjects/TDLidar2/TDLidarBackup/TDLidar` (every claim has a file:line behind it)
plus the prior `Notes/MIDI-DepthMotionFX-Plan.md`. Target project: `/Users/ari/Documents/XcodeProjects/Points`
(fresh SwiftUI template, already git-init'd).

---

## 0. What Points is

A standalone iOS **visual synthesizer** whose instrument is a live point cloud. TDLidar's Point Cloud mode,
freed from its TouchDesigner-serving constraints:

| TDLidar constraint | Points |
|---|---|
| TCP geometry stream (50k cap, 16 B/point, CPU readback) | **Deleted.** Points render GPU-resident, never touch the CPU |
| OSC geometry out | **Deleted.** OSC becomes an *input* |
| Orbit/swipe camera | **Fixed camera.** 90°-aligned, slight manually-triggered offsets only |
| ~50k point ceiling (UI + TCP) | **200,000 points** (GPU capacity 307,200 already exists) |
| Motion FX bounded by "must ship clean points downstream" | FX are the product — unbounded history, spawn/kill, feedback |
| Full-screen viewer + slide-up settings bar | **3:4 viewport pinned top + permanent "change bar" below** |
| No modulation | **Mod matrix:** device motion, audio analysis, MIDI, OSC-in, face blendshapes, touch, LFOs |

NDI video out **stays** (the rendered viewport, alpha-keyable). Local MP4 recording stays.

### The three modes

1. **CLOUD (back LiDAR)** — the ported point cloud mode. ARKit `.sceneDepth` → pin-screen conditioning →
   GPU unproject → points. Camera fixed.
2. **FACE (front TrueDepth)** — front point cloud + ARKit face tracking. TrueDepth depth cloud via AVCapture
   *or* ARKit face session supplying the 1220-vertex mesh + 52 blendshapes as mod sources. (The two front
   stacks are hardware-exclusive — see §4.4.)
3. **LUMEN (back RGB)** — the new mode. Back camera image projected as a **flat point grid where per-pixel
   luminance drives point depth**. No depth sensor at all → runs at **60 fps** (depth modes are sensor-capped
   at 30). Flatter than the LiDAR cloud by design; `flatProjection`'s constant-refDepth math is the exact
   geometry (`BackLiDARShaders.metal:369-374`). Fixed grid = **stable per-point identity**, which unlocks the
   per-point-state effects (Murmuration, Pour, Gel) that were impossible in the atomic-append LiDAR path.

---

## 1. Architecture

### 1.1 Pipeline (the "R3" rule: points never leave the GPU)

```
DEPTH SOURCES                         RASTER FX (2D, depth-domain, ping-pong history)
back:  ARSession .sceneDepth ──► pin-screen (median-3 + conf gate)──┐
front: AVCapture TrueDepth sync (depth master, Float32) ────────────┤
lumen: AVCapture BGRA 4:3 @60 ──► luma extract (r32Float "depth") ──┤
                                                                    ▼
        [Vanish (pre-EMA)] → [EMA stabilize] → [bilateral → holes → accumulate/sculpt]
        → [NEW: EQ Terrain / Resonator / Feedback Tunnel / Slit-Scan / H-Hold …]
        → [Light Paint] → [Riptide] → [Trails 2.0] → [fxRGBModulate/Velocity 2.0] → [JBU 2×]
                                                                    ▼
                                  unprojectPointCloud (pinhole OR flat/luma grid)
                                  atomic append → 24 B/point MTLBuffer ring (cap 307,200)
                                                                    ▼
        POINT-DOMAIN GPU TAIL (all new — replaces CPU "Seam B")
        [ghost/echo appends] → [springs/particles: Pour, Kick Shatter, Murmuration]
        → [per-point look kernel (ported FilterEngine formulas)] → [strobe/kill]
                                                                    ▼
                    PointCloudRenderer (fixed camera, MTKView 60fps, painter's blend)
                    ├── on-screen 3:4 viewport
                    ├── PointCloudCapture → NDI (3:4, 30/60fps, alpha-key)
                    └── PointCloudVideoRecorder → H.264 MP4 → Photos
```

**Non-negotiable change vs TDLidar:** delete the per-frame GPU→CPU readback
(`PointCloudGPUUnprojector.swift:370-388`), the `deliverPointCloud` CPU merges (`ContentView.swift:3110-3212`)
and the `uploadPoints` repack (`PointCloudViewer.swift:282-315`). At 200k×30fps that's ~18M element-ops/sec
across three threads (~230 MB/s of copies) — the survey calls GPU-residency "near-mandatory, not an
optimization." The renderer gets a new vertex function that fetches directly from the unprojector's
interleaved 24-byte buffer (`device float*` + `vid*6` — the existing `float3*` stride-16 signature cannot
bind it; `packed_float3` would "shear the cloud into ghost copies" per `PointCloudShaders.metal:31-36`).
TCP was the only consumer that needed CPU points. It's gone.

**Sensor/render decoupling:** depth arrives at ~30 fps, the renderer runs 60. Between depth frames the FX
clock still advances (time-animated kernels re-run on retained state), so effects stay liquid at 60 even
when geometry updates at 30. Lumen mode is natively 60/60.

### 1.2 Module map (new project layout)

```
Points/
├── App/            PointsApp.swift, ModeCoordinator (camera-ownership state machine)
├── Render/         MetalContext, PointCloudRenderer(+MTKView), Shaders/ (PointShaders.metal,
│                   DepthKernels.metal, EffectKernels.metal), FixedCamera
├── Capture/        CaptureManager (front depth + lumen RGB), BackLiDARDepthRenderer (ARKit),
│                   FaceEngine (ARKit face), CameraFormat
├── Engine/         PointCloudPipeline (was sendPointCloudOSC/deliverPointCloud logic),
│                   CleanupPipeline (was PointCloudCleanup), GPUUnprojector, EffectStack
├── Mod/            ParamRegistry, ModRouter, ModMatrix, LFOBank,
│                   Sources/ (MotionSource, AudioSource, MIDISource, OSCInSource, FaceSource, TouchSource)
├── Output/         NDISource, PointsNDIManager, ViewportCapture (was PointCloudCapture),
│                   VideoRecorder, RecordingsStore
├── UI/             ViewportView, ChangeBar/ (BoxRow, ControlStage, RulerSlider, MacroPads, XYPad),
│                   SettingsSheet, Typography, Haptics, HUDComponents, Layout
├── Settings/       AppSettings (pts.* keys), SnapshotConfig structs, Scenes (A/B presets)
├── Permissions/    PermissionGate, LocalNetworkProbe
└── NDI/            libndi_ios.a + include/ + bridging header (vendored)
```

---

## 2. Port map from TDLidar

### 2.1 Copy verbatim (rename subsystem strings only)

| File | Why |
|---|---|
| `Pro/MetalContext.swift` | Device/queue/CVMetalTextureCache singleton; `wrap(buffer:pixelFormat:plane:)` already plane-aware — Lumen's Y-plane wrap is one call |
| `Typography.swift` (+ JetBrains Mono fonts, UIAppFonts plist entries) | Weight-in-PostScript-name system; monospace = readouts that don't jitter |
| `Haptics.swift` | Process-lifetime generators — fixes a real iOS 26.5 EXC_BAD_ACCESS with fire-and-forget generators |
| `HUDComponents.swift` | Circle buttons + settings-sheet chrome (SettingsCard, MonoMenuPicker…). Keep the "SF Symbol LAST in ZStack" Liquid-Glass invariant (`:11-14`) |
| `iPad/Layout.swift` | isWideLayout, 1.4× scaling, `iPadBarWidth(720)` for the change bar |
| `CameraFormat.swift` | `applyFourThreeFormat` + `applyNDIFrameRate(60)` + `BackCameraZoom` — literally the Lumen 3:4@60 recipe |
| `DepthColorMap.swift` | 15 colormaps, pure Swift. Add one helper baking `bgraLUT()` into a 256×1 `MTLTexture` for vertex-shader sampling; drop `requiresPro` + `rawContour` |
| `NDISource.swift`, `Pro/PointCloudNDIManager.swift` | Clean NDI sender + 30fps wrapper; rename source to "Points" |
| `NDI-Bridging-Header.h` + `Pro/NDI/` (lib + headers) | `#define PROCESSINGNDILIB_STATIC` **before** the import; fat lib has no arm64-sim slice (see §2.5) |
| `Permissions/LocalNetworkProbe.swift`, `PermissionGate.swift` | TN3179 NWBrowser permission probe for `_ndi._tcp` |
| `Pro/PointCloudVideoRecorder.swift` | Best recorder: GPU-direct into writer pool, off-main appends, sequential PTS, 60-min ceiling, drain-on-stop |
| `NetworkMonitor.swift` | `localIPv4Addresses` = the "send OSC to this phone at IP:port" readout |
| `PhoneSensorManager.swift` | Device-motion core (rates, ref frames, per-axis gate/sens, quaternion calibrate, altimeter). Retarget emit → mod matrix; delete Watch block |
| `AudioAnalysisEngine.swift` | Full analyzer (bands/onsets/burst/20-band FFT/true RMS). Retarget `onFrame` → mod matrix; rename defaults prefix |
| `Pro/PointCloudFilters.swift` | Sendable filter-stack model + JSON persistence — the change bar's data model |
| `DepthOutputView.swift` | Zero-lag BGRA monitor (AVSampleBufferDisplayLayer) if an NDI-out preview is wanted |

### 2.2 Adapt

| File | Changes |
|---|---|
| `Pro/BackLiDARShaders.metal` | Keep all kernels verbatim (EMA, bilateral, holes, accumulate/sculpt, vanish, trails, light paint, riptide, fxRGBModulate, motion-cutout+reduce, pin-screen, JBU, `pcHash12`/`pcHue2rgb`). Adapt `unprojectPointCloud`: strip rgbSwapUV/flip debug params, add luma-as-Z source, extend velocity to 2D. Wire the two **dormant** kernels: `motionCutoutRaster` (complete, unwired — re-slot pre-EMA per `PointCloudGPUUnprojector.swift:222-231`) and `depthToBGRA` (`metal:212`, zero call sites — useful for a 2D depth/luma monitor) |
| `Pro/PointCloudCleanup.swift` | The architectural core: ping-pong + parity + `pending*Reset` discipline, `PCCleanupConfig.snapshot()` per-frame transport, encode ordering. Delete CPU `PointCloudPointCleanup` (voxel/despeckle); drop trail bias keys; expose hardcoded `velGain/settleFrames/maxAge` (`:174-176`); fix the trailRecede snapshot-vs-default drift (1.0 vs 0.3, `:89` vs `SettingsView.swift:2852`); plumb real fps into the seconds→per-frame decay conversions (`:563` assumes 30) |
| `Pro/PointCloudGPUUnprojector.swift` | Keep ring/semaphore + pass sequencing. **Remove the tuple readback** — new completion hands `(MTLBuffer, count)`. Capacity 307,200 already ≥ 200k |
| `Pro/PointCloudViewer.swift` | Keep renderer core (pipeline cache per pixel format, `renderToTexture`, lookAt/perspective, MTKView factory: no depth buffer, painter's blend, 60fps). Add direct-buffer point source + `vid*6` vertex fetch + buffer-less Lumen grid vertex fn (derive `(u,v)` from `vertex_id`, sample camera tex, luma→Z). Delete orbit-cube state. Add `FixedCamera` (§3) |
| `Pro/PointCloudShaders.metal` | Keep `pc_point_vertex/fragment` sprites; add packed-fetch + Lumen variants |
| `Pro/BackLiDARDepthRenderer.swift` | Keep ARSession + pin-screen + YCbCr→BGRA pooled convert + `MainActor.assumeIsolated` sync processing. Delete the Env/Raw bilateral branch + its knobs |
| `CaptureManager.swift` | Keep skeleton (.inputPriority, `bestDepthCapableFormat`, depth-master synchronizer, 3ms-tolerance throttle, `stop(completion:)` handoff, per-frame autoreleasepool). Strip Camera Control plumbing + Photos priming. Add Lumen configure path: RGB-only, `applyFourThreeFormat(minWidth:1280)` + 60fps, no depth output |
| `FaceTracker.swift` | Keep ARSession + Sendable FaceUpdate + blendshape L/R mirror + threshold. Replace OSC build with mod-source writes; extend mesh export to strided/full 1220 verts as renderable points |
| `FrontDistanceManager.swift` | Drop its private session; port `minDepth()` (`:182-207`) as a pure function over the main depth buffer → "proximity" mod source |
| `Pro/PointCloudCapture.swift` → `ViewportCapture` | Keep CADisplayLink → pooled IOSurface → `renderToTexture` → vImage alpha-key → NDI. Replace 9:16 table with **3:4**: 810×1080 / 1080×1440 (default) / 1620×2160. Replace main-thread `waitUntilCompleted()` (`:223-226`) with the recorder's `addCompletedHandler` async pattern. Allow 60 for Lumen |
| `Pro/PointCloudSettingsBar.swift` → `ChangeBar` | The permanent bar (§6). Keep boxRow + dividers + control stage + all control helpers + RulerSlider (promote to ONE shared component — it's file-private-duplicated ×3 today). Delete grabber/dragY/onClose, tcpPanel, orbit boxes. Add `visible(in:)` context filtering + fallback reselect from `LiDARSettingsBar.swift:39-41,146-148` |
| `Pro/PointCloudSettingsView.swift` | The "i" sheet: keep points/cleanup/stabilization/viewer/NDI sections + Reset; delete TCP + PLY export + orbit rows |
| `SettingsView.swift` → `AppSettings.swift` | Extract ONLY the class shell + kept keys under a fresh `pts.*` prefix. Preserve: `@Observable nonisolated final class … @unchecked Sendable`, closure-init UserDefaults read + `didSet` write-back, `object(forKey:) != nil` idiom (never `v > 0`), init() migration scaffold, per-camera profile snapshot, `resetToDefaults` + resettableKeys |
| `CameraControlsCoordinator.swift` → `ModRouter` | Generalize `dispatch()` (`:106-197`): {normalized 0–1 source} × {target param id} → range adapter (min/max/curve/quantize) → idempotent `@MainActor` write. Registered once, no-ops when inactive — the proven no-race shape. iPhone-16 Camera Control becomes just another router input |
| `OSCSender.swift` → `OSCInSource` | Invert the OSC 1.0 codec (`:330-386`) into an `NWListener(.udp)` receiver; lift PermissionGate gating, denial watchdog, plainEnglish error map, keyPrefix persistence |
| `SensorStreamCoordinator.swift` → `InputCoordinator` | Keep the patterns only: `enginesShouldRun` gate, `sync(need,&running,start,stop)`, 20 Hz viz throttle + 64-sample history, single-owner AVAudioSession deactivation, route-change re-tap, mic picker. Delete ~70% (Vision engines, NDI overlay burn, watch/NFC) |
| `AirPodsMotionEngine.swift` | Keep HeadPose/recenter/watchdog/tilt; strip Pro gating + OSC. Optional mod source |
| `RemoteControlManager.swift` | Optional trigger source (play/pause/next). Keep command-center path only; volume-KVO capture is dead while AVCaptureEventInteraction exists + fights the audio session — ship without it |
| `TouchInputManager.swift` | Clean 3-slot multitouch engine, zero camera semantics. Swap OSC emission in `report()` for mod-source callback → becomes the XY pad / viewport touch input. Keep `isMultipleTouchEnabled=true` + cancelled-mirrors-ended |
| `ResetSettingsButton.swift` | Rewire onReset → stop NDI; point at new key set |
| `Info.plist` keys | Keep `_ndi._tcp`/`_ndi._udp` + NSLocalNetworkUsageDescription + camera/mic/Photos-add strings + CADisableMinimumFrameDurationOnPhone; drop `_tdlidar-scene._tcp` + ssh/smb/rfb discovery types |

### 2.3 Rewrite (logic kept, execution model replaced)

| Source | Replacement |
|---|---|
| `ContentView.swift:2811-3300` (`sendPointCloudOSC` + `deliverPointCloud` + `handleBackLiDARFrame`) | `PointCloudPipeline` class. Keep verbatim: stride = √(W·H/density), intrinsics scaling, per-camera flip/refDepth (`autoFlipX = !useBackCamera`, `frontMirrorSign = -1`, refDepth 0.45 front / 1.6 back, zFar 2.5×refDepth), frozen-centroid centering + explicit reset hook, thermal density backoff. Delete: TCP/OSC sends, CPU fallback loop, direct UserDefaults reads on the capture queue (one snapshot struct instead — default-drift has bitten twice: `ContentView.swift:2957-2996`) |
| CPU Echo ring (`ContentView.swift:3134-3162`) + FilterEngine echo (`PointCloudFilterEngine.swift:169-183`) | **One** GPU Echo 2.0 (§5.1). Two things are called ECHO today; unify |
| CPU Gravity pool (`ContentView.swift:3164-3212`) | GPU **Pour** (§5, effect 9) |
| `PointCloudFilterEngine.swift` (CPU per-point loop, 8×-variant expansion) | One per-point Metal look kernel. All 20 formulas port 1:1 (falseColor/contour/fog/mist/glow/wave/drift/dust/rift/slice/bore/scan/veil/lines/prism); implement WIRE as the intended line lattice (header TODO `:19`); SWARM becomes Murmuration. Uniforms (zmin/zspan/centroid) from a small GPU reduce |
| `Pro/PointCloudInteractiveViewer.swift` | ~40-line UIViewRepresentable hosting the MTKView + `FixedCamera` presets. The 6-line spherical placement formula (`:253-260`) is the only survivor |
| MIDI | **Net-new** (zero CoreMIDI in the old codebase): CoreMIDI client + input port (UMP API), endpoint hot-plug, `MIDINetworkSession` (RTP), `CABTMIDICentralViewController` BLE sheet. Normalize {cc, ch, value 0–1} / noteOn/Off → ModRouter. MIDI clock → tempo bus (v2) |

### 2.4 Drop entirely

`PointCloudTCPStreamer.swift` (+ call sites `ContentView.swift:1470, 2411-2425, 3217`; `MeshCloudViewer.swift:27,86,274`),
`GeometryStreamServer.swift` + `SceneStreamProtocol.swift` (already dead — never instantiated),
`SceneOSCSerializer.swift` (+ `TDLidarApp.swift:40` DEBUG call), `NDIManager.swift` (2,351-line TD depth-video encoder),
`CombinedNDIManager.swift`, `CameraNDIManager.swift`, `SensorCameraRelay.swift`, `MPSDepthUpscaler.swift`,
`Face3DTrackingManager.swift` (owns a conflicting session; ARKit face is strictly richer),
`NetworkDiscovery.swift`, `IPDiscoveryField.swift`, `NDIRecorder.swift` (fold `recordingsDir`/`saveToPhotos`
statics into `RecordingsStore`), all Store/Paywall, MeshCloud/SceneBuild/Sensors modes, `WelcomeView`.

### 2.5 NDI integration checklist (fresh Xcode project)

- Vendor `NDI/` (libndi_ios.a — 268 MB fat x86_64+arm64 — + 17 headers).
- `HEADER_SEARCH_PATHS = $(PROJECT_DIR)/Points/NDI/include`, `LIBRARY_SEARCH_PATHS = $(PROJECT_DIR)/Points/NDI`,
  `OTHER_LDFLAGS = -lndi_ios -lc++`, lib in Frameworks phase, `SWIFT_OBJC_BRIDGING_HEADER` set.
- Bridging header: `#define PROCESSINGNDILIB_STATIC` **before** `#import "Processing.NDI.Lib.h"`.
- No arm64-simulator slice → wrap NDI calls in `#if !targetEnvironment(simulator)` (or exclude arch).
- Info.plist: `NSBonjourServices = [_ndi._tcp, _ndi._udp]` (required even though we only send — the
  permission probe browses it), `NSLocalNetworkUsageDescription`, `NSPhotoLibraryAddUsageDescription`.
- No multicast entitlement needed (old app ships without one).
- Replicate `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (project.pbxproj:404) — the `nonisolated` annotations
  on NDISource/recorders depend on it.

---

## 3. The fixed camera

Renderer already owns eye/center/up/fovY and the fixed path already exists
(`applyViewerCamera`: eye=(0,0,d), center=origin, up=+Y — `PointCloudViewer.swift:350-357`). Points arrive
pre-centered on a **frozen centroid** (`ContentView.swift:3240-3258`) so origin = mid-cloud. All orbit/swipe
machinery lives in one droppable file.

**`FixedCamera` spec:**

- State: `facing ∈ {front, back, left, right}` (azimuth = k·π/2), `nudge = (azOffset, elOffset)` each clamped
  **±8°**, `dolly` (0.05–40 m clamp, slider-set only), `fov` (20–120°).
- Placement: the 6-line spherical formula from `PointCloudInteractiveViewer.swift:253-260` around pivot=origin.
  Because azimuth/elevation are set analytically (never accumulated from gestures) and the pivot is the
  centroid-centered origin, **off-center input can never skew the cloud — it stays 90°-aligned by construction**.
- Nudge triggers are explicit controls (change-bar buttons / MIDI notes / a dedicated "Angle" box), animated
  with `.spring(response: 0.4, dampingFraction: 0.85)`, and always return to detent on double-tap. No drag
  gesture ever writes camera state.
- `depthCurve` z-scale (neutral 0.60) + `parallax` depth-weighted XY spread (`PointCloudFilterEngine.swift:119,137-141`)
  stay as the "fake dimensionality" knobs — they pop depth without moving the camera, exactly what a fixed
  rig needs.
- Lumen framing: discrete lens stops 0.5×/1×/2× via `BackCameraZoom` virtual-device switch-over — framing
  without gestures.

---

## 4. Modulation system (the synth core)

### 4.1 ParamRegistry

One declarative table, registered at startup:

```swift
struct ParamDescriptor {
    let id: ParamID            // "trails.decay"
    let label: String          // "TRAILS FADE"
    let group: ParamGroup      // .cleanup, .look, .fx, .camera, .output
    let modes: Set<Mode>       // [.cloud, .face, .lumen]
    let range: ClosedRange<Float>
    let curve: Curve           // linear / exp / quantized(steps)
    let kind: Kind             // .continuous, .toggle, .trigger (monotonic token), .enum
    let set: @MainActor (Float) -> Void   // writes AppSettings (didSet persists; snapshot picks up next frame)
    let get: @MainActor () -> Float
}
```

~90 params at launch (inventory §7). `.trigger` reuses the **monotonic-token pattern** from Sculpt re-seed
(`pc.sculpt.reseed`, `PointCloudSettingsBar.swift:523-527`) — the proven UI→render-thread one-shot.

### 4.2 ModRouter + ModMatrix

`ModRouter` = the generalized `CameraControlsCoordinator.dispatch` (survey: "register everything, adapter
no-ops when inactive" killed the mode-swap race surface). On top, the **ModMatrix**: N assignments of
`{source, param, depth −1…+1, slew ms, mode: add|replace}`. Sources are sample-and-hold latest-value (the
old coordinator's leading-edge throttle drops values — wrong for modulation; survey gotcha).

Base value (change bar) + Σ(mod depths) → clamp → `set()`. The bar renders a **mod ring** around any
modulated box showing live modulation amount (see §6).

### 4.3 Sources

| Source | From | Channels | Rate |
|---|---|---|---|
| **Motion** | `PhoneSensorManager` (copy) | pitch/roll/yaw (calibrated), userAccel xyz (gated), rotationRate xyz, gravity, altitude, |accel| jerk | 50–100 Hz |
| **Audio** | `AudioAnalysisEngine` (copy) | bass/mid/high (auto-gain 0–1), drumLow/Mid/High onsets (50 ms hold), burst, 20-band FFT, true RMS, host-derived spectral centroid | ~47–94 Hz (nominal 30/60 — decimation is approximate, survey gotcha) |
| **MIDI** (net-new) | CoreMIDI UMP + Network + BLE | CC (0–1), note gates, velocity, pitch bend; clock v2 | event |
| **OSC-in** (net-new) | NWListener UDP, inverted codec | `/points/mod/<n>` floats, `/points/param/<id>`, `/points/trigger/<id>` | event |
| **Face** (FACE mode) | `FaceTracker` (adapt) | 52 blendshapes (L/R mirrored for performer), head yaw/pitch/roll, gaze, proximity (ported `minDepth`) | 30 Hz |
| **Touch** | `TouchInputManager` (adapt) | XY pad x/y/force ×3 slots, viewport taps | 120 Hz |
| **Internal** | new LFOBank | 4 LFOs (sine/tri/S&H, 0.02–8 Hz, tempo-syncable v2), 2 AR envelopes triggerable by any onset | 60 Hz |
| **AirPods** (optional) | `AirPodsMotionEngine` | head tilt ±1, accel/rotation magnitudes | ~25 Hz (interpolate; stale→0) |

### 4.4 Session/hardware realities (from survey — design around these)

- **One camera owner at a time.** ARSession ⟷ AVCaptureSession handoffs must be sequenced through
  `CaptureManager.stop(completion:)` (`:171-192` exists precisely for this race). `ModeCoordinator` owns the
  state machine: CLOUD (ARKit back) / FACE-cloud (AVCapture front) / FACE-mesh (ARKit front) / LUMEN
  (AVCapture back RGB). No MultiCam anywhere in the ported code — front-face + back-cloud simultaneous is
  out of scope v1.
- **Audio session:** one `.playAndRecord` owner; engine `stop()` never deactivates the session — the
  coordinator deactivates only when the LAST consumer leaves (else siblings die `.isBusy`). Route change →
  stop()/start() the analyzer to re-bind format.
- **Volume buttons are unreliable** while a capture view + AVCaptureEventInteraction exist — don't build
  triggers on them.
- **Continuous modulation vs history resets:** `accumulate`/`sculptFrames` changes reset their history every
  frame if modulated (`PointCloudCleanup.swift:431-433`). Registry marks such params `modSafe: false`
  (bar-settable, not matrix-routable) or the reset trigger gets reworked to fire only on user edits.
- Magnetometer channels vanish below calibration accuracy `.low` — matrix must tolerate absent channels.

---

## 5. Effects

### 5.0 The shared upgrade: one optical-flow pass

Today Trails fans dust along a screen-space *age gradient* (hence the biasX/biasY hack) and Velocity sees
only Z-motion. One new quarter/native-res kernel — Lucas-Kanade-lite on the EMA depth raster (spatial grads
+ temporal dt already resident in the shear state) → `rg16Float` flow ping-pong (~0.2 MB) — feeds Trails 2.0,
Velocity 2.0, and Motion-Cutout. Paid once.

### 5.1 The three keepers, reworked

**ECHO 2.0 — "Beat Echo" (replaces the CPU ring AND the FilterEngine echo).**
GPU snapshot ring: 8 slices of {depth r32Float + color rgba8} at native 256×192 (~3 MB). Capture fires **on
beat / tap-tempo / MIDI-clock quantize**, not per frame. In unproject, each pixel *stochastically* picks
live-or-ghost-slot via `pcHash12(gid ^ frameSeed)` against a weight table → total emitted points stay ≤ one
frame's worth — **echo no longer inflates point count, ever** (the old CPU merge was O(N·count) and ~52 MB
at 200k). Per-ghost: zPush, scale-about-centroid, hue rotate (`pcHue2rgb`), and an optional **spring-lag
transform** (second-order follower of the live centroid; young ghosts snap, old ones float and overshoot —
MIDI notes can each hold one ghost). Params: mix (master), count 1–8, quantize 1/1–1/8, zPush ±0.5 m,
scale/ghost 0.9–1.1, hue step 0–90°, lag stiffness.

**TRAILS 2.0 — "Comet Phosphor".**
State repacked to (heldZ, age, vx, vy): on vacate, latch the **true flow vector**. Dust offset =
`v·age + ½(g+wind)·age²` — ballistic, with **g = device attitude's world-down projected to screen** (trails
always fall *down* regardless of phone orientation) and wind from gyro rate. Dual time-constant phosphor
decay (fast 0.05–0.5 s + slow 0.2–8 s; hue mixes white-hot → phosphor-green by age ratio). Beat-gate option:
`keepProb *= gate(beatPhase, div, width)` — trance-gate dust strobing on musical subdivisions; decay
specified in **beats** when clock present. Onset "flash" momentarily saturates persistence (overdriven CRT).
Deletes biasX/biasY. Same texture format out — the unproject dust path is untouched.

**VELOCITY 2.0 — "Momentum Smear".**
True 3D per-pixel velocity `v = (flow.xy·z/f, dz·fps)` — lateral motion finally registers. "Stretch"
finally **displaces**: each energetic point emits at a hash-jittered fraction along `−v·streakTime`
(statistically fills its own motion smear at zero count cost), with an optional k-copy streak emitter whose
global atomic budget degrades gracefully as the 307,200 ring fills. Color modes: vectorscope (hue = flow
angle, sat = speed), flat tint, spectrum, or **spectral-centroid hue** (dark bass = red streaks, bright
highs = cyan). Exposes the hardcoded velGain(25)/settleFrames(8)/maxAge(30). Onset → 200 ms flow-freeze
latch (streaks hang in air).

### 5.2 The ten new effects (all realtime, all externally driven)

| # | Effect | Domain | Primary drivers | State / cost |
|---|---|---|---|---|
| 1 | **Feedback Tunnel** | raster | MIDI CC regen (>0.95 self-oscillates), gyro yaw→spin, touch→center, burst→zoom kick | 2× rg32Float @depth res (0.8–4.9 MB), 1 dispatch |
| 2 | **Raster Rescan** (Rutt-Etra) | unproject fold-in | MIDI CC line-count sweep 192→8, bass→Z-deflection, roll→scan angle, onset→interlace flip | zero state, ~0 dispatches |
| 3 | **Slit-Scan Time Slab** | raster | touch angle→time gradient, MIDI→slab depth, jawOpen→delay (FACE), onset→stutter | K=120 slices ≈ 24 MB back, 2 dispatches |
| 4 | **Drumhead Resonator** | raster | drum onsets→band impulses (far/mid/near = 3-zone kit), MIDI note→ring pitch, CC→damping, jerk→whole-frame hit | 2× rg32Float, 1 dispatch (spring+Laplacian wave eq) |
| 5 | **Kick Shatter** | raster-state→unproject offset | onset-low→radial detonation, pad hold→riser / release→slam (k×10), CC→impulse gain | 2× rg32Float 256×192 (0.75 MB), 1 dispatch |
| 6 | **Bass Shockwave** | unproject uniform | onset→wave spawn at center, touch→spawn at point (drum surface), MIDI note→pitched speed | ~160 B uniform ring, zero dispatches |
| 7 | **EQ Terrain** | raster (pre-FX slot) | 20-band FFT→per-zone depth bulge (columns/rings), kick→2× punch, OSC array→external EQ | 80 B uniform, 1 tiny dispatch. Upstream insert → Trails/Paint see audio bulges as *real motion* |
| 8 | **Strobe Cutter** | unproject kill path | beat→population strobe (different random half each flash — shimmer, not flicker), bass env→duty (sidechain pump), pad→blackout/whiteout, LFO→slice-plane sweep | zero state |
| 9 | **Pour** (Gravity Fall's GPU descendant) | point tail | **attitude→true world-down: tilt the phone, pour the scene**; touch→gravity wells (hold = mass); burst→wells flip repulsive; CC→looseness | shared pos/vel buffers ~12.6 MB, 1 dispatch |
| 10 | **Murmuration** (SWARM realized) | point tail (LUMEN/FACE stable-ID) | jawOpen→scatter, smile→cohesion (face bursts into a flock and re-lands), mid band→alignment, touch→predator, CC→max speed | vel+pos textures ~9 MB, 2 dispatches (grid-neighborhood boids, O(9N)) |

**Bench (v2 pool, designs ready):** Lissajous Rewrap (cloud collapses to phase-locked scope figures, MIDI
ratio-locked), Iso-Contour Slicer (FFT-carved topographic slices), Maelstrom (curl-noise fluid + onset vortex
rings), Gel (Verlet lattice — kick thumps a visible pressure wave through the body), H-Hold Tear (sync-loss
roll/skew on gyro shake, ~3 KB, stacks under everything).

Every effect follows the house discipline: own ping-pong pair, parity flip, `pending*Reset` seed-from-live
(Metal `.private` textures are **undefined at alloc** — the forceReset branches are load-bearing,
`BackLiDARShaders.metal:592-594, 821-825`), 0 = bit-exact bypass, params via one snapshot struct,
Swift↔Metal structs field-order-locked (share a header).

---

## 6. UI design

### 6.1 Layout (mobile-first, thumb-first)

Portrait-locked iPhone (iPad: same layout centered via `iPadBarWidth(720)`).

```
┌─────────────────────────────┐  ← safe-area top
│                             │
│      3:4 VIEWPORT           │  393×524 pt on a 393-wide phone.
│      true black #000        │  Full-bleed points; chrome overlays,
│      (points render here)   │  never crops. Top-corner status pills:
│                             │  ● NDI (green when connected), ● REC,
│                             │  fps/point-count readout (JBMono, 11pt)
├─────────────────────────────┤
│ UTILITY ROW (44pt)          │  mode chips CLOUD·FACE·LUMEN (center,
│                             │  selection-haptic) · NDI btn · REC btn ·
│                             │  scene A/B · ⓘ settings sheet
├─────────────────────────────┤
│ BOX ROW (54pt, h-scroll)    │  78×54pt cells: TITLE + live value,
│ ▏FX▕ ▏LOOK▕ ▏CLEAN▕ ▏CAM▕  │  accent stroke when selected, rotated
│                             │  category dividers, auto-center scroll
├─────────────────────────────┤
│ CONTROL STAGE (≥92pt)       │  morphs per selected box: RulerSlider /
│                             │  seg-pills / mini-columns / color / enum
├─────────────────────────────┤
│ PERFORM ROW (~64pt)         │  4 macro pads (momentary|latch) + XY pad
│                             │  toggle (stage becomes XY surface)
└─────────────────────────────┘  ← 44pt bottom pad + defersSystemGestures
```

Everything below the viewport **is** the change bar — permanent, never slides away. Structure, control
vocabulary, RulerSlider (Canvas 120-tick photo-edit ruler), live-value cells, divider labels and the
measured-offset mounting trick come straight from `PointCloudSettingsBar.swift`; context filtering
(`visible(in:)` per mode) from `LiDARSettingsBar`. All controls bind `@Observable AppSettings` directly →
edits hit the render next frame.

### 6.2 The change bar as instrument

- **Boxes are params; long-press a box → MOD assign sheet**: "Move a MIDI control / make a sound / tilt the
  phone…" — first source that crosses a threshold binds (MIDI-learn generalized to every source). Assigned
  boxes render a **mod ring** (thin arc around the cell showing base value + live modulation excursion, like
  a synth's LED ring). Tap-hold ring → depth/slew editor; swipe-down on ring → unbind.
- **Macro pads**: each pad = a saved bundle of {param, target value, attack/release}. Momentary (hold) or
  latch (tap). Pad 4 defaults to **TAP TEMPO** feeding the beat bus (Echo quantize, Trail gate, Strobe).
- **XY pad mode**: control stage becomes a 3-slot multitouch surface (`TouchInputManager`) — x/y/force are
  matrix sources; also the spawn surface for Bass Shockwave / Pour wells.
- **Scenes A/B**: two full param snapshots (JSON, same persistence pattern as `pc.filterStack`); the A↔B
  control is a crossfader — ParamRegistry interpolates continuous params, switches enums at 50%. This is the
  "program change" foundation for MIDI presets later.
- **Trigger buttons** (re-seed sculpt, flush trails, clear feedback, re-center motion) use the monotonic
  UserDefaults token pattern.

### 6.3 Feel (from the iOS/camera design pass)

- **Canvas:** true black everywhere. Chrome = flat translucent black; **no gradients over the viewport** —
  nothing competes with the points. One accent color (electric cyan `Color(.displayP3, red: 0.2, green: 0.9, blue: 1.0)`,
  P3 so it actually glows on OLED); yellow reserved for record/warn.
- **Type:** JBMono everywhere (ported system). Numeric readouts never jitter — monospace is load-bearing.
  Box titles 8.7pt tracked +1.2; stage value readout 13pt.
- **Haptics** (all via the ported process-lifetime `Haptics` enum): `.selectionChanged` box select + mode
  chips; `.soft` ruler detents (throttle ≥80 ms); `.rigid` at zero-detent of centered params; `.medium` on
  record start, macro latch, scene switch; `.success` notification when NDI connects / file saved.
- **Motion:** springs — box select `.spring(0.32, 0.78)`, stage morph `.snappy(0.28)`, camera nudge
  `.spring(0.4, 0.85)`, mode crossfade 240 ms easeOut. Sliders and the ruler are `.linear` — they must not
  fight the finger. Everything ≤400 ms. `Reduce Motion` → crossfades, kill springs, keep haptics.
- **Touch targets** ≥44pt everywhere (54pt cells, 46pt circle buttons already comply); primary performance
  controls live in the bottom thumb zone by construction.
- **Latency is the feature:** app launches into live points. Black viewport → chrome fades in 240 ms →
  first depth frame crossfades in ≤160 ms. Target cold-start ≤ 1 s to moving points, mode switch ≤ 400 ms
  (session handoff hidden behind the crossfade).
- **Permissions:** pre-prompt explainer cards before camera/mic/local-network system prompts ("Nothing is
  uploaded — NDI streams only on your LAN"). App remains usable with mic denied (audio sources just absent).
- **Status honesty:** REC uses wall-clock timer + red dot; NDI pill shows connection count
  (`NDIlib_send_get_no_connections` is already polled per send).
- Keep-screen-on default **ON** (performance tool); Dynamic Island respected — no root `ignoresSafeArea`
  (the survey's ContentView comment; apply per-surface only).

---

## 7. Settings inventory (keep / rework / discard)

New prefix `pts.*`; migrate nothing (fresh app). Ranges from code, not doc comments (two documented
default/doc mismatches: `pcViewerFieldOfView` 120-not-60, `pcAppleFilter` false-not-true).

**Keep as-is (cleanup & look):** density (→ range 500–200,000; snap 1k; thermal backoff steeper at the top),
pointSize, zoom/dolly (pick ONE normalization — bar 1.89-span vs sheet 2.7-span disagree today), fov,
depthCurve, edgeRelax, parallax, freeze, colorEnabled (single toggle — the OSC payload variant dies),
stabilization, surfaceSmooth, fillHoles, accumulate, grazingCull (keep per-camera force-0-on-back logic),
edgeStable, appleFilter/confidence gate, detailUpsample (cap 2× on front — 4× front = ~5M-thread JBU),
flatProjection+refDepth (promoted: Lumen's foundation), cloudOffset xyz, one user mirror toggle
(autoFlipX baked in), colormap, keepScreenOn, NDI enabled/resolution(3:4)/removeAlpha/sourceName, recording.

**Keep FX banks (all of §5):** trails.* (minus bias.x/.y), echo.* (reworked semantics), lightpaint.*,
velocity.* (+newly exposed velGain/settleFrames/maxAge), age.*, sculpt.* (incl. reseed token), shear/riptide.*,
erase/vanish.*, motion-cutout.* (resurrected), gravity.*→pour.*, plus new keys per new effect (`pts.fx.<name>.*`).

**Keep input conditioning:** audio.sens/clamp/beatSensitivity/burstSensitivity/autoGainDecay/outputRate,
mic input picker + micSmoothing, motion.updateRate/refFrame/per-axis gate+sens, airpodsTiltGain,
faceEngine.blendshapeThreshold, proximity min/max/roi.

**Discard:** all pcTCP* (+ the enable-forces-density≥20k side effect), pointCloudOSCEnabled + all OSC-out
targets + per-channel emit toggles, pointCloudColorEnabled (wire-payload), pc.flipX/Y/Z send-flips,
pc.fovScale (vestigial), pc.viewerEnabled, pcViewerFixedZoom (dead path), showAxes/axesOpacity,
orbitCube* / orbitSpeed / moveSpeed (no orbit), pcColorFlipU/V/SwapUV (bake correct UV in code),
pc.rgb.* legacy v7.1 keys, pc.ply.density, sensors.rate, performance.supercharge, watch.*, voxelSize +
despeckle as CPU passes (visual need covered by grazing cull + edge reject; re-do voxel as GPU dither only
if a quantize look is requested).

**House rules carried over:** `object(forKey:) != nil` default idiom; generate AppSettings defaults and
snapshot fallbacks **from one table** (drift bit twice); resettableKeys preserves migration markers.

---

## 8. Performance budget (iPhone Pro, A17+)

| Stage | Budget @60 fps (16.6 ms GPU) |
|---|---|
| Raster FX chain (≤13 dispatches @256×192–640×480) | < 1.5 ms |
| JBU 2× + unproject (200k) | ~2 ms |
| Point tail (springs/ghosts/look kernel, ≤4 dispatches @200k) | ~3 ms |
| Render 200k sprites (painter's blend, overdraw-bound) | ~4 ms |
| ViewportCapture render-to-texture (NDI @30) | amortized ~1 ms |
| Headroom | ~5 ms |

CPU per frame: uniforms + snapshot struct only — **no per-point loops anywhere**. Memory: point rings 22 MB
(already allocated at 307,200×24 B×3) + FX state ≤ ~40 MB with Slit-Scan resident. Thermal: keep the density
backoff, steepen to /4 at `.critical`. Sensor 30 fps ⟷ render 60 fps decoupled (§1.1).

Known killers to never reintroduce: CPU tuple readback, `waitUntilCompleted()` on main in the NDI tick,
FilterEngine CPU loop, echo/gravity CPU merges, SceneKit anything.

---

## 9. Gotcha ledger (port-time tripwires, all file:line'd in survey)

1. `.private` textures undefined at alloc → every new state texture replicates the `pending*Reset` +
   seed-from-live branch, or you get "renders differently under Instruments."
2. Swift↔Metal param structs match by **field order** via `setBytes` — share a generated header.
3. Trails dust must bypass edge/grazing culls and dither AFTER the z-gate — reordering reintroduces the
   one-sided cutoff artifact.
4. Depth-master ordering in the synchronizer (`[dOutput, vOutput]`) or +1 frame latency.
5. Frame throttles subtract 3 ms tolerance or newer iPhones silently halve fps (two independent copies).
6. Per-frame `autoreleasepool` in capture delegates is load-bearing (OOM crash).
7. ARSessionDelegate on iOS 18+ fires on main — process via `MainActor.assumeIsolated`; a Task hop backlogs
   ARFrames (warns at 11 retained).
8. CVMetalTexture wrappers retained through GPU completion (`keeps` arrays) or intermittent garbage.
9. Front mirroring lives at THREE layers (depth autoFlipX, RGB frontMirrorSign, blendshape L/R swap) — miss
   one and the app feels wrong-handed.
10. Lumen luma range: keep 32BGRA capture + in-shader `dot(c.rgb, (0.299,0.587,0.114))` (color needed anyway);
    if switching to Y-plane, request `420f` FullRange or displacement silently clips at 16/235.
11. Camera frames arrive landscape; pick ONE orientation convention and bake it into the grid vertex fn.
12. AVAssetWriter locks dimensions at first frame — freeze NDI/record resolution while recording.
13. Finalize recordings on backgrounding via UIBackgroundTask or the MP4 corrupts.
14. On-screen viewport and NDI raster must share the 3:4 aspect — sprite size scales with viewport height,
    mismatched aspects render different relative dot sizes.
15. Frozen centroid needs an explicit reset on mode/camera change or the cloud sits offset.

---

## 10. Build phases

| Phase | Scope | Exit test |
|---|---|---|
| **1 — Skeleton** (~1 wk) | Copy-verbatim files in; AppSettings shell (`pts.*`); ModeCoordinator; CLOUD mode: ARKit → pin-screen → unproject → **direct-buffer** renderer @200k; FixedCamera; 3:4 viewport + minimal change bar (density/size/zoom boxes) | 200k points @60 fps render, camera fixed, no CPU point loops (verify in Instruments) |
| **2 — FX chain port** (~1 wk) | Cleanup pipeline + all raster FX kernels wired incl. dormant motion-cutout; per-point look kernel (FilterEngine formulas); Echo 2.0; change bar grows the full FX group; scenes A/B | Every ported effect performable from the bar; echo at constant point budget |
| **3 — Lumen + Face** (~1 wk) | Lumen: RGB 4:3@60 capture → luma grid vertex path; FACE: TrueDepth cloud + ARKit face mesh/blendshape source; session handoff sequencing; per-mode bar filtering | Three modes switch cleanly ≤400 ms; Lumen 60/60 |
| **4 — Mod matrix** (~1.5 wk) | ParamRegistry (~90 params); ModRouter; motion + audio + touch + LFO sources; mod rings + long-press assign; macro pads + tap tempo | Tilt-drives-Pour, kick-drives-Shockwave demo end-to-end |
| **5 — MIDI + OSC-in** (~1 wk) | CoreMIDI (USB/Network/BLE) net-new; OSC receiver from inverted codec; learn UI; NetworkMonitor IP readout | External controller + TD OSC drive any param |
| **6 — New FX wave 1** (~1.5 wk) | Shared flow pass; Trails 2.0 + Velocity 2.0; Feedback Tunnel, Bass Shockwave, Strobe Cutter, EQ Terrain, Kick Shatter | The "drop demo": build/drop performable with two pads and a fader |
| **7 — New FX wave 2** (~1.5 wk) | Pour, Murmuration, Raster Rescan, Slit-Scan, Drumhead Resonator | jawOpen-scatters-face demo; tilt-pours-room demo |
| **8 — Output polish** (~1 wk) | NDI 3:4 + async capture + alpha key; recorder + Photos; permission pre-prompts; thermal tuning; Reduce Motion; haptic pass; app icon | Sustained 30-min NDI+record set without thermal collapse |

Phases 4–5 are independent of 6–7 (registry ships with existing FX; new FX land without MIDI).

## 11. Decisions for Ari

1. **Lumen color source** — BGRA capture + in-shader luma (recommended: one texture, color free) vs Y-plane r8Unorm.
2. **Echo 2.0 flavor** — stochastic Beat Echo core with spring-lag as a secondary (recommended) vs full Phantom-Ensemble polyphonic ghosts v1.
3. **Point-tail state budget** — Pour+Murmuration share pos/vel buffers (~12.6 MB, exclusive-or at runtime) vs independent (both live, +9 MB).
4. **FACE default** — TrueDepth depth cloud (denser, 30 fps, AVCapture) vs ARKit mesh-as-cloud (1220 verts + blendshapes in one session, depth only ~15 fps). Recommend: ARKit session as default (blendshapes are the point), depth-cloud as a face sub-mode.
5. **v1 change-bar box list** — proposed: FX group (10 new + 3 reworked + paint/vanish/sculpt/riptide), LOOK (size/color/colormap/depthCurve/parallax), CLEAN (stabilize/smooth/holes/accumulate/cull), CAM (angle nudge/dolly/fov/lens), OUT (NDI/record/scenes). Trim if the row overwhelms.
6. **AirPods + Remote-command sources** — ship v1 or defer (both optional adapters, ~2 d).
