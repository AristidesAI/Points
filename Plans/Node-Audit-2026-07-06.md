# Node Audit — 2026-07-06

Full audit of every registered node: description vs. actual behaviour, what was changed in
Round 1 (commit `99d5920`), and what Round 2 covers. Statuses:

- **real** — implemented and the description is honest
- **stub** — returns zeros until its engine lands (description now says so)
- **passthrough** — registered, wiring compiles, but the render feature isn't built yet (description now says so)
- **mismatch** — works, but with a caveat noted below

## Round 1 — what was fixed

**Your flagged list:**

| Complaint | Root cause | Fix |
|---|---|---|
| Face Region does nothing | Emitted a constant 0 ("until face tracking lands") | Real soft mask following the face via body pose; RADIUS/FEATHER/INVERT |
| Body nodes (non-hand) | Body Region also constant 0; Hand Position read the LEFT wrist only; Joint still a stub | Body Region real (depth cut for person/background, joint circles for head/torso/arms/hands); Hand Position falls back to the right wrist; Joint → Round 2 |
| Background always black | Node registered but the renderer never read it | Renderer clears to the node's R/G/B (also NDI/Record when ALPHA off) |
| Lights — no code? | Correct, there was none | Point/directional/spot lighting implemented in the fragment shader |
| Shape: ring/disc/spike broken, slab=sphere, cube rounded | Degenerate morph math; normals never recomputed | All morph targets rebuilt (true torus ring, flat coin disc, square slab, star spike, fixed cone) with per-shape normals; **diamond added** |
| Shape by Depth does nothing | Its 0-1 output decoded as "morph toward sphere" — a no-op | Target-shape index now packed in + TARGET picker (same fix for Shape Blend) |
| Noise mono, bar too tall | No color path; 12 sliders one-per-row + inline preview | New color output through a palette MAP; preview lives in the minimap slot while selected; sliders 3-per-row |
| Counter unclear | Worked, description was one line | Raw count output added; description + HOW TO USE example |
| On Start does nothing visible | Fired one 1-frame pulse at start | New **seconds** output counting up from placement; fired kept for reset/kick wiring |
| Toggle unclear | Worked, description was one line | Rewritten description + example (fist → mute latch) |
| Descriptions/examples | — | HOW TO USE section in the node detail card, examples for all 131 nodes with real port names (`NodeUsage.swift`) |

**Extra bugs the audit found (also fixed in Round 1):**

- **Wave** — SPEED did nothing (phase never advanced). Now travels.
- **Orbit** — swirled around a point up-right of frame (uv vs view-space mix-up). Now the true centre.
- **Shockwave** — the FIRE input was never read (taps/pads only). Wired triggers now fire it.
- **Sample & Hold** — level-triggered (a held trigger made it track). Now edge-triggered.
- **Camera** — only the default `cam` node was read; palette-added Cameras were silent. Fixed.
- **Displays/Gate** — trigger wires were rejected by validation. New trigger→signal coercion.
- **Stale descriptions** — audio nodes claimed "live when the engine lands" but ARE live; Record claimed multi-node capture; Compare claimed strict >; Ripple claimed a drivable centre. All rewritten to match reality.

## Every node (129 audited)

| Node | Status after Round 1 | Round-1 change / caveat |
|---|---|---|
| Abs (`abs`) | real | — |
| Add (`add`) | real | — |
| Audio Levels (`audio-levels`) | real | Description fixed: it IS live (mic starts when the node exists). |
| Mic Level (`audio-rms`) | real | Description fixed: live; notes it shares Audio Levels' auto-gained lane. |
| Background (`background`) | real | IMPLEMENTED: clear color from R/G/B, read by main + NDI/Record passes. Gradient param removed until a real gradient pass exists. |
| Beat Trigger (`beat-trigger`) | real | Description fixed: live drum onsets. |
| Binary Display (`binary-display`) | real | Triggers can now wire in (new trigger→signal coercion). |
| Bloom (`bloom`) | passthrough | — |
| Body Region (`body-region`) | real | IMPLEMENTED: person/background = depth cut at RANGE metres; head/torso/arms/hands = joint-tracked circles (elbows/neck/root added to the Vision bus). |
| Brightness (`brightness`) | real | — |
| Burst (`burst`) | real | Description fixed: live loudness pulse. |
| Camera (`camera`) | real | FIXED: the renderer reads any Camera node (was hardcoded to the default 'cam' id). Jog rows still target the default — round 2. |
| Chance (`chance`) | real | — |
| Clamp (`clamp`) | real | — |
| Clock (`clock`) | real | — |
| Color Clamp (`color-clamp`) | real | — |
| Color Gamma (`color-gamma`) | real | — |
| Color Invert (`color-invert`) | real | — |
| Color Levels (`color-levels`) | real | — |
| Color Mix (`color-mix`) | real | — |
| Screen Blend (`color-screen`) | real | — |
| Sticky Note (`comment`) | mismatch | There is no text field or edit UI anywhere — the card only ever shows the title 'Sticky Note', so it can't actually hold a teaching note. |
| Compare (`compare`) | real | Description fixed: a ≥ b. |
| Constant (`constant`) | real | — |
| Contrast (`contrast`) | real | — |
| Counter (`counter`) | real | New raw count output; description explains COUNT/RESET/WRAP with a Clock example. |
| Trigger Delay (`delay-trigger`) | real | — |
| Depth Drive (`depth-drive`) | real | — |
| Depth Fog (`depth-fog`) | real | — |
| Depth Gradient (`depth-gradient`) | real | — |
| Displace (`displace`) | real | — |
| Divide (`divide`) | mismatch | The divisor is clamped to >=0.0001 (Shaders.metal op 10: A/max(B,0.0001)), so a zero or NEGATIVE b doesn't divide — it returns a huge positive ~a*10000 instead of a/b. |
| Duotone (`duotone`) | real | — |
| Echo (`echo`) | real | — |
| Envelope (`envelope`) | real | — |
| Face Region (`face-region`) | real | IMPLEMENTED: soft circle tracking the face via body pose (nose), patched per frame; RADIUS/FEATHER/INVERT params. |
| FFT Band (`fft-band`) | stub | Description now says NOT WIRED UP YET and points to Audio Levels. |
| Field Curve (`field-curve`) | real | — |
| Field Fold (`field-fold`) | real | — |
| Fract (`fract`) | real | — |
| Freeze (`freeze`) | real | — |
| Gate (`gate`) | real | Triggers can now wire into in/open (new trigger→signal coercion). |
| Grain (`grain`) | passthrough | — |
| Hand Gesture (`hand-gesture`) | real | — |
| Hand Openness (`hand-openness`) | real | Openness is quantized (fingers-up ÷ 4): it steps 0/.25/.5/.75/1 rather than a continuous fist→palm sweep — use SMOOTHING to ease the steps. |
| Hand Position (`hand-position`) | real | Falls back to the right wrist when the left is unseen (was left-only). |
| Head Pose (`head-pose`) | real | — |
| Hide (`hide`) | real | — |
| Hue Shift (`hsv-shift`) | real | — |
| Joint (`joint`) | stub | — |
| Lag (`lag`) | real | — |
| Left Hand Gesture (`left-hand-gesture`) | real | Chirality is raw Vision — a code comment warns the mirrored front camera may report sides swapped on device. |
| Left Hand Pinch (`left-hand-pinch`) | real | Chirality comes raw from Vision — the code itself warns the mirrored front camera may report left/right swapped on device; same hidden 0-10 OUTMAX as Hand Pinch. |
| LFO (`lfo`) | real | — |
| Light (`light`) | real | IMPLEMENTED: point/directional/spot lighting in the fragment shader; replaces the built-in light while the node exists. |
| Light Gradient (`light-gradient`) | real | — |
| Live Update (`live-update`) | real | — |
| Look At (`look-at`) | passthrough | — |
| Macro (`macro`) | stub | — |
| Material (`material`) | passthrough | — |
| Max (`max`) | real | — |
| MIDI CC (`midi-cc`) | real | — |
| MIDI Note (`midi-note`) | real | — |
| Min (`min`) | real | — |
| Mix (`mix`) | real | — |
| Multiply (`multiply`) | real | — |
| NDI Out (`ndi-out`) | real | The image wire is cosmetic: node presence + STREAM=START drives the offscreen pass, and only the first NDI node in the graph is consulted. |
| Negate (`negate`) | real | — |
| Noise (`noise`) | real | New color output through a palette MAP (mono default). Preview moved to the minimap slot; sliders now 3 per row. |
| On Start (`on-start`) | real | New seconds output counting up from the moment the node lands (the 'counter from placement' you asked for); fired still pulses once. |
| One Minus (`one-minus`) | real | — |
| Orbit (`orbit`) | real | FIXED: swirls around the true frame centre (was offset up-right due to a uv/view-space mix-up). |
| OSC In (`osc-in`) | stub | — |
| OSC Out (`osc-out`) | stub | — |
| Output (`output`) | real | — |
| Palette (`palette`) | real | — |
| Person Present (`person-present`) | real | PRESENT needs a full VNDetectHumanBodyPose hit — a hand or face alone doesn't count as someone in frame. |
| Pin Color (`pin-color`) | passthrough | — |
| Hand Pinch (`pinch-amount`) | real | Default OUTMAX is 10 but exposed params clamp their drive at 1, so the pinch saturates ~10% into the spread — lower OUTMAX to 1; the description never mentions the 0-10 scale. |
| Posterize (`posterize`) | real | — |
| Power (`power`) | real | — |
| Quantize (`quantize`) | real | — |
| Ripple (`radial-ripple`) | mismatch | Description now says rings come from the frame centre. Round 2: drivable centre. |
| Random (`random`) | real | — |
| Receive (`receive`) | stub | — |
| Record (`record`) | real | Description fixed: one Record node per patch, captures the finished frame. |
| Remap (`remap`) | real | — |
| Render Settings (`render-settings`) | passthrough | — |
| Reroute (`reroute`) | real | Ports are field.float, so color wires can't attach (no fieldColor→fieldFloat coercion) — it's an elbow for float/vec3 field wires only. |
| Right Hand Gesture (`right-hand-gesture`) | real | Same chirality caveat: the mirrored front camera may report sides swapped on device. |
| Right Hand Pinch (`right-hand-pinch`) | real | Same caveats as Left Hand Pinch: Vision chirality may read swapped on the mirrored front camera, and the default 0-10 OUTMAX saturates exposed params early. |
| Rotation (`rotation`) | real | — |
| Sample & Hold (`sample-hold`) | real | FIXED: edge-triggered — a held-high trigger no longer makes the output track the input. |
| Scatter (`scatter`) | real | — |
| Send (`send`) | stub | — |
| Shape (`shape`) | real | Ring/disc/slab/spike/cone rebuilt in the vertex shader with per-shape normals (cube now reads sharp, disc reads flat); DIAMOND added. |
| Shape Blend (`shape-blend`) | real | FIXED: now packs the target-shape index into the morph value + new TARGET picker — previously always decoded as sphere (no effect). |
| Shape by Depth (`shape-by-depth`) | real | FIXED: same target-index packing fix + TARGET picker; near/far morph works now. |
| Shape Morph (`shape-morph`) | real | — |
| Shockwave (`shockwave`) | real | FIXED: a wired FIRE trigger now births waves (was tap/pad only) — Beat Trigger.low → fire works. |
| Sine (`sine`) | real | — |
| Size (`size`) | real | — |
| Size by Depth (`size-by-depth`) | real | — |
| Slew (`slew`) | real | — |
| Smoothstep (`smoothstep`) | real | — |
| Spin (`spin`) | real | — |
| Spring (`spring`) | real | — |
| Square Root (`sqrt`) | real | — |
| Stem (`stem`) | passthrough | — |
| Step Sequencer (`step-sequencer`) | real | — |
| Stretch (`stretch`) | real | — |
| Strobe Color (`strobe-color`) | real | — |
| Subtract (`subtract`) | real | — |
| Switch (`switch`) | real | — |
| Threshold (`threshold`) | real | — |
| Threshold Color (`threshold-color`) | real | — |
| Timer (`timer`) | real | — |
| Tint (`tint`) | real | — |
| Toggle (`toggle`) | real | Description rewritten: latching switch with fist→mute example. |
| Touch (`touch`) | real | — |
| Trail (`trail`) | real | — |
| Transport (`transport`) | real | — |
| Twist (`twist`) | real | — |
| Value Display (`value-display`) | real | Triggers can now wire in (new trigger→signal coercion). |
| Velocity (`velocity`) | real | — |
| Velocity Color (`velocity-color`) | real | Does no motion sensing itself — it is a plain colormap lookup of its speed input; the movers-burn behavior only appears with Velocity.speed (or similar) wired in. |
| Vignette (`vignette`) | passthrough | — |
| Wander (`wander`) | real | — |
| Wave (`wave`) | real | FIXED: SPEED now travels the sheet (phase lane patched per frame — was static). |

## Round 2 — DONE (same day)

1. DONE **Control-state persistence** — slider drags no longer reset Counter/Toggle/Envelope/On Start (state survives recompiles; pruned only when a node is deleted).
2. DONE **Joint node** — real: pick any of the 19 tracked skeleton joints, live x/y + a smoothed speed output.
3. DONE **Hand Openness** — continuous 0-1 (mean finger extension, was quantized to quarter steps).
4. DONE **Ripple centre** — CENTERX/CENTERY params, drivable via expose (wire Hand Position to carry the ripple).
5. DONE **Sticky Note** — editable text (NOTE field in the settings bar, shown on the card).
6. DONE **Send/Receive** — paired in the compiler: a Receive compiles as whatever feeds the matching Send channel; loops read 0.
7. DONE **Camera jog rows** — target the selected Camera node.
8. DONE **Divide** — sign-preserving divisor guard in the shader (negative divisors work); pinch OUTMAX saturation note added.
9. DONE **FFT Band** — real: 20 log-spaced auto-gained bands (40 Hz → 8 kHz) from the mic FFT, BAND param picks one.

## Round 3 — DONE (backlog implementation, commits 23300ac…)

- **Post stack real** (phase A): scene renders offscreen; one composite applies Background
  (solid + radial GRADIENT), Bloom (bright-pass + gaussian), Vignette, animated Grain.
  Render Settings GHOST = additive, depth-test-off hologram blending. Applies to the view,
  NDI and Record outputs alike; ALPHA outputs stay keyed.
- **Material / Look At / Lights / Stem** (phase B): unlit / lit (roughness + metallic
  speculars) / matcap shading; up to 4 simultaneous Lights; Look At orients every pin to a
  drivable point; Stem profiles square/round/blade with THICKNESS + TAPER.
- **Domain / UV Transform / Edge Policy** (phase C): rect·hex·radial·spiral·scatter·
  perspective lattices with a live A→B MORPH; pan/zoom/rotate the image under the pins;
  fade/clamp pins at the frame border.
- **Cleanup passes** (phase D): Despeckle Voxel, Smooth Surface (bilateral), Accumulate
  (temporal) — real GPU passes chained after fill-holes + EMA.
- **Proximity + OSC** (phase E): Proximity reads the nearest subject live (nearness +
  entered trigger); OSCEngine listens on UDP :9000 (/points/mod/1-8) and broadcasts
  /points/out/1-8 on :9001; OSC In/Out nodes real with SLOT params.

## Remaining backlog

- Detail Upsample (JBU joint bilateral upsample) — description says NOT WIRED UP YET
- Confidence texture — AVFoundation depth exposes no confidence map; needs ARKit
- Macro grouping — editor feature (collapse/expand node groups)
- Sticky Note on-canvas text editing is settings-bar only (no inline card editing)
- Specular view-direction is approximated as frontal; pass the real eye if orbit speculars read wrong
- OSC broadcast may need the multicast entitlement on device; receiving on :9000 is unaffected
- On-device check: hand chirality may be swapped on the mirrored front camera (code comment flags where to swap)
- Live Depth model issues (from Plans/TESTINGDoc.md §Live Depth) — separate work item
