---
title: Freeze
parent: Move Nodes
grand_parent: Node Reference
layout: default
nav_order: 9
---
# Freeze

**ID** `freeze` · **Family** MOVE · **GPU** (interpreterOp)

While hold is up, each pin keeps its captured value. Release melts to live.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `hold` | 0 – 1 | 0 | Freeze amount |

| Port | Direction | Type |
|------|-----------|------|
| `in` | input | fieldFloat |
| `out` | output | fieldFloat |

## Trigger: Fist → Freeze

```mermaid
graph TD
    fist[Gestures.fist] --> freeze[Freeze<br/>hold exposed]
```
