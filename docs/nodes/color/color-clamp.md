---
title: Color Clamp
parent: Color Nodes
grand_parent: Node Reference
layout: default
nav_order: 8
---
# Color Clamp

**ID** `color-clamp` · **Family** COLOR · **GPU** (interpreterOp)

Clips every channel to [low, high].

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `low` | 0 – 1 | 0 | Black floor |
| `high` | 0 – 1 | 1 | White ceiling |

| Port | Direction | Type |
|------|-----------|------|
| `color` | input | fieldColor |
| `out` | output | fieldColor |
