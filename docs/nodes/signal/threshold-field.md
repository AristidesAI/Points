---
title: Threshold (Field)
parent: Signal Nodes
grand_parent: Node Reference
layout: default
nav_order: 12
---
# Threshold (Field)

**ID** `threshold` · **Family** SIGNAL · **GPU** (interpreterOp)

Step function: 1 if in ≥ level, else 0.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `level` | 0 – 1 | 0.5 | Threshold |

| Port | Direction | Type |
|------|-----------|------|
| `in` | input | fieldFloat |
| `out` | output | fieldFloat |
