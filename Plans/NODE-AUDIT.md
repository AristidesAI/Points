# Node audit — what actually works vs. what's a placeholder (2026-07-04)

Went through every registered node. Split into **REAL** (emits a real GPU op or runs real
control logic — drag it in and it does something) and **PLACEHOLDER** (wires up + validates,
but needs a subsystem that isn't in the pipeline yet). This build makes the **whole audio
family real**; the rest of the placeholders are grouped by the one subsystem each needs.

## REAL — works today (≈100 nodes)

- **SOURCE:** Depth, Video Color, Still Image, Clip Transport, Confidence, Domain, Grid Info,
  Region (rect/ellipse). *(Proximity = stub, see below.)*
- **GRID:** Point Display (FREE/PINOUT, all params), Size.
- **FILTER:** Grazing Cull (real GPU cull — verified culling silhouettes on device),
  EMA Smooth / Fill Holes / Apple Depth Filter (real, act by presence on the capture/EMA layer).
  *(Accumulate / Smooth Surface / Despeckle / Detail Upsample = passthrough, see below.)*
- **MOVE:** Displace, Velocity, Echo, Wave, Jitter, Scatter, Twist, Shockwave, Spring, Lag, Trail,
  Ripple. All emit real per-pin VM ops.
- **COLOR:** Palette, Pin Color, Tint, Depth Gradient, Hue Shift, Velocity Color, Color Mix,
  Posterize, Strobe Color, Brightness.
- **SIGNAL (math/logic/mod):** Add, Subtract, Multiply, Divide, Min, Max, Mix, Clamp, Remap, Abs,
  Sine, Smoothstep, Threshold, Constant, Random, Compare, Switch, LFO, Envelope, Wander,
  Sample & Hold, Chance, Slew.
- **TIME:** Transport, Clock, Step Sequencer, Counter, Timer, Toggle, Gate, Trigger Delay, On Start.
- **TOOLS:** Reroute, Send, Receive, Macro, Sticky Note, Value Display.
- **STAGE:** Camera, Output.
- **AUDIO — NOW REAL (this build):** Audio Levels (bass/mid/high/rms), Mic Level, Beat Trigger
  (low/mid/high onset triggers), Burst (broadband transient). Driven by a live mic FFT
  (`AudioEngine.swift`, Accelerate vDSP), auto-gained 0-1. Mic turns on only while an audio node
  is in the graph (asks permission first). **Try:** `Audio Levels.bass → Size` and clap.

## PLACEHOLDER — needs one named subsystem each

## NOW REAL — Render geometry + Vision (2026-07-04 night)

- **SHAPE family is real.** The instance buffer carries per-pin rotation + shape-morph + stretch
  (`InstanceOut` → 64 B), applied in the vertex shader. **Shape** (sphere↔cube), **Shape Morph**
  (0-1 blend, drivable by audio/depth/anything), **Stretch** (per-axis scale → needles/slabs),
  **Rotation** (static turns), **Spin** (continuous from the clock) all emit real VM ops feeding
  three new `Output` inputs: **rotation · shape · stretch**. (Rotation is only visible on a
  non-sphere Shape, as expected.)
- **Vision body/hand is real (control values).** `VisionEngine.swift` runs `VNDetectHumanBodyPose`
  + `VNDetectHumanHandPose` on the colour frame (throttled ~13 fps, off a background queue),
  feeding `ControlContext`. Live now: **Head Pose, Hand Position, Hand Pinch** (index↔thumb),
  **Hand Openness, Hand Gesture** (palm/fist/peace/point), **Person Present**. Runs only while a
  body node is in the graph. ★ needs on-device tuning of the coordinate mapping (front-mirror).

## STILL placeholder

| Nodes | Needs |
|-------|-------|
| **Body Region, Face Region** (2) | person-**segmentation** mask (`VNGeneratePersonSegmentation`) bound as a kernel texture + a `bodyMask` op — deferred: it's the one untestable piece (mask orientation vs the pin grid needs a device). |
| **Joint** (1) | pick one of 19 body joints → control (pose is already tracked; just needs the joint selector). |
| **Look At, Stem, Material** (3) | Look At = orient-to-target math; Stem/Material = renderer shading (arms already exist via Point Display ARMS). |
| **UV Transform, Edge Policy** (2) | source-image warp / border policy. |
| **MIDI CC, MIDI Note** (2) | **CoreMIDI** input. |
| **OSC In, OSC Out** (2) | **UDP OSC**. |
| **FFT Band** (1) · **Proximity** (1) | expose 20 FFT bins · CPU depth-min readback. |

These wire + validate, read 0 / pass through until their subsystem lands. None crash.

## Next
1. **Body Region segmentation mask** (device-tune the orientation) — confine any effect to the body.
2. **MIDI / OSC** (small, mechanical). 3. Look At / Material shading.

## Round 4 — DONE

- Detail Upsample real: JBU — depth resampled at FACTOR× res, edges snapped to the RGB image
- Macro grouping real: GROUP collapses a selection into one card (wires re-anchor on it,
  dragging moves the group), EXPAND/delete restores
- Sticky Note: inline text editing on the card while selected
- Speculars use the real camera eye — highlights track the orbit
- Testing templates (Max Complexity, Trigger Test) removed from the project page; new
  **Device Test** project wires the on-device checklist with numbered Sticky Notes
  (depth cleanup, shapes, stage/post, face tracking, proximity)

## Remaining backlog

- Confidence texture — AVFoundation depth exposes no confidence map; needs ARKit (the node
  reads a constant 1.0 and its description says so)
- OSC broadcast may need the multicast entitlement on device; receiving on :9000 is unaffected
- On-device check: hand chirality may be swapped on the mirrored front camera (code comment flags where to swap)
- Live Depth model issues (from Plans/TESTINGDoc.md §Live Depth) — separate work item
