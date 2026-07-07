---
title: Color Gamma
parent: Color Nodes
grand_parent: Node Reference
layout: default
nav_order: 5
---
# Color Gamma

**ID** `color-gamma` · **Family** COLOR · **GPU** (interpreterOp)

Per-channel gamma power curve.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `gamma` | 0.2 – 4 | 1 | <1 lifts shadows; >1 deepens |

| Port | Direction | Type |
|------|-----------|------|
| `color` | input | fieldColor |
| `out` | output | fieldColor |
