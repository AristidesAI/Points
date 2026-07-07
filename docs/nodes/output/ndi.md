---
title: NDI
parent: Output Nodes
grand_parent: Node Reference
layout: default
nav_order: 2
---
# NDI

**ID** `ndi` · **Family** OUTPUT · **Render** (render-read)

Streams the rendered viewport as an NDI video source with alpha channel.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `streamName` | text | Points | Name for receivers |
| `fps` | 30 / 60 | 30 | Stream frame rate |
| `alphaKey` | bool | true | Transparent bg |
