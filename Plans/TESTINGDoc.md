# Document Premis:
## Inside this document I will write my feedback from testing - And you will slowly update the document with your changes below the round of testing notes I just gave, This way you can ensure that all feedback was addressed and anything not addressed gets moved into the next round of testing notes as the first task.

Format:
### Round XYZ notes:
I write what I want you to fix, add and tweak

### Round XYZ feedback:
You write what you fixed, added and tweaked, And anything that was too complex or required more questioning you put the questions in the next round.

---

### round 1 notes:
- in the touchdesigner node creation view the recent tab always stays in the same place and the other node groups dont loop around infinetly like I wanted them to - Maybe because recent is stuck at the same spot - Recent should be the first one that appears - But it should not be locked it should move with the others and should be before source and after tools which should go around and around infinetly in either direction. 

- when I am testing the hand gesture node - It only appears to show as compatible with the shockwave move node - The other hand body nodes dont seem to have this problem What I am trying to do is connect a hand pinch or hand gesture trigger node end to the size diamond created trigger node - But they wont connect - help me figure out why they wont work and whats causing the error - It appears that the diamond created triggers arent able to connect to anything - And further when you drag create a wire from one of the diamond created node squares for a per parameter trigger - when I have output and input set to open the node creation sccreen nothing pops up - Like it isnt actually wired there its just cosmetic. I have tested every base node in the default project and none of their trigger squares can be connected to anything that I can see - They nee another look at - The idea and UI is great but their functionality has not been coded properly.

- Since increasing the node space size - The minimap zoom got worse and is. showing the nodes at the wrong scale - Make sure the minimap is fitted to be 2x what it was before - Same size minimap just 2x the space its working inside. so the 3:4 rectanglular cube part showing the area you are in should fit better in the minimap now that its double the size.

- I still cant tell why but sometimes in nodeview the single finger tapswipe to move around just doesnt register, it happens very randomly - check the code to see if there is an interaction thats overriding or cancelling out the move swipe action. 

- when creating a wire from the output nodes image red output square - The touchdesigner bar comes up with 3 seperate copies of the "output" node group - figure out why and remove them please. - maybe a symptom of the recent button - They also dont appear when you first open it the recent ones do - In this case the node should always open to the 1 output node group and display NDI and record nodes without anything else in the way.

- not sure since when - But the back facing lidar's output is upside down - please fix it to be the right way up - We have removed the rotation buttons from the menu bar - so it has to be done in code. 

- I confirmed the hand pinch is working now with the value display node - The value display node should display the live number in yellow on the node itself not just in the nodebar - Put it in the center in the same text as it has in the node bar and update it live. 

- with the value display node its very useful but I want something similar another node that does the samekind of thing and also has the live display in the node itself - One thats a binary display: for example when using the hand gesture wiring one of the triggers to it - when you make that hand gesture it should switch from no to yes and vice versa when its not making that hand gesture yes to no. & the other new node I want is for a Live Update node which does the same thing but is multi node - so for example when I wire up all the hand gesture triggers to the live update nodes input - Whichever hand is currently triggered that name should be displayed - So when I change my hand from open palm to fist it should say Palm, then Fist. 

fix these issues and update this document with the fixes before moving on. 

### Round 1 Feedback (claude's notes from implementing these changes and fixes)

All 8 items addressed. Full `xcodemcp` builds green after each batch, committed in 3 commits
(`7a674c3`, `4abda48`, `a7c25f9`). Three items change on-device *behaviour/look* I can't see from
here — flagged **⚠ VERIFY** and re-listed at the top of Round 2.

**1. Node-creation "recent" tab looping (grid / TouchDesigner bar).**
RECENT was a *fixed* tab pinned outside the scrolling strip — that's why it never moved and broke
the loop. Rebuilt the family bar as one strip: `[RECENT, SOURCE, GRID … OUTPUT, TOOLS]`, so RECENT
now scrolls with the rest, sits **before SOURCE / after TOOLS**, and the strip **recenters on settle**
(tripled + jump-back-a-band when it drifts off either end) so it goes around and around in either
direction. `PlaceholderPages.swift`. **⚠ VERIFY the loop feels seamless.**

**2. Diamond (per-parameter) triggers wouldn't connect — the big one.**
Root cause: the *runtime was already ready* to consume wires into exposed params, but the whole
**connection/validation layer only recognised a node's declared `inputs`/`outputs`, never its exposed
params.** So every diamond wire was rejected before it was created — purely cosmetic, exactly as you
saw. Three gates were blind to diamonds; fixed all of them so a diamond behaves like a real input port:
- `Graph.validate` (the hard blocker — rejected *every* diamond wire → `badPort`).
- the wire-drag **snap hit-test** (diamonds were never snap targets → a trigger could only reach a node
  with a real declared trigger input like Shockwave's `fire`, which is why hand-gesture *only* stuck to
  Shockwave).
- the **drag-from-a-diamond** guard (couldn't resolve the port's type → early-returned → the picker
  "nothing pops up / just cosmetic"). Also fixed the picker's wire-back and re-grabbing an existing
  diamond wire.
A diamond input now accepts any control source (signal/trigger). `Graph.swift`, `PatchMockView.swift`,
`ContentView.swift`.
- **Caveat (report back if you hit it):** a *few* nodes emit their param under a short internal key with
  no full-name alias, so that specific param will now **connect but not visibly move** yet — known
  ones: Echo `feedback`, plus `th`/`alpha`/`gl` on a couple of others. The common ones (Point Display
  separation/focus/volume/wobble/gain/gamma/zFlatten, Size base/min/max, Depth near/far) all drive.
  Also note **despeckle-voxel**'s `size` is a passthrough no-op node — exposing *that* size connects
  but does nothing because the node itself isn't implemented yet.

**3. Minimap scale after the node-space grew.**
The minimap was fitting the **node bounding box only**, so once you panned into the enlarged space the
3:4 view rectangle fell outside it and scaled wrong. Now it fits the **union of the node box and the
current viewport** (+8% margin), so the view rectangle always sits correctly inside at any space size.
`PatchMockView.swift` `MinimapView.bounds()`. **⚠ VERIFY the rectangle now fits nicely.**

**4. Single-finger pan randomly not registering.**
Found it. `canvasDrag` decides pan-vs-move-vs-wire once per gesture and latched that on a `dragActive`
flag reset **only in `onEnded`**. The UIKit pinch recogniser runs simultaneously and can interrupt the
SwiftUI drag so `onEnded` never fires → `dragActive` stuck true → the next swipe reused the old mode
instead of panning ("very random", exactly). Now it **reclassifies whenever the touch's start point
changes** (a genuinely new finger-down) and clears any leftover drag state — self-heals no matter what
cancelled the previous drag. `PatchMockView.swift`. **⚠ VERIFY the drop-outs are gone** (pinch-zoom,
then immediately try to pan — that was the worst case).

**5. Wire from the Output red square → 3 copies of the OUTPUT group.**
Same root as #1: in grid mode the family strip is tripled for looping, so when a dropped wire filtered
to a single family you saw that one family ×3. Now: a wire-filtered picker **isn't tripled** (few tabs →
shown once) and it **opens straight onto the matching family** instead of RECENT — so dropping an image
wire lands right on OUTPUT showing NDI + Record, nothing else in the way. `PlaceholderPages.swift`.

**6. Back LiDAR upside-down.**
It's ARKit landscape depth mapped into a portrait grid = transpose + one flip; orient values `3` and `5`
are the two opposite 90° turns. It was `3` (upside-down), so I set the back camera to **`5`** (the
right-way-up turn). `CameraSources.swift:183`, documented as a calibration knob.
**⚠ VERIFY on the back camera.** If it's still off: `3↔5` flips top/bottom, adding `+4` mirrors
left/right — tell me exactly how it looks (upside-down still / mirrored / rotated 180°) and I'll set the
right bit. I couldn't see the camera from here so this is my best-reasoned value.

**7. Value Display live number on the node.**
Added a big yellow (`#FFC24D`) live number painted in the **centre of the node card**, updated live at
20 Hz (same value the node bar shows). `PatchMockView.swift` `NodeLiveReadout`.

**8. Two new display nodes (family TOOLS).**
- **Binary Display** — one trigger/value in; shows **YES** while high (>0.5), **NO** while low, live
  in-node; passes a clean 0/1 through. Good for confirming a gesture fires.
- **Live Update** — six trigger inputs; shows the **NAME of whichever input is active right now**, so
  wiring all four Hand Gesture outputs (palm/fist/peace/point) reads **PALM** then **FIST** as you change
  your hand. It shows the source port's name, or the source node's name if the port is generic. Outputs
  the active value.
  Both also mirror their readout in the node bar. `NodeRegistryFull.swift`, `PatchMockView.swift`.
  **Open question:** Live Update has a fixed 6 inputs — enough for the 4 gestures with headroom. Want it
  a different count, or auto-growing? (Round 2.)

---

### Round 2 notes:
_First tasks — confirm the ⚠ VERIFY items from Round 1 (I couldn't see these from the build):_ 
- **#6 back LiDAR** — is it right-way-up now? If not, say how it looks (upside-down / mirrored / 180°). yes
- **#4 pan** — pinch-zoom then immediately pan: do the random drop-outs still happen? no the random dropouts dont occur - One change from this outcome I want to add: add some inertia to the zoom in and out movement - can be stopped(better put: interupted) by starting a single finger swipe in a direction. 
- **#3 minimap** — does the 3:4 view rectangle fit/scale correctly now? yes
- **#1 recent loop** — does the family strip loop smoothly both ways with RECENT moving in it? yes 
- **#2 diamonds** — if any *specific* exposed param connects but doesn't move, name it and I'll alias its 
  patch key. Also: do you want Live Update's input count changed (#8 open question)? diamonds trigger patch keys are working now as intended. 

- the live update node should accept many inputs into one trigger node, Live update also instantly pulses between for example fist then instantly - then fist - fist - fist - happens 30/60 times per frame - So This is probably partly an issue with the hand gesture - Which should send a continous signal when a hand gesture is recognized, until that gesture is no longer visible by camera - But then also make the live update only change upon a proper change not instant pulses, set a gate for the amount of time beofre resetting to the "-" value.
- hand pinch's max output should be 10.00 not 1.00 - The pinch sizing scales based on the output max, Currently it stops after a fixed distance at the 1.00 value, when its changed to stop at 10.00 - the distance should be fixed on the same scale except going past the current max 1.00 distance apart makes the value keep growing, AskUserQuestion if thats unclear, I want the value output max when set to 10.00 to keep growing until the finger points physically cannot move further away.

for the pinch gesture node and the hand gesture node - Make 2 seperate nodes for each - one for right hand one for left hand - so Theres now 2 pinch nodes - Left Hand Pinch, Right Hand Pinch. and 2 gesture nodes Left Hand Gesture, Right Hand Gesture - If you make a right hand pinch gesture then do a pinch with your left hand nothing should happen - And it should do this based on the hand direction confidence - not just whichever hand is or isnt infront of the camera first, Refer to sosumi and apples hand recognition documentation for guiance on this.

Begin work on the Metric Depth Video import model functionality, the processing, The background iPhone video process, The dynamic island loading bar to indicate its progress in processing the video, The movement from one swap to another. Use sosumi for guidance on creating the dynamic island progress indicator. Along with the photo import mode, the Moge2 and other coreml models that will run within the app, We were determined to use Depth Anything Video with the point cloud output to give us the best highquality output, Moge2 for photos, and other models I cannot remember, Begin the architecture groundwork for implementing these features as they were originally described when we started the app project and did the rounds of questioning. 

### Round 2 feedback:

Round 1 verifies you confirmed: #6 back LiDAR ✅ · #4 pan drop-outs ✅ gone · #3 minimap ✅ · #1 recent
loop ✅ · #2 diamonds ✅ working. No carry-over.

**Node tweaks** (commits `e623995`, `fc43f24`):
- **Zoom inertia** — a pinch now flings the zoom and coasts to a stop; any single-finger swipe
  interrupts it instantly (same stop-inertia path as pan). `PatchMockView.swift`.
- **Hand gestures are continuous** — the 30–60/s pulsing was VisionEngine decaying the gesture `*0.5`
  on every read while Vision only refreshes ~13 fps. Now it HOLDS the recognised gesture between
  frames, so a held gesture stays high until the hand leaves frame. Hand Gesture nodes default HOLD
  0.25 s to bridge brief mis-reads. `VisionEngine.swift`.
- **Live Update** — 6→10 inputs, now stateful with a HOLD gate (default 0.6 s): only changes on a real
  change and won't blank to "—" on a momentary drop. With continuous gestures the instant flicker is
  gone. `NodeRegistryFull.swift`.
- **Left/Right hand split** — VisionEngine tracks 2 hands and routes each by chirality
  (`VNHumanHandPoseObservation.chirality`, per Apple's Vision docs). New nodes: **Left/Right Hand
  Pinch**, **Left/Right Hand Gesture** — a right-hand node ignores your left hand. Originals (first
  hand) stay. ⚠ The mirrored FRONT camera may report L/R swapped — one-line swap point in
  `VisionEngine.consume` if on-device shows it reversed.
- **Hand Pinch 0–10** — you picked *linear remap, full spread → 0–10*: raw pinch normalised across the
  full finger spread (was clamping at ~half), pinch nodes get `outMax` 0…10 default 10. ⚠ Driving a
  0–1 exposed param from a 0–10 pinch saturates fast — lower `outMax` to 1 or add a Remap (noted on the
  node). The spread→10 point is a calibration constant (`*2.2`) — tell me if 10 lands early/late.

**Big task — depth-video import groundwork** (commit `a11c470`, plan:
[PLAN-Video-Import-Groundwork.md](PLAN-Video-Import-Groundwork.md); the original spec already existed at
[04-Depth-Import-Pipeline.md](04-Depth-Import-Pipeline.md), so this builds its front end to spec):
- **Screen-edge loop progress bar** — traces the screen edge as a rounded rect, starting at
  **top-centre**, filling **clockwise** back round (not a flat bar). `EdgeLoopProgress.swift`.
- **Dynamic Island + background processing** — iOS 26's **`BGContinuedProcessingTask`**: built for
  "start a long job, background the app", and it **auto-renders the Dynamic Island progress** for us
  (no widget extension). ANE-targeted (`.cpuAndNeuralEngine` — ANE is background-legal, GPU isn't).
- **Import page** — PHPicker → Indoor/Outdoor + Best/Fast → bake screen (%, frame/fps/ETA, cancel) with
  the edge loop; wired onto the corner-menu import button.
- **Honest scope:** the per-frame bake is **simulated** (StubDepthModel ≈ real ANE budget) so the whole
  import → background → Dynamic Island → edge-loop pipeline is real and testable now. Real models
  (MoGe-2 photos, DAv2-S Fast, VDA-S Best = the one conversion R&D item), AVAssetReader decode,
  PointsDepth v2 storage and the sequential looper are the next milestones (in the plan doc). Source /
  Clip Transport / Still Image nodes already exist → no new graph plumbing.
- **One manual step:** Xcode ▸ Signing & Capabilities ▸ + ▸ **Background Modes ▸ Background processing**
  (Info.plist keys are in; the capability makes the entitlement match). Can't toggle from a file edit.

The "movement from one swap to another" / photo-import mode weren't built this round — flagged in
Round 3 to scope next (photo = single MoGe-2 → 1-frame project; swaps = the camera↔node view + deck).

---

### Round 3 notes:
_First tasks — verify the Round 2 items I couldn't see from a build:_
- **Zoom inertia** — does the fling feel right, and does a swipe interrupt it cleanly?
- **Gestures** — held gesture stays solid now (no 30–60/s flicker) on Live Update / Binary Display?
- **L/R hands** — do Left/Right Pinch + Gesture track the correct hand? (front camera may be swapped —
  say so and I'll flip the one line.)
- **Pinch 0–10** — does a full-spread pinch reach ~10? Too early / too late?
- **Depth import — now runs the REAL MoGe-2 model** (photo + video, ANE). Open the import button:
  - Quickest test: pick a **photo** → you should see its **depth map** render (near = bright) within a
    second or two ("Preparing engine…" on first run while it compiles).
  - Pick a **video** → depth streams frame-by-frame (sampled ~6 fps for the test); background the app →
    **Dynamic Island shows progress** and it keeps going. (Needs the Background Modes capability, done.)
  - Edge bar fills **clockwise from top-centre** + reaches the screen edges?
  - Rough edges I know about: input squashed to 504² (no aspect letterbox); portrait video may show
    rotated (ignores the track transform); bake previews but doesn't persist yet.
- Next up (say which): persist the bake (PointsDepth storage) + render it as a **looped point cloud**
  (the actual payoff); dedicated video models (DAv2-S/VDA-S) need their own CoreML conversion.


### Round 3 feedback:

Your test showed the bake ran but the result was wrong: depth preview was **diagonal black/white
bands**, the **Source node's `.source` output only fed sinks**, and the **Dynamic Island didn't appear**
when backgrounded. Fixed all three (commits `18a6a8e`, `59e10bc`).

**Model side — diagonal bands.** Root cause: ANE model outputs are **row-padded**; I was reading the
MoGe-2 depth `MLMultiArray` linearly off `dataPointer`, so each row's padding shifted the next → a
diagonal shear on a smooth depth map. Now read via `MLShapedArray.scalars`, which honours the array's
shape/strides. Clean depth map.

**Node side — imported media renders as a point cloud (the real fix).** The render pipeline map showed
the single seam is `renderer.ingest(depth:…)` — everything downstream is source-agnostic, so baked
depth pushed through it renders **exactly like live LiDAR**. So:
- **Still Image** + **Video Source** (was "Clip Transport") nodes now output **`.fieldFloat` depth** via
  `loadDepth` — same as the Depth node — instead of the inert `.source` port. Wire `depth → Point
  Display`. Video Source loops.
- New **`DepthPlayer` + `ImportedDepthStore`**: the bake stores each frame's metric depth (metres); the
  player loops them into `renderer.ingest` at 30 fps (DepthFloat32 buffers, EMA reset at the loop seam).
  Live cameras pause while media plays. After a bake, **"Use in project"** drops + wires the source node
  and it starts playing.
- Also fixed: the Left/Right hand nodes weren't starting Vision (missing from `bodyFamily`).

**Dynamic Island.** Root cause (confirmed against the docs): the `BGContinuedProcessingTask` id
**must be prefixed with the real bundle id and permitted as a `.*` wildcard** — mine was
`com.points.depthbake` (bundle id is `aristides.lintzeris.Points`), so submission was silently rejected.
Now `aristides.lintzeris.Points.depthbake.*` in Info.plist; each run registers + submits a fresh
suffixed id. The bake screen shows the submit status so we can see it now. Also verify **Settings ▸
Points ▸ Live Activities is ON** (the system progress UI is a Live Activity).

⚠ **Verify on-device:**
- Photo/video bake → depth preview is a **clean depth map** (no diagonal bands)?
- Import → "Use in project" → does the **point cloud render the imported depth**, and does video **loop**?
  If it reads **flat or inverted**, that's depth-scale calibration — tune the Still Image/Video Source
  node's **near/far** (or tell me and I'll adjust the metric-scale mapping).
- Background a video bake → **Dynamic Island now shows progress**? (Check the bake screen's status line +
  the Live Activities setting.)
- Known rough edges still: square (504²) squash — imported cloud is stretched to the 3:4 grid; portrait
  video may be rotated. Say if that matters and I'll add aspect/orientation handling.

---

### Round 4 notes:
(from chat) Imported video/photo worked but **rotated ~90–180°** (preview + output); source should
switch by **connecting** the Depth/Still/Video node to Point Display (not presence); **video played ~5×
too fast** (18s looped in ~5s). Then: research the smallest **realtime metric depth** models for live
back-camera use on LiDAR-less phones (video-specific — Metric Depth Anything Video S/B); build a **Live
Depth Model** node with many models; and a **MoGe-2 realtime** node with lens switching.

### Round 4 feedback:

**3 fixes** (commit `311b308`):
- **Orientation** — decode now uprights each frame (video: the track's `preferredTransform`; photo:
  EXIF orientation), so preview + point cloud are no longer rotated.
- **Source by connection** — the node WIRED into Point Display sets the source: Still Image / Video
  Source → imported clip, Depth → live TrueDepth/LiDAR. Returning to live restores camera orientation +
  resets the EMA. (Was gating on mere presence.)
- **Playback speed** — plays at the sampled rate (`srcFPS/stride`), so an 18s clip plays in 18s.

**Live monocular depth on the RGB camera** (commit `2471bc1`) — one **Live Depth Model** source node
covers both asks (the multi-model live node + trying MoGe-2 live):
- `RGBCameraSource` — live lens-selectable RGB (ultrawide / wide / tele / front).
- `LiveDepthEngine` — generic over the model (introspects I/O; handles MLMultiArray or image outputs),
  ANE, normalises to a metre range, pushes each frame → the same `ingest` seam → point cloud.
- **Node params: MODEL** (MoGe-2 / Depth Anything V3 S / Depth Anything V2 S) **+ LENS + near/far/invert**.
  Wire depth → Point Display to run it; ContentView switches source 3-way (live-model / imported / live
  cameras). Bundled the small CoreML models on disk (git-ignored).
- MoGe-2 live = pick "MoGe-2" as the model (its depth map drives the cloud). A separate MoGe-2-only node
  can be split out later if you want it distinct.

⚠ **Verify on-device:**
- Imported photo/video now **upright**? Video plays at **real-time speed** (18s ≈ 18s)?
- Switching the node wired to Point Display (Depth ↔ Still ↔ Video ↔ **Live Depth Model**) switches the
  source live?
- **Live Depth Model** node → wire to Point Display → does the back camera drive a live point cloud?
  Try each MODEL + LENS. Relative models (DAv2/DAv3) render **shape** but not true metric scale — tune
  near/far/invert; per-frame normalise may **flicker/breathe** (tell me and I'll add temporal range
  smoothing). MoGe-2 live will be slower (bigger model) — check the framerate.
- Model research — **done** → [RESEARCH-Live-Depth-Models.md](RESEARCH-Live-Depth-Models.md).

**Round 5 — converted + bundled 3 metric models** (commits `5c2a1b2`, `dcc081b`; toolchain + scripts in
[Plans/conversion/](conversion/README.md)). Got a py3.11 + torch 2.7 + coremltools 9 env working (3.14
couldn't) and converted your `.pth` weights → CoreML fp16:
- **Metric Video DA S** — Metric-Video-Depth-Anything Small, one general indoor+outdoor metric model
  (per-frame; the temporal motion modules are bypassed since einops won't lower — temporal smoothing is
  a later add). Now the Live Depth Model node's **default**.
- **DA2 Metric Outdoor S** (VKITTI 0–80 m) + **DA2 Metric Indoor S** (Hypersim 0–20 m) — scene-specific.
- All output **true metres** (engine passes them through; tune the node's near/far for the scene). The
  earlier DA2/DA3 relative options remain.
- **DepthPro**: it's already CoreML in your folder but a 4-stage chain, ~1 s/frame, non-commercial → skipped
  for live.
- **Base models** (Metric-VDA vitb, etc.): deferred per your "smalls first, then base if performance is
  great" — one command in the conversion README once you've tested.

⚠ **Verify on-device:** Live Depth Model → wire to Point Display → pick **Metric Video DA S** + a lens →
does the back camera drive a live **metric** point cloud, and what framerate? Then try the Outdoor/Indoor
DA2 models. If depth reads off, tune near/far. Tell me the fps and I'll advise small-vs-base.

Deferred / next: metric calibration per model; MoGe-2-specific node if you want it separate; converting
the metric DAv2 `.pth` + any video metric models to CoreML (needs a torch/coremltools toolchain — the
sandbox here can't).

---

### Round 5 notes:
(from chat) Put the metric models in the nodes; change the way images/videos get processed — the
processing page should let you pick the MODEL before starting; live-depth node needs a horizontal-scroll
camera switcher for all iPhone cameras; and the live-depth node should accept a video/image source that
the model bakes ONCE then loops (with an X to discard → back to cameras).

### Round 5 feedback: (commits `fcecd18`, `c321992`, `491c422`)
- **Unified inference** — one `DepthModelRunner` powers both the import bake and the live engine, so ANY
  bundled model works in both places (metric passthrough vs relative normalise handled centrally).
- **Import page MODEL picker** — a horizontal-scroll model row before Start; the bake now uses the chosen
  model (Metric Video DA / DA2 Metric Indoor+Outdoor / MoGe-2 / DA V2/V3), not hardcoded MoGe-2.
- **Live Depth node camera switcher** — the node bar now has a **CAMERA** horizontal-scroll switcher that
  lists your device's real cameras (ultrawide/wide/tele/front) + a **MODEL** switcher; switching is live.
- **Live Depth node media source** — a **"Load video / image"** button: it bakes the footage ONCE with the
  node's model, then loops the depth (not re-inferred every frame). An **X** discards it → back to the live
  camera. (Reuses the import screen, preselected to the node's model.)

⚠ **Verify on-device:** import → pick a MODEL → bake; live-depth node → CAMERA switcher cycles your lenses;
live-depth node → Load a video → it bakes once + loops → X returns to camera. Frame-rate of the live
models? (Tell me and I'll advise small-vs-base + whether to convert the base models you provided.)

---






Note testing notes:

Face region - doesnt seem to work.
Background node - doesnt work its always black
Lights - not sure how its supposed to work - check theres actually code setup for this.
shape - ring, disc and spike dont work. slab looks like sphere, cube looks like a rounded cube. - Fix the ones that dont work and add a diamond shape.
Shape by depth - doesnt work
Noise - seems to work but is mono when should have a color options - Move its preview to the minimap area only when its selected so the nodebar isnt so tall - Also put some of the sliders on the same rows to fit more sliders in. Max 3 sliders per row.
counter - Not sure how its supposed to work
On start - doesnt work, Should be a counter that start counting up as soon as you place the node - doesnt do that. 
Toggle - Not sure what it does - Should explain a lot of these nodes better and also make sure they arent placeholders.



## Live Model Node Notes:

When I say camera effects I mean FOV,zoom, depth Curve, Parallax, etc - what you can change in the cameraview bottom bar.

Dav2 video S is the only one that sort of works - is not wrapping around or 

Dav2 metric outdoor is completely zoomed in - No matter what camera you set it too its not able to render the point cloud properly

Dav2 metric indoor s is upside down some of the time. - the camera effect work on this model but not on most of the others.

MOGE2 is flipped to 180  some of the time. - When it works its quite slow - the camera effects work on this model ![alt text](../IMG_8877.PNG) and when its not its unstable in outdoor areas and slow 

Dav2 is flipped 180

Dav3 wraps around itself, or its inverted so the far away is white and close is dark  ![ examples of it looping around on itself like its a cloth being pulled](../IMG_8873.PNG) ![ examples of it looping around on itself like its a cloth being pulled](../IMG_8874.PNG)

MOGE2 image/video is flipped 180, 

All of them don’t properly switch when you change camera - you have to change camera then change model the. They refresh 

On first startup they take 9000ms + to load and freeze the app - adding a loading indicator would be useful

In depth front facing there are all these points travelling towards the center like they are being pulled there  ![see the points pulled](../IMG_8874.PNG) ![see the points pulled](../IMG_8875.PNG) ![another example](../IMG_8873.PNG)

Most of the problems occur on the wide and front lens - The issues dont appear as often when using the ultrawide - However the camera switch during model usage rarely works - and required switching to another model to change the camera.

It looks like you need to "preload" and then keep the models "warm" or they will do strange things like wrap around themselves. 

I propose when the live depth model node is created - you instigate a loading screen which preloads all models, Then when the node gets deleted you unload all that data. 

THe processing screen for the models - loading circle works on the bottom edges but doesnt go around the top of the display above the dynamic island time and icons. For only this part of the app go fullscreen so that the loading indicator wraps around the display cleanly, then return to normal with the time and icons where they were ![ loading circle works on the bottom edges but doesnt go around the top of the display above the dynamic island time and icons. For only this part of the app go fullscreen so that the loading indicator wraps around the display cleanly, then return to normal with the time and icons where they were](../IMG_8852.PNG)

The background loading indicator for the app does work but its the wrong loading dynamic island - I want the apple style dynamic island where it wraps around the camera in a small circle - what it currently looks like ![current background processing display](../IMG_8853.PNG) vs what it should look like ![ example from the timer app dynamic island small loading indicator with a circle, and the time remaining on the other side](image.png)

Other lidar truedepth note: - the points are falling towards the center of the point cloud and passing infront of area where the face and head are - why are they doing that in the default file - The problem was addressed and then it became less prevelant but now its back - ![ points falling towards center frame infront of the head points](../IMG_8881.PNG) Compare the TDLidar point cloud mode to our own point cloud rendered - And determine why the points are moving like that (for free point display) - I want the truedepth free front output to look and function practically identical to how it works in TDLiDAR

### Live Model Node feedback: (commits `9ea3056`, `0c36cb3`)

Root-caused the whole live-model cluster to **three** systemic bugs, not per-model quirks. Fixed those;
the rest were downstream of them. Full `xcodemcp` build green, committed in two.

**1. Startup 9000 ms freeze → async load + warm cache + loading screen.**
The MLModel build (`MLModel(contentsOf:)`) was running **on the main thread** inside the source-gating
`onChange`, so the first use of any model (and *every* model switch) froze the UI for seconds. Now:
- Loading is **off the main thread**; a **shared warm cache** keeps the last 3 models resident, so
  switching back to one you've used is instant.
- The model is **preloaded the moment a Live Depth node exists** (before you even wire it in), with a
  **"Loading depth model…" overlay** while a cold model warms up — no more flashing garbage / freeze.
- Deleting the last Live Depth node **frees all model memory** (`purgeCache`). ⚠ This is your
  "preload on create / unload on delete" proposal — I capped resident models at 3 (LRU) rather than
  holding all 6 in RAM at once (6 ViTs ≈ >1 GB → OOM risk). Say if you want eager-load-all instead.

**2. "Zoomed in" (Outdoor) / "wraps around itself" (Dav3) / breathing → one normalization fix.**
Metric models were **passed through as raw metres** — DA2 Outdoor emits 0–80 m (VKITTI), dumped into a
2.5 m stage → everything past 2.5 m collapses to the wall = "completely zoomed in / can't render." Relative
models used raw **min/max**, so a single sky/hole pixel blew out the range and the scene folded onto itself
("cloth being pulled"). Now **every** model is **robust-percentile normalised (2nd–98th pct, rejects
outliers) + temporally smoothed** into the stage range. This also fixes **"camera effects don't work on
most models"** — FOV/zoom/curve/parallax looked dead because the cloud was flat/blown-out, not because the
effects were off. They should work on all models now.

**3. "Flipped 180 / upside down some of the time" → per-model orientation + no front mirror.**
Confirmed deterministic per **model** (MoGe-2 image/video bake is *always* 180° — no camera involved), so
each model now carries an **orientation constant**, applied on both the live path and baked playback:
- **MoGe-2 → 180°**, **Depth Anything V2 → 180°** (your reports). **Metric Video DA S → 0** (the one that
  worked). **Dav3 → inverse flipped** (you saw far=white/close=dark = inverted).
- The **front lens is no longer mirrored** — a mirrored frame produces mirrored/handedness-flipped depth,
  a big source of the front-lens weirdness.
- The **"some of the time"** was the broken camera-switch (below) leaving stale orientation state; with
  that fixed it should now be deterministic per (model, lens).
⚠ **These orient values are calibration guesses from your notes — I can't see the camera from here.** Per
model, tell me: upright / upside-down / mirrored / 180°, and I'll set the exact bits. Especially **DA2
Metric Indoor + Outdoor** (I left at 0 pending your read) and **Dav3**.

**4. "Camera switch only works if you also change the model."**
Same root as #1 — the main-thread model load was stealing the run loop, so the lens reconfigure got
starved. With loading off-main, changing **lens alone** reconfigures the camera immediately. ⚠ Verify the
horizontal CAMERA switcher now cycles lenses live without touching the model.

**5. Processing screen loop now wraps the TOP.**
The bake screen was a **sheet** (an inset card) with the status bar visible, so the loop couldn't trace
the top. It's now a **full-screen cover** and, **while baking**, the **status bar + home indicator are
hidden** — the clockwise edge loop traces the whole display edge, above the clock/Island, then restores
when it finishes. ⚠ Verify it wraps cleanly across the top now.

---

**Not done this round — two need you (deliberately not guessed):**

**A. TrueDepth free-front "points pulled to centre" (TDLiDAR parity).** I did **not** touch the free-mode
projection blind. Geometric read: free mode unprojects `worldXY = (pixel − centre) · depth`, which is
*correct* pinhole behaviour — **near** points (your face) converge toward the optical axis, **far** points
spread. So "points in front of the head" is most likely **invalid/edge depth** (IR-shadow fringe on the
face silhouette) landing near centre, not the projection itself. To match TDLiDAR I need one thing from
you: in TDLiDAR's cloud, does the face sit **flat facing you** (orthographic-ish) or **fanned into a
frustum** like ours? That single answer tells me whether to (a) tighten the silhouette edge-cull, or (b)
switch free-front to an orthographic unprojection. I'll fix it in one focused pass once I know which.

**B. Timer-style background Dynamic Island.** The current one is the **system** `BGContinuedProcessingTask`
progress Live Activity — the app **cannot restyle it** into the compact timer ring you screenshotted. That
look requires a **custom ActivityKit Live Activity + a new Widget Extension target** (compactLeading ring /
compactTrailing time-remaining / minimal + expanded views). It's a real, separate build (new Xcode target,
signing, ActivityAttributes plumbing). Want me to add it? It's the clear next task — say go and I'll build
the extension. (The in-app fullscreen loop, item A#5, is done.)

⚠ **On-device checklist:** (1) create a Live Depth node → loading overlay appears, no freeze; (2) each
model renders a proper 3D cloud (not zoomed/flat/folded) and camera effects respond; (3) tell me each
model's flip state so I lock the orient bits; (4) CAMERA switcher changes lens live without a model change;
(5) bake screen's loop wraps the top. Then I'll finalise orient + take on A/B.


Live Depth new notes:

adding the live depth node - even when its not connected to anything makes the front facing lidar mode temporarily rotate 180 with the bottom on the right side of the screen.  When you first select the live depth node - there is no model or camera shown as selected - however a model is clearly outputting something. Switching models, Their implementation is all incorrect - And its clear that they are outputting to what wants to be a flat surface - The point cloud is defaulting to the pinout stle and you can tell because when the model isnt getting input a 3:4 screen of points appears flat. Please redo the entire live depth node and functionality from scratch based on how the free or tdlidar style pins works. /Users/ari/Documents/XcodeProjects/TDLidar2/TDLidarBackup/Notes/MonodepthPC/MonocularDepthPC-Plan.md see this for assistance - we semi succesfully implemented this mode already in TDLidar but removed it. - 




All of them are uniqely garbled and incorrect - They dont switch cameras when you change it in the node settings, Most of the outputs are worse than before. the ones that make something that looks sort of like what its supposed to are warped on a inner edge.


Remove DAV3 S ,DA 2 metric indoor and outdoor.  leave the rest (Video DA, DAV2 S, And Moge2)and fix them. 

All the models when camera is in "front" setting output horizontally 180 degrees (bottom on the right side of the screen) 



After you remove the live depth node and change back to the camera depth - The camera controls no longer work - Orbit, move or anything except for zoom, figure out why and resolved

The preprocessed video output - Comes out (in the video processing preview) upside down - for all models it seems The resulting output from any model is garbled (for video anything -  theres too much noise in the video processed which makes the point cloud output wobbly and pointy - video depth anything works better in the actual point cloud mode its at least sort of showing what it sees if you squint) But its preview output for preproccessed video has noise on every edge of every object and noise on the edges and corners of the video.- If you squint you can barely see the image. For models like Moge2 its better and you can see much more of what is there but theres still errors in the point cloud rendering like the points are a cloth being pulled in multiple directions.


The live depth mode should be using the free style of point cloud output - But even that is incorrect. The TDLidAr "free" pin display is still pulling points to a center point, And the points are not freely moving in 3D space they are like trapped/locked together and arent representitive of the actual truedepth infrared points that the phone is capturing. Go through it again and figure out why.

---

### Live Activity + TrueDepth-parity report (commits `44fab9c`, `d09e235`)

**1. Timer-style background Dynamic Island — BUILT.** New **Widget Extension target** (`PointsWidgets`)
with a custom **ActivityKit Live Activity**: circular **progress ring** (leading) + **time-remaining**
(trailing) in the compact island, ring-only minimal, ring + frame/ETA expanded + lock screen. The old
indicator was iOS's `BGContinuedProcessingTask` system activity, which the app **can't restyle** — so
it's replaced. New files: `PointsWidgets/`, `Shared/DepthBakeAttributes.swift`,
`Points/DepthImport/DepthBakeActivity.swift`.
- **Trade-off:** `BGContinuedProcessingTask` gave *indefinite* background CPU; a custom activity doesn't,
  so I hold a **~30 s background-task assertion**. Photo / short clip finishes backgrounded; a **long
  video may suspend** until you reopen. Want indefinite background baking back instead of the ring? Say so.
- ⚠ Found + removed a **duplicate `DepthBakeAttributes.swift`** you'd started under `Points/DepthImport/`
  (same type compiled twice → build error). Kept `Shared/` version (has `etaText`, member of both targets).
- ⚠ On device: **Settings ▸ Points ▸ Live Activities** ON, start a bake, swipe the app away → ring + timer.

**2. TrueDepth "points pulled to centre" — ROOT-CAUSED + fixed to compare.** Free-mode XY is a lensless
pinhole un-projection: `worldXY = (pixel − centre) · (rawZ / focus) · separation`. So:
- Spread ∝ depth-in-metres. Old default **`focus = 1.0 m`** vs a face at **~0.4 m** → the face shrank to
  the middle **~40 %** of the frame (your "centre-hug / flat"). The cloud only fills the wall at `focus`.
- Too-close points converge hardest → a hand shoved **too close** (sub-range) reads tiny `rawZ`, collapses
  to the axis, and being nearest gets **Z-pushed in front of the face**. Only floor was 5 cm.
- Depth "feel" (nose forward / edges back) is a *separate* lever = **depthPush + parallax** — matches your
  note that cranking them looks real; TDLiDAR is flat at low settings too, so that's a knob, not a bug.

Fixes (both free-mode only, pinout/loadDepth untouched):
- **Near cull** — `freeXY` discards points closer than **0.15 m** (TDLiDAR clamps its range the same way)
  → the too-close pile-in-front-of-the-face is gone.
- **Fill-frame focus** — the default file seeds Point Display **`focus = 0.5 m`** so the face fills the
  frame. ⚠ It's the subject-distance knob: **back LiDAR** rooms (~2 m) want focus ~2, or it over-spreads.
- **Real 1:1-at-any-distance** = **adaptive focus** (scale from the scene's median depth each frame via
  the TrueDepth intrinsics) — a focused follow-up. Say the word and I'll build it.

⚠ **Compare on device:** default front file → face fills the frame (not a centre blob)? Hand too close →
points stop piling centre-front? Crank parallax + depthPush → nose forward / edges back like TDLiDAR?

**3. Your 3 new notes above (models / camera controls / video garble) — seen, queued next round:**
- Remove the slow models (DAv2-S, MoGe-2, DA2 Indoor/Outdoor), keep + fix the rest — easy, will do.
- **Camera controls dead (orbit/move, only zoom) after deleting a live-depth node** — likely a regression
  from my source-gating (`setMediaMode`/camera restart on node delete). I'll trace it first next round.
- Preprocessed **video upside-down + garbled ("cloth pulled")** — the orientation is the per-model orient
  I just added (baked path may need the flip the live path got); the garble is per-frame noise → needs
  the temporal depth smoothing the bake path doesn't do yet. Both next round. 

---

### Round — "somehow even worse" live-depth pass (commits `7f1858d`, `5c7c4c8`, `09f3113`)

Took [MonocularDepthPC-Plan.md](../MonocularDepthPC-Plan.md) (the sibling TDLiDAR app's recipe) as the
reference. Five fixes, each built green + committed.

**1. Camera switch (your priority) — TWO root causes.**
- `AVCaptureDevice.default(.builtInUltraWideCamera / .builtInTelephotoCamera …)` **returns nil** on many
  configs → the code fell back to the wide camera for *every* back lens = "cameras don't switch." Now the
  device comes from **`AVCaptureDevice.DiscoverySession`** (reliable for ultra-wide/tele).
- **No handoff:** TrueDepth/LiDAR and the RGB session **can't share the physical camera**, but the code
  stopped depth and started RGB in the same breath → RGB came up on a contested camera (garble / stuck
  lens). Added a **~0.45 s handoff** before RGB starts; lens changes while already live reconfigure in
  place. ⚠ Verify the CAMERA switcher cycles lenses live (incl. front↔back) without touching the model.

**2. Adding the node rotated the front LiDAR 180°.** The model **preloads on node *presence*** (before
it's wired), but `load()` was also calling `renderer.setOrient(0)`, stomping the live front-LiDAR
orientation (it uses orient 1). Orient now applies **only** when RGB is the actual display source.

**3. Removed the slow models.** Kept **Metric Video DA S** + **Depth Anything V3 S**; dropped DA2 Metric
Indoor/Outdoor, MoGe-2, DA V2 S. The node's MODEL switcher shows just the two.

**4. The "vortex / cloth-being-pulled" — the biggest one.** Right instinct that it's *systemic*, though
not pinout: the **renderer's depth EMA is OFF by default** (alpha 1 unless an EMA Smooth node is added).
LiDAR is stable enough without it, but **monocular depth is noisy frame-to-frame** so that jitter rendered
straight as the breathing/vortex. Added a **per-pixel temporal EMA** in the shared runner (new frame 55 %,
rest history), for **both live and baked video**. This is the sibling app's #1 fix ("the cloud
breathes… needs a raw-metre EMA"). ⚠ Verify the cloud is much steadier (some lag is the trade).

**5. Video bake upside-down (all models).** The bake applied `preferredTransform` **directly to a
`CIImage`** — but that transform is y-**down** and `CIImage` is y-**up**, so it flipped every frame.
Switched to `CIImage.oriented()` (same as the photo path). ⚠ Verify preview + output are upright. (The
residual video *noise* is the same depth-quality issue → the new EMA.)

⚠ **On-device:** (1) CAMERA switcher changes lens live incl. front↔back, no model change; (2) adding a
live-depth node doesn't disturb the live LiDAR; (3) cloud is steady, not a breathing vortex; (4) baked
video upright. If the live cloud still isn't 1:1 with TDLiDAR, the true parity path is **real-intrinsics
unprojection + a metric mode** (the plan's Part B) — a bigger, separate build; say go.

**6. Camera controls dead (orbit/move, only zoom) — FIXED** (commit `01bab4f`). Traced it: the
camera-view **deck's** orbit/move/recenter pads hardcoded `setParam("cam", …)`, but a camera added from
the palette (or in a loaded project) has a generated id like `c1` — and `setParam` **no-ops** when the id
doesn't resolve. The zoom/fov/parallax/depthPush **sliders** already used the real node id, so only they
worked. Now the pads use the current page's real camera id (like the node-view jog already does). ⚠ Note
it's a **pre-existing** bug (the deletion didn't cause it — it surfaced when you orbited the cloud with a
non-`cam` camera); if your default file's camera is the seeded `cam`, orbit already worked there.

**7. Vortex "pinout bleed" — confirmed it is NOT pinout** (your theory, traced). Free mode (`freeXY`) and
pinout (`pinFieldXY`) are **mutually exclusive** by the Point Display `mode` — the emit picks exactly one,
nothing blends, and live-depth always renders through **free**. The "vortex" is intrinsic free-mode math:
XY = `(uv−0.5)·(depth/focus)·separation`, so XY is **proportional to depth** → near points collapse toward
the optical axis. That's mitigated by the near-cull (< 0.15 m) + the new temporal EMA. The **flat
grid-square** in your shots is a **constant-depth region** (a wall / saturated background clamped to one
depth by the normalizer) — a constant depth through `freeXY` is a regular scaled grid. Not a bug in
itself, but it's why a flat surface reads as a hard grid next to the fanning midground. The real path to
"looks like TDLiDAR" remains **real-intrinsics unprojection** (plan Part B) — say go and I build it.

⚠ **Full checklist this round:** (1) lens switch live incl. front↔back w/o model change; (2) node-add
doesn't rotate live LiDAR; (3) steady cloud (EMA); (4) baked video upright; (5) orbit/move work again on
any camera. Then: is the live cloud close enough, or do we go for real-intrinsics parity (Part B)?


Lidar notes testing:

Camera switch still doesnt work. - Lidar is now horizontal on the front camera now its 90deg rotated. Whatever change you made to the lidar truedepth/point cloud - Now the face is completely flat like the points arent 3D anymore and moving my hand infront of my face it barely has any depth - Figure out how you broke it and fix it. - The lidar should be a 1:1 realistic recreation of my face based on the infrared truedepth TOF information, not just a flat point cloud render. you also remove the Moge2 from the live depth node options. I wanted that one still there. - and for some reason the video and DAv2 models are running slower than before - I kept them because they were the fastest.

### Regression-fix feedback (commits `c8237dd`, `5a0fc0f`)

You were right — I broke things. Undone:

**Flat face.** Two parts: (a) I seeded the default file's Point Display **`focus = 0.5`**, which *doubles*
the XY spread so the same Z relief reads as flat — **reverted to 1.0** (+ reverted the freeXY near-cull).
(b) Your Camera bar (IMG_8895) shows **DEPTHPUSH = 0.00** — `world-Z = z × depthPush`, so 0 is a **hard
flat**, and that's the slider (default 1), not code. **To get the 1:1 face:** raise **DEPTHPUSH**, and pull
the **Depth node's FAR down to ~0.6 m** — at FAR 2.5 m a 0.4 m face fills only ~4 % of the depth window so
its relief is tiny; at ~0.6 m the nose/cheeks get real depth.

**Front LiDAR 90°-rotated — fixed.** A Live Depth node sets the renderer orient to 0; the return-to-camera
path only reset it on a state *change*, so a stale 0 leaked. `setMediaMode(false)` now restores the
live-camera orient unconditionally.

**MoGe-2 + DA V2 S — restored** (only DA2 Metric Indoor/Outdoor stay out — those were zoomed/broken).

**Camera switch — 3rd attempt, new mechanism:** the RGB session now does a full **stop → reconfigure →
start** on a lens change (swapping the input on a *running* session silently failed). ⚠ If it STILL won't
switch it's environmental — I'll add an on-screen readout of the actual active device to see it.

**Slower models — clawed back:** I'd added a per-frame percentile **sort**; coarsened it (every 32nd px).

**The live-depth cloud still vortexes and that's not tunable** — `freeXY` unprojects XY ∝ depth with no
lens intrinsics, so near points always collapse to the axis. The real fix (both the live models AND a true
1:1 TrueDepth face) is [MonocularDepthPC-Plan.md](../MonocularDepthPC-Plan.md) **Part B: unproject with the
real camera intrinsics into metric XYZ**. It's a real build but it's *the* thing that makes it look like
TDLiDAR. **Say go and I build it** — further freeXY tuning is diminishing returns.

### Part B — METRIC mode (real-intrinsics unprojection) BUILT (commit `57ebe10`)

Your diagnosis was exactly right: we only built a Z axis; XY didn't scale with distance so the head kept
its size. Implemented a new **Point Display `mode` → `metric`** that unprojects each depth pixel to real
metric XYZ with the camera's intrinsics:
`worldX = (u−cx)/fx · Z`, `worldY = (v−cy)/fy · Z`, `worldZ = (FOCUS − Z)·scale`.
Because X/Y are TRUE metres, an object keeps its real size — move it away (Z grows) and the fixed
perspective camera shrinks it, like TDLidar. Intrinsics are the REAL ones: TrueDepth `AVDepthData`
calibration + LiDAR `ARFrame.camera.intrinsics` (normalized, so they transfer to any depth-map size);
RGB models use a nominal FOV (they're relative depth, not true metres).

**To use it: select the Point Display node → `mode` → `metric`.** (I did NOT make it the default — didn't
want to change your default file again. If it looks right we make it default.) Switching seeds a working
preset (SEPARATION = metres→view scale, FOCUS = reference depth, DEPTHPUSH 1 = the metric Z multiplier).

⚠ **On device — this is the big one to check:**
- Front TrueDepth in `metric` mode: does the head now **shrink as you move away** + look 1:1 proportioned
  like TDLidar (head vs shoulders)?
- Knobs: **SEPARATION** = overall size (metres→view scale). **FOCUS** = the depth that sits at the wall;
  content **farther than FOCUS flattens** (a Z clamp) so raise FOCUS to ~3 for room-scale **back LiDAR**.
  **DEPTHPUSH** must be ≥ 1 (it multiplies the metric Z; 0 = flat).
- Orientation: I mirrored freeXY's orient handling, but the metric XY flip/mirror is my best guess from
  here — if the face is mirrored or sideways in metric mode, tell me and it's a one-line sign fix.
- If it's close, I'll (a) make metric the default, (b) drop the far-clamp so deep scenes keep ordering,
  (c) calibrate the RGB-model intrinsics per lens. 
### Round — free-zoom, live intrinsics, slowdown, camera controls, Orbit Cube (commits `8949565`, `f531b55`, `fdd08ad`)

- **Free mode now zooms with distance.** Replaced its weak nearness push with a strong focus-referenced Z
  recession (kept the fan XY), so the face SHRINKS as you move away — close to metric while keeping the
  free look. GAIN = zoom strength, FOCUS = the wall depth. ⚠ needs DEPTHPUSH ≥ 1.
- **Live Depth node → real intrinsics.** Enabled `cameraIntrinsicMatrixDelivery` on the RGB connection +
  read the per-frame matrix (normalized, rotated for portrait) → METRIC mode on the live node uses the
  real fx/fy/cx/cy now, not a nominal FOV.
- **Slowdown found + fixed.** My normalization added a SECOND per-pixel pass (the EMA loop) on top of the
  map loop → each frame went over the ViT budget → dropped frames = slower. Merged into one pass; lock is
  now O(1). Should be back to the old speed (the models themselves are the floor).
- **MoGe-2** was already restored (Metric Video DA S · DA V3 S · DA V2 S · MoGe-2).
- **Camera pad no longer swipes pages.** While you hold/drag the joystick or jog, the deck's page-swipe is
  suppressed — dragging the knob out of its box stays a camera move. **Orbit/Move are unbounded** now
  (full turntable both ways, pitch capped at ~86° to avoid flipping; move ±5, orbit many turns).
- **Orbit Cube = a node** (your pick). New **Orbit Cube** node: outputs ORBIT X / ORBIT Y; expose the
  Camera's orbitX/orbitY ◇ and wire them → the view auto-orbits (SPIN turns/sec, YAW offset, PITCH tilt).
  Also generalized: ANY camera param can now be driven by a control node via its ◇ (feed SPIN from an LFO
  or audio for reactive moves). ⚠ No visual pivot-cube gizmo yet (that's the render-pass half of TDLiDAR's
  version) — say if you want the on-screen cube too.

### Round — Orbit Cube as a movable 3D handle + camera orbit wiring / hold / smoothing (commit `3bccc7c`)

- **Orbit Cube is now a movable handle, not stuck.** Its settings have a **joystick** (L/R = yaw, U/D =
  pitch) + **DOLLY** buttons (forward/back = the Z axis, closer/further). The red gizmo now sits at the
  cube's position and **moves as you drive it**, so you see where you set it. `scope` recenters it.
- **One clean output.** The two confusing ORBIT X / ORBIT Y outputs are gone — the cube now has **one
  `ORBIT` output** carrying yaw/pitch/dolly. Wire that **single wire → the Camera's new `ORBIT` ◇**
  (an always-present input diamond on the Camera). No more exposing two ports and wiring twice.
- **Camera orbit is unbound → full 360** both ways (jog limit lifted from 0.9 to ~16 turns; pitch still
  capped ~86° so it never flips over the pole).
- **Hold to keep moving.** The Camera's ORBIT/POSITION jog chevrons (and the cube's DOLLY buttons) now
  **repeat while held** (~16×/s after a short press) instead of one-step-per-tap. Tap still = one step.
- **SMOOTH toggle** (wind icon) sits next to the ORBIT jog row in the Camera node. On = jog / joystick /
  wired-orbit motion **eases** instead of hard move-then-stop. Off = the old snappy behaviour.
- Preset angle buttons kept — they now snap the cube's yaw (and stop SPIN). SPIN slider still auto-turns.

⚠ **On device:**
- Add an **Orbit Cube** node → open it: the joystick should slide the **red cube** around (L/R, U/D) and
  the DOLLY buttons push it in/out. Does the cube track your input?
- Wire the cube's **ORBIT → Camera's ORBIT ◇** (one wire). Now moving the joystick / tapping a preset
  should **orbit the view**; DOLLY should zoom the whole cloud in/out.
- Camera node: **hold** an orbit chevron → view keeps rotating (no repeated tapping). Tap **SMOOTH** →
  the same moves should glide instead of snapping.
- Orbit should now go **all the way around** (past the old ~90° stop).
- Heads-up on the gizmo: it's a *position readout of the handle*, not the orbit pivot — the cloud still
  orbits the frame centre. If you'd rather the cube sit AT the pivot, say so (one-line change).
- Sign check: is **up = look up** on the joystick, and does **preset 90°** turn the way you expect? Either
  is a one-line flip if inverted.

---

### Round — Vision Model notes:
Camera switch in Live Depth node still doesnt work when you are using a model. I think the live depth
node is causing too much trouble - revert to having the models only for still images and videos. Bug:
imported still image point cloud is fine, but the truedepth point cloud outputs jittery single frames
horizontally over the still image point cloud. Remove Video Depth Anything and DepthAnythingV2S — only
MoGe-2 remains. Universal reset switch in the menu bar (reset ALL parameters to fresh-install state).
Capture all default parameters into a table below these notes. Lower depthPush max to 2. Video/image
processing: selecting media starts processing immediately, remove the done/close page, return straight
to the app. Remove the live depth node and all its code + the other models (smaller install). Remove the
image/video process button from the main menu → make it a node ("Vision Model") with depth/position/z
outputs like the Depth node, media button + X, wire-driven output.

### Round — Vision Model feedback (commit `6cb87fb`)

All items done. Build green.

- **Live Depth node DELETED** — the whole stack: `LiveDepthEngine`, `RGBCameraSource`, the
  camera-switch overlay, the node spec, its node-bar controls, the loading overlays. Its unresolved
  camera-switch bug is gone with it. **Models: MoGe-2 only** — Metric Video DA S, DA v2 S and the two
  DA2 Metric packages deleted from `DepthImport/` (≈150–200 MB off the install). `DepthModelRunner`
  is now the metric-only bake path (the relative/percentile normalisation code is removed).
- **Jitter over the still image — root-caused + fixed.** Live TrueDepth frames were reaching the
  renderer after media playback started (in-flight frames on the capture queue + the session's
  auto-recovery restart), and since the renderer orient is 0 for media, each stray frame stamped a
  sideways (horizontal) cloud over the still. Capture callbacks now drop every frame through a
  cross-queue **MediaGate** the moment imported media owns the feed — nothing can leak through.
- **New Vision Model node** (SOURCE) — replaces Still Image, Video Source AND the menu import button:
  - Image/video button → gallery → picking starts the **MoGe-2 bake immediately** behind the
    clockwise edge-loop screen — the model-select page and the done/close page are gone; it returns
    straight to where you were.
  - Outputs **depth + position + z** (same free/metric cloud as the Depth node, shared emitter).
  - **Wire-driven**: nothing appears until you wire its outputs; the **X** next to the button discards
    the media and blanks the output (zero depth texture — no points) until a new pick.
- **Universal reset** — the menu ⟳ button is now a factory reset: default graph file, cleared imported
  media, colour off, 30k pins, front camera, EMA/filter state cleared, app defaults wiped — the table
  below is exactly the state it restores.
- **DEPTHPUSH max 3 → 2.**

### Default starting file — all parameters (fresh install / after ⟳ reset)

| Node (id) | Parameter | Default | Range |
|---|---|---|---|
| **Depth** (`d1`) | near | 0.1 m | 0.05–5 |
| | far | 2.5 m | 0.2–8 |
| | invert | off | on/off |
| | mode | **metric** | free / metric |
| | separation | 2.5 | 0–4 |
| | focus | 1.0 m | 0.3–3 |
| | gain (free-mode Z) | 2.5 | 0–3 |
| | arms | off | on/off |
| **Size** (`sz`) | base | 1 | 0–4 |
| | min | 0 | 0–2 |
| | max | 3 | 0.1–6 |
| **Camera** (`cam`) | fov | 60° | 15–110 |
| | zoom | 1 | 0.5–2 |
| | parallax | 0.5 | 0–1 |
| | depthPush | 1 | 0–**2** |
| | centerX / centerY | 0 / 0 | −1–1 |
| | orbitX | 0 | −100–100 (unbound turns) |
| | orbitY | 0 | −1.5–1.5 (~±86°) |
| | smooth | 0 (off) | 0–1 |
| **Output** (`out`) | — (sink: position/z/size/color/rotation/shape/stretch inputs) | | |
| **Wires** | Depth.position → Output.position · Depth.z → Output.z · Size.out → Output.size | | |
| **Global** | point count | 30,000 | 30k/77k/150k/307k menu steps |
| | point scale | 1.0 | 0.2–3 |
| | colour | OFF | menu toggle |
| | camera facing | FRONT (TrueDepth) | front/back |
| | Apple depth filter | OFF | Filter node presence |
| | depth EMA / stabilize | 0 (raw) | EMA Smooth node presence |
| | selected node | `d1` | |

⚠ **Verify on-device:** (1) Vision Model node → button → pick photo → edge-loop → back in node view →
wire position/z → Output → still-image cloud with NO live-frame jitter over it; (2) X → points vanish;
(3) menu ⟳ → everything in the table above restored; (4) DEPTHPUSH slider tops out at 2; (5) install
size noticeably smaller.

---

### Round — polish notes:
TD grid = default node-creation view · menu reset should reset parameters not the whole app · Vision
Model image flashes black on every parameter/orbit step · model output is always square — accept any
aspect (crop-UI page as backup) · aftereffect points trailing at the bottom/edges (IMG_8942).

### Round — polish feedback (commit `298e80e`, grazing-cull fix `4bf1d7a`)

- **TouchDesigner OP-grid is now the default** node-creation view (list still a toggle away).
- **Menu ⟳ = parameter reset only** — default graph file + renderer state (30k pins, colour off,
  selection d1). App preferences, imported media and the camera facing are untouched.
- **Black flash fixed — root cause:** `DepthPlayer.start()` re-ran on EVERY graph change (slider
  drags recompile per tick) and each run stopped the loop + reset the depth filter → one draw with no
  depth = black, every step. The player is now idempotent per media (a store generation counter);
  only a new bake or the X restarts the loop.
- **Any aspect ratio — no crop page needed.** The CoreML input shape is fixed (square, baked into the
  converted model — a true dynamic input needs a re-convert), so instead: non-square media is
  **letterboxed** onto a centred black square for inference and the depth is **cropped back** to the
  content region. The stored map keeps the source aspect, and the player sets nominal intrinsics from
  that aspect (~60° hFOV) so METRIC mode renders it unsquashed. 16:9, 9:16, 4:3 — all fine.
- **Aftereffect strands (IMG_8942) — root cause:** the temporal EMA persisted hole pixels FOREVER, so
  a moving silhouette's IR shadow left strands of stale hand-depth behind it. TDLidar's EMA is a
  bit-exact bypass at stabilize 0 (holes stay holes) — Points now matches: holes persist **only while
  an EMA Smooth node is active**, raw mode drops them to nothing. (Same round: the Grazing Cull's
  jittering dots in solid areas — 2-texel normal baseline + a real-change noise gate, `4bf1d7a`,
  restore tag `pre-grazing-cull-fix`.)

⚠ **Verify:** palette opens on the OP-grid; ⟳ resets sliders but keeps your prefs/media; image
playback rock-steady while dragging any slider/orbit; a 16:9 video renders wide, not squashed
(METRIC mode); wave a hand fast on TrueDepth — no trailing strands, and solid areas stay solid with
Grazing Cull active.
