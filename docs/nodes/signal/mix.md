---
title: Mix
parent: Signal Nodes
grand_parent: Node Reference
layout: default
nav_order: 7
---
# Mix

**ID** `mix` · **Family** SIGNAL · **GPU** (interpreterOp)

Linear interpolation: a × (1−t) + b × t.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `t` | 0 – 1 | 0.5 | Blend factor |

| Port | Direction | Type |
|------|-----------|------|
| `a` | input | fieldFloat |
| `b` | input | fieldFloat |
| `out` | output | fieldFloat |
