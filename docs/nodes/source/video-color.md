---
title: Video Color
parent: Source Nodes
grand_parent: Node Reference
layout: default
nav_order: 2
---

# Video Color

**ID** `video-color` · **Family** SOURCE · **GPU** (interpreterOp)

Samples the RGB camera image at each pin's UV coordinate. Produces per-pin color for routing through color transforms.

## Parameters

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `exposure` | −2 – 2 | 0 | Exposure in stops (2^exposure multiplier) |

## Ports

| Port | Direction | Type | Description |
|------|-----------|------|-------------|
| `color` | output | fieldColor | Camera color at each pin |

## Standard Use: Video Color → Duotone

```mermaid
graph LR
    vc[Video Color<br/>exposure: 0] -->|color| duotone[Duotone<br/>shadow: navy<br/>light: gold]
    duotone -->|color| output[Output]
```

## Trigger Modulation: LFO → Exposure Sweep

```mermaid
graph TD
    lfo[t-LFO<br/>type: sine rate: 0.5] --> remap[t-Remap<br/>outMin: -1 outMax: 1]
    remap --> vc[Video Color<br/>exposure exposed]
```

Slow sine sweeps exposure from −1 to +1 stops — breathing brightness.
