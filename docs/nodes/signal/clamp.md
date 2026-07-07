---
title: Clamp
parent: Signal Nodes
grand_parent: Node Reference
layout: default
nav_order: 8
---
# Clamp

**ID** `clamp` · **Family** SIGNAL · **GPU** (interpreterOp)

Clamps input to [min, max].

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `min` | −4 – 4 | 0 | Lower bound |
| `max` | −4 – 4 | 1 | Upper bound |

| Port | Direction | Type |
|------|-----------|------|
| `in` | input | fieldFloat |
| `out` | output | fieldFloat |
