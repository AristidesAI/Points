---
title: Camera
parent: Stage Nodes
grand_parent: Node Reference
layout: default
nav_order: 1
---
# Camera

**ID** `camera` · **Family** STAGE · **Render** (render-read)

Viewport camera: field of view, zoom, parallax, orbit.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `fov` | 10 – 120 | 55 | Field of view (degrees) |
| `zoom` | 0.1 – 4 | 1 | Zoom level |
| `parallax` | 0 – 1 | 0.5 | Perspective strength |
| `depthPush` | 0 – 3 | 1 | Z exaggeration |
| `centerX/Y` | −1 – 1 | 0 | Pivot offset |
| `orbitX/Y` | −π – π | 0 | Orbit (radians) |
| `dolly` | −1 – 1 | 0 | Eye distance |
