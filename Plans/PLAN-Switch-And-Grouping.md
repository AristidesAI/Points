# Plan — Switch / Gate nodes & Network Grouping

**Status:** Plan only, awaiting your approval — no code written. Against the FLAT model ([PLAN-Trigger-System.md](PLAN-Trigger-System.md)). Written 2026-07.

## What you asked for

1. A **base/annotation box** (TouchDesigner style) to segregate parts of the network and group repeated node clusters.
2. Contingent on an **Output switcher**: a gate that mirrors Output's 7 inputs (position, z, size, color, rotation, shape, stretch), accepts *many* wires per channel, and lets you pick which one reaches Output — so you flip between whole rendering methods with one tap, with a master "switch all" and a per-wire nav bar that hues the active wire. You also want this switching to work on **any node, not just Output**.

## There is a cleaner way — and it's already half-built

Your instinct (a gate that multiplexes what reaches Output) is right. But a single node that mirrors all 7 Output channels is the hard, rigid version. The flat system already has the pieces for a better one:

- There's an existing **2-way `switch`** node (`a`, `b`, `pick → out`). We generalize *that* instead of inventing a mega-node.
- The flat model already lets one control drive many params at once (expose ◇ → wire one source to many). That *is* your "master switch," for free.

### Recommendation: a generic **N-way Switch** node (not an Output-mirror)

One reusable primitive, placed anywhere:

- **Dynamic inputs.** A Switch starts with `in1`, `in2`; a "＋ input" adds `in3`, `in4`… (same dynamic-port mechanism as the exposed-param ◇ ports). Its type is set by the first wire — a color Switch, a position Switch, a float Switch, all the same node.
- **One output**, wired wherever you want (Output.color, Output.position, a Size node, *anything* — this is why it beats an Output-only gate).
- **`active` index param** — which input passes through. And `active` is a normal param, so you **expose ◇ it and drive it** — a Pad, an LFO, a MIDI note, an If/Then, one tap. That single mechanism gives you: manual pick, one-tap flip, automated switching, and logic-driven switching, with nothing new.
- **Active-wire hue** (your nav-bar idea) — the active input port and its incoming wire render in an accent hue; the others dim. Reads at a glance which branch is live.

**Master / "switch everything at once":** you drop one Switch per channel you want to flip (Color Switch → Output.color, Position Switch → Output.position, …), then wire **one control** (a Pad, or a small **Scene** control that outputs an index) into all their exposed `active` ports. One tap moves them together. No monolithic node, and it composes to *any* subset of channels — not just Output's 7.

**Why this is better than the mirror-Output node**
- Generic and reusable — works on every node/channel, which is exactly what you said you ultimately want.
- Reuses machinery that already exists (dynamic ports + expose-and-drive) instead of a bespoke 7-channel node.
- Type-safe per instance; no "which of 7 rows am I wiring" confusion.
- The "master" falls out of the flat model instead of being a special mode.

### Compiler story (how the switch actually flips)

- **Default — recompile-on-switch.** Only the *active* branch compiles; changing `active` recompiles (µs, like the existing option-flip `driveOption`). Zero wasted GPU on inactive branches. Perfect for scene/method switching (occasional, one-tap). This is the lazy-correct default.
- **Upgrade path — runtime crossfade.** If you later want to *blend/rapidly modulate* between methods (not just hard-cut), compile all branches and select/mix live with a patched index. More GPU, instant/smooth. Add only if hard-cut proves too limiting. `// ponytail: hard-cut first; live mux only if crossfade is needed.`

## Grouping — keep it visual, don't reintroduce sub-graphs

Two different things hide under "base COMP":
1. **Visual segregation** — a labeled box behind a cluster of nodes so you can see and move "the color rig" as a unit.
2. **Encapsulation** — collapse a subnetwork into one node.

We just *removed* nested sub-graphs (the trigger view) to make the app simpler. Reintroducing collapsible COMPs would walk that back. Your real need reads as **segregation**, which the visual box gives without any graph-architecture change:

### Recommendation: **Annotation Box** (upgrade the existing no-op Sticky Note)
- A resizable, labeled, tinted rectangle that sits *behind* nodes. Give it a title + color.
- **Dragging the box moves every node inside it** (group-move) — that's the "group repeated clusters" behavior, cheaply.
- Purely an editor object (position, size, title, color); it does not touch compilation. Stored on the Graph like nodes.
- Snap-select: tap the box header to select all nodes it contains (then Switch/duplicate/delete them together).

Encapsulation-into-one-node is deferred — if you genuinely want collapsible COMPs later, that's a separate, bigger decision we take deliberately (not as a side effect of grouping).

## How they compose (the workflow you described)

1. Build "Method A" (a cluster of color/shape/motion nodes) inside an **Annotation Box** titled "A".
2. Build "Method B" in another box.
3. Feed both boxes' outputs into per-channel **Switch** nodes before Output.
4. Expose each Switch's `active`, wire one **Pad/Scene** control to all of them → one tap swaps A↔B across every channel, active branch hued.

## Phasing (once approved)
1. **N-way Switch** — generalize the existing `switch`: dynamic inputs, `active` index (drivable/exposable), recompile-on-switch, active-port hue. The keystone.
2. **Scene control** (optional) — a tiny node/pad that outputs an index to drive many Switches together.
3. **Annotation Box** — Sticky Note → resizable labeled frame + group-move + contains-select.

Each builds + is testable alone.

## Open questions
1. **Switch type-locking:** lock a Switch to the first wire's type (a color Switch rejects a float wire), or allow mixed? (Lean: lock to first wire — clearest.)
2. **Hard-cut vs crossfade** for v1? (Lean: hard-cut / recompile-on-switch; add crossfade later only if needed.)
3. **Annotation Box vs new node:** upgrade the existing Sticky Note in place, or add a separate "Group Box"? (Lean: upgrade Sticky Note — one grouping object.)
4. **Master switching:** a dedicated **Scene** node, or just document "wire one Pad to every Switch's active"? (Lean: ship the plain wire-one-to-many first; add a Scene node if it's used a lot.)
5. Do you still want a convenience **"Output Switch"** preset (a Switch pre-wired to all 7 Output channels) on top of the generic node, for the common case? (Lean: skip until the generic one is in hand.)
