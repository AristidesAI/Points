#include <metal_stdlib>
using namespace metal;

// Field order MUST match PinUniforms in PinRenderer.swift.
struct Uniforms {
    float4x4 viewProj;
    uint cols; uint rows; uint count; uint orient;      // orient bits: 1 swapUV, 2 flipU, 4 flipV
    float extX; float extY; float zWorldScale; float pinSize;   // zWorldScale = Camera node depth push
    float stemThickness; float nearM; float farM; uint colorMode;
    uint isStem; uint pad0; uint pad1; uint pad2;
};

// Field order MUST match VMParams in PinRenderer.swift.
struct VMParams {
    uint instrCount; uint stateStride; uint colorIsLuma; uint colorEnabled;
    float time; float beatPhase; float dt; float pad;
    float4 waveT;    // shockwave birth times (P.time clock); < -1e5 = inactive
    float4 waveCA;   // wave 0 center (xy), wave 1 center (zw) — view units
    float4 waveCB;   // wave 2 center (xy), wave 3 center (zw)
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
    float2 duv = mapUV(guv, U.orient);
    float2 baseXY = float2(mix(-U.extX, U.extX, guv.x), mix(U.extY, -U.extY, guv.y));

    float4 regs[32];
    float3 posOff = float3(0.0);
    float sizeMul = 1.0;
    float keep = 1.0;                               // grazing/edge culls (freeXY) zero this
    float3 rotAcc = float3(0.0);                    // Rotation/Spin (euler turns)
    float3 stretchAcc = float3(1.0);               // Stretch (per-axis scale)
    float shapeMorph = 0.0;                         // 0 sphere → 1 cube
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
                if (hi - lo > 0.06) keep = 0.0;      // ~6 cm spread = silhouette flying pixel
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
            case 10: r = A / max(B, float4(0.0001)); break;
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
            case 27: r = float4(hash01(A.x * ins.imm.x + ins.imm.y * 137.7)); break;
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
            case 41: {                                                          // pinFieldXY (Point Display)
                // imm = (separation, volume, wobble, edgeLock); A.x = depth nearness 0..1.
                float t = A.x;
                float2 rel = baseXY;                              // center of the pinout = origin
                float2 off = rel * (ins.imm.x - 1.0);            // SEPARATION: bunch/spread the grid
                off += rel * (t * ins.imm.y);                    // VOLUME: pins open outward with depth (TDLidar cloud)
                float2 wob = float2(hash01(float(gid) * 0.618) * 2.0 - 1.0,
                                    hash01(float(gid) * 1.113 + 31.7) * 2.0 - 1.0);
                off += wob * (t * ins.imm.z);                    // WOBBLE: depth-driven lateral jitter
                bool edgeP = (col == 0u || col == U.cols - 1u || row == 0u || row == U.rows - 1u);
                if (ins.imm.w > 0.5 && edgeP) off = float2(0.0); // EDGE LOCK: outer ring pinned to frame
                r = float4(off, 0.0, 0.0);
                break;
            }
            case 42: {                                                          // pinFieldZ (Point Display)
                // imm = (gain, gamma, zFlatten, edgeLock); A.x = depth nearness.
                float t = pow(max(A.x, 0.0), ins.imm.y) * ins.imm.x * ins.imm.z;
                bool edgeP = (col == 0u || col == U.cols - 1u || row == 0u || row == U.rows - 1u);
                if (ins.imm.w > 0.5 && edgeP) t = 0.0;
                r = float4(t);
                break;
            }
            case 44: {                                                          // freeXY (Point Display FREE mode)
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
            case 45: {                                                          // grazeCull (FILTER node)
                // TDLidar cleanup pass as a node: silhouette edge-reject + grazing-normal cull.
                // A passes through untouched; culled pins get size 0 via the kernel keep flag.
                // imm = (grazing01, edgeThreshM, 0, 0).
                // ponytail: principal point ≈ frame centre; rays use span 1.2 (~63° TrueDepth hFOV).
                r = A;
                float rawZ = depthTex.sample(smp, duv).r;
                if (!(rawZ > 0.05) || !isfinite(rawZ)) break;
                float2 texel = float2(1.0 / float(depthTex.get_width()),
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
            case 57: shapeMorph = A.x; write = false; break;                   // writeShape (0-1)
            case 58: r = float4(P.time * ins.imm.xyz, 0.0); break;             // spinTurns(rate)
            default: write = false; break;
        }
        if (write) regs[min(ins.dst, 31u)] = r;
    }

    outBuf[gid].posSize = float4(baseXY + posOff.xy, max(posOff.z, 0.0), sizeMul * keep);
    outBuf[gid].color = color;
    outBuf[gid].rot = float4(rotAcc, clamp(shapeMorph, 0.0, 1.0));
    outBuf[gid].scl = float4(stretchAcc, 0.0);
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
};

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
        wp = float3(xy + vin.pos.xy * U.stemThickness * io.posSize.w, (vin.pos.z + 0.5) * len);
    } else {
        // SHAPE family: morph sphere→cube, stretch per-axis, then rotate. Unit-mesh in local space.
        float3 lp = vin.pos;
        float m = io.rot.w;
        if (m > 0.001) {
            float mx = max(max(abs(lp.x), abs(lp.y)), abs(lp.z));
            float3 cube = mx > 1e-4 ? lp / mx : lp;   // project the sphere vertex onto the unit cube
            lp = mix(lp, cube, m);
        }
        lp *= io.scl.xyz;                              // stretch
        float3 e = io.rot.xyz * 6.2831853;             // turns → radians
        if (e.x != 0.0 || e.y != 0.0 || e.z != 0.0) {
            lp = rotateEuler(lp, e);
            nrm = rotateEuler(nrm, e);
        }
        wp = float3(xy + lp.xy * size, z + lp.z * size);
    }

    VOut o;
    o.pos = U.viewProj * float4(wp, 1.0);
    o.nrm = nrm;
    o.color = U.isStem != 0u ? io.color.rgb * 0.55 : io.color.rgb;
    return o;
}

fragment float4 pin_fragment(VOut in [[stage_in]]) {
    float3 n = normalize(in.nrm);
    float3 l = normalize(float3(0.35, 0.5, 0.8));
    float diff = max(dot(n, l), 0.0);
    float rim = pow(1.0 - max(n.z, 0.0), 2.0) * 0.22;
    float3 c = in.color * (0.35 + 0.72 * diff) + rim * in.color;
    return float4(c, 1.0);
}

// ---- Temporal depth filter — TDLidar temporalDepthEMA port. Deadband HYSTERESIS HOLD
//      (zero jitter on static scenes) + velocity-adaptive alpha (motion pushes alpha → 1,
//      so movement never lags). State ping-pong: .r = emaZ, .g = jitter-energy velocity.
//      Point Display's "stabilize" s drives: alpha = 1-0.9s, deadband = 0.008s + 0.012s/m. ----
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
        // hole: FREE persists (TDLidar — points never blink); pinout retracts to the wall
        dOut = prevValid ? (P.holePersist > 0.5 ? d0 : d0 * 0.90) : 0.0;
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
