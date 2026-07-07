---
title: Twist
parent: Move Nodes
grand_parent: Node Reference
layout: default
nav_order: 7
---
# Twist

**ID** `twist` · **Family** MOVE · **GPU** (interpreterOp)

Whirlpools pin positions around the view center.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `angle` | −0.5 – 0.5 | 0 | Twist (turns) |
| `falloff` | 0 – 4 | 0.8 | Radial falloff |

| Port | Direction | Type |
|------|-----------|------|
| `angle` | input | fieldFloat |
| `offset` | output | fieldVec3 |
