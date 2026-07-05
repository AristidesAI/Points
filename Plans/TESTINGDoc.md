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

---

### Round 4 notes:


### Round 4 feedback:

---

### Round 5 notes:


### Round 5 feedback:

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

