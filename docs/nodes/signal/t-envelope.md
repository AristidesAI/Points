---
title: Envelope
parent: Signal Nodes
grand_parent: Node Reference
layout: default
nav_order: 26
---
# Envelope

**ID** `t-envelope` · **Family** SIGNAL · **CPU** (control)

Trigger → smooth 0–1. Rises while trigger held, falls when released.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `attack` | 0.001 – 3 | 0.05 | Rise time (seconds) |
| `release` | 0.005 – 6 | 0.35 | Fall time (seconds) |

| Port | Direction | Type |
|------|-----------|------|
| `trig` | input | trigger |
| `out` | output | signal |
