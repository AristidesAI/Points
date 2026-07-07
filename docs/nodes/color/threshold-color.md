---
title: Threshold Color
parent: Color Nodes
grand_parent: Node Reference
layout: default
nav_order: 9
---
# Threshold Color

**ID** `threshold-color` · **Family** COLOR · **GPU** (interpreterOp)

Two flat colors split at a brightness level. High-contrast poster effect.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `level` | 0 – 1 | 0.5 | Split point |
| `darkR/G/B` | 0 – 1 | 0/0/0.15 | Below-threshold |
| `liteR/G/B` | 0 – 1 | 1/0.95/0.8 | Above-threshold |

| Port | Direction | Type |
|------|-----------|------|
| `color` | input | fieldColor |
| `color` | output | fieldColor |
