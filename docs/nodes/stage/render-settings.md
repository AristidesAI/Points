---
title: Render Settings
parent: Stage Nodes
grand_parent: Node Reference
layout: default
nav_order: 4
---
# Render Settings

**ID** `render-settings` · **Family** STAGE · **Render** (render-read)

Global render toggles and post-processing.

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `ghost` | bool | false | Additive ghost blending |
| `pointCount` | 1000 – 200000 | 30000 | Active pin count |
| `pinSize` | 0.001 – 0.1 | 0.012 | Default pin size |
| `bloom` | bool | false | Bloom glow |
| `bloomIntensity` | 0 – 3 | 1 | Bloom brightness |
| `bloomRadius` | 0 – 20 | 6 | Bloom spread (px) |
| `vignette` | 0 – 1 | 0 | Edge darkening |
| `grain` | 0 – 1 | 0 | Film grain |
