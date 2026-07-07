---
title: Clock
parent: Time Nodes
grand_parent: Node Reference
layout: default
nav_order: 2
---
# Clock

**ID** `clock` · **Family** TIME · **CPU** (control)

Global clock with BPM, beat count, and phase.

| Port | Direction | Type |
|------|-----------|------|
| `beat` | output | trigger |
| `bar` | output | trigger |
| `phase` | output | signal |
| `bpm` | output | signal |

```mermaid
graph TD
    clock[Clock<br/>bpm:120] -->|beat| sw[Shockwave<br/>fire port]
    clock -->|bar| palette[Palette<br/>shift exposed]
```
