---
title: Random
parent: Signal Nodes
grand_parent: Node Reference
layout: default
nav_order: 14
---
# Random

**ID** `random` · **Family** SIGNAL · **GPU** (interpreterOp)

Stable per-pin random 0–1. Same every frame until reseeded.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `seed` | 0 – 9999 | 1 | Random seed |
| `contrast` | 0.25 – 4 | 1 | Distribution shape |
| `amount` | 0 – 1 | 1 | Spread from 0.5 |

| Port | Direction | Type |
|------|-----------|------|
| `out` | output | fieldFloat |
