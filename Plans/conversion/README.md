# Depth model → CoreML conversion

Scripts that convert the PyTorch metric-depth weights → CoreML fp16 for the **Live Depth Model** node.
Run on macOS with **Python 3.11** (coremltools's native libs don't load on 3.13/3.14).

## Env (once)
```bash
uv venv --python 3.11 /tmp/mlconv
uv pip install --python /tmp/mlconv/bin/python "torch==2.7.0" "torchvision==0.22.0" \
    coremltools timm numpy pillow opencv-python-headless einops easydict
# model code:
git clone --depth 1 https://github.com/DepthAnything/Depth-Anything-V2 /tmp/DAV2
git clone --depth 1 https://github.com/DepthAnything/Video-Depth-Anything /tmp/VDA
sed -i '' 's/mode="bicubic"/mode="bilinear"/' /tmp/DAV2/metric_depth/depth_anything_v2/dinov2.py
sed -i '' 's/mode="bicubic"/mode="bilinear"/' /tmp/VDA/video_depth_anything/dinov2.py
```

## Key tricks (why the naive convert fails)
- **`torch.export` + `run_decompositions({})`**, NOT `jit.trace` — trace leaves `aten::Int` casts on
  tensor-derived shapes that coremltools can't lower.
- DINOv2 positional-embedding interp is monkeypatched to a **constant-grid bilinear** (fixed input res).
- **`ct.ImageType(scale=1/255)`** + ImageNet normalisation folded into the model wrapper.
- Video model (Metric-VDA): the temporal **motion modules are bypassed** (einops `rearrange` won't lower
  under export) → a **per-frame** metric model from the video-trained weights. Temporal consistency is
  dropped — do it in Metal (depth EMA) or via a stateful KV-cache model later.

## Done (bundled, git-ignored, in Points/DepthImport/)
```bash
# DA V2 Metric Small — outdoor (VKITTI, 0-80m) + indoor (Hypersim, 0-20m):
/tmp/mlconv/bin/python convert_dav2_metric.py --enc vits \
    --pth ~/Downloads/depth_anything_v2_metric_vkitti_vits.pth  --max_depth 80 --out .../DAv2MetricOutdoor_S.mlpackage
/tmp/mlconv/bin/python convert_dav2_metric.py --enc vits \
    --pth ~/Downloads/depth_anything_v2_metric_hypersim_vits.pth --max_depth 20 --out .../DAv2MetricIndoor_S.mlpackage
# Metric Video Depth Anything Small (general metric, per-frame):
/tmp/mlconv/bin/python convert_vda.py --enc vits \
    --pth ~/Downloads/metric_video_depth_anything_vits.pth --out .../MetricVideoDA_S.mlpackage
```

## Base models (do after the smalls test well — bigger/slower)
```bash
/tmp/mlconv/bin/python convert_vda.py --enc vitb \
    --pth ~/Downloads/metric_video_depth_anything_vitb.pth --out .../MetricVideoDA_B.mlpackage
```
Then add a `LiveModel(name:"Metric Video DA B", resource:"MetricVideoDA_B", metric:true)` in
`LiveDepthEngine.swift` and to the `live-depth` node's `model` option list.
