#include <metal_stdlib>
using namespace metal;

// Field order MUST match PinUniforms in PinRenderer.swift.
struct Uniforms {
    float4x4 viewProj;
    uint cols; uint rows; uint count; uint orient;      // orient bits: 1 swapUV, 2 flipU, 4 flipV
    float extX; float extY; float zWorldScale; float pinSize;   // zWorldScale = Camera node depth push
    float stemThickness; float nearM; float farM; uint colorMode;
    uint isStem; uint pad1; uint pad2;
    float edgeReject;   // Depth node EDGECULL — built-in silhouette flying-pixel reject (metres)
    float4 lightPos[4];    // Light nodes: xyz = position (point/spot) or direction (directional); w = type 0/1/2
    float4 lightParams[4]; // x intensity, y falloff, z enabled, w unused
    float4 material;       // Material node: x mode (0 unlit / 1 lit / 2 matcap), y roughness, z metallic, w lightCount
    float4 lookAt;         // Look At node: xyz target (view units), w amount (0 = off)
    float4 stemParams;     // Stem node: x profile (0 square / 1 round / 2 blade), y taper, z thickness×, w unused
    float4 eyePos;         // camera eye (world/view units) — real view dir for speculars under orbit
    float4 camIntrin;      // Depth-node METRIC mode: fx_n, fy_n, cx_n, cy_n (normalized intrinsics)
};

// Field order MUST match VMParams in PinRenderer.swift.
struct VMParams {
    uint instrCount; uint stateStride; uint colorIsLuma; uint colorEnabled;
    float time; float beatPhase; float dt; float pad;
    float4 waveT;    // shockwave birth times (P.time clock); < -1e5 = inactive
    float4 waveCA;   // wave 0 center (xy), wave 1 center (zw) — view units
    float4 waveCB;   // wave 2 center (xy), wave 3 center (zw)
    float4 uvT;      // UV Transform node: offsetX, offsetY, scale, rotate (turns)
    float4 edge;     // Edge Policy node: mode (0 none / 1 fade / 2 clamp), margin, 0, 0
    float4 domain;   // Domain node: topologyA, topologyB, morph, 0
};

// Field order MUST match PinInstruction in PinProgram.swift. 32 bytes.
struct PinInstr {
    uint op; uint dst; uint a; uint b;
    float4 imm;
};

struct InstanceOut {
    float4 posSize;   // xyz = world position (offset applied), w = size multiplier
    float4 color;
    float4 rot;       // xyz = euler turns (Rotation/Spin), w = shape morph 0 sphere → 1 cube
    float4 scl;       // xyz = per-axis stretch (Stretch), default 1; w unused
};

// Euler (turns already ×2π) rotation applied in code — avoids column-major matrix confusion.
static inline float3 rotateEuler(float3 p, float3 e) {
    float cx = cos(e.x), sx = sin(e.x);
    p = float3(p.x, p.y * cx - p.z * sx, p.y * sx + p.z * cx);
    float cy = cos(e.y), sy = sin(e.y);
    p = float3(p.x * cy + p.z * sy, p.y, -p.x * sy + p.z * cy);
    float cz = cos(e.z), sz = sin(e.z);
    return float3(p.x * cz - p.y * sz, p.x * sz + p.y * cz, p.z);
}

static inline float2 mapUV(float2 uv, uint orient) {
    if (orient & 1u) uv = uv.yx;
    if (orient & 2u) uv.x = 1.0 - uv.x;
    if (orient & 4u) uv.y = 1.0 - uv.y;
    return uv;
}

static inline float hash01(float x) {
    uint n = uint(abs(x) * 65536.0);
    n = (n ^ 61u) ^ (n >> 16u);
    n *= 9u; n = n ^ (n >> 4u); n *= 0x27d4eb2du; n = n ^ (n >> 15u);
    return float(n & 0x00FFFFFFu) / 16777215.0;
}

// Domain node — topology warps of the canonical grid uv. 0 rect · 1 hex · 2 radial ·
// 3 spiral · 4 scatter · 5 perspective. Pure remap of each pin's HOME uv; depth/color
// sampling follows the pin to its new home.
static inline float2 topoUV(float2 g, int t, uint gid, uint cols, uint count) {
    if (t == 1) {                        // hex: odd rows offset half a cell
        if ((gid / cols) & 1u) g.x += 0.5 / float(max(cols - 1u, 1u));
        return g;
    } else if (t == 2) {                 // radial: x = angle, y = ring radius
        float a = g.x * 6.2831853;
        float r = 0.5 * (0.08 + 0.92 * g.y);
        return float2(0.5 + r * cos(a), 0.5 + r * sin(a));
    } else if (t == 3) {                 // spiral: golden-angle sunflower
        float tt = float(gid) / float(max(count - 1u, 1u));
        float r = 0.5 * sqrt(tt);
        float a = float(gid) * 2.39996323;
        return float2(0.5 + r * cos(a), 0.5 + r * sin(a));
    } else if (t == 4) {                 // scatter: stable per-pin hash
        return float2(hash01(float(gid) * 0.6180339 + 7.0),
                      hash01(float(gid) * 1.1134 + 31.7));
    } else if (t == 5) {                 // perspective: rows bunch toward the top
        float v = g.y * g.y;
        return float2(0.5 + (g.x - 0.5) * mix(0.35, 1.0, v), v);
    }
    return g;                            // rect
}

// ---- 3D noise field (Noise node) — value + gradient(Perlin), animatable off P.time ----
static inline float hash1_3(int3 p) {
    int n = p.x * 374761393 + p.y * 668265263 + p.z * 1274126177;
    n = (n ^ (n >> 13)) * 1274126177;
    return float((n ^ (n >> 16)) & 0x00FFFFFF) / 16777215.0;   // 0..1
}
static inline float3 grad1_3(int3 p) {
    float a = hash1_3(p) * 6.2831853;
    float z = hash1_3(p + int3(37, 17, 7)) * 2.0 - 1.0;
    float rz = sqrt(max(1.0 - z * z, 0.0));
    return float3(cos(a) * rz, sin(a) * rz, z);
}
// value noise in [-1,1]; hermite=quintic smoothing, else linear (blocky "random")
static inline float valueNoise3(float3 P, bool hermite) {
    float3 i = floor(P), f = fract(P);
    float3 u = hermite ? f * f * f * (f * (f * 6.0 - 15.0) + 10.0) : f;
    int3 c = int3(i);
    float n000 = hash1_3(c + int3(0,0,0)), n100 = hash1_3(c + int3(1,0,0));
    float n010 = hash1_3(c + int3(0,1,0)), n110 = hash1_3(c + int3(1,1,0));
    float n001 = hash1_3(c + int3(0,0,1)), n101 = hash1_3(c + int3(1,0,1));
    float n011 = hash1_3(c + int3(0,1,1)), n111 = hash1_3(c + int3(1,1,1));
    float nx00 = mix(n000, n100, u.x), nx10 = mix(n010, n110, u.x);
    float nx01 = mix(n001, n101, u.x), nx11 = mix(n011, n111, u.x);
    return mix(mix(nx00, nx10, u.y), mix(nx01, nx11, u.y), u.z) * 2.0 - 1.0;
}
// gradient (Perlin) noise in ~[-1,1]
static inline float gradNoise3(float3 P) {
    float3 i = floor(P), f = fract(P);
    float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    int3 c = int3(i);
#define GN3(dx,dy,dz) dot(grad1_3(c + int3(dx,dy,dz)), f - float3(dx,dy,dz))
    float n000 = GN3(0,0,0), n100 = GN3(1,0,0), n010 = GN3(0,1,0), n110 = GN3(1,1,0);
    float n001 = GN3(0,0,1), n101 = GN3(1,0,1), n011 = GN3(0,1,1), n111 = GN3(1,1,1);
#undef GN3
    float nx00 = mix(n000, n100, u.x), nx10 = mix(n010, n110, u.x);
    float nx01 = mix(n001, n101, u.x), nx11 = mix(n011, n111, u.x);
    return clamp(mix(mix(nx00, nx10, u.y), mix(nx01, nx11, u.y), u.z) * 1.4, -1.0, 1.0);
}

// ============================================================================
// PIN PROGRAM — register-VM interpreter (Layer A). Every pin runs the same
// broadcast instruction stream: zero divergence. Ops mirror PinOp in Swift.
// ============================================================================
kernel void pin_program(constant Uniforms &U [[buffer(0)]],
                        constant VMParams &P [[buffer(1)]],
                        constant PinInstr *prog [[buffer(2)]],
                        device float *state [[buffer(3)]],
                        device InstanceOut *outBuf [[buffer(4)]],
                        texture2d<float> depthTex [[texture(0)]],
                        texture2d<float> colorTex [[texture(1)]],
                        texture2d<float> paletteTex [[texture(2)]],
                        uint gid [[thread_position_in_grid]]) {
    if (gid >= U.count) return;
    constexpr sampler smp(filter::linear, address::clamp_to_edge);

    uint col = gid % U.cols;
    uint row = gid / U.cols;
    float2 guv = float2(float(col) / float(max(U.cols - 1u, 1u)),
                        float(row) / float(max(U.rows - 1u, 1u)));
    // Domain node: warp each pin's home uv through topology A→B (morph blends them).
    if (P.domain.x > 0.5 || (P.domain.y > 0.5 && P.domain.z > 0.001)) {
        float2 gA = topoUV(guv, int(P.domain.x + 0.5), gid, U.cols, U.count);
        float2 gB = topoUV(guv, int(P.domain.y + 0.5), gid, U.cols, U.count);
        guv = mix(gA, gB, clamp(P.domain.z, 0.0, 1.0));
    }
    float2 duv = mapUV(guv, U.orient);
    // UV Transform node: pan/zoom/rotate the source image under the pins.
    if (P.uvT.x != 0.0 || P.uvT.y != 0.0 || P.uvT.z != 1.0 || P.uvT.w != 0.0) {
        float2 c = duv - 0.5;
        float ang = P.uvT.w * 6.2831853;
        float cs = cos(ang), sn = sin(ang);
        c = float2(c.x * cs - c.y * sn, c.x * sn + c.y * cs);
        duv = c / max(P.uvT.z, 0.05) + 0.5 - P.uvT.xy;
    }
    float2 baseXY = float2(mix(-U.extX, U.extX, guv.x), mix(U.extY, -U.extY, guv.y));

    float4 regs[32];
    float3 posOff = float3(0.0);
    float sizeMul = 1.0;
    float keep = 1.0;                               // grazing/edge culls (freeXY) zero this
    float3 rotAcc = float3(0.0);                    // Rotation/Spin (euler turns)
    float3 stretchAcc = float3(1.0);               // Stretch (per-axis scale)
    float shapeMorph = 0.0;                         // morph amount toward the target shape (0-1)
    float shapeTarget = 0.0;                        // which shape to morph toward (0 sphere,1 cube,2 tube,…)
    float4 color = float4(0.78, 0.78, 0.78, 1.0);   // neutral default (color OFF)
    uint stateBase = gid * P.stateStride;

    // Default silhouette edge-reject (TDLidar point-cloud + LiDAR cleanup, Apple filtering OFF):
    // cull flying pixels where the 4-neighbour depth spread is large. Without this the IR-shadow
    // fringe on the face edge (worse on the projector-shadow side) falls backwards toward the
    // background. Runs in BOTH free & pinout, independent of any node.
    {
        float2 texel = float2(1.0 / float(depthTex.get_width()), 1.0 / float(depthTex.get_height()));
        float zC = depthTex.sample(smp, duv).r;
        if (zC > 0.05 && isfinite(zC)) {
            float zL = depthTex.sample(smp, duv - float2(texel.x, 0.0)).r;
            float zR = depthTex.sample(smp, duv + float2(texel.x, 0.0)).r;
            float zU = depthTex.sample(smp, duv - float2(0.0, texel.y)).r;
            float zD = depthTex.sample(smp, duv + float2(0.0, texel.y)).r;
            if (isfinite(zL) && isfinite(zR) && isfinite(zU) && isfinite(zD)) {
                float lo = min(min(zL, zR), min(zU, zD));
                float hi = max(max(zL, zR), max(zU, zD));
                if (U.edgeReject > 0.0001 && hi - lo > U.edgeReject) keep = 0.0;   // silhouette flying pixel
            }
        }
    }

    for (uint i = 0; i < P.instrCount; i++) {
        PinInstr ins = prog[i];
        float4 A = regs[min(ins.a, 31u)];
        float4 B = regs[min(ins.b, 31u)];
        float4 r = float4(0.0);
        bool write = true;
        switch (ins.op) {
            case 0: i = P.instrCount; write = false; break;                    // halt
            case 1: r = ins.imm; break;                                       // const
            case 2: {                                                          // loadDepth(near,far,invert)
                float raw = depthTex.sample(smp, duv).r;
                bool valid = raw > 0.05 && isfinite(raw);
                // No upper gate: pins closer than NEAR keep pushing forward (t > 1) instead of
                // plateauing at the wall — the "goes flat past a certain distance" cap is gone.
                float t = valid ? max((ins.imm.y - raw) / max(ins.imm.y - ins.imm.x, 0.001), 0.0) : 0.0;
                if (ins.imm.z > 0.5) t = valid ? max(1.0 - t, 0.0) : 0.0;
                r = float4(t); break;
            }
            case 3: r = float4(guv, baseXY); break;                            // loadUV
            case 4: {                                                          // loadIndex
                float ni = float(gid) / float(max(U.count - 1u, 1u));
                r = float4(ni, hash01(float(gid) * 0.618), distance(guv, float2(0.5)), 0.0); break;
            }
            case 5: {                                                          // loadColor(exposureMul)
                float4 c = colorTex.sample(smp, duv);
                float3 rgb = P.colorIsLuma ? float3(0.12 + 0.88 * c.r) : c.rgb;
                r = float4(rgb * ins.imm.x, 1.0); break;
            }
            case 6: r = float4(P.time, P.beatPhase, P.dt, 0.0); break;         // loadTime
            case 7: r = A + B; break;
            case 8: r = A - B; break;
            case 9: r = A * B; break;
            case 10: {                                                     // div, sign-preserving guard
                float4 bb = select(max(B, float4(0.0001)), min(B, float4(-0.0001)), B < float4(0.0));
                r = A / bb; break;
            }
            case 11: r = A * ins.imm.x + ins.imm.y; break;                     // madd
            case 12: r = mix(A, B, ins.imm.x); break;                          // mix
            case 13: r = mix(A, B, regs[min(uint(ins.imm.w), 31u)].x); break;  // mixv
            case 14: r = clamp(A, ins.imm.x, ins.imm.y); break;
            case 15: r = (A - ins.imm.x) / max(ins.imm.y - ins.imm.x, 0.0001)
                         * (ins.imm.w - ins.imm.z) + ins.imm.z; break;         // remap
            case 16: r = abs(A); break;
            case 17: r = min(A, B); break;
            case 18: r = max(A, B); break;
            case 19: r = pow(max(A, float4(0.0)), ins.imm.x); break;
            case 20: r = sin(A * ins.imm.x + ins.imm.y) * ins.imm.z + ins.imm.w; break;
            case 21: r = fract(A); break;
            case 22: r = sqrt(max(A, float4(0.0))); break;
            case 23: r = smoothstep(ins.imm.x, ins.imm.y, A); break;
            case 24: r = float4(step(ins.imm.x, A.x)); break;                  // stepOp
            case 25: r = float4(length(A.xyz)); break;                         // len
            case 26: r = float4(distance(A.xy, ins.imm.xy)); break;            // dist2
            case 27: r = float4(hash01(A.x * ins.imm.x * 131.0 + hash01(ins.imm.y * 0.0137) * 1024.0)); break;  // seed folded through hash → no uint overflow / precision collapse past seed≈490
            case 28: {                                                          // palette(row, shift)
                // clamp (not wrap): a negative shift pulls hot ends down without far
                // pixels wrapping to the hot end of the map
                float t = clamp(A.x + ins.imm.z, 0.0, 0.999);
                float v = (ins.imm.y + 0.5) / 8.0;
                r = paletteTex.sample(smp, float2(t, v)); break;
            }
            case 29: r = float4(state[stateBase + uint(ins.imm.x)]); break;    // loadState
            case 30: state[stateBase + uint(ins.imm.x)] = A.x; write = false; break;
            case 31: { uint s = stateBase + uint(ins.imm.x);
                       r = float4(state[s], state[s + 1], state[s + 2], 0.0); break; }
            case 32: { uint s = stateBase + uint(ins.imm.x);
                       state[s] = A.x; state[s + 1] = A.y; state[s + 2] = A.z; write = false; break; }
            case 33: posOff.z += A.x; write = false; break;                    // writeZ
            case 34: posOff += A.xyz; write = false; break;                    // writePos
            case 35: sizeMul *= max(A.x, 0.0); write = false; break;           // writeSize
            case 36: color = A; write = false; break;                          // writeColor
            case 37: {                                                          // hash3(seed)
                float s = ins.imm.x;
                r = float4(hash01(float(gid) * 0.618 + s) * 2.0 - 1.0,
                           hash01(float(gid) * 1.113 + s + 31.7) * 2.0 - 1.0,
                           hash01(float(gid) * 1.618 + s + 77.3) * 2.0 - 1.0, 0.0);
                break;
            }
            case 38: {                                                          // twist(cx,cy,falloff)
                float2 c = ins.imm.xy;
                float2 d = baseXY - c;
                float rr = length(d);
                float ang = A.x * 6.2831853 * exp(-rr * ins.imm.z);
                float cs = cos(ang), sn = sin(ang);
                float2 rot = float2(d.x * cs - d.y * sn, d.x * sn + d.y * cs);
                r = float4(rot - d, 0.0, 0.0);
                break;
            }
            case 39: {                                                          // shockwave(speed,width,damping)
                float pulse = 0.0;
                for (uint j = 0; j < 4; j++) {
                    float t0 = P.waveT[j];
                    if (t0 < -1e5) continue;
                    float age = P.time - t0;
                    if (age < 0.0) continue;
                    float2 c = j == 0 ? P.waveCA.xy : (j == 1 ? P.waveCA.zw : (j == 2 ? P.waveCB.xy : P.waveCB.zw));
                    float rr = distance(baseXY, c);
                    float x = rr - age * ins.imm.x;
                    float w = max(ins.imm.y, 0.005);
                    pulse += exp(-(x * x) / (2.0 * w * w)) * exp(-age * ins.imm.z);
                }
                r = float4(pulse);
                break;
            }
            case 40: {                                                          // rectMask(cx,cy,hw,hh)
                float dx = fabs(baseXY.x - ins.imm.x) / max(ins.imm.z, 0.001);
                float dy = fabs(baseXY.y - ins.imm.y) / max(ins.imm.w, 0.001);
                r = float4(max(dx, dy));
                break;
            }
            case 44: {                                                          // freeXY (Depth node FREE mode)
                // TDLidar front point-cloud fan, intrinsic-free: XY spreads with z/focus so the
                // cloud sits on the pinout grid at the focus depth and fans into a frustum off it.
                // imm = (separation, focusM, 0, 0). Culls live in the Grazing Cull FILTER node (op 45).
                float rawZ = depthTex.sample(smp, duv).r;
                bool valid = rawZ > 0.05 && isfinite(rawZ);
                if (!valid) { r = float4(0.0); keep = 0.0; break; }
                // fan: sensor-space displacement scaled by z/focus, mapped back to screen axes
                float2 n = (duv - 0.5) * (rawZ / max(ins.imm.y, 0.05)) * ins.imm.x;
                float2 s = n;                                     // undo mapUV for a direction
                if (U.orient & 2u) s.x = -s.x;
                if (U.orient & 4u) s.y = -s.y;
                if (U.orient & 1u) s = s.yx;
                float2 freeXY = float2(s.x * 2.0 * U.extX, -s.y * 2.0 * U.extY);
                r = float4(freeXY - baseXY, 0.0, 0.0);
                break;
            }
            case 47: {                                                          // unprojectXY (METRIC mode)
                // Real camera-intrinsics unprojection: worldX = (u-cx)/fx · Z, worldY = (v-cy)/fy · Z.
                // Because X/Y are TRUE metres, an object keeps its real size — so when it moves away
                // (Z grows) the fixed perspective camera makes it recede + shrink, like TDLidar.
                // imm.x = scale (metres → view units). camIntrin = fx_n,fy_n,cx_n,cy_n (normalized).
                float z = depthTex.sample(smp, duv).r;
                if (!(z > 0.02) || !isfinite(z)) { r = float4(0.0); keep = 0.0; break; }
                float2 m = float2((duv.x - U.camIntrin.z) / max(U.camIntrin.x, 1e-4),
                                  (duv.y - U.camIntrin.w) / max(U.camIntrin.y, 1e-4)) * z;
                if (U.orient & 2u) m.x = -m.x;      // sensor XY → screen XY (mirror freeXY's orient undo)
                if (U.orient & 4u) m.y = -m.y;
                if (U.orient & 1u) m = m.yx;
                float2 screen = float2(m.x, -m.y) * ins.imm.x;   // metres × scale; -y = screen up
                r = float4(screen - baseXY, 0.0, 0.0);           // writePos re-adds baseXY
                break;
            }
            case 48: {                                                          // unprojectZ (METRIC mode)
                // Metric depth → world Z, framed so nearer = forward. imm.x = scale, imm.y = zRef.
                float z = depthTex.sample(smp, duv).r;
                if (!(z > 0.02) || !isfinite(z)) { r = float4(0.0); break; }
                r = float4((ins.imm.y - z) * ins.imm.x);         // (zRef − z)·scale; ×depthPush in the vertex
                break;
            }
            case 45: {                                                          // grazeCull (FILTER node)
                // TDLidar cleanup pass as a node: silhouette edge-reject + grazing-normal cull.
                // A passes through untouched; culled pins get size 0 via the kernel keep flag.
                // imm = (grazing01, edgeThreshM, gateM, baselineTexels).
                // ponytail: principal point ≈ frame centre; rays use span 1.2 (~63° TrueDepth hFOV).
                r = A;
                float rawZ = depthTex.sample(smp, duv).r;
                if (!(rawZ > 0.05) || !isfinite(rawZ)) break;
                // BASELINE slider: per-pixel sensor noise over a 1-texel step (~1 mm lateral at
                // 0.5 m) swings the normal wildly, so flat frontal areas culled random flickering
                // dots. A wider baseline calms the slope noise; the GATE below does the rest —
                // edge LINES still read a big spread, so they still cull.
                float2 texel = max(ins.imm.w, 1.0) * float2(1.0 / float(depthTex.get_width()),
                                                            1.0 / float(depthTex.get_height()));
                float zL = depthTex.sample(smp, duv - float2(texel.x, 0)).r;
                float zR = depthTex.sample(smp, duv + float2(texel.x, 0)).r;
                float zU = depthTex.sample(smp, duv - float2(0, texel.y)).r;
                float zD = depthTex.sample(smp, duv + float2(0, texel.y)).r;
                bool nbrOK = isfinite(zL) && isfinite(zR) && isfinite(zU) && isfinite(zD)
                             && zL > 0.05 && zR > 0.05 && zU > 0.05 && zD > 0.05;
                if (!nbrOK) break;
                float lo = min(min(zL, zR), min(zU, zD));
                float hi = max(max(zL, zR), max(zU, zD));
                if (ins.imm.y > 0.0001 && hi - lo > ins.imm.y) { keep = 0.0; break; }
                if (ins.imm.x > 0.001) {
                    // GATE slider: the grazing cull fires only where the local depth spread is
                    // a REAL change (gate + 2·gate per metre; default 6 mm covers TrueDepth
                    // noise). Solid frontal areas sit under the floor → never culled, no jitter;
                    // silhouette edges and steep grazing surfaces far exceed it → cull as before.
                    if (hi - lo < ins.imm.z * (1.0 + 2.0 * rawZ)) break;
                    const float span = 1.2;
                    float2 cen = duv - 0.5;
                    float3 pL = float3((cen - float2(texel.x, 0)) * span * zL, zL);
                    float3 pR = float3((cen + float2(texel.x, 0)) * span * zR, zR);
                    float3 pU = float3((cen - float2(0, texel.y)) * span * zU, zU);
                    float3 pD = float3((cen + float2(0, texel.y)) * span * zD, zD);
                    float3 nrm = normalize(cross(pR - pL, pD - pU));
                    float3 viewDir = normalize(float3(cen * span, 1.0));
                    // Stronger sweep so the CULL slider is visibly graded: at 1.0 it rejects
                    // any surface angled more than ~30° off the view ray.
                    float cosThresh = mix(0.0, 0.85, clamp(ins.imm.x, 0.0, 1.0));
                    if (abs(dot(nrm, viewDir)) < cosThresh) { keep = 0.0; }
                }
                break;
            }
            case 43: {                                                          // hueShift(turns) — YIQ rotate
                float3 c = A.rgb;
                float y = dot(c, float3(0.299, 0.587, 0.114));
                float iC = dot(c, float3(0.596, -0.274, -0.322));
                float q = dot(c, float3(0.211, -0.523, 0.312));
                float ang = ins.imm.x * 6.2831853;
                float cs = cos(ang), sn = sin(ang);
                float i2 = iC * cs - q * sn, q2 = iC * sn + q * cs;
                r = float4(clamp(float3(y + 0.956 * i2 + 0.621 * q2,
                                        y - 0.272 * i2 - 0.647 * q2,
                                        y - 1.106 * i2 + 1.703 * q2), 0.0, 1.0), A.a);
                break;
            }
            case 55: rotAcc += A.xyz; write = false; break;                    // writeRot (turns)
            case 56: stretchAcc *= max(A.xyz, float3(0.01)); write = false; break; // writeStretch
            case 57: shapeTarget = floor(A.x); shapeMorph = fract(A.x); write = false; break;  // writeShape: value = targetIndex + morph(0-1)
            case 58: r = float4(P.time * ins.imm.xyz, 0.0); break;             // spinTurns(rate)
            case 46: {   // noise3: 3D noise [-1,1]; a.x=optional z-drive; imm=(freq, seed, packed[ty+axis*10+aspect*100], timeMove)
                int packed = int(ins.imm.z);
                int ty = packed % 10;
                int axis = (packed / 10) % 10;   // 0 x · 1 y · 2 z
                int aspect = packed / 100;
                float3 coord = float3(baseXY, A.x);
                if (aspect > 0) coord.x *= U.extX / max(U.extY, 1e-4);
                coord *= ins.imm.x;                                                    // frequency
                float3 tmask = float3(axis == 0 ? 1.0 : 0.0, axis == 1 ? 1.0 : 0.0, axis == 2 ? 1.0 : 0.0);
                coord += tmask * (P.time * ins.imm.w);                                 // animate along the chosen axis
                coord += float3(ins.imm.y * 13.1);                                     // seed
                float n;
                if (ty == 0 || ty == 5) n = gradNoise3(coord);                         // perlin / harmonic base
                else if (ty == 1) n = gradNoise3(coord.yzx * 1.31 + 4.2);              // simplex (skewed approx)
                else if (ty == 4) n = valueNoise3(coord, true);                        // hermite (quintic)
                else if (ty == 3) n = step(0.5, valueNoise3(coord, false));            // sparse (0/1)
                else n = valueNoise3(coord, false);                                    // random (linear)
                r = float4(n); break;
            }
            default: write = false; break;
        }
        if (write) regs[min(ins.dst, 31u)] = r;
    }

    // Edge Policy node: what happens when warps push pins past the frame border.
    if (P.edge.x > 0.5) {
        float2 fxy = baseXY + posOff.xy;
        float2 lim = float2(U.extX, U.extY);
        if (P.edge.x > 1.5) {                                   // clamp: pins pile up at the border
            float2 cl = clamp(fxy, -lim, lim);
            posOff.xy += cl - fxy;
        } else {                                                // fade: size falls off across MARGIN
            float m = max(P.edge.y, 0.01) * 3.0;                // margin (uv) → view units
            float over = max(max(fabs(fxy.x) - lim.x, fabs(fxy.y) - lim.y), 0.0);
            keep *= clamp(1.0 - over / m, 0.0, 1.0);
        }
    }

    // No Z clamp: the cloud extends BOTH ways off the wall (points farther than FOCUS go
    // behind it) — clamping pancaked everything beyond ~1 m flat, killing TDLidar perspective.
    outBuf[gid].posSize = float4(baseXY + posOff.xy, posOff.z, sizeMul * keep);
    outBuf[gid].color = color;
    outBuf[gid].rot = float4(rotAcc, clamp(shapeMorph, 0.0, 1.0));
    outBuf[gid].scl = float4(stretchAcc, shapeTarget);   // scl.w carries the shape morph TARGET index
}

// ============================================================================
// Instanced pin render — reads the interpreter's InstanceOut buffer.
// ============================================================================
struct VIn {
    float3 pos [[attribute(0)]];
    float3 nrm [[attribute(1)]];
};

struct VOut {
    float4 pos [[position]];
    float3 nrm;
    float3 color;
    float3 wpos;   // world-space position for the Light node (point/spot falloff)
};

// ---- Orbit-pivot gizmo: a small solid cube at the camera's orbit centre ----
struct GizmoUniforms { float4x4 mvp; float4 color; };
struct GizmoVOut { float4 pos [[position]]; float3 nrm; };

vertex GizmoVOut gizmo_vertex(VIn vin [[stage_in]], constant GizmoUniforms &G [[buffer(1)]]) {
    GizmoVOut o;
    o.pos = G.mvp * float4(vin.pos, 1.0);
    o.nrm = vin.nrm;
    return o;
}
fragment float4 gizmo_fragment(GizmoVOut in [[stage_in]], constant GizmoUniforms &G [[buffer(1)]]) {
    // simple top-lit shade so the cube reads as 3D
    float l = 0.55 + 0.45 * clamp(dot(normalize(in.nrm), normalize(float3(0.4, 0.8, 0.5))), 0.0, 1.0);
    return float4(G.color.rgb * l, G.color.a);
}

vertex VOut pin_vertex(VIn vin [[stage_in]],
                       uint iid [[instance_id]],
                       constant Uniforms &U [[buffer(1)]],
                       const device InstanceOut *inst [[buffer(2)]]) {
    InstanceOut io = inst[iid];
    float size = U.pinSize * io.posSize.w;
    float z = io.posSize.z * U.zWorldScale;   // Camera node depth push (world-space Z exaggeration)
    float2 xy = io.posSize.xy;

    float3 wp;
    float3 nrm = vin.nrm;
    if (U.isStem != 0u) {
        float len = max(z - size * 0.4, 0.0);
        // Stem node styling: BLADE flattens the profile, TAPER narrows toward the cap.
        float2 prof = vin.pos.xy;
        if (U.stemParams.x > 1.5) prof *= float2(2.2, 0.28);            // blade
        float along = vin.pos.z + 0.5;                                  // 0 wall → 1 cap
        prof *= max(1.0 - U.stemParams.y * along, 0.05);                // taper
        wp = float3(xy + prof * U.stemThickness * U.stemParams.z * io.posSize.w, along * len);
    } else {
        // SHAPE family: morph the sphere toward a target shape, stretch per-axis, then rotate.
        // Every target is a continuous remap of the same unit-sphere vertex → fully blendable, no
        // new mesh. Normals morph WITH the shape so cubes read sharp and discs read flat.
        float3 lp = vin.pos;
        float m = io.rot.w;
        int ti = int(io.scl.w + 0.5);
        if (m > 0.001 && ti > 0) {
            float3 n0 = lp * 2.0;                                  // unit-sphere point (mesh radius 0.5)
            float ax = fabs(n0.x), ay = fabs(n0.y), az = fabs(n0.z);
            float mx = max(max(ax, ay), az);
            float2 dirXY = normalize(n0.xy + float2(1e-5, 0.0));
            float3 tgt = n0, tn = n0;
            if (ti == 1) {                                          // cube
                tgt = n0 / max(mx, 1e-4);
                tn = (az >= ax && az >= ay) ? float3(0.0, 0.0, sign(n0.z))
                   : (ax >= ay ? float3(sign(n0.x), 0.0, 0.0) : float3(0.0, sign(n0.y), 0.0));
            } else if (ti == 2) {                                   // tube (open cylinder shell)
                tgt = float3(dirXY, n0.z);
                tn = float3(dirXY, 0.0);
            } else if (ti == 3) {                                   // slab (flat square panel)
                float mxy = max(max(ax, ay), 1e-4);
                tgt = float3(n0.xy / mxy, n0.z * 0.22);
                tn = (az > max(ax, ay) * 0.7) ? float3(0.0, 0.0, sign(n0.z))
                   : (ax >= ay ? float3(sign(n0.x), 0.0, 0.0) : float3(0.0, sign(n0.y), 0.0));
            } else if (ti == 4) {                                   // cone (base -z → apex +z)
                tgt = float3(dirXY * 0.5 * (1.0 - n0.z), n0.z);
                tn = normalize(float3(dirXY * 2.0, 1.0));
            } else if (ti == 5) {                                   // ring (torus, hole through z)
                float v = asin(clamp(n0.z, -1.0, 1.0)) * 2.0;
                tgt = float3(dirXY * (0.7 + 0.3 * cos(v)), 0.3 * sin(v));
                tn = normalize(float3(dirXY * cos(v), sin(v)));
            } else if (ti == 6) {                                   // disc (flat coin, faces camera)
                tgt = float3(n0.xy * 1.2, n0.z * 0.1);
                tn = float3(0.0, 0.0, n0.z >= 0.0 ? 1.0 : -1.0);
            } else if (ti == 7) {                                   // spike (6-point star along ±xyz)
                tgt = n0 * mix(0.25, 1.3, pow(mx, 6.0));
                tn = n0;
            } else if (ti == 8) {                                   // diamond (octahedron)
                tgt = n0 / max(ax + ay + az, 1e-4);
                tn = normalize(float3(sign(n0.x), sign(n0.y), sign(n0.z)));
            }
            lp = mix(lp, tgt * 0.5, m);
            nrm = normalize(mix(nrm, tn, m));
        }
        lp *= io.scl.xyz;                              // stretch
        float3 e = io.rot.xyz * 6.2831853;             // turns → radians
        if (e.x != 0.0 || e.y != 0.0 || e.z != 0.0) {
            lp = rotateEuler(lp, e);
            nrm = rotateEuler(nrm, e);
        }
        // Look At node: orient every pin's +z toward a point — iron-filings tracking.
        if (U.lookAt.w > 0.001) {
            float3 dirL = normalize(U.lookAt.xyz - float3(xy, z) + float3(1e-5, 0.0, 0.0));
            float3 xA = normalize(cross(float3(0.0, 1.0, 0.0), dirL));
            float3 yA = cross(dirL, xA);
            float3 lp2 = xA * lp.x + yA * lp.y + dirL * lp.z;
            float3 n2 = xA * nrm.x + yA * nrm.y + dirL * nrm.z;
            lp = mix(lp, lp2, U.lookAt.w);
            nrm = normalize(mix(nrm, n2, U.lookAt.w));
        }
        wp = float3(xy + lp.xy * size, z + lp.z * size);
    }

    VOut o;
    o.pos = U.viewProj * float4(wp, 1.0);
    o.nrm = nrm;
    o.color = U.isStem != 0u ? io.color.rgb * 0.55 : io.color.rgb;
    o.wpos = wp;
    return o;
}

fragment float4 pin_fragment(VOut in [[stage_in]],
                             constant Uniforms &U [[buffer(1)]]) {
    float3 n = normalize(in.nrm);
    float3 albedo = in.color;
    float rim = pow(1.0 - max(n.z, 0.0), 2.0);
    int mode = int(U.material.x + 0.5);
    if (mode == 0) return float4(albedo, 1.0);                    // Material UNLIT: flat color

    float rough = U.material.y, metal = U.material.z;
    int lightCount = clamp(int(U.material.w + 0.5), 0, 4);
    float3 v = normalize(U.eyePos.xyz - in.wpos);   // real view dir — speculars track the orbit
    float3 specCol = mix(float3(1.0), albedo, metal);
    float3 c;

    if (mode == 2) {                                              // MATCAP: analytic studio look
        float3 key = normalize(float3(0.5, 0.6, 0.65));
        float diff = max(dot(n, key), 0.0);
        float spec = pow(max(dot(reflect(-key, n), v), 0.0), mix(64.0, 6.0, rough));
        c = albedo * (0.22 + 0.62 * diff)
          + specCol * spec * (1.0 - rough * 0.6)
          + rim * 0.35 * mix(float3(1.0), albedo, 0.5);
    } else if (lightCount > 0) {                                  // Light nodes (up to 4)
        c = albedo * 0.12;
        for (int i = 0; i < lightCount; i++) {
            if (U.lightParams[i].z < 0.5) continue;
            float3 l; float atten = 1.0;
            float type = U.lightPos[i].w;
            if (type > 0.5 && type < 1.5) {
                l = normalize(U.lightPos[i].xyz);                 // directional
            } else {
                float3 d = U.lightPos[i].xyz - in.wpos;
                float dist = length(d);
                l = d / max(dist, 1e-4);
                atten = 1.0 / (1.0 + U.lightParams[i].y * dist * dist);
                if (type > 1.5) {                                 // spot: soft cone toward the centre
                    float3 axis = normalize(-U.lightPos[i].xyz);
                    atten *= smoothstep(0.55, 0.85, dot(-l, axis));
                }
            }
            float e = U.lightParams[i].x * atten;
            c += albedo * max(dot(n, l), 0.0) * 0.9 * e;
            float spec = pow(max(dot(reflect(-l, n), v), 0.0), mix(64.0, 4.0, rough));
            c += specCol * spec * (1.0 - rough) * e;
        }
        c += rim * 0.22 * albedo;
    } else {                                                      // built-in default light
        float3 l = normalize(float3(0.35, 0.5, 0.8));
        float diff = max(dot(n, l), 0.0);
        c = albedo * (0.35 + 0.72 * diff) + rim * 0.22 * albedo;
        float spec = pow(max(dot(reflect(-l, n), v), 0.0), mix(64.0, 4.0, rough));
        c += specCol * spec * (1.0 - rough) * 0.5;
    }
    return float4(c, 1.0);
}

// ============================================================================
// POST STACK — scene renders offscreen, then one composite pass applies the
// STAGE nodes: Background (solid + radial gradient), Bloom (bright-pass +
// gaussian, added here), Vignette, Grain. Runs for the view, NDI and Record.
// ============================================================================
struct PostParams {
    float4 bg;     // rgb = Background node color, w = gradient amount
    float4 fx;     // x bloomIntensity, y vignette, z grain, w time
    float4 misc;   // x alphaKey (1 = transparent bg out), y bloomOn, z/w unused
};

struct PostVOut {
    float4 pos [[position]];
    float2 uv;
};

vertex PostVOut post_vertex(uint vid [[vertex_id]]) {
    // fullscreen triangle
    float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    PostVOut o;
    o.pos = float4(p, 0.0, 1.0);
    o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    return o;
}

fragment float4 post_composite(PostVOut in [[stage_in]],
                               texture2d<float> scene [[texture(0)]],
                               texture2d<float> bloom [[texture(1)]],
                               constant PostParams &P [[buffer(0)]]) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float4 s = scene.sample(smp, in.uv);
    float3 c;
    if (P.misc.x > 0.5) {
        c = s.rgb;                                        // alpha-keyed: no background painted
    } else {
        float3 bg = P.bg.rgb;
        if (P.bg.w > 0.001) {                             // radial gradient: centre glow → dark edges
            float d = distance(in.uv, float2(0.5));
            bg *= mix(1.0, clamp(1.45 - d * 1.9, 0.0, 1.0), P.bg.w);
        }
        c = mix(bg, s.rgb, clamp(s.a, 0.0, 1.0));
    }
    if (P.misc.y > 0.5) c += bloom.sample(smp, in.uv).rgb * P.fx.x;
    if (P.fx.y > 0.001) {                                 // vignette
        float d = distance(in.uv, float2(0.5));
        c *= 1.0 - P.fx.y * smoothstep(0.35, 0.78, d);
    }
    if (P.fx.z > 0.001) {                                 // film grain, refreshed per frame
        float g = hash01(dot(in.pos.xy, float2(1.0, 787.0)) + fract(P.fx.w) * 4096.0) - 0.5;
        c = max(c + g * P.fx.z * 0.28, float3(0.0));
    }
    return float4(c, P.misc.x > 0.5 ? clamp(s.a, 0.0, 1.0) : 1.0);
}

// Bright-pass into a half-res texture; blurred by MPS, added back in post_composite.
kernel void bloom_brightpass(texture2d<float, access::sample> scene [[texture(0)]],
                             texture2d<float, access::write> outT [[texture(1)]],
                             constant float &threshold [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= outT.get_width() || gid.y >= outT.get_height()) return;
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(outT.get_width(), outT.get_height());
    float4 s = scene.sample(smp, uv);
    float3 c = s.rgb * s.a;
    float luma = dot(c, float3(0.299, 0.587, 0.114));
    outT.write(float4(c * smoothstep(threshold, threshold + 0.25, luma), 1.0), gid);
}

// ---- Temporal depth filter — TDLidar temporalDepthEMA port. Deadband HYSTERESIS HOLD
//      (zero jitter on static scenes) + velocity-adaptive alpha (motion pushes alpha → 1,
//      so movement never lags). State ping-pong: .r = emaZ, .g = jitter-energy velocity.
//      the EMA Smooth node's "stabilize" s drives: alpha = 1-0.9s, deadband = 0.008s + 0.012s/m. ----
struct EmaParams {
    float alpha;          // base EMA gain; 1 = passthrough
    float deadband;       // metres, absolute hold threshold
    float deadbandPerM;   // metres per metre of depth
    float motionAdapt;    // velocity → alpha boost
    float holePersist;    // 1 = keep last good depth through dropouts (FREE); 0 = retract (pinout)
    float reset;          // 1 = seed from current frame
    float pad0; float pad1;
};

// ---- Depth hole-fill — TDLidar's cleanupFillHoles port. The front IR projector casts a
//      depth SHADOW on one side of the subject (invalid pixels) that, with Apple filtering off,
//      reads as a black band / smear trail. Each invalid pixel is filled with the
//      inverse-distance-weighted average of its valid neighbours (radius scales with strength),
//      so the shadow closes WITHOUT Apple's smoothing. Runs before the temporal EMA.
struct FillParams { uint w; uint h; int radius; float gapThresh; };

// Fill an invalid pixel (IR shadow) toward the FOREGROUND, never a fg/bg blend. Two passes over
// the window: (1) find the nearest valid depth, (2) average only neighbours within gapThresh of it.
// A naive all-neighbour average blended the near face with the far background → mid-depth pins
// that "fall backwards" at the silhouette. This pulls the shadow onto the face surface instead.
kernel void depth_fill_holes(texture2d<float, access::read> inD [[texture(0)]],
                             texture2d<float, access::write> outD [[texture(1)]],
                             constant FillParams &P [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= P.w || gid.y >= P.h) return;
    float dC = inD.read(gid).r;
    if (dC > 0.05 && isfinite(dC)) { outD.write(float4(dC), gid); return; }   // already valid
    int R = P.radius;
    float dMin = 1e9;
    for (int dy = -R; dy <= R; ++dy) {
        for (int dx = -R; dx <= R; ++dx) {
            int2 q = int2(gid) + int2(dx, dy);
            if (q.x < 0 || q.y < 0 || q.x >= int(P.w) || q.y >= int(P.h)) continue;
            float d = inD.read(uint2(q)).r;
            if (d > 0.05 && isfinite(d)) dMin = min(dMin, d);
        }
    }
    if (dMin > 1e8) { outD.write(float4(0.0), gid); return; }   // no valid neighbours
    float wSum = 0.0, dSum = 0.0;
    for (int dy = -R; dy <= R; ++dy) {
        for (int dx = -R; dx <= R; ++dx) {
            int2 q = int2(gid) + int2(dx, dy);
            if (q.x < 0 || q.y < 0 || q.x >= int(P.w) || q.y >= int(P.h)) continue;
            float d = inD.read(uint2(q)).r;
            if (!(d > 0.05) || !isfinite(d) || d > dMin + P.gapThresh) continue;   // foreground only
            float w = 1.0 / float(dx * dx + dy * dy + 1);
            wSum += w; dSum += d * w;
        }
    }
    outD.write(float4(wSum > 1e-6 ? dSum / wSum : 0.0), gid);
}

// ---- FILTER-node cleanup chain (after fill-holes + EMA): Despeckle Voxel, Smooth
//      Surface (bilateral), Accumulate (temporal). Presence of the node runs the pass. ----
struct CleanParams { uint w; uint h; float gap; float radius; float alpha; float reset; float pad0; float pad1; };

// Despeckle Voxel: drop isolated returns — a pixel survives only with enough neighbours
// at a similar depth (within GAP metres) in its 5×5 window.
kernel void depth_despeckle(texture2d<float, access::read> inD [[texture(0)]],
                            texture2d<float, access::write> outD [[texture(1)]],
                            constant CleanParams &P [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= P.w || gid.y >= P.h) return;
    float d = inD.read(gid).r;
    if (!(d > 0.05) || !isfinite(d)) { outD.write(float4(0.0), gid); return; }
    int support = 0;
    for (int dy = -2; dy <= 2; ++dy) {
        for (int dx = -2; dx <= 2; ++dx) {
            if (dx == 0 && dy == 0) continue;
            int2 q = int2(gid) + int2(dx, dy);
            if (q.x < 0 || q.y < 0 || q.x >= int(P.w) || q.y >= int(P.h)) continue;
            float dn = inD.read(uint2(q)).r;
            if (dn > 0.05 && isfinite(dn) && fabs(dn - d) < P.gap) support++;
        }
    }
    outD.write(float4(support >= max(int(P.radius), 1) ? d : 0.0), gid);   // SUPPORT slider
}

// Smooth Surface: 2D bilateral — smooths surfaces without bleeding across silhouettes
// (range sigma ~5 cm). RADIUS 1-4 px.
kernel void depth_bilateral(texture2d<float, access::read> inD [[texture(0)]],
                            texture2d<float, access::write> outD [[texture(1)]],
                            constant CleanParams &P [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= P.w || gid.y >= P.h) return;
    float d = inD.read(gid).r;
    if (!(d > 0.05) || !isfinite(d)) { outD.write(float4(0.0), gid); return; }
    int R = clamp(int(P.radius), 1, 4);
    float invS2 = 1.0 / (2.0 * float(R) * float(R) * 0.25 + 0.5);
    float wSum = 0.0, dSum = 0.0;
    for (int dy = -R; dy <= R; ++dy) {
        for (int dx = -R; dx <= R; ++dx) {
            int2 q = int2(gid) + int2(dx, dy);
            if (q.x < 0 || q.y < 0 || q.x >= int(P.w) || q.y >= int(P.h)) continue;
            float dn = inD.read(uint2(q)).r;
            if (!(dn > 0.05) || !isfinite(dn)) continue;
            float dz = (dn - d) / max(P.gap, 0.005);                     // SIGMA slider (range sigma, m)
            float w = exp(-float(dx * dx + dy * dy) * invS2 - dz * dz);
            wSum += w; dSum += dn * w;
        }
    }
    outD.write(float4(wSum > 1e-6 ? dSum / wSum : d), gid);
}

// Accumulate: temporal blend toward the current frame (alpha = 1/FRAMES) — denser,
// calmer cloud; holes keep the accumulated depth.
kernel void depth_accumulate(texture2d<float, access::read> cur [[texture(0)]],
                             texture2d<float, access::read> prev [[texture(1)]],
                             texture2d<float, access::write> outT [[texture(2)]],
                             constant CleanParams &P [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= P.w || gid.y >= P.h) return;
    float d = cur.read(gid).r;
    bool dv = d > 0.05 && isfinite(d);
    if (P.reset > 0.5) { outT.write(float4(dv ? d : 0.0), gid); return; }
    float p = prev.read(gid).r;
    bool pv = p > 0.05 && isfinite(p);
    float o = dv ? (pv ? p + (d - p) * P.alpha : d) : (pv ? p : 0.0);
    outT.write(float4(o), gid);
}

// Detail Upsample: joint bilateral upsample (TDLidar JBU) — depth resampled at FACTOR×
// resolution, guided by the RGB image so depth edges snap to color edges. gap lane = luma
// sigma; alpha lane = colorIsLuma flag.
kernel void depth_jbu(texture2d<float, access::sample> inD [[texture(0)]],
                      texture2d<float, access::sample> guide [[texture(1)]],
                      texture2d<float, access::write> outD [[texture(2)]],
                      constant CleanParams &P [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= P.w || gid.y >= P.h) return;
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    constexpr sampler nn(filter::nearest, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5) / float2(P.w, P.h);
    float4 gC = guide.sample(smp, uv);
    float lumC = P.alpha > 0.5 ? gC.r : dot(gC.rgb, float3(0.299, 0.587, 0.114));
    float2 lowTexel = float2(1.0 / float(inD.get_width()), 1.0 / float(inD.get_height()));
    float wSum = 0.0, dSum = 0.0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            float2 quv = uv + float2(dx, dy) * lowTexel;
            float d = inD.sample(nn, quv).r;
            if (!(d > 0.05) || !isfinite(d)) continue;
            float4 gN = guide.sample(smp, quv);
            float lumN = P.alpha > 0.5 ? gN.r : dot(gN.rgb, float3(0.299, 0.587, 0.114));
            float dl = (lumN - lumC) / max(P.gap, 0.01);          // luma range sigma
            float w = exp(-float(dx * dx + dy * dy) * 0.4 - dl * dl);
            wSum += w; dSum += d * w;
        }
    }
    outD.write(float4(wSum > 1e-6 ? dSum / wSum : 0.0), gid);
}

kernel void depth_ema(texture2d<float, access::read> cur [[texture(0)]],
                      texture2d<float, access::read> prev [[texture(1)]],
                      texture2d<float, access::write> outT [[texture(2)]],
                      constant EmaParams &P [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= cur.get_width() || gid.y >= cur.get_height()) return;
    float d = cur.read(gid).r;
    bool curValid = d > 0.05 && isfinite(d);
    if (P.reset > 0.5) { outT.write(float4(curValid ? d : 0.0, 0, 0, 1), gid); return; }
    float2 st = prev.read(gid).rg;
    float d0 = st.x, vel = st.y;
    bool prevValid = d0 > 0.05 && isfinite(d0);
    float dOut, velOut = vel;
    if (!curValid) {
        // Hole: persist ONLY under EMA Smooth (P.holePersist), else drop to 0 — TDLidar's raw
        // bypass. Persisting always left stale depth trailing off moving silhouettes (the
        // "aftereffect" strands); the old ×0.9 retract slid points toward the principal point.
        dOut = (P.holePersist > 0.5 && prevValid) ? d0 : 0.0;
        velOut = prevValid ? vel : 0.0;
    } else if (!prevValid) {
        dOut = d;                              // first sight: seed, no smoothing
        velOut = 0.0;
    } else {
        float delta = d - d0;
        float adelta = fabs(delta);
        float effDb = P.deadband + P.deadbandPerM * d;
        if (adelta <= effDb) {
            dOut = d0;                         // hysteresis hold → zero-jitter static
            velOut = vel * 0.7;
        } else {
            vel = vel * 0.7 + adelta * 0.3;    // jitter-energy low-pass
            float aEff = clamp(P.alpha + P.motionAdapt * vel, 0.0, 1.0);
            dOut = d0 + aEff * delta;          // motion → alpha ~1 → no lag
            velOut = vel;
        }
    }
    outT.write(float4(dOut, velOut, 0, 1), gid);
}
