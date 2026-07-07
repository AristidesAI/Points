---
title: Confidence
parent: Source Nodes
grand_parent: Node Reference
layout: default
nav_order: 4
---

# Confidence

**ID** `confidence` · **Family** SOURCE · **GPU** (interpreterOp)

Per-pin sensor confidence 0–1. Noisy edges score low. Reads 1.0 until the confidence texture is bound.

## Parameters

| Param | Range | Default | Description |
|-------|-------|---------|-------------|
| `floor` | 0 – 1 | 0 | Values below clamped to 0 |

## Ports

| Port | Direction | Type | Description |
|------|-----------|------|-------------|
| `confidence` | output | fieldFloat | Confidence 0–1 |

## Standard Use: Confidence → Hide

```mermaid
graph LR
    conf[Confidence<br/>floor: 0.3] -->|confidence| hide[Hide<br/>mode: fade]
    hide -->|size| size[Size]
```

Low-confidence edge pixels fade away for cleaner silhouettes.
