---
title: Head Pose
parent: Body Nodes
grand_parent: Node Reference
layout: default
nav_order: 4
---
# Head Pose

**ID** `head-pose` · **Family** BODY · **CPU** (control)

Head orientation from TrueDepth camera.

| Port | Direction | Type |
|------|-----------|------|
| `yaw` | output | signal |
| `pitch` | output | signal |
| `roll` | output | signal |

```mermaid
graph TD
    head[Head Pose] -->|yaw| camera[Camera<br/>orbitX exposed]
    head -->|pitch| camera
```
