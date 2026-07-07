---
title: Threshold (Trigger)
parent: Signal Nodes
grand_parent: Node Reference
layout: default
nav_order: 25
---
# Threshold (Trigger)

**ID** `t-threshold` · **Family** SIGNAL · **CPU** (control)

Schmitt trigger: fires when level crosses RISE; re-arms below FALL.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `rise` | 0 – 1 | 0.6 | Fire threshold |
| `fall` | 0 – 1 | 0.4 | Re-arm threshold |
| `cooldown` | 0 – 2 | 0.08 | Min time between fires |

| Port | Direction | Type |
|------|-----------|------|
| `level` | input | signal |
| `fired` | output | trigger |

```mermaid
graph TD
    volume[Audio Volume] --> threshold[t-Threshold<br/>rise:0.6 fall:0.4]
    threshold --> envelope[t-Envelope<br/>attack:0.02 release:0.3]
```
