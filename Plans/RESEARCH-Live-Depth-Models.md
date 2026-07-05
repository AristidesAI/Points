# Research — Live Monocular METRIC Depth Models for iPhone 15 Pro+ (A17+) ANE

For the **Live Depth Model** node (back-camera live depth → point cloud on LiDAR-less phones).
Anchor benchmark: Apple's DA-V2 **Small (relative) F16 CoreML = 33.9 ms on iPhone 15 Pro Max (~29 fps)**.
Every ViT-S / DPT model @~518 is in that ballpark on ANE; ViT-B ≈ 2–3× slower; ViT-L usually < 15 fps.

## Bottom line
- **One** model is video-temporal **AND** metric **AND** commercial **AND** ANE-small:
  **`depth-anything/Metric-Video-Depth-Anything-Small`** (Apache-2.0, ViT-S 28.4M, intrinsics-free,
  true single-frame **streaming** mode). No CoreML exists → convert.
- **Fastest ship-now metric:** convert **DA V2 Metric Small** (VKITTI outdoor 0–80 m / Hypersim indoor
  0–20 m) — Apache, ViT-S, ~30 fps; **we already have the `.pth`** in ~/Downloads.
- Conversion needs a torch + coremltools toolchain (this sandbox can't run it — coremltools native libs
  fail on the local Python). Recipe below.

## Video-specific (temporally consistent) — ranked
| # | Model | Size | Metric | License | Stream | CoreML |
|---|---|---|---|---|---|---|
| 1 | **Metric-Video-Depth-Anything-Small** | ViT-S 28.4M | ✅ | **Apache-2.0** | ✅ | convert |
| 2 | Metric-Video-Depth-Anything-Base | ViT-B 113M | ✅ | CC-BY-NC ❌ | ✅ | — |
| 3 | Video-Depth-Anything-Small | 28.4M | relative | Apache ✅ | ✅ | ONNX/TRT only |
| — | DepthCrafter (diffusion) / FlashDepth (A100) / NVDS / ChronoDepth | heavy | mixed | mixed | — | not mobile-real-time |

## Per-frame metric fallbacks — ranked
| # | Model | Size | Metric | License | ANE ~real-time | CoreML |
|---|---|---|---|---|---|---|
| 1 | **DA V2 Metric Small — VKITTI / Hypersim** | 24.8M | ✅ scene-specific | **Apache** | ~30 fps | have `.pth`, convert |
| 2 | MoGe-2 ViT-B (**bundled, in use**) | 104M | ✅ point map | **MIT** | ~10–15 fps | ✅ have it |
| 3 | MoGe-2 ViT-S (`vits-normal`) | 35M | ✅ | MIT | likely ✅ | convert |
| 4 | Metric3D v2 ViT-S | ViT-S | ✅ (needs intrinsics) | CC0/BSD ✅ | yes if trimmed | ONNX only |
| 5 | DA3METRIC-LARGE | ViT-L 0.35B | ✅ (needs focal) | Apache | < 15 fps | — |
| — | UniDepth v2 / ZoeDepth / Apple Depth Pro | — | ✅ | **NC / heavy** ❌ | mostly no | — |

**On our disk:** DA3 small/base 504 are **relative** (not metric — metric DA3 is Large-only). DA2 Base
F16 relative. Ready CoreML we DON'T have and could grab: **`sdkv2/DepthAnythingV3Mono-CoreML`** (DA3 Mono
Large, relative, 504 fp16, Apache) — a strong relative option.

## CoreML conversion recipe (per-frame DPT/DINOv2 head — DA-V2 metric, Metric-VDA unit, MoGe-2, DA3)
```python
import torch, coremltools as ct
model.eval()
example = torch.rand(1, 3, 518, 518)
traced = torch.jit.trace(model, example)
shapes = ct.EnumeratedShapes(shapes=[[1,3,392,518],[1,3,518,518],[1,3,518,686]], default=[1,3,518,518])
ml = ct.convert(traced,
    inputs=[ct.ImageType(name="image", shape=shapes, scale=1/255.0, bias=[0,0,0],
                         color_layout=ct.colorlayout.RGB)],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16, compute_units=ct.ComputeUnit.ALL)
ml.save("MetricDepth.mlpackage")
```
ANE rules: **EnumeratedShapes not RangeDim** (RangeDim → GPU/CPU fallback); **fp16 + ImageType**; replace
DINOv2 **bicubic** positional-embedding interp with **bilinear** before tracing (else fallback; ~0 quality
loss); optional int8 palettization ~halves size. Expect ViT-S@518 ≈ 28–35 ms on A17/A18.

**Metric-VDA-Small streaming:** convert the encoder+DPT per-frame first (fast path). The temporal
attention is the hard 10% — either (a) do temporal smoothing in Metal (EMA / flow-warp) — ship-now, or
(b) carry the KV cache with an iOS-17 **stateful** model (`ct.StateType`/`MLState`) — the "correct" path.

## Recommendation
1. **Now:** convert `Depth-Anything-V2-Metric-VKITTI-Small` (have weights) → drop into the Live Depth
   Model node's model list → validate ANE fps. Add a Metal-side depth EMA for temporal stability.
2. **Best:** convert `Metric-Video-Depth-Anything-Small` (per-frame first, then on-device temporal state).
3. Keep MoGe-2 (bundled) as the "high-quality metric point-map / lower-fps" mode; keep DA-V2/DA3 small
   (bundled, relative) as fast shape-only options.

Sources: hf.co/depth-anything/Metric-Video-Depth-Anything-Small · hf.co/apple/coreml-depth-anything-v2-small ·
github/DepthAnything/Video-Depth-Anything · coremltools flexible-inputs guide · hf.co/sdkv2/DepthAnythingV3Mono-CoreML
