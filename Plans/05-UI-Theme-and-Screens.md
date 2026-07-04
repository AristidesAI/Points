# Points — UI Theme & Screens

To be validated in the HTML/CSS mockup BEFORE any Swift. Decisions from Q&A rounds 8, 14, 15, 19, 20.

---

## 1. Theme — "Workbench Gray" (dual theme, Blender-like)

| Token | Dark (default) | Light |
|---|---|---|
| canvas / chrome bg | `#474646` base; panels `#3A3939`; canvas `#404040` | `#BCBCBC` base; panels `#C9C9C9`; canvas `#B4B4B4` |
| viewport | true black `#000` always (the stage is sacred, both themes) | `#000` |
| text primary / secondary | `#EDEDED` / `#A8A8A8` | `#1E1E1E` / `#4A4A4A` |
| hairlines / node outlines | 1px `#5C5B5B` | 1px `#8F8F8F` |
| accent (selection, active) | electric cyan (P3) — final value in mockup | same |
| danger/record | `#FF453A` | same |

- Node **family colors** (header bars + wire glows + palette tabs): 10 desaturated-but-distinct
  hues at equal perceived lightness — SOURCE red · GRID orange · SHAPE yellow-green · MOVE green ·
  COLOR magenta · SIGNAL white/gray · BODY cyan · TIME violet · STAGE blue · TOOLS neutral. Exact
  values chosen in the mockup with a color-blind check (deuteranopia sim).
- Nodes: 10pt radius, solid header + solid body **when selected/focused**; unselected drop to ~40%
  body opacity with the 1px outline + header color staying crisp (Blender focus model). Over-video
  dim slider shifts the whole balance.
- Wires: 1px core in type color + 2px soft glow; activity pulse; trigger flashes.
- Depth cues: soft 8pt shadows under floating panels (dark theme), none in light.

## 2. Typography

**Decision deferred to mockup** (user: "decide later"). Shortlist to trial in the mockup, all
grotesque ("arial-based"), all strong at tiny sizes with tabular numerals:

1. **Inter** (variable; the safe excellent choice)
2. **Space Grotesk** (more personality; weaker <10pt, fake-tabular via `font-feature-settings`)
3. **Archivo** (condensed axis useful for dense node labels)

Scale (pt): node title 11 · port label 9 · inspector label 12 · value readout 13 tabular ·
deck knob label 10 · section headers 13/semibold · browser card title 14.

## 3. Screens

### 3.1 Browser (launch)
Square-card grid (2-col phone), live thumbnails, name + edited-ago. Top bar: app mark, theme
toggle, settings gear. Row 1: **+ New** card + **Templates shelf** (horizontal, tier chips
Basics/Motion/Body/Music/Wild). Long-press card → context menu (rename/duplicate/delete/share
code). Template cards show a tier badge; opening = instant, **copy-on-edit** fork.

### 3.2 PLAY
Per [02 §4](02-Node-System-and-Editor.md): 3:4 black viewport (status pills top-left: fps · pins ·
thermal; REC dot + elapsed; NDI dot + connection count) · top-right **vertical pill-stack
accordion** (collapsed: one 44pt pill with 3 status dots; expanded: NDI toggle / Record /
Switch Cam / Frame-rate / Settings; tap-away or 6s collapses) · transport strip (PATCH · source
badge · BPM+tap · deck page dots) · deck pages (4×2; knob/fader/pad/XY/picker).

### 3.3 PATCH
Fullscreen canvas over the live render (dim slider on the right edge). Top strip: back-to-PLAY,
breadcrumb (macro depth), undo/redo, frame-all, minimap toggle. Bottom: collapsible inspector
sheet. All interactions per [02 §3](02-Node-System-and-Editor.md).

### 3.4 Import
Sheet: media preview, Indoor/Outdoor segmented ask, quality tier (Best/Fast), trim handles, size +
ETA estimate line, Start. Then: bake progress screen (depth-frame thumbnails filling a strip, fps,
ETA, "keeps running in background" note) → Live Activity when backgrounded.

### 3.5 Permissions
Pre-prompt explainer cards before camera/mic/local-network/Photos-add system prompts. App stays
usable with mic denied (audio nodes read zero, badge on Audio nodes).

## 4. Motion & haptics

- Springs for panel/accordion/palette (`response 0.32-0.45, damping 0.8`); sliders/scrub strictly
  linear. Everything ≤400ms. Reduce Motion → crossfades.
- Haptics (process-lifetime generators — port TDLidar `Haptics.swift`): selection on node/box
  select + snap-connect; light on wire attach; rigid on zero-detents; medium on record start/stop,
  macro latch; success on NDI connect + bake complete.
- 120Hz: editor canvas pans/zooms at ProMotion regardless of render fps setting.

## 5. HTML mockup checklist (next deliverable)

One self-contained page, tabbed: Browser / PLAY / PATCH / Import.
- [ ] Both themes toggle (#474646 / #BCBCBC), font A/B/C switcher (Inter/Space Grotesk/Archivo)
- [ ] PLAY: 3:4 stage placeholder (animated CSS pin-grid illusion), accordion expand, deck page
      with all 5 control types
- [ ] PATCH: 8-10 fake nodes with family colors, selected-vs-translucent states, wires with pulse
      animation, dim slider affecting a fake video layer, inspector sheet collapsed/expanded
- [ ] Node palette overlay (search + family tabs)
- [ ] Import sheet + bake progress
- [ ] Family color-blind sanity strip
Iterate with Ari; lock font + accent + family palette; only then Swift.
