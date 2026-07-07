---
title: Sine
parent: Signal Nodes
grand_parent: Node Reference
layout: default
nav_order: 10
---
# Sine

**ID** `sine` · **Family** SIGNAL · **GPU** (interpreterOp)

sin(in × freq + phase), normalized 0–1.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `frequency` | 0 – 40 | 6 | Frequency multiplier |
| `phase` | −6.28 – 6.28 | 0 | Phase offset |

| Port | Direction | Type |
|------|-----------|------|
| `in` | input | fieldFloat |
| `out` | output | fieldFloat |
