---
title: Lag
parent: Move Nodes
grand_parent: Node Reference
layout: default
nav_order: 2
---
# Lag

**ID** `lag` · **Family** MOVE · **GPU** (interpreterOp)

Exponential smoothing over time. One float of state per pin.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `halfLife` | 0 – 5 | 0 | Half-life (seconds). 0 = passthrough |

| Port | Direction | Type |
|------|-----------|------|
| `in` | input | fieldFloat |
| `out` | output | fieldFloat |

```mermaid
graph LR
    depth[Depth] -->|depth| lag[Lag<br/>halfLife:0.3]
    lag -->|out| dd[Depth Drive]
```
