---
title: Look At
parent: Shape Nodes
grand_parent: Node Reference
layout: default
nav_order: 7
---

# Look At

**ID** `look-at` · **Family** SHAPE · **Render** (render-read)

Orients every pin to face a target point. Needs a non-sphere Shape to be visible.

## Parameters

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `x` | −2 – 2 | 0 | Look target X |
| `y` | −2 – 2 | 0 | Look target Y |
| `z` | 0 – 4 | 2 | Look target Z |
| `amount` | 0 – 1 | 1 | Blend strength |

## Trigger: Hand → Look At

```mermaid
graph TD
    hand[Hand Position] -->|x| remap[t-Remap<br/>outMin:-2 outMax:2]
    remap --> look[Look At<br/>x exposed]
    hand -->|y| remap2[t-Remap<br/>outMin:-2 outMax:2]
    remap2 --> look
```
