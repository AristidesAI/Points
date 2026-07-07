---
title: Light
parent: Stage Nodes
grand_parent: Node Reference
layout: default
nav_order: 2
---
# Light

**ID** `light` · **Family** STAGE · **Render** (render-read)

Point, directional, or spot light. Up to 4 active. Requires Material in "lit" mode.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `type` | point / directional / spot | point | Light type |
| `intensity` | 0 – 5 | 1 | Brightness |
| `falloff` | 0 – 10 | 2 | Distance falloff |
| `x/y/z` | −3 – 3 | 0/0/3 | Position or direction |
| `enabled` | bool | true | Toggle |
