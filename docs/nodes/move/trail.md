---
title: Trail
parent: Move Nodes
grand_parent: Node Reference
layout: default
nav_order: 3
---
# Trail

**ID** `trail` · **Family** MOVE · **GPU** (interpreterOp)

Peak-hold with decay: rises instantly, falls slowly. Glowing afterimages.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `decay` | 0 – 10 | 1.5 | Decay speed. 0 = instant |

| Port | Direction | Type |
|------|-----------|------|
| `in` | input | fieldFloat |
| `out` | output | fieldFloat |
