---
title: Contrast
parent: Color Nodes
grand_parent: Node Reference
layout: default
nav_order: 4
---
# Contrast

**ID** `contrast` · **Family** COLOR · **GPU** (interpreterOp)

Pushes colors away from mid-grey. Pivots around 0.5.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `amount` | 0 – 3 | 1.4 | 1=unchanged; >1 crunchier; <1 flatter |

| Port | Direction | Type |
|------|-----------|------|
| `color` | input | fieldColor |
| `out` | output | fieldColor |
