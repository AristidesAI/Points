---
title: Spring
parent: Move Nodes
grand_parent: Node Reference
layout: default
nav_order: 5
---
# Spring

**ID** `spring` · **Family** MOVE · **GPU** (interpreterOp)

Physical spring simulation per pin. Position + velocity state — wobbles with overshoot.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `stiffness` | 0 – 40 | 0 | Spring constant. 0 = off |
| `damping` | 0 – 2 | 0.7 | Damping |

| Port | Direction | Type |
|------|-----------|------|
| `target` | input | fieldFloat |
| `out` | output | fieldFloat |
