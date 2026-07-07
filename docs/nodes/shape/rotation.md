---
title: Rotation
parent: Shape Nodes
grand_parent: Node Reference
layout: default
nav_order: 5
---

# Rotation

**ID** `rotation` · **Family** SHAPE · **GPU** (interpreterOp)

Static per-pin orientation in turns. Use with a non-sphere Shape to see.

## Parameters

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `x` | −0.5 – 0.5 | 0 | X rotation (turns) |
| `y` | −0.5 – 0.5 | 0 | Y rotation (turns) |
| `z` | −0.5 – 0.5 | 0 | Z rotation (turns) |

## Ports

| Port | Direction | Type | Description |
|------|-----------|------|-------------|
| `turns` | input | fieldVec3 | Per-pin rotation |
| `rot` | output | fieldVec3 | Final rotation (wire to Output.rotation) |
