import sys, argparse, math, types, torch, torch.nn as nn, torch.nn.functional as F, coremltools as ct
sys.path.insert(0, "/tmp/VDA")
from video_depth_anything.video_depth import VideoDepthAnything

CFG = {'vits': {'encoder':'vits','features':64,'out_channels':[48,96,192,384]},
       'vitb': {'encoder':'vitb','features':128,'out_channels':[96,192,384,768]}}

def make_clean_interp(res):
    g = res // 14
    def _interp(self, x, w, h):
        N = self.pos_embed.shape[1] - 1; g0 = int(math.sqrt(N))
        if g0*g0 == N and g0 == g: return self.pos_embed
        dim = self.pos_embed.shape[-1]; cls = self.pos_embed[:, :1]
        patch = self.pos_embed[:, 1:].reshape(1, g0, g0, dim).permute(0,3,1,2).float()
        patch = F.interpolate(patch, size=(g, g), mode="bilinear", align_corners=False)
        return torch.cat([cls, patch.permute(0,2,3,1).reshape(1, g*g, dim)], dim=1).to(x.dtype)
    return _interp

ap = argparse.ArgumentParser()
ap.add_argument('--enc', default='vits'); ap.add_argument('--pth', required=True)
ap.add_argument('--out', required=True); ap.add_argument('--res', type=int, default=518)
a = ap.parse_args()

m = VideoDepthAnything(**CFG[a.enc], metric=True)
m.load_state_dict(torch.load(a.pth, map_location='cpu'), strict=True)
m.eval()
m.pretrained.interpolate_pos_encoding = types.MethodType(make_clean_interp(a.res), m.pretrained)
# Bypass the temporal motion modules (einops rearrange won't lower under torch.export) → per-frame
# metric depth from the video-trained weights. Temporal consistency is dropped (do it in Metal / a
# stateful model later); the encoder + DPT head are what matter for a single frame.
def _passthrough(self, hidden_states, *args, **kwargs):
    return hidden_states, []       # [] so the head's h0+h1+h2+h3 concat works (cached list unused per-frame)
for mm in m.head.motion_modules:
    mm.forward = types.MethodType(_passthrough, mm)

class Wrap(nn.Module):                      # per-frame (T=1): [1,3,res,res] 0..1 -> [1,res,res] metres
    def __init__(self, m):
        super().__init__(); self.m = m
        self.register_buffer('mean', torch.tensor([0.485,0.456,0.406]).view(1,1,3,1,1))
        self.register_buffer('std',  torch.tensor([0.229,0.224,0.225]).view(1,1,3,1,1))
    def forward(self, x):
        x5 = (x.unsqueeze(1) - self.mean) / self.std   # [1,1,3,res,res]
        return self.m(x5)[:, 0]                         # [1,res,res]

w = Wrap(m).eval()
ex = torch.rand(1, 3, a.res, a.res)
with torch.no_grad():
    prog = torch.export.export(w, (ex,)); prog = prog.run_decompositions({})
ml = ct.convert(prog,
    inputs=[ct.ImageType(name="image", shape=(1,3,a.res,a.res), scale=1/255.0,
                         bias=[0.0,0.0,0.0], color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="depth")],
    minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
ml.save(a.out); print("SAVED", a.out)
