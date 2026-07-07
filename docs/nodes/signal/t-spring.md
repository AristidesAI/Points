---
title: Spring (CPU)
parent: Signal Nodes
grand_parent: Node Reference
layout: default
nav_order: 28
---
# Spring (CPU)

**ID** `t-spring` · **Family** SIGNAL · **CPU** (control)

Physical follow toward target with overshoot/settle.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `stiffness` | 1 – 300 | 120 | Spring constant |
| `damping` | 1 – 40 | 18 | Damping |

| Port | Direction | Type |
|------|-----------|------|
| `target` | input | signal |
| `out` | output | signal |
