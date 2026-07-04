# Points — How the node system works (read once, never guess again)

The graph is a **signal chain that ends at one node: `Output`**. Everything you build is "how do I
feed Output's four inputs." That's the whole mental model.

```
   Depth ──▶ Point Display ──▶ Output.position   (where each pin sits, XY offset)
                          └──▶ Output.z          (how far each pin pushes forward)
   Size ───────────────────▶ Output.size        (how big each pin is)
   (optional Color chain) ─▶ Output.color        (each pin's colour)
```

If a wire reaches `Output`, it's on screen. If it doesn't, it does nothing. Delete-safe: `Output`
can't be removed.

## 1. Three kinds of node (this is the key)

| Kind | What it carries | Examples | Rule |
|------|-----------------|----------|------|
| **FIELD** (per-pin) | a value **per pin** — 307k of them, on the GPU | Depth, Point Display, Size, Grazing Cull, Scatter, Twist, Trail, Palette | These are the "pin wires" (teal / blue / pink squares). They flow into `Output`. |
| **CONTROL** (one value/frame) | **one** number this frame, same for every pin | LFO, Audio Levels, Body Region signals, Envelope, Clock | White square (`signal`). A control value **broadcasts** — every pin gets the same number. |
| **STAGE** (global) | not wired at all | **Camera**, Output | Read straight by the renderer. Camera has **no output port** on purpose — you never wire it, you just edit its sliders. |

**Why your Camera node "won't connect": it isn't supposed to.** It's a global. Select it, its FOV /
ZOOM / PARALLAX / PUSH / ORBIT / POSITION drive the whole view. No wire needed. (That dead orange
`cam` port is gone now.)

## 2. Port types + colours (squares now match wires)

The little square's colour **is** the wire's colour (fixed this build). Colour = **type**:

- **white** `signal` — one control value/frame
- **teal** `field.float` — a per-pin number (depth, size, z…)
- **blue** `field.vec3` — a per-pin XYZ offset (position)
- **pink** `field.color` — a per-pin RGBA
- **yellow** `trigger` — a rising-edge pulse (drum hit, tap)

You can only connect compatible types, but the graph **auto-adapts** the sensible ones:

- `signal → field.float` — the one control value is **broadcast** to every pin.
- `field.float → field.vec3` — splats to (x,x,x); `field.vec3 → field.float` — takes .x.
- `field.vec3 ↔ field.color` and `vec3 ↔ color` — treat XYZ as RGB.

So an **LFO (white) drops straight onto Size (teal)** — the graph broadcasts it. That's legal.

## 3. The one thing to understand about CONTROL → pins

A control value is **the same for every pin**. So:

- **LFO → Size** = the *whole wall* pulses together (a strobe). ✅ what you want for a beat.
- **Audio bass → Size** = the whole wall breathes with the bass. ✅

To make something **per-pin / spatial**, you either
1. **multiply a field by the control** (e.g. `Depth × AudioBass` → louder = deeper), or
2. use a **FIELD source that is already spatial** — e.g. **Body Region** outputs a per-pin `mask`
   (1 on the person's arm, 0 elsewhere). That's a real per-pin field you can route into size/colour/hide.

## 4. Recipes (build these by dragging a wire out of a port onto empty space → pick the node)

**Audio drives pin size (beat strobe)**
`Audio Levels.bass ▶ Size.size` — or drop an **LFO** (rate 8, square) onto `Size.size`.
(The **Beat Strobe** template already wires the LFO for you.)

**Audio drives pin shape / push**
`Audio Levels.bass ▶ Multiply.b`, `Point Display.z ▶ Multiply.a`, `Multiply ▶ Output.z`.
Now depth is scaled by loudness — pins jump forward on the kick.

**Hands drive the pins (body/vision)**
`Body Region (region = hands).mask ▶ Size.size` — pins only grow where your hands are.
Route the same `mask` into a **Palette** or **Hide** to light up / cut out by body part.
(`Body Region` / `Face Region` are the "how do body nodes connect" answer — they emit a **per-pin
mask field**, so they plug in exactly where Depth does: anywhere a `field.float` is accepted.)

**Cleaner cloud**
`Depth ▶ Grazing Cull ▶ EMA Smooth ▶ Point Display` — insert the red FILTER nodes on the depth wire.

**Colour by depth**
`Point Display.z ▶ Palette.t`, `Palette.color ▶ Output.color` (the **Arm Fire** template does this).

## 5. How to actually wire, on the phone

- **Pull a new wire:** press a port square, slide up/down to pick the exact port, drag out. Drop it on
  a compatible square to connect. Drop an **output** on empty space → the node list opens showing
  **only nodes that accept it**, and it auto-connects.
- **Insert a node onto a wire:** tap the wire (turns white) → **+** → pick a node → it splices in-line.
- **Re-route a wire:** tap it (white) → drag its end to a new port. Tapping a port never steals a wire.

## Status of the buses
Audio / MIDI / OSC / Body nodes are **registered and wire up correctly today** — they output real
`signal`/`mask` ports and the graph accepts them. They currently read **zeros** until the audio and
Vision engines land (next phase), so the wire is correct but the value is 0. Body Region masks are
the first to go live with the Vision pass.
