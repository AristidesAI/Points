---
title: Node Reference
layout: default
nav_order: 3
has_children: true
---

# Node Reference

{: .no_toc }

Complete reference for all 110+ nodes in Points, organized by family. Each node page includes parameter breakdowns, example patches with Mermaid diagrams, and trigger modulation examples.

## Node Families

| Family | Category | Count |
|--------|----------|-------|
| [Source](/nodes/source) | Depth, color, and sensor inputs | 6 |
| [Grid](/nodes/grid) | Layout, topology, and spatial organization | 10 |
| [Filter](/nodes/filter) | Depth cleanup, temporal smoothing, upsampling | 8 |
| [Shape](/nodes/shape) | Pin geometry, rotation, stems, materials | 10 |
| [Move](/nodes/move) | Positional transforms, physics, time effects | 9 |
| [Color](/nodes/color) | Palette mapping, color transforms, blending | 12 |
| [Signal](/nodes/signal) | Math ops, noise, trigger logic, envelopes | 30+ |
| [Body](/nodes/body) | Vision tracking, hand gestures, face blendshapes | 12+ |
| [Time](/nodes/time) | LFOs, clocks, beat-synced modulators | 5 |
| [Stage](/nodes/stage) | Camera, lights, background, render settings | 8 |
| [Output & Tools](/nodes/output-tools) | NDI, recording, drive params | 3 |

## How to Read Node Pages

Each node page follows this format:

```
## Node Name

**ID:** `node-id` · **Family:** category · **Execution:** GPU / CPU

Description of what the node does.

### Parameters
| Param | Range | Default | Description |
|-------|-------|---------|-------------|

### Ports
| Port | Direction | Type | Description |

### Example: Use Case
A Mermaid diagram showing a practical patch using the node.

### Trigger Modulation
A Mermaid diagram showing how to drive the node from a trigger/signal.
```
