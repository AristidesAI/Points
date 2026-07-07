---
title: Face Blendshapes
parent: Body Nodes
grand_parent: Node Reference
layout: default
nav_order: 5
---
# Face Blendshapes

**ID** `face-blendshapes` · **Family** BODY · **CPU** (control)

52 ARKit blendshape coefficients from TrueDepth.

| Key Ports | Description |
|-----------|-------------|
| `jawOpen` | Jaw openness |
| `mouthSmile` | Smile amount |
| `eyeBlinkLeft/Right` | Eye blink |
| `browDownLeft/Right` | Brow furrow |
| `mouthPucker` | Pucker |

```mermaid
graph TD
    face[Face Blendshapes] -->|jawOpen| size[Size<br/>base exposed]
    face -->|mouthSmile| palette[Palette<br/>shift exposed]
```
