# AGENTS.md — Points Visual LiDAR Synthesizer

## Project Overview

Points is a standalone iOS **visual synthesizer** — a live point cloud instrument with 110+ GPU nodes. The user creates patches by wiring nodes together in a graph, producing real-time Metal-rendered point cloud visuals driven by LiDAR, TrueDepth, or RGB camera sources plus audio/MIDI/OSC modulation.

- **Target:** iOS 26.5+, Swift 5.0, Metal
- **Bundle ID:** `aristides.lintzeris.Points`
- **Repo:** `/Users/ari/Documents/XcodeProjects/Points`

## Build & Test Commands

```bash
# Build via xcodemcp (always do full builds, never partial):
# Use xcodemcp for all build/test operations

# Profiling guidance: suggest Instruments templates for GPU/CPU/memory profiling
```

**Rule:** After every code change, run a full xcodemcp test build. Identify and resolve ALL warnings immediately. If xcodemcp isn't working, fix it before anything else.

## Project Vocabulary (Shorthand)

| Term | Meaning |
|------|---------|
| Points / dots / circles / spheres | Point cloud points (all synonyms) |
| Nodebar / nodeview bottom bar | Bottom bar with node browser |
| Cameraview / camerabar / camera view bottom bar | Bottom bar with sliders, pads, buttons |

## Architecture

See [Plans/00-Master-Plan.md](./Plans/00-Master-Plan.md) for the full architecture document.

### Key Principles

1. **GPU-resident points:** Points never leave the GPU. No CPU readback pipeline (the old TDLidar TCP path is deleted). Renderer fetches directly from the unprojector's interleaved 24-byte buffer.

2. **Three depth sources:**
   - **CLOUD** (back LiDAR): ARKit `.sceneDepth` → pin-screen conditioning → GPU unproject
   - **FACE** (front TrueDepth): AVCapture TrueDepth sync + ARKit blendshapes
   - **LUMEN** (back RGB): Luma-as-depth from BGRA, 60fps native (no sensor cap)

3. **Hybrid engine:**
   - **Layer A (GPU):** Pin program — a register VM with 58 opcodes executed per-point in Metal compute. Defined in `PinProgram.swift` (`PinOp` enum) and `Shaders.metal` (`pin_program` kernel). Field order MUST match between Swift and Metal structs.
   - **Layer B (CPU):** Control-rate nodes evaluated in Swift via `GraphRuntime`.

4. **PipelineStore:** Async Metal pipeline compilation off the main thread. Renderers request PSOSet; UI stays responsive during first-launch shader compile.

### Directory Map

| Path | Purpose |
|------|---------|
| `Points/` | App entry, UI, rendering, engines |
| `Points/Graph/` | Node graph model, runtime, registry, pin program VM |
| `Points/NDI/` | NDI video output (C bridge) |
| `Points/DepthImport/` | Depth video import, MoGe depth estimation |
| `Shared/` | Widget/Live Activity shared types |
| `Models/` | CoreML depth models (DepthPro, Depth Anything) |
| `Plans/` | Design docs, node catalog, testing plan |

### Key Files

| File | Role |
|------|------|
| `PointsApp.swift` | App entry, browser→stage flow, tutorial overlay |
| `PlayView.swift` | Flat "Signal-Loss" style controls (VSlider, pads) |
| `PinRenderer.swift` | Metal renderer: pipeline setup, frame dispatch, all GPU struct definitions |
| `Shaders.metal` | All Metal shaders: `pin_program` kernel, post-processing, lighting |
| `PinProgram.swift` | Pin instruction set (58 VM ops), `PinProgramBuilder`, `CompiledPinProgram` |
| `GraphRuntime.swift` | Live graph: compile→run, undo/redo, feature flags, `ProgramFrame` |
| `Graph.swift` | Document model: nodes, wires, validation, Codable persistence |
| `NodeRegistry.swift` | Node catalog: source/grid/filter/shape/move/color/signal/body/time/stage nodes |
| `NodeRegistryFull.swift` | Remaining nodes from the full catalog |
| `NodeRegistryVisualPack.swift` | Visual pack nodes |
| `NodeSpec.swift` | Type system: `PortType`, `NodeFamily`, `ParamSpec`, `NodeSpec`, auto-adapt rules |
| `TriggerNodes.swift` | Trigger/easing node implementations |
| `AudioEngine.swift` | Audio analysis (FFT, beat detection) |
| `MIDIEngine.swift` | MIDI input handling |
| `OSCEngine.swift` | OSC protocol |
| `NDIManager.swift` | NDI video output |
| `CameraSources.swift` | Camera pipeline management |
| `RecordingManager.swift` | MP4 recording |
| `VisionEngine.swift` | Vision framework (face tracking, etc.) |
| `Theme.swift` | Dark theme colors |

### Node System

Nodes are defined via `NodeSpec` in `NodeRegistry.swift` (and `NodeRegistryFull.swift`). Each spec has:
- **`id`**: Unique string key (e.g., `"depth"`, `"pinout"`, `"palette"`)
- **`family`**: Category (`source`, `grid`, `filter`, `shape`, `move`, `color`, `signal`, `body`, `time`, `stage`, `output`, `tools`)
- **`inputs`/`outputs`**: Typed ports with `PortType` (supports auto-adapt: broadcast, splat, color↔vec3)
- **`params`**: Float/bool/option parameters with ranges
- **`emit`**: Closure that generates `PinInstruction` sequences via `PinProgramBuilder`
- **`execution`**: `.interpreterOp` (GPU) or `.control` (CPU)

Ports use auto-adapt: `signal→fieldFloat` (broadcast), `vec3↔color`, `fieldFloat→fieldVec3` (splat), etc. See `PortType.accepts()`.

## Critical Conventions

### Metal/Swift Field Order Matching

**Non-negotiable:** Every struct crossing the Swift↔Metal boundary must have identical field order in both files. The key structs are:

| Swift Struct | Metal Struct | File |
|---|---|---|
| `PinUniforms` | `Uniforms` | `PinRenderer.swift` / `Shaders.metal` |
| `VMParamsSwift` | `VMParams` | `PinRenderer.swift` / `Shaders.metal` |
| `PinInstruction` | `PinInstr` | `PinProgram.swift` / `Shaders.metal` |
| `GizmoUniformsSwift` | `GizmoUniforms` | `PinRenderer.swift` / `Shaders.metal` |
| `FillParamsSwift` | `FillParams` | `PinRenderer.swift` / `Shaders.metal` |
| `CleanParamsSwift` | `CleanParams` | `PinRenderer.swift` / `Shaders.metal` |
| `EmaParamsSwift` | `EmaParams` | `PinRenderer.swift` / `Shaders.metal` |
| `PostParamsSwift` | `PostParams` | `PinRenderer.swift` / `Shaders.metal` |

When adding a field, update BOTH sides simultaneously. Mismatched layouts cause silent rendering corruption.

### PinOp Opcodes

The VM uses explicit opcodes in `PinOp` enum (58 ops). Some are retired: 41 and 42 are permanently retired (`pinField` ops). Do not reuse retired opcode numbers.

### Patches System

Runtime values are injected into compiled instructions via the `patches` dictionary (`[String: [PatchRef]]`). Keys are `"nodeID.paramName"` or `"nodeID.portName"`. This allows live slider updates without recompiling the pin program.

### Commit Convention

After every successful xcodemcp test build, make a git commit. Do NOT include "Claude" as an author.

## Development Environment

- **Apple docs:** Use `sosumi` MCP server and `/sosumi` skill
- **iOS best practices:** Use `/axiom` skills
- **Builds:** Use `xcodemcp` for full test builds
- **Profiling:** Suggest Instruments templates for performance analysis

## Model Files

Large ML models in `Models/`:
- DepthPro: encoder, decoder, depth, transform (`.mlpackage`)
- Depth Anything V2: metric ViT-S/B variants (`.pth`)
- MoGe2: normal estimation (`.mlpackage`) in `DepthImport/`

These are NOT committed to git (use git-lfs or external storage).
