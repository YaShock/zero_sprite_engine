# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Vision

Zero Sprite Engine is a 2D engine built in Odin on top of Raylib. The core constraint: **no sprite sheets or fixed-resolution artwork**. Every visible object must be described mathematically/procedurally.

## Commands

Enter the development environment (NixOS/Nix):
```
nix develop
```

Run a demo:
```
odin run src/demos/breakout
```

There is no separate build step — `odin run` compiles and runs in one command. Each demo under `src/demos/` is its own `package main`.

Profile any demo (F3 toggles the overlay, F4 writes a report to `profiles/`):
```
ZSE_PROFILE=1 odin run src/demos/galcon            # overlay on, report on exit
ZSE_PROFILE_SECONDS=20 odin run src/demos/galcon   # benchmark: quit after 20 s and write a report
```
`ZSE_PROFILE_SECONDS` runs first record nothing for a 5 s warm-up (`ZSE_PROFILE_WARMUP=N` changes it; `benchmark.sh` sets 0); `ZSE_PROFILE_OVERLAY=off` measures without drawing the overlay.

Repeatable frames for comparing builds: `ZSE_FIXED_DT=0.016667` advances scene time by a fixed step every frame. AlgoGame and Light Room also take `ALGO_SHOT=<s>` / `ROOM_SHOT=<s>` (save a screenshot at that game time and quit) and `ALGO_SEED` / `ROOM_SEED`; the other demos have no screenshot hook.

Entity editor (look scripts with live preview and param sliders), and its preset check:
```
odin run src/tools/editor
odin run src/tools/editor -- --check
```

Run headlessly (virtual X display, no window on the desktop; GLVND still picks the real GPU driver, but presenting through Xvfb copies every frame back to system memory, so frame rates and CPU usage there are not representative):
```
env -u WAYLAND_DISPLAY nix shell nixpkgs#xvfb-run -c xvfb-run -a -s '-screen 0 1600x900x24' odin run src/demos/breakout
```
If Xvfb isn't ready in time, raylib fails to open the window and the program exits at once (exit code 0, no frames, no profiler report); just run it again.

Benchmark every demo (20 s each, headless; reports go to `profiles/bench/<label>/`; AlgoGame and Light Room play themselves when `ZSE_PROFILE_SECONDS` is set):
```
src/tools/benchmark.sh <label>
```

The OLS language server is configured via `ols.json` at the repo root.

## Changelog

`CHANGELOG.md` must be updated before each commit: add an entry for the commit with the profiler results, measured as described at the top of that file (run `src/tools/benchmark.sh` for the previous commit, from a `git worktree`, and for the new code, alternately, twice each, in one session) and compared with the previous entry. If the results show an unacceptable performance degradation, don't add the entry or commit; fix the regression first, or ask the user whether the cost is acceptable. Title the entry with the commit's subject (a commit can't contain its own hash); add the hash to that heading when writing the next entry, as in `<hash> — <subject>`.

## Architecture

Guiding principles: everything visible except text is a shader-computed visual effect; effects are composable mathematical functions governed by parameters; demos contain only game logic plus compositions of those functions.

### VFX language (`src/engine/vfx/`)

A "look" is an expression tree of `^vfx.Node` built with constructors in `node.odin` (`coord`, `world`, `uv`, `time`, `age`, `param`, arithmetic, `fbm`, `voronoi`, `sd_box`, `fill`, `glow`, `lit`, `stack`, `shatter`, `sparks`, ...). `vfx.Expr` is a union that also accepts plain `f32`, `[2]f32`, `[4]f32` and `rl.Color`, so constants can be passed directly.

- Every node is a pure function of the local coordinate `p` (object space, origin at the entity center, virtual units, y down). `codegen.odin` emits each node as a GLSL function `T n<id>(vec2 p)`, so subtrees can be re-evaluated at other positions (`at`, `lit` finite differences, `shatter`).
- Every numeric leaf becomes a parameter slot (packed four per vec4), which the fragment shader reads from the entity's instance record with `u_p(i)` (see Drawing below); only tree *structure* (plus compile-time ints such as fbm octaves or shard grid size) is baked into the shader, so e.g. all bricks of one kind share one shader and differ only in parameter values.
- The shader cache is keyed by `vfx.layout(look)`: a hash of the structure plus the parameter slots' initial values. Both come from `walk` in `codegen.odin`, the one pass that hashes the tree (children first, shared nodes once) and assigns every slot (constants, params, param/data arrays, the instances array); `compile` runs it first and only looks slots up, so `layout` and `compile` agree by construction. GLSL is generated only for structures not seen yet. Anything that changes the generated code (a new `Node` field, op-specific data) must also be fed into `walk`'s hash.
- `InitOptions.bake_constants` makes constants GLSL literals instead of slots (their values are then part of the key): faster shaders, but looks that differ only in a constant no longer share one. AlgoGame and Light Room use it.
- Generated `main` is straight-line code (`emit_local`): every node once into a local `t<k>`. Only subtrees evaluated at other positions become functions `T n<id>(vec2 p)` (`emit`; the ops listed in `emit_local`'s function case: `at`, `lit`, `lit_scene`, `shatter`; a new op that re-evaluates a child elsewhere must be added there). `gate(condition, value)` computes `value` only inside an `if`.
- `vfx.param(name, default)` creates a named slot that game code changes at runtime with `eng.set_param(id, name, value)`.
- Nodes are allocated with `context.temp_allocator`; trees are transient and freed at the end of the frame.
- Lists of values set by game code: `param_array` (slots in the instance record, read by index with `pget`; a few hundred values at most), `data_array` (a float texture owned by the material, read with `dget`, uploaded only where `eng.set_param_array` wrote), and `instances` (an instanced look: one entity draws one quad per record of the array in a single draw call through `vertex_instanced.glsl`; `eng.set_instances` sets the records; `instance`/`instance4`/`instance4_of` read them, `coord()` is relative to the record's quad). Readers: `curve`, `sd_capsules`, `sd_capsule_groups`, `glow_points`, `metaballs`; with `bins` from `eng.bin_shapes` (`bins.odin`) each pixel visits only the shapes in its grid cell.
- 3D looks (Light Room) cast a ray through each pixel: `march_solid`/`solid_normal` (sphere tracing of `Solid` kinds), `point_lights`, `capsule_shadows`, `capsule_occlusion`, `haze_lights`; positions and directions are vec4s with w = 0. `layer_sample` reads a buffer layer (see Engine). These nodes, the array readers and instancing are not in the look-script `BUILTINS`; `int_fbm`, `falloff` and `gate` are.
- The GLSL library lives in `vfx/glsl/`: `vertex.glsl` (the vertex shader of every look), `vertex_instanced.glsl` (of instanced looks; `vfx.vertex_shader_of` tells them apart by a marker line in the fragment source, which the shader manifest relies on), `header.glsl` (inputs, uniforms and the `Instances` block) and `prelude.glsl` (noise, SDF, lighting and particle helpers that generated code calls by name). `glsl.odin` embeds them with `#load`, so the binary has no runtime file dependency; renaming a helper means updating `codegen.odin` too. `editor --check` compiles the library (both vertex shaders too) on its own before the presets. Format strings passed to `fmt.sbprintf` in `codegen.odin` must escape braces as `{{`/`}}`.

- Every constructor takes `loc := #caller_location` and tags its node with the calling procedure (`Node.origin`), so a look's root names the function that built it; the profiler uses this to label looks.

Adding a node: add an `Op`, a constructor in `node.odin` (with the `loc` parameter, returning through `origin`), its case in `emit` in `codegen.odin`, and, to expose it to look scripts, an entry in `BUILTINS` in `script.odin`.

**Lighting**: `lit(color, height, light)` shades a height field from one fixed direction per look; `lit_scene(color, height, light)` uses the engine's scene lights instead (see below), with the pixel's world position and the entity's rotation applied, and counts as animated (never cached).

**Look scripts** (`script.odin`): a small text language mapping 1:1 onto the constructors (`let`, `param NAME = V in [MIN, MAX] animate PERIOD`, `size`, `pad`, `lifetime`, operators with constant folding, swizzles, named arguments). `parse_script` type-checks arguments so most mistakes are reported with line/column instead of producing bad GLSL.

### Engine (`src/engine/`)

Single global scene (`scene` in `entity.odin`, `engine` in `engine.odin`); all procs operate on these singletons.

1. `init_context(InitOptions)`: window at a virtual resolution, letterboxed via a `Camera2D` (no render texture, so shaders evaluate at native resolution; `u_px` gives the virtual size of one pixel for anti-aliasing). Frame pacing: raylib's busy-waiting limiter is disabled; `InitOptions.vsync` (`Auto` by default, also `On`/`Off`, changeable with `set_vsync`) starts with vsync and, in `Auto`, turns it off after ~1.5 s if it keeps the game below `fps` (e.g. a 60 Hz monitor with `fps = 144`); without vsync the engine sleeps to the target, spinning only the last millisecond. Monitor refresh rates aren't queried because Wayland doesn't report which monitor a window is on. For the same reason raylib's borderless mode (`ToggleBorderlessWindowed`) always fills monitor 0 there; `fill_monitor(i)` fills a chosen one (on Wayland by calling `glfwSetWindowMonitor` directly, `gpu_posix.odin`), and `find_monitor` takes a number or a name such as `HDMI-A-1` (Light Room's `ROOM_MONITOR`).
2. `add_entity(look, pos, size, SpawnOptions)` compiles the look into a `Material` (shared shader + owned param values) and returns an `int` ID. `pos` is the **center**; `size` is the logical size seen by `vfx.size()`; `pad` enlarges the drawn quad for glows/debris; `lifetime` auto-removes the entity; `blend` selects alpha/additive. `add_text` adds the only non-shader drawable.
3. `run(on_update)`: advances scene time (scaled by `set_time_scale`, 0 = paused), calls `on_update`, draws layers in z order, removes expired entities, frees the temp allocator. `quit()` ends it after the frame.

`Drawable :: union { Material, Text }`, `Collider :: union { RectCollider, CircleCollider }`. `BlendMode`: `Alpha`, `Additive`, `Premultiplied` (the look returns premultiplied color, so one look can draw solid shapes and the light around them) and `Max`. Layers use swap-with-last removal; `set_layer_y_sorted` makes a layer draw by the bottom edge of each entity (for three-quarter views), `set_layer_sorted` by `set_sort_key`, highest first (e.g. distance from a 3D camera). `collide(a, b)` returns a `Contact` (normal pointing from b to a, depth); colliders are centered on the entity.

Special layers (`entity.odin`): `set_layer_resolution` draws a layer into an image `divisor` times smaller (optionally blurred, half-float with `precise`) and stretches it over the screen (out of focus, and divisor² cheaper to shade); `set_layer_buffer` draws it into a half-float image that is never shown, only read by looks with `vfx.layer_sample`; `set_layer_bloom` copies the screen drawn so far at that point, blurs its bright parts and adds them back. Images and buffers are rendered before the frame (`render_layer_images`, with `engine.px_factor` > 1 for the pixel size); in the frame, a bloom or image layer flushes the draws batched so far.

`gpu.odin` holds the direct OpenGL work: instanced draws, timer queries, compiling generated shaders to get the driver's error log, float render targets, and the program cache: linked programs saved with `glGetProgramBinary` under `$XDG_CACHE_HOME` (or `~/.cache`, `%LOCALAPPDATA%` on Windows) `/zero_sprite_engine/shaders`, keyed by both shader sources plus the GPU and driver, so a look compiled once loads at once in any later run of any game (`ZSE_SHADER_CACHE=off` disables it). Platform specifics live in `gpu_posix.odin` (binds the few rlgl symbols it needs directly from `system:raylib`, because `vendor:raylib/rlgl` links a bundled static library that the Nix raylib does not provide, and loads OpenGL through the system GLFW that raylib uses) and `gpu_windows.odin` (raylib bundles GLFW there, so GL is loaded through WGL and vsync goes through raylib); `profiler_posix.odin`/`profiler_windows.odin` read memory and CPU time. `try_make_material` reports a rejected shader instead of panicking; `draw_material_at` draws a material outside the scene (tool previews). `set_overlay` adds a per-frame draw callback in virtual coordinates; `InitOptions.match_window` makes the virtual resolution follow the window (tools).

**Drawing** (`material.odin`, `batching.odin`, `gpu.odin`): looks are drawn with instancing, not through raylib. `render_entities` first groups the scene (`batching.odin`): walking the layers in z order, each entity joins the newest group of its shader and blend mode unless an entity in a later group overlaps its quad (rotated bounding boxes, looked up in a 32×32 grid over the virtual screen; quads that only share an edge don't overlap), and otherwise starts a new group. Only the order of overlapping quads is kept, so mixed layers batch too; text and cached looks are groups of one. The groups then become a `DrawList`: consecutive instances with the same shader, blend mode and pixel size share one `DrawCall`, and whatever raylib draws is a `RaylibDraw` step in between. `submit_draws` uploads all instance records at once and issues the steps (`glDrawArraysInstanced` per call). Each instance is a record of vec4s (quad, size/rotation/age, extent/origin, then the parameter slots); a call binds a 64 KB window of the uniform buffer (`INSTANCE_VEC4S` = 4096) as its shader's `Instances` block, starting at its first record. Generated code reads slots with `u_p(i)`: in a call of one instance (and in instanced looks) at the constant index `3 + i`, which drivers keep in registers like uniforms; a call of several instances uses the shader's batched variant (`vfx.batched_source`: `u_p(i)` indexed by the instance's flat `v_params`), compiled the first time the look is drawn batched (`call_program`) and recorded in the shader manifest. Indexing by `v_params` turns every parameter read into a memory load on Intel (Light Room's letters took 75% longer), so a shader drawn alone must not pay for batching. Measured alternatives that were slower: a buffer texture (a fetch per parameter per pixel), `glBufferSubData` per draw call (a stall per call) and mapping per draw call (the driver then keeps the buffer in system memory, slowing large quads). `draw_material_at` and cache refreshes go through a one-instance list (`draw_now`). A material with data arrays owns a float texture (bound on unit 1; buffer layers on 2 and 3), so consecutive instances share a call only if they share it; an instanced look's call draws its one entity record `m.instances` times, and the grouping uses the box around its records' quads instead of the entity's quad. Only `u_time`, `u_px`, the matrices (read from rlgl, so camera and render-texture modes work) and the scene lights are uniforms. The profiler's per-look "draws" are draw calls.

**Scene lights** (`lights.odin`): up to `MAX_LIGHTS` (8, matching `glsl/header.glsl`) point or directional lights plus an ambient color, for looks built with `vfx.lit_scene`: `add_light` returns an id, `get_light(id)` to move/recolor, `remove_light`, `clear_lights`, `set_ambient`. The engine starts with ambient 0.25 plus a key light equivalent to `lit`'s default, so switching a look to `lit_scene` keeps its appearance; games usually `clear_lights()` and set up their own. Light uniforms are packed once per frame and uploaded to each shader that uses them once per frame (`ShaderEntry.lights_frame`). Breakout's ball and Galcon's sun are scene lights.

**Shader manifest** (`shader_manifest.odin`): every shader a game compiles is recorded in `.shader-cache/<title>.shaders` (gitignored) and compiled again at the next startup, before the first frame, so effects first seen mid-game in an earlier run don't stall later runs. Entries are matched by full generated source, so a stale manifest costs only startup time; entries unused for 5 runs are dropped. `InitOptions.no_shader_manifest` turns it off (the editor does). `precompile()` is still useful for the first run.

**Profiler** (`profiler.odin`): CPU zones form a call tree keyed by (name, parent); the engine times `update`/`render`/`present`/`cleanup` and game code adds `eng.profile_scope("name")`. Under `render`, `offscreen` (caches and layer images) and `flush` are timed apart, since some drivers (NVIDIA on Windows) wait for the display there instead of in the buffer swap; the verdict leaves them out of CPU work. GPU time per look comes from timestamp queries around each material draw, read back a few frames later. Shader compile time and startup are tracked separately from per-frame averages. Tool UIs and the profiler overlay are drawn with plain raylib primitives, not vfx, so they stay cheap and don't distort what is measured.

### Tools (`src/tools/`)

- `editor/`: entity editor. `text_editor.odin` (code editor widget), `ui.odin` (immediate-mode widgets, interface colors), `editor.odin` (app: recompiles after typing pauses, keeps the last good look on errors, param sliders and animation, presets in `presets/*.look`, reference and GLSL views). Presets include looks ported from the demos (`cave_rock`, `cave_fog`, `nanobot` from AlgoGame, `light_glow` from Light Room) with their arrays replaced by simple stand-ins.

### Demos (`src/demos/`)

Each demo is a self-contained `package main` importing `eng "../../engine"` and `fx "../../engine/vfx"`, split into `colors.odin` (named compile-time `rl.Color` constants), `looks.odin` (compositions) and the game logic file.

- `breakout/`: bricks, wall background, paddle, ball, explosions.
- `tower_defense/`: randomized terrain and road (`terrain_look`), walking golems whose animation, facing, health and status effects are params (`enemy_look`), three towers with level-driven looks, projectiles, shard deaths; balance tables live in `data.odin`.
- `stress/`: performance test, not a game. Deterministic (fixed seed, no input, uncapped frame rate) and staged: ~400 still looks from six families, +400 animated ones from eight more, +300 rotating movers under 6 moving scene lights with per-frame param and text updates (y-sorted layer), +120 spawned effects per second, then double the animated and mover load. Each family is its own `*_look` function in two structural variants, so the profiler reports it on its own line. After each stage it prints entity count, setup time and frame avg/p99 (`benchmark.sh` keeps that in `<demo>.log`).
- `algo_game/`: AlgoGame, an underwater cave flyer: cave rock and corals as instanced looks, the ship, sparks and jellyfish as capsule lists (`sd_capsules`, with bins for the long ones), spores and wall glows as instanced light splats, goo as blobs splatted into a buffer layer that its outline look samples, out-of-focus fog and jellyfish layers. `ALGO_STAGE` keeps only what an earlier stage of the port had.
- `light_room/`: Light Room, a 3D tech demo: a room, a flood and an underwater scene, every object a sphere-traced or capsule look on a sorted layer, with point lights, capsule shadows and occlusion (shadow buffer layer), haze, reflections and bloom (`ROOM_SHADOWS`, `ROOM_AO`, `ROOM_HAZE`, `ROOM_REFLECTIONS`, `ROOM_BLOOM` = off to compare). `ROOM_PART=flood|deep` starts later.
- `galcon/`: Galcon Fusion clone. Space backdrop, drifting asteroids/debris/comets, planets as rotating lit globes (`sphere` + `planet_surface` per kind, randomized palettes), owner rings and selection driven by params; bot AI lives in `bots.odin`.
