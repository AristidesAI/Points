---
title: Color Levels
parent: Color Nodes
grand_parent: Node Reference
layout: default
nav_order: 7
---
# Color Levels

**ID** `color-levels` · **Family** COLOR · **GPU** (interpreterOp)

Full tone control: gamma then gain then lift.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `gamma` | 0.2 – 4 | 1 | Power curve |
| `gain` | 0 – 3 | 1 | Multiply |
| `lift` | −0.5 – 0.5 | 0 | Brightness offset |

| Port | Direction | Type |
|------|-----------|------|
| `color` | input | fieldColor |
| `out` | output | fieldColor |
