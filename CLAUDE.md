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

The OLS language server is configured via `ols.json` at the repo root.

## Architecture

Guiding principles: everything visible except text is a shader-computed visual effect; effects are composable mathematical functions governed by parameters; demos contain only game logic plus compositions of those functions.

### VFX language (`src/engine/vfx/`)

A "look" is an expression tree of `^vfx.Node` built with constructors in `node.odin` (`coord`, `world`, `uv`, `time`, `age`, `param`, arithmetic, `fbm`, `voronoi`, `sd_box`, `fill`, `glow`, `lit`, `stack`, `shatter`, `sparks`, ...). `vfx.Expr` is a union that also accepts plain `f32`, `[2]f32`, `[4]f32` and `rl.Color`, so constants can be passed directly.

- Every node is a pure function of the local coordinate `p` (object space, origin at the entity center, virtual units, y down). `codegen.odin` emits each node as a GLSL function `T n<id>(vec2 p)`, so subtrees can be re-evaluated at other positions (`at`, `lit` finite differences, `shatter`).
- Every numeric leaf becomes a slot in `uniform vec4 u_p[]` (packed four per vec4, since drivers may pad each element of a float array to a full register); only tree *structure* (plus compile-time ints such as fbm octaves or shard grid size) is baked into the shader. The generated source is the shader cache key, so e.g. all bricks of one kind share one shader and differ only in parameter values.
- `vfx.param(name, default)` creates a named slot that game code changes at runtime with `eng.set_param(id, name, value)`.
- Nodes are allocated with `context.temp_allocator`; trees are transient and freed at the end of the frame.
- GLSL helpers (noise, SDFs, lighting) live in `glsl.odin`. Format strings passed to `fmt.sbprintf` must escape braces as `{{`/`}}`.

Adding a node: add an `Op`, a constructor in `node.odin`, and its case in `emit` in `codegen.odin`.

### Engine (`src/engine/`)

Single global scene (`scene` in `entity.odin`, `engine` in `engine.odin`); all procs operate on these singletons.

1. `init_context(InitOptions)`: window at a virtual resolution, letterboxed via a `Camera2D` (no render texture, so shaders evaluate at native resolution; `u_px` gives the virtual size of one pixel for anti-aliasing).
2. `add_entity(look, pos, size, SpawnOptions)` compiles the look into a `Material` (shared shader + owned param values) and returns an `int` ID. `pos` is the **center**; `size` is the logical size seen by `vfx.size()`; `pad` enlarges the drawn quad for glows/debris; `lifetime` auto-removes the entity; `blend` selects alpha/additive. `add_text` adds the only non-shader drawable.
3. `run(on_update)`: advances scene time (scaled by `set_time_scale`, 0 = paused), calls `on_update`, draws layers in z order, removes expired entities, frees the temp allocator.

`Drawable :: union { Material, Text }`, `Collider :: union { RectCollider, CircleCollider }`. Layers use swap-with-last removal; `set_layer_y_sorted` makes a layer draw by the bottom edge of each entity (for three-quarter views). `collide(a, b)` returns a `Contact` (normal pointing from b to a, depth); colliders are centered on the entity.

`material.odin` binds `rlGetTextureIdDefault`/`rlGetShaderIdDefault` directly from `system:raylib`, because `vendor:raylib/rlgl` links a bundled static library that the Nix raylib does not provide.

### Demos (`src/demos/`)

Each demo is a self-contained `package main` importing `eng "../../engine"` and `fx "../../engine/vfx"`, split into `colors.odin` (named compile-time `rl.Color` constants), `looks.odin` (compositions) and the game logic file.

- `breakout/`: bricks, wall background, paddle, ball, explosions.
- `tower_defense/`: randomized terrain and road (`terrain_look`), walking golems whose animation, facing, health and status effects are params (`enemy_look`), three towers with level-driven looks, projectiles, shard deaths; balance tables live in `data.odin`.
- `galcon/`: Galcon Fusion clone. Space backdrop, drifting asteroids/debris/comets, planets as rotating lit globes (`sphere` + `planet_surface` per kind, randomized palettes), owner rings and selection driven by params; bot AI lives in `bots.odin`.
