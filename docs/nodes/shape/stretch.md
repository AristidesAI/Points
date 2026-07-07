---
title: Stretch
parent: Shape Nodes
grand_parent: Node Reference
layout: default
nav_order: 4
---

# Stretch

**ID** `stretch` · **Family** SHAPE · **GPU** (interpreterOp)

Per-axis pin scale — stretch points into tubes, needles, or slabs.

## Parameters

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `x` | 0.1 – 4 | 1 | X-axis stretch |
| `y` | 0.1 – 4 | 1 | Y-axis stretch |
| `z` | 0.1 – 4 | 1 | Z-axis stretch |

## Ports

| Port | Direction | Type | Description |
|------|-----------|------|-------------|
| `scale` | output | fieldVec3 | Per-axis scale (wire to Output.stretch) |
