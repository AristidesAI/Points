---
title: Light Gradient
parent: Color Nodes
grand_parent: Node Reference
layout: default
nav_order: 2
---
# Light Gradient

**ID** `light-gradient` · **Family** COLOR · **GPU** (interpreterOp)

Maps how bright each pin's camera color is onto a colormap.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `map` | palette names | thermal | Color map |
| `intensity` | 0 – 3 | 1 | Brightness multiplier |

| Port | Direction | Type |
|------|-----------|------|
| `color` | input | fieldColor |
| `color` | output | fieldColor |
