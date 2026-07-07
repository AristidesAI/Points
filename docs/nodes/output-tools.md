---
title: Output & Tools
layout: default
parent: Node Reference
nav_order: 10
---

# Output & Tools Nodes

{: .no_toc }

Output nodes are the final sinks — they send the rendered point cloud to the screen, NDI stream, or MP4 file. Tools nodes provide utility functions.

## Table of contents
{: .text-delta }
- TOC
{:toc}

---

## Output

**ID:** `output` · **Family:** output · **Execution:** render

The final render sink. Everything must route through Output to appear on screen.

### Ports

| Port | Direction | Type | Description |
|------|-----------|------|-------------|
| `position` | input | fieldVec3 | Final point positions |
| `z` | input | fieldFloat | Final Z push |
| `color` | input | fieldColor | Final per-pin color |
| `size` | input | fieldFloat | Final per-pin size |
| `shape` | input | fieldFloat | Pin shape index |
| `rotation` | input | fieldVec3 | Pin rotation |
| `stretch` | input | fieldVec3 | Per-axis stretch |

{: .note }
The Output node is always present in every graph. You don't need to add it — just wire into its ports from the palette or by exposing them.

---

## NDI

**ID:** `ndi` · **Family:** output · **Execution:** render

Streams the rendered viewport as an NDI video source. High-quality, low-latency network video for live production.

### Parameters

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `streamName` | text | "Points" | Name visible to NDI receivers |
| `fps` | 30 / 60 | 30 | Stream frame rate |
| `alphaKey` | bool | true | Transparent background for compositing |

### Example: NDI Workflow

```mermaid
graph LR
    P[Points<br/>NDI Node] -->|"NDI Stream"| OBS[OBS Studio]
    OBS -->|"RTMP"| TWITCH[Twitch / YouTube]
```

---

## Record

**ID:** `record` · **Family:** output · **Execution:** render

Records the viewport to an H.264 MP4 file saved to the Photos library.

### Parameters

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `fps` | 30 / 60 | 30 | Recording frame rate |
| `quality` | low / medium / high | high | Encoding quality |

---

## Drive Param

**ID:** `trigger-drive` · **Family:** tools · **Execution:** CPU (control)

{: .warning }
**Hidden from palette.** This node routes a value into one of its host node's sliders. Obsolete now that you can wire directly into exposed params.

### Parameters

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `target` | param name | base | Which slider to drive |
| `mode` | offset / replace / multiply | offset | How to combine with the slider value |
| `amount` | −4–4 | 1 | Scale on the incoming value |
