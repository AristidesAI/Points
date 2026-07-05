# Plan — Tutorial / Template Projects (flat model)

**Status:** Plan. Not yet built. These become `loadTemplate` cases in `GraphRuntime` + tiles in the project picker (next to the "＋" and the existing demo). Written 2026-07 against the FLAT modulation model (see [PLAN-Trigger-System.md](PLAN-Trigger-System.md)).

## Goal

Teach a newcomer to build their own networks — not just load a finished one — by laddering up one concept per project. Each tutorial is a **small, real, working network** the user opens, reads, and then extends. Every one ends with a one-line "now you try" nudge (a param to expose, a wire to add). Order = difficulty.

The teaching spine, in order: **pipeline → expose-a-param → drive it with a signal → sense the world → branch with logic → compose.** Each project introduces exactly one new idea on top of the last.

## The 7 tutorials

### T1 · "First Light" — the pipeline
- **Network:** Depth → Point Display → Output. (This is the minimum viable graph.)
- **Teaches:** what the three core nodes do; that data flows left→right into Output; how to pan/zoom the canvas; the settings bar.
- **Now you try:** drag the Depth `near`/`far` sliders and watch the cloud.

### T2 · "Make It Move" — expose + drive
- **Network:** T1 + an **LFO** wired into Depth's exposed **near** port.
- **Teaches:** the ◇ expose toggle → a param becomes a port; wire a Signal node into it; the value now animates. The single most important flat-model skill.
- **Now you try:** expose `far` too and wire the same LFO — or add a **Remap** between them to change the range.

### T3 · "Colour from Light" — the color chain
- **Network:** Video Color → **Light Gradient** → Output.color (+ T1 geometry).
- **Teaches:** color is its own field you transform and wire into `Output.color`; the new color pack (Light Gradient, Duotone, Contrast). RGB-driven visuals.
- **Now you try:** swap Light Gradient for **Duotone**, or stack **Contrast** before it.

### T4 · "Reach Out" — body input
- **Network:** Hand Pinch → Depth.near (exposed); Hand Openness → exposed Size.max.
- **Teaches:** body/vision nodes as live signals; that a control source is just another node you wire into a port. Also the natural place to surface the vision **debug/verify** step.
- **Now you try:** point **Value Display** at the pinch to confirm tracking, then drive a color param with it.

### T5 · "If This Then That" — logic
- **Network:** Audio Levels → **Threshold** → **If / Then** (A=fast palette, B=slow) → drive a color/param; a **Value Display** on the Threshold shows the 0/1.
- **Teaches:** boolean logic as nodes; hysteresis (Threshold); reading live 0/1. The programmatic core.
- **Now you try:** add an **And** so it only fires when a hand is also present.

### T6 · "Depth Sculpting" — the depth pack
- **Network:** Depth → **Depth Bands** → Output.shape via **Shape Blend**; Depth → **Size by Depth** → Size; **Depth Fog** on the color.
- **Teaches:** the new depth nodes; that one depth field can fan out to shape, size, and color at once.
- **Now you try:** add **Depth Slice** into Size to reveal only a slab of the cloud.

### T7 · "Full Instrument" — compose
- **Network:** a deliberately rich but READABLE patch combining T2–T6: audio-reactive color, pinch-driven depth, a logic gate, a depth-shaped morph. This is the "graduation" project and doubles as the max-showcase.
- **Teaches:** nothing new — it proves the pieces compose without becoming the old "madness" flat demo (because each sub-idea is a tidy cluster).

## Build notes

- Each = one `case` in `loadTemplate(_:)` building the nodes/wires/`exposedParams` directly (mirror the existing template cases; set `exposedParams` on the host nodes and add the driver wires).
- Project-picker tiles: reuse the existing card style; a small "TUTORIAL" tag + the one-line teaching goal as the subtitle. Group them before the blank "＋".
- Keep each network **≤ ~8 nodes** so it reads at a glance on a phone.
- A tiny persistent "▸ what this teaches / now you try" chip in the corner when a tutorial is open (dismissable), instead of a modal walkthrough — non-blocking, matches the app's flat style.

## Open questions
1. In-canvas coaching chip vs a one-time overlay card on open? (Lean: dismissable chip.)
2. Should T7 be the same as the existing max-complexity demo, or a new curated one? (Lean: new, curated for readability.)
3. Do tutorials live in the project picker permanently, or behind a "Learn" entry? (Lean: a "Learn" row so they don't clutter real projects.)
