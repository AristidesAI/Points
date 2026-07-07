---
title: Shockwave
parent: Move Nodes
grand_parent: Node Reference
layout: default
nav_order: 8
---
# Shockwave

**ID** `shockwave` · **Family** MOVE · **GPU** (interpreterOp)

Expanding rings fired by triggers. Up to 4 active waves.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `speed` | 0 – 4 | 1.2 | Expansion speed |
| `width` | 0 – 0.6 | 0.12 | Ring thickness |
| `damping` | 0 – 6 | 1.2 | Decay rate |

| Port | Direction | Type |
|------|-----------|------|
| `fire` | input | trigger |
| `pulse` | output | fieldFloat |

## Trigger: Beat → Shockwave

```mermaid
graph TD
    beat[Beat Detect] --> sw[Shockwave<br/>fire port]
    sw -->|pulse| dd[Depth Drive<br/>gain exposed]
```
