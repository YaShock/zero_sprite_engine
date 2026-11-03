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

Benchmark every demo (20 s each, headless; reports go to `profiles/bench/<label>/`):
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
- The shader cache is keyed by `vfx.layout(look)`: a hash of the structure that walks the tree exactly like `emit` (children first, shared nodes once, ids in emission order) and also collects the parameter slots' initial values. GLSL is generated only for structures not seen yet. Anything that changes the generated code (a new `Node` field, op-specific data) must also be fed into `walk` in `codegen.odin`; on a cache miss `try_make_material` asserts that `layout` and `compile` agree on the slots.
- `vfx.param(name, default)` creates a named slot that game code changes at runtime with `eng.set_param(id, name, value)`.
- Nodes are allocated with `context.temp_allocator`; trees are transient and freed at the end of the frame.
- The GLSL library lives in `vfx/glsl/`: `vertex.glsl` (the one vertex shader of every look), `header.glsl` (inputs, uniforms and the `Instances` block) and `prelude.glsl` (noise, SDF, lighting and particle helpers that generated code calls by name). `glsl.odin` embeds them with `#load`, so the binary has no runtime file dependency; renaming a helper means updating `codegen.odin` too. `editor --check` compiles the library on its own before the presets. Format strings passed to `fmt.sbprintf` in `codegen.odin` must escape braces as `{{`/`}}`.

- Every constructor takes `loc := #caller_location` and tags its node with the calling procedure (`Node.origin`), so a look's root names the function that built it; the profiler uses this to label looks.

Adding a node: add an `Op`, a constructor in `node.odin` (with the `loc` parameter, returning through `origin`), its case in `emit` in `codegen.odin`, and, to expose it to look scripts, an entry in `BUILTINS` in `script.odin`.

**Lighting**: `lit(color, height, light)` shades a height field from one fixed direction per look; `lit_scene(color, height, light)` uses the engine's scene lights instead (see below), with the pixel's world position and the entity's rotation applied, and counts as animated (never cached).

**Look scripts** (`script.odin`): a small text language mapping 1:1 onto the constructors (`let`, `param NAME = V in [MIN, MAX] animate PERIOD`, `size`, `pad`, `lifetime`, operators with constant folding, swizzles, named arguments). `parse_script` type-checks arguments so most mistakes are reported with line/column instead of producing bad GLSL.

### Engine (`src/engine/`)

Single global scene (`scene` in `entity.odin`, `engine` in `engine.odin`); all procs operate on these singletons.

1. `init_context(InitOptions)`: window at a virtual resolution, letterboxed via a `Camera2D` (no render texture, so shaders evaluate at native resolution; `u_px` gives the virtual size of one pixel for anti-aliasing). Frame pacing: raylib's busy-waiting limiter is disabled; `InitOptions.vsync` (`Auto` by default, also `On`/`Off`, changeable with `set_vsync`) starts with vsync and, in `Auto`, turns it off after ~1.5 s if it keeps the game below `fps` (e.g. a 60 Hz monitor with `fps = 144`); without vsync the engine sleeps to the target, spinning only the last millisecond. Monitor refresh rates aren't queried because Wayland doesn't report which monitor a window is on.
2. `add_entity(look, pos, size, SpawnOptions)` compiles the look into a `Material` (shared shader + owned param values) and returns an `int` ID. `pos` is the **center**; `size` is the logical size seen by `vfx.size()`; `pad` enlarges the drawn quad for glows/debris; `lifetime` auto-removes the entity; `blend` selects alpha/additive. `add_text` adds the only non-shader drawable.
3. `run(on_update)`: advances scene time (scaled by `set_time_scale`, 0 = paused), calls `on_update`, draws layers in z order, removes expired entities, frees the temp allocator.

`Drawable :: union { Material, Text }`, `Collider :: union { RectCollider, CircleCollider }`. Layers use swap-with-last removal; `set_layer_y_sorted` makes a layer draw by the bottom edge of each entity (for three-quarter views). `collide(a, b)` returns a `Contact` (normal pointing from b to a, depth); colliders are centered on the entity.

`gpu.odin` binds the few rlgl symbols it needs directly from `system:raylib` (because `vendor:raylib/rlgl` links a bundled static library that the Nix raylib does not provide) and loads OpenGL through the system GLFW that raylib uses, for instanced draws, timer queries and compiling generated shaders to get the driver's error log. `try_make_material` reports a rejected shader instead of panicking; `draw_material_at` draws a material outside the scene (tool previews). `set_overlay` adds a per-frame draw callback in virtual coordinates; `InitOptions.match_window` makes the virtual resolution follow the window (tools).

**Drawing** (`material.odin`, `batching.odin`, `gpu.odin`): looks are drawn with instancing, not through raylib. `render_entities` first groups the scene (`batching.odin`): walking the layers in z order, each entity joins the newest group of its shader and blend mode unless an entity in a later group overlaps its quad (rotated bounding boxes, looked up in a 32×32 grid over the virtual screen; quads that only share an edge don't overlap), and otherwise starts a new group. Only the order of overlapping quads is kept, so mixed layers batch too; text and cached looks are groups of one. The groups then become a `DrawList`: consecutive instances with the same shader, blend mode and pixel size share one `DrawCall`, and whatever raylib draws is a `RaylibDraw` step in between. `submit_draws` uploads all instance records at once and issues the steps (`glDrawArraysInstanced` per call). Each instance is a record of vec4s (quad, size/rotation/age, extent/origin, then the parameter slots); a call binds a 64 KB window of the uniform buffer (`INSTANCE_VEC4S` = 4096) as its shader's `Instances` block, and generated code reads slots with `u_p(i)`, indexed by the instance's flat `v_params`, which is as cheap as uniforms while a warp stays within one instance. Measured alternatives that were slower: a buffer texture (a fetch per parameter per pixel), `glBufferSubData` per draw call (a stall per call) and mapping per draw call (the driver then keeps the buffer in system memory, slowing large quads). `draw_material_at` and cache refreshes go through a one-instance list (`draw_now`). Only `u_time`, `u_px`, the matrices (read from rlgl, so camera and render-texture modes work) and the scene lights are uniforms. The profiler's per-look "draws" are draw calls.

**Scene lights** (`lights.odin`): up to `MAX_LIGHTS` (8, matching `glsl/header.glsl`) point or directional lights plus an ambient color, for looks built with `vfx.lit_scene`: `add_light` returns an id, `get_light(id)` to move/recolor, `remove_light`, `clear_lights`, `set_ambient`. The engine starts with ambient 0.25 plus a key light equivalent to `lit`'s default, so switching a look to `lit_scene` keeps its appearance; games usually `clear_lights()` and set up their own. Light uniforms are packed once per frame and uploaded to each shader that uses them once per frame (`ShaderEntry.lights_frame`). Breakout's ball and Galcon's sun are scene lights.

**Shader manifest** (`shader_manifest.odin`): every shader a game compiles is recorded in `.shader-cache/<title>.shaders` (gitignored) and compiled again at the next startup, before the first frame, so effects first seen mid-game in an earlier run don't stall later runs. Entries are matched by full generated source, so a stale manifest costs only startup time; entries unused for 5 runs are dropped. `InitOptions.no_shader_manifest` turns it off (the editor does). `precompile()` is still useful for the first run.

**Profiler** (`profiler.odin`): CPU zones form a call tree keyed by (name, parent); the engine times `update`/`render`/`present`/`cleanup` and game code adds `eng.profile_scope("name")`. GPU time per look comes from timestamp queries around each material draw, read back a few frames later. Shader compile time and startup are tracked separately from per-frame averages. Tool UIs and the profiler overlay are drawn with plain raylib primitives, not vfx, so they stay cheap and don't distort what is measured.

### Tools (`src/tools/`)

- `editor/`: entity editor. `text_editor.odin` (code editor widget), `ui.odin` (immediate-mode widgets, interface colors), `editor.odin` (app: recompiles after typing pauses, keeps the last good look on errors, param sliders and animation, presets in `presets/*.look`, reference and GLSL views).

### Demos (`src/demos/`)

Each demo is a self-contained `package main` importing `eng "../../engine"` and `fx "../../engine/vfx"`, split into `colors.odin` (named compile-time `rl.Color` constants), `looks.odin` (compositions) and the game logic file.

- `breakout/`: bricks, wall background, paddle, ball, explosions.
- `tower_defense/`: randomized terrain and road (`terrain_look`), walking golems whose animation, facing, health and status effects are params (`enemy_look`), three towers with level-driven looks, projectiles, shard deaths; balance tables live in `data.odin`.
- `stress/`: performance test, not a game. Deterministic (fixed seed, no input, uncapped frame rate) and staged: ~400 still looks from six families, +400 animated ones from eight more, +300 rotating movers under 6 moving scene lights with per-frame param and text updates (y-sorted layer), +120 spawned effects per second, then double the animated and mover load. Each family is its own `*_look` function in two structural variants, so the profiler reports it on its own line. After each stage it prints entity count, setup time and frame avg/p99 (`benchmark.sh` keeps that in `<demo>.log`).
- `galcon/`: Galcon Fusion clone. Space backdrop, drifting asteroids/debris/comets, planets as rotating lit globes (`sphere` + `planet_surface` per kind, randomized palettes), owner rings and selection driven by params; bot AI lives in `bots.odin`.
