---
title: Ellipse Region
parent: Grid Nodes
grand_parent: Node Reference
layout: default
nav_order: 5
---

# Ellipse Region

**ID** `region-ellipse` · **Family** GRID · **GPU** (interpreterOp)

Soft circular mask in view space: 1 inside, 0 outside.

## Parameters

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `radius` | 0.02 – 1 | 0.3 | Circle radius in UV |
| `feather` | 0 – 0.5 | 0.12 | Edge softness |
| `invert` | bool | false | Invert (hole vs spotlight) |

## Ports

| Port | Direction | Type | Description |
|------|-----------|------|-------------|
| `center` | input | vec2 | Center UV (default 0.5,0.5) |
| `mask` | output | fieldFloat | Soft mask 0–1 |

## Standard Use: Region → Hide

```mermaid
graph LR
    ellipse[Ellipse Region<br/>radius:0.4] -->|mask| hide[Hide<br/>mode:fade]
    hide -->|size| size[Size]
```

## Trigger: Hand → Region Center

```mermaid
graph TD
    hand[Hand Position] -->|x| ellipse[Ellipse Region<br/>center exposed]
    hand -->|y| ellipse
```
