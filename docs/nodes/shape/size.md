---
title: Size
parent: Shape Nodes
grand_parent: Node Reference
layout: default
nav_order: 1
---

# Size

**ID** `size` · **Family** SHAPE · **GPU** (interpreterOp)

Final pin size = base × input, clamped to min/max. Size 0 hides a pin.

## Parameters

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `base` | 0 – 4 | 1 | Base size multiplier |
| `min` | 0 – 2 | 0 | Minimum size |
| `max` | 0.1 – 6 | 3 | Maximum size |

## Ports

| Port | Direction | Type | Description |
|------|-----------|------|-------------|
| `size` | input | fieldFloat | Per-pin size |
| `out` | output | fieldFloat | Final clamped size |

## Standard Use

```mermaid
graph LR
    depth[Depth] -->|depth| remap[Remap<br/>outMin:0.2 outMax:3]
    remap -->|out| size[Size<br/>base:1]
    size -->|out| output[Output.size]
```

## Trigger: Beat → Size Pulse

```mermaid
graph TD
    beat[Beat Detect] --> envelope[t-Envelope<br/>attack:0.02 release:0.15]
    envelope --> remap[t-Remap<br/>outMin:1 outMax:4]
    remap --> size[Size<br/>base exposed]
```
