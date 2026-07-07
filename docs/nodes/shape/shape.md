---
title: Shape
parent: Shape Nodes
grand_parent: Node Reference
layout: default
nav_order: 2
---

# Shape

**ID** `shape` · **Family** SHAPE · **GPU** (interpreterOp)

Pin cap geometric form. Changes the visual appearance of every point.

## Parameters

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `type` | sphere / cube / tube / slab / cone / ring / disc / spike / diamond | sphere | Pin shape |

## Ports

| Port | Direction | Type | Description |
|------|-----------|------|-------------|
| `shape` | output | fieldFloat | Shape index (wire to Output.shape) |

## Standard Use: Shape + Spin

```mermaid
graph LR
    shape[Shape<br/>type:cube] -->|shape| output[Output.shape]
    spin[Spin<br/>z:0.5] -->|rot| output[Output.rotation]
```

Use a non-sphere shape with Spin to see rotation visibly.
