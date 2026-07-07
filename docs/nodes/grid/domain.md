---
title: Domain
parent: Grid Nodes
grand_parent: Node Reference
layout: default
nav_order: 3
---

# Domain

**ID** `domain` · **Family** GRID · **Render** (render-read)

The pin lattice topology. Determines how pins are arranged across the viewport.

## Parameters

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `topologyA` | rect / hex / radial / spiral / scatter / perspective | rect | Primary topology |
| `topologyB` | rect / hex / radial / spiral / scatter / perspective | radial | Secondary (morph target) |
| `morphAmount` | 0 – 1 | 0 | Blend A→B |

## Topology Types

| rect | Standard rectangular grid |
| hex | Honeycomb — odd rows offset |
| radial | Concentric rings |
| spiral | Sunflower (Fermat) spiral |
| scatter | Random distribution |
| perspective | Vanishing-point projected |

## Trigger Modulation: Gesture → Topology Snap

```mermaid
graph TD
    fist[Gestures.fist] --> envelope[t-Envelope<br/>attack:0.1 release:0.8]
    envelope --> domain[Domain<br/>morphAmount exposed]
```
