---
title: Rect Region
parent: Grid Nodes
grand_parent: Node Reference
layout: default
nav_order: 6
---

# Rect Region

**ID** `region-rect` · **Family** GRID · **GPU** (interpreterOp)

Soft rectangular mask in view space: 1 inside, 0 outside.

## Parameters

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `width` | 0.1 – 3 | 1.5 | Box width in UV |
| `height` | 0.1 – 4 | 2 | Box height in UV |
| `feather` | 0.01 – 1 | 0.2 | Edge softness |
| `invert` | bool | false | Invert mask |

## Ports

| Port | Direction | Type | Description |
|------|-----------|------|-------------|
| `center` | input | vec2 | Center UV |
| `mask` | output | fieldFloat | Soft mask 0–1 |
