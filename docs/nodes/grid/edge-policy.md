---
title: Edge Policy
parent: Grid Nodes
grand_parent: Node Reference
layout: default
nav_order: 8
---

# Edge Policy

**ID** `edge-policy` · **Family** GRID · **Render** (render-read)

Controls what happens when warps push pins past the frame border.

## Parameters

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `mode` | none / fade / clamp | fade | FADE: shrink at edge; CLAMP: pile up; NONE: fly out |
| `margin` | 0 – 0.3 | 0.05 | Edge transition zone width |
