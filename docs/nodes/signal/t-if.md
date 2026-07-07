---
title: If / Then
parent: Signal Nodes
grand_parent: Node Reference
layout: default
nav_order: 20
---
# If / Then

**ID** `t-if` · **Family** SIGNAL · **CPU** (control)

If COND > 0.5 pass A, else B. Core conditional logic.

| Port | Direction | Type |
|------|-----------|------|
| `cond` | input | signal |
| `a` | input | signal |
| `b` | input | signal |
| `out` | output | signal |

```mermaid
graph TD
    volume[Audio Volume] --> threshold[t-Threshold<br/>rise:0.6]
    threshold --> ifnode[t-If / Then]
    depth[Depth.depth] -->|a| ifnode
    constant[Constant 0] -->|b| ifnode
```
