---
title: Pinch
parent: Body Nodes
grand_parent: Node Reference
layout: default
nav_order: 2
---
# Pinch

**ID** `pinch` · **Family** BODY · **CPU** (control)

Hand pinch distance. 0 = fingertips touching.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `gain` | 0 – 4 | 1 | Multiplier |
| `outMin/outMax` | 0 – 10 | 0/10 | Output range (wider than vision) |
| `smoothing` | 0 – 1 | 0 | Smooth |
| `invert` | bool | false | Invert |

| Port | Direction | Type |
|------|-----------|------|
| `distance` | output | signal |

```mermaid
graph TD
    pinch[Pinch<br/>outMin:0 outMax:1] --> scatter[Scatter<br/>amount exposed]
```
