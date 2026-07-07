---
title: Palette
parent: Color Nodes
grand_parent: Node Reference
layout: default
nav_order: 1
---
# Palette

**ID** `palette` · **Family** COLOR · **GPU** (interpreterOp)

Maps any 0–1 value through a color lookup table. The primary colorization node.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `map` | thermal / viridis / plasma / inferno / magma / cividis / turbo / coolwarm | thermal | Color gradient |
| `shift` | −1 – 1 | 0 | Hue shift |

| Port | Direction | Type |
|------|-----------|------|
| `t` | input | fieldFloat |
| `color` | output | fieldColor |

```mermaid
graph LR
    depth[Depth] -->|depth| palette[Palette<br/>map:viridis]
    palette -->|color| output[Output.color]
```
