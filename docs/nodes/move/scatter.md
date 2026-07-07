---
title: Scatter
parent: Move Nodes
grand_parent: Node Reference
layout: default
nav_order: 6
---
# Scatter

**ID** `scatter` · **Family** MOVE · **GPU** (interpreterOp)

Throws each pin along its seeded random direction. Amount 0 = home.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `amount` | 0 – 1 | 0 | Scatter strength |
| `seed` | 0 – 9999 | 3 | Random seed |

| Port | Direction | Type |
|------|-----------|------|
| `amount` | input | fieldFloat |
| `offset` | output | fieldVec3 |

## Trigger: Pinch → Scatter

```mermaid
graph TD
    pinch[Pinch] --> remap[t-Remap<br/>outMin:0 outMax:1]
    remap --> scatter[Scatter<br/>amount exposed]
```
