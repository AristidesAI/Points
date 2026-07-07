---
title: Depth Rings
parent: Grid Nodes
grand_parent: Node Reference
layout: default
nav_order: 10
---

# Depth Rings

**ID** `depth-rings` · **Family** GRID · **GPU** (interpreterOp)

Sinusoidal contour lines rippling through depth.

## Parameters

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `frequency` | 1 – 60 | 18 | Ring density |
| `sharpness` | 1 – 8 | 2 | Ring edge sharpness |

## Ports

| Port | Direction | Type | Description |
|------|-----------|------|-------------|
| `depth` | input | fieldFloat | Depth field |
| `rings` | output | fieldFloat | Contour value 0–1 |
