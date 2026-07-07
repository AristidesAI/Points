---
title: Home
layout: default
nav_order: 1
---

# POINTS

**Visual LiDAR Synthesizer** — A live point cloud instrument. Wire 110+ GPU nodes together. Modulate with audio, MIDI, OSC, and gestures. Create real-time Metal-rendered visuals from LiDAR, TrueDepth, or RGB camera sources.

---

[GET STARTED](/getting-started){: .btn }
[NODE REFERENCE](/nodes){: .btn }
[INTEGRATIONS](/integrations){: .btn }

---

## How It Works

```
DEPTH SOURCE  →  CLEANUP  →  FX PIPELINE  →  PINOUT  →  RENDER (60fps)
    ↑                            ↑
 LiDAR / TrueDepth / RGB    Audio / MIDI / OSC / Vision
```

Points never leave the GPU. The Metal renderer fetches directly from a 24-byte interleaved buffer — no CPU readback, no frame drops at 200,000 points.

## Three Camera Modes

| Mode | Sensor | FPS | Character |
|------|--------|-----|-----------|
| CLOUD | Back LiDAR `.sceneDepth` | 30 | True metric 3D depth — real size at any distance |
| FACE | Front TrueDepth | 30 | Face mesh + 52 blendshape mod sources |
| LUMEN | Back RGB luma-as-depth | 60 | Flat grid projection — stable pin identity for per-pin history FX |

## Node Families

<div class="op-menu" markdown="1">

<div class="op-category" markdown="1">
<div class="op-category-header">SOURCE</div>
[Depth](/nodes/source/depth){: .op-link }
[Video Color](/nodes/source/video-color){: .op-link }
[Vision Model](/nodes/source/vision-model){: .op-link }
[Confidence](/nodes/source/confidence){: .op-link }
[Proximity](/nodes/source/proximity){: .op-link }
</div>

<div class="op-category" markdown="1">
<div class="op-category-header">GRID</div>
[Grid Info](/nodes/grid/grid-info){: .op-link }
[Pinout](/nodes/grid/pinout){: .op-link }
[Domain](/nodes/grid/domain){: .op-link }
[Jitter](/nodes/grid/jitter){: .op-link }
[Ellipse Region](/nodes/grid/region-ellipse){: .op-link }
[Rect Region](/nodes/grid/region-rect){: .op-link }
[UV Transform](/nodes/grid/uv-transform){: .op-link }
[Edge Policy](/nodes/grid/edge-policy){: .op-link }
[Depth Bands](/nodes/grid/depth-bands){: .op-link }
[Depth Rings](/nodes/grid/depth-rings){: .op-link }
</div>

<div class="op-category" markdown="1">
<div class="op-category-header">FILTER</div>
[Grazing Cull](/nodes/filter/grazing-cull){: .op-link }
[Apple Depth Filter](/nodes/filter/apple-depth-filter){: .op-link }
[EMA Smooth](/nodes/filter/ema-smooth){: .op-link }
[Fill Holes](/nodes/filter/fill-holes){: .op-link }
[Accumulate](/nodes/filter/accumulate){: .op-link }
[Smooth Surface](/nodes/filter/smooth-surface){: .op-link }
[Despeckle Voxel](/nodes/filter/despeckle-voxel){: .op-link }
[Detail Upsample](/nodes/filter/detail-upsample){: .op-link }
</div>

<div class="op-category" markdown="1">
<div class="op-category-header">SHAPE</div>
[Size](/nodes/shape/size){: .op-link }
[Shape](/nodes/shape/shape){: .op-link }
[Shape Morph](/nodes/shape/shape-morph){: .op-link }
[Stretch](/nodes/shape/stretch){: .op-link }
[Rotation](/nodes/shape/rotation){: .op-link }
[Spin](/nodes/shape/spin){: .op-link }
[Look At](/nodes/shape/look-at){: .op-link }
[Stem](/nodes/shape/stem){: .op-link }
[Material](/nodes/shape/material){: .op-link }
[Hide](/nodes/shape/hide){: .op-link }
</div>

<div class="op-category" markdown="1">
<div class="op-category-header">MOVE</div>
[Depth Drive](/nodes/move/depth-drive){: .op-link }
[Lag](/nodes/move/lag){: .op-link }
[Trail](/nodes/move/trail){: .op-link }
[Ripple](/nodes/move/ripple){: .op-link }
[Spring](/nodes/move/spring){: .op-link }
[Scatter](/nodes/move/scatter){: .op-link }
[Twist](/nodes/move/twist){: .op-link }
[Shockwave](/nodes/move/shockwave){: .op-link }
[Freeze](/nodes/move/freeze){: .op-link }
</div>

<div class="op-category" markdown="1">
<div class="op-category-header">COLOR</div>
[Palette](/nodes/color/palette){: .op-link }
[Light Gradient](/nodes/color/light-gradient){: .op-link }
[Duotone](/nodes/color/duotone){: .op-link }
[Contrast](/nodes/color/contrast){: .op-link }
[Color Invert](/nodes/color/color-invert){: .op-link }
[Color Gamma](/nodes/color/color-gamma){: .op-link }
[Threshold Color](/nodes/color/threshold-color){: .op-link }
[Color Levels](/nodes/color/color-levels){: .op-link }
[Color Clamp](/nodes/color/color-clamp){: .op-link }
[Screen Blend](/nodes/color/screen-blend){: .op-link }
[Depth Fog](/nodes/color/depth-fog){: .op-link }
</div>

<div class="op-category" markdown="1">
<div class="op-category-header">SIGNAL</div>
[Add](/nodes/signal/add){: .op-link }
[Subtract](/nodes/signal/subtract){: .op-link }
[Multiply](/nodes/signal/multiply){: .op-link }
[Divide](/nodes/signal/divide){: .op-link }
[Min](/nodes/signal/min){: .op-link }
[Max](/nodes/signal/max){: .op-link }
[Mix](/nodes/signal/mix){: .op-link }
[Clamp](/nodes/signal/clamp){: .op-link }
[Remap](/nodes/signal/remap){: .op-link }
[Sine](/nodes/signal/sine){: .op-link }
[Smoothstep](/nodes/signal/smoothstep){: .op-link }
[Threshold](/nodes/signal/threshold-field){: .op-link }
[Noise](/nodes/signal/noise){: .op-link }
[Constant](/nodes/signal/constant){: .op-link }
[Random](/nodes/signal/random){: .op-link }
</div>

<div class="op-category" markdown="1">
<div class="op-category-header">TRIGGER</div>
[If / Then](/nodes/signal/t-if){: .op-link }
[And](/nodes/signal/t-and){: .op-link }
[Or](/nodes/signal/t-or){: .op-link }
[Not](/nodes/signal/t-not){: .op-link }
[Threshold](/nodes/signal/t-threshold){: .op-link }
[Envelope](/nodes/signal/t-envelope){: .op-link }
[Curve](/nodes/signal/t-curve){: .op-link }
[Spring](/nodes/signal/t-spring){: .op-link }
[Add (CPU)](/nodes/signal/t-add){: .op-link }
[Multiply (CPU)](/nodes/signal/t-multiply){: .op-link }
[Remap (CPU)](/nodes/signal/t-remap){: .op-link }
</div>

<div class="op-category" markdown="1">
<div class="op-category-header">BODY</div>
[Hand Position](/nodes/body/hand-position){: .op-link }
[Pinch](/nodes/body/pinch){: .op-link }
[Gestures](/nodes/body/gestures){: .op-link }
[Head Pose](/nodes/body/head-pose){: .op-link }
[Face Blendshapes](/nodes/body/face-blendshapes){: .op-link }
</div>

<div class="op-category" markdown="1">
<div class="op-category-header">TIME</div>
[LFO](/nodes/time/lfo){: .op-link }
[Clock](/nodes/time/clock){: .op-link }
</div>

<div class="op-category" markdown="1">
<div class="op-category-header">STAGE</div>
[Camera](/nodes/stage/camera){: .op-link }
[Light](/nodes/stage/light){: .op-link }
[Background](/nodes/stage/background){: .op-link }
[Render Settings](/nodes/stage/render-settings){: .op-link }
</div>

<div class="op-category" markdown="1">
<div class="op-category-header">OUTPUT</div>
[Output](/nodes/output/output){: .op-link }
[NDI](/nodes/output/ndi){: .op-link }
[Record](/nodes/output/record){: .op-link }
</div>

</div>
