---
title: Duotone
parent: Color Nodes
grand_parent: Node Reference
layout: default
nav_order: 3
---
# Duotone

**ID** `duotone` · **Family** COLOR · **GPU** (interpreterOp)

Two-tone remap: dark pins take shadow color, bright pins take light color.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `shadowR/G/B` | 0 – 1 | 0.1/0.05/0.3 | Shadow color |
| `lightR/G/B` | 0 – 1 | 1/0.85/0.4 | Light color |

| Port | Direction | Type |
|------|-----------|------|
| `color` | input | fieldColor |
| `color` | output | fieldColor |

```mermaid
graph LR
    vc[Video Color] -->|color| duo[Duotone<br/>shadow:navy light:gold]
    duo -->|color| output[Output.color]
```
