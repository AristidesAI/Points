---
title: Grid Info
parent: Grid Nodes
grand_parent: Node Reference
layout: default
nav_order: 1
---

# Grid Info

**ID** `grid-info` · **Family** GRID · **GPU** (interpreterOp)

Per-pin identity constants: UV coordinates, normalized index, stable hash, and distance from center. Foundation values used by most FX nodes for per-pin variation.

## Ports

| Port | Direction | Type | Description |
|------|-----------|------|-------------|
| `uv` | output | fieldVec3 | UV coordinate 0–1 |
| `index` | output | fieldFloat | Normalized pin index 0–1 |
| `hash` | output | fieldFloat | Stable per-pin random 0–1 |
| `centerDist` | output | fieldFloat | Distance from view center 0–1 |
