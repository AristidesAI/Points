import sys, argparse, math, types, torch, torch.nn as nn, torch.nn.functional as F, coremltools as ct
sys.path.insert(0, "/tmp/DAV2/metric_depth")
from depth_anything_v2.dpt import DepthAnythingV2

# Trace-safe positional-embedding interp: fixed input res → the target patch grid is a Python
# CONSTANT, so no aten::Int cast on a tensor (which coremltools can't lower).
def make_clean_interp(res):
    g = res // 14
    def _interp(self, x, w, h):
        N = self.pos_embed.shape[1] - 1
        g0 = int(math.sqrt(N))
        if g0 * g0 == N and g0 == g:
            return self.pos_embed
        dim = self.pos_embed.shape[-1]
        cls = self.pos_embed[:, :1]
        patch = self.pos_embed[:, 1:].reshape(1, g0, g0, dim).permute(0, 3, 1, 2).float()
        patch = F.interpolate(patch, size=(g, g), mode="bilinear", align_corners=False)
        patch = patch.permute(0, 2, 3, 1).reshape(1, g * g, dim)
        return torch.cat([cls, patch], dim=1).to(x.dtype)
    return _interp

CFG = {'vits': {'encoder':'vits','features':64,'out_channels':[48,96,192,384]},
       'vitb': {'encoder':'vitb','features':128,'out_channels':[96,192,384,768]},
       'vitl': {'encoder':'vitl','features':256,'out_channels':[256,512,1024,1024]}}

ap = argparse.ArgumentParser()
ap.add_argument('--enc', default='vits'); ap.add_argument('--pth', required=True)
ap.add_argument('--max_depth', type=float, required=True); ap.add_argument('--out', required=True)
ap.add_argument('--res', type=int, default=518)
a = ap.parse_args()

m = DepthAnythingV2(**CFG[a.enc], max_depth=a.max_depth)
m.load_state_dict(torch.load(a.pth, map_location='cpu'))
m.eval()
m.pretrained.interpolate_pos_encoding = types.MethodType(make_clean_interp(a.res), m.pretrained)

class Wrap(nn.Module):
    def __init__(self, m, res):
        super().__init__(); self.m = m; self.ph = res // 14; self.pw = res // 14
        self.register_buffer('mean', torch.tensor([0.485,0.456,0.406]).view(1,3,1,1))
        self.register_buffer('std',  torch.tensor([0.229,0.224,0.225]).view(1,3,1,1))
    def forward(self, x):                       # x: [1,3,res,res] in 0..1 RGB
        x = (x - self.mean) / self.std
        # Constant patch sizes (fixed input) so the DPT head's int(patch*14) is a const, not a tensor.
        feats = self.m.pretrained.get_intermediate_layers(
            x, self.m.intermediate_layer_idx[self.m.encoder], return_class_token=True)
        depth = self.m.depth_head(feats, self.ph, self.pw) * self.m.max_depth
        return depth.squeeze(1)                 # -> [1,res,res] metric metres

w = Wrap(m, a.res).eval()
ex = torch.rand(1, 3, a.res, a.res)
with torch.no_grad():
    prog = torch.export.export(w, (ex,))   # torch.export lowers shape-ints symbolically
    prog = prog.run_decompositions({})     # TRAINING dialect -> ATEN for coremltools

ml = ct.convert(
    prog,
    inputs=[ct.ImageType(name="image", shape=(1,3,a.res,a.res), scale=1/255.0,
                         bias=[0.0,0.0,0.0], color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="depth")],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,
    compute_units=ct.ComputeUnit.ALL)
ml.save(a.out)
print("SAVED", a.out)
