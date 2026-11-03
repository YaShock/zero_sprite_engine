# Changelog

Each entry records a commit with the engine's own profiler results, so performance changes are visible commit by commit.

**How the numbers are measured.** `src/tools/benchmark.sh <label>` runs every demo for 20 s with `ZSE_PROFILE_SECONDS=20` on a virtual X display (see "Run headlessly" in `CLAUDE.md`). To compare two versions, run them alternately, twice each, in one session (the previous commit from a `git worktree`): the laptop heats up over a session, and runs taken minutes apart differ more than most changes do. Tables show the average of both runs and the worst frame of either. Breakout and Galcon get no input, so they measure the serve scene and the title screen; the tower defense run includes its first wave (at 12 s).

- GPU time per frame, startup time and shader compiles are representative, though GPU time drifts with the GPU's clock speed (by up to 2× within one session so far), so only compare entries measured side by side.
- FPS and CPU usage are not representative: presenting through the virtual display copies every frame back to system memory, which caps Breakout (set to 120 FPS) at about 75 FPS and keeps a CPU core busy. They are still comparable between versions measured the same way.
- Startup and compile times also depend on the graphics driver's own shader cache.

Hardware for all entries so far: NVIDIA GeForce RTX 3070 Laptop GPU.

## Group draws by look where quads don't overlap

- Before the draw list is built, the scene is grouped: each entity joins the newest group drawing its shader with its blending, i.e. it may be drawn earlier than its place in the scene order, unless something it would then be drawn before overlaps its quad. Only the order of overlapping quads is visible, so mixed layers (and looks spread over several layers) now share draw calls. Overlaps are looked up in a 32×32 grid over the virtual screen.
- Screenshots at a fixed time step are pixel-identical to 96b76a2 in Breakout, tower defense and Galcon; the stress test differs from it only as much as two runs of either version differ from each other.

| Demo | FPS | Frame ms (median / p99 / worst) | Hitches | GPU ms/frame | CPU | Startup ms | Shaders compiled |
|---|---|---|---|---|---|---|---|
| Breakout | 93.5 | 10.57 / 14.62 / 23.28 | 2 | 0.68 | 100% | 56 | 0 (20 from manifest in 29 ms) |
| Tower defense | 59.3 | 16.73 / 20.46 / 28.89 | 0 | 0.84 | 84% | 74 | 0 (27 from manifest in 42 ms) |
| Galcon | 59.6 | 16.72 / 18.45 / 30.51 | 0 | 0.58 | 80% | 22 | 0 (7 from manifest in 3 ms) |

Most expensive looks (GPU ms/frame): Breakout: `wall_background_look` 0.38 ms, `brick_look` 0.29 ms; Tower defense: `enemy_look` 0.51 ms, `panel_look` 0.15 ms; Galcon: `space_look` 0.57 ms, `asteroid_look` 0.01 ms.

Compared with 96b76a2, measured alternately in the same session (it measured 0.97, 0.89 and 0.64 ms of GPU time per frame there):

- Draw calls per frame: tower defense 18.2 → 11.9 (trees 6.1 → 2, boulders 3.3 → 2), Galcon 3.5 → 3.4, Breakout unchanged at 13 (its bricks were already consecutive).
- GPU time per frame in the three games is unchanged within noise: Breakout's 0.97 → 0.68 ms comes with the same 13 draw calls, so it is the GPU's clock, not the change.
- CPU time in `render` rises slightly in the small demos, the cost of grouping (zone `batch`, which also builds the draw list): Breakout 0.39 → 0.50 ms, tower defense 0.61 → 0.65 ms, Galcon 0.40 → 0.43 ms.
- All hitches, in both versions, were spent waiting in present (the compositor), not in the game's own work.

Stress test, the average of two runs (96b76a2 in parentheses):

| Stage | Entities | Setup ms | Frame avg ms | Frame p99 ms |
|---|---|---|---|---|
| 1. still variety | 400 | 12.9 | 22.3 (22.6) | 25.2 (26.2) |
| 2. animated | 800 | 10.6 | 25.1 (25.5) | 30.6 (31.1) |
| 3. movers and lights | 1,160 | 8.1 | 26.8 (26.4) | 32.3 (32.6) |
| 4. spawn churn (+120 effects/s) | 1,160 | 0 | 27.5 (28.7) | 32.5 (38.2) |
| 5. double load | 1,860 | 18.7 | 30.4 (30.9) | 35.6 (36.9) |

Over the whole run: 1,023 → 602 draw calls per frame, GPU time per frame 4.40 → 4.05 ms (`brick_look` 1.34 → 1.13 ms), CPU in `render` 3.47 → 3.24 ms, of which grouping takes 1.29 ms. Per family: animated tiles 51 → 20 calls, movers 93 → 27, spawned effects 7.5 → 3.6. Still tiles stay at 62–66 calls: each one's padding overlaps its neighbours', so every row has to be drawn in order. Stage frame times are present-bound on the virtual display (see bfa0220) and change within noise.

Also tried and not adopted: a variant of each look shader reading its parameters from plain uniforms, for draw calls whose instances all have the same values (compiled in the background with `KHR_parallel_shader_compile`), to recover the per-pixel cost of reading parameters from the instance block. With eight Breakout walls holding the load equal, the wall cost 2.61–2.67 ms per frame with the variant and 2.63–2.64 ms without (about 4% less relative to the bricks it doesn't affect), and Galcon's backdrop didn't change, so most of the +18% measured in 96b76a2 must come from elsewhere.

## 96b76a2 — Draw looks with instancing

- Looks are drawn with their own instanced draw calls instead of through raylib: consecutive entities with the same shader and blending share one call, and each entity's position, size, rotation, age and parameter values are a record in a uniform block that one shared vertex shader and the look's fragment shader read.
- The scene's records are uploaded once per frame; text and cached looks are still drawn by raylib, between the calls, in scene order.

| Demo | FPS | Frame ms (median / p99 / worst) | Hitches | GPU ms/frame | CPU | Startup ms | Shaders compiled |
|---|---|---|---|---|---|---|---|
| Breakout | 81.6 | 12.00 / 17.47 / 23.62 | 1 | 1.48 | 100% | 44 | 0 (20 from manifest in 22 ms) |
| Tower defense | 58.2 | 16.78 / 23.00 / 39.32 | 1 | 1.16 | 92% | 78 | 0 (27 from manifest in 46 ms) |
| Galcon | 58.4 | 16.77 / 22.84 / 34.27 | 2 | 1.41 | 92% | 20 | 0 (7 from manifest in 3 ms) |

Most expensive looks (GPU ms/frame): Breakout: `wall_background_look` 0.80 ms, `brick_look` 0.66 ms; Tower defense: `enemy_look` 0.77 ms, `terrain_look` 0.08 ms; Galcon: `space_look` 1.37 ms, `asteroid_look` 0.03 ms.

Compared with bfa0220, measured alternately in the same session (it measured 3.72, 3.03 and 2.63 ms of GPU time per frame there):

- GPU time per frame: Breakout −60%, tower defense −62%, Galcon −46%. Draw calls per frame: Breakout 82 → 13 (the 72 bricks take 6), Galcon 31 → 4, tower defense 33 → 21.
- CPU time in `render`: Breakout 0.79 → 0.42 ms, Galcon 0.51 → 0.42 ms, tower defense unchanged.
- Breakout's FPS rises from 70 to 82 on the virtual display; the other demos are capped at 60.
- A look's parameters are now read from the instance block with an index instead of from plain uniforms, which costs per pixel in large, heavy looks: Breakout's full-screen wall measured +18% with the load held equal (eight walls in both versions). In the table above it shows 0.50 → 0.80 ms, partly because the GPU clocks down once the rest of the frame gets cheaper.
- Shader startup compiles take longer per shader (tower defense 29 → 46 ms for 27 shaders), with the vertex shader and uniform block linked into each program.

Stress test, the average of two runs (bfa0220 in parentheses):

| Stage | Entities | Setup ms | Frame avg ms | Frame p99 ms |
|---|---|---|---|---|
| 1. still variety | 400 | 12.9 | 22.7 (26.4) | 27.2 (38.3) |
| 2. animated | 800 | 11.2 | 27.8 (37.5) | 33.7 (53.8) |
| 3. movers and lights | 1,160 | 8.3 | 32.0 (35.7) | 39.6 (39.6) |
| 4. spawn churn (+120 effects/s) | 1,160 | 0 | 32.5 (35.7) | 41.8 (40.1) |
| 5. double load | 1,860 | 19.0 | 34.5 (39.3) | 40.6 (43.7) |

Over the whole run: GPU time per frame 11.44 → 6.47 ms, CPU in `render` 5.27 → 3.47 ms. The stress layers mix families in random order, so few neighbours share a shader (1,087 → 1,006 draw calls); the gain there comes from each call being cheaper (no raylib batch flush and uniform uploads per entity): most looks cost a quarter to a third of before at the same number of calls. Heavy looks pay the per-pixel cost above: `brick_look` 0.92 → 1.76 ms, `rings_look` and `marble_look` +8%.

Tried and measured slower on the way: instance records in a buffer texture (wall +73%, one fetch per parameter per pixel), `glBufferSubData` per draw call (+35–60% for looks drawn alone, a stall per call) and mapping the buffer per draw call (the driver then keeps it in system memory: wall +94%, space +58%).

Also tried and not adopted: fading out fbm layers finer than a pixel. At the demos' native scale almost no layer is finer than a pixel, so it cost about 3% of GPU time in every demo and only helped looks drawn at half size.

## bfa0220 — Structure-keyed shader cache, shader manifest, scene lights

- Shaders are cached by a hash of the look's structure, so spawning a look seen before generates no GLSL.
- Every shader a game compiles is recorded in `.shader-cache/` and compiled at the next startup, before the first frame.
- Scene lights (`add_light`, `vfx.lit_scene`): the Breakout ball and the Galcon sun light the scene.

| Demo | FPS | Frame ms (median / p99 / worst) | Hitches | GPU ms/frame | CPU | Startup ms | Shaders compiled |
|---|---|---|---|---|---|---|---|
| Breakout | 74.0 | 13.41 / 17.30 / 32.60 | 4 | 3.08 | 100% | 46 | 0 (20 from manifest in 20 ms) |
| Tower defense | 58.6 | 16.75 / 20.30 / 32.10 | 0 | 1.78 | 90% | 92 | 0 (54 from manifest in 58 ms) |
| Galcon | 59.0 | 16.75 / 22.11 / 35.71 | 1 | 1.09 | 87% | 18 | 0 (7 from manifest in 2 ms) |

Most expensive looks (GPU ms/frame): Breakout: `brick_look` 2.59 ms, `wall_background_look` 0.39 ms; Tower defense: `enemy_look` 1.08 ms, `tree_look` 0.22 ms; Galcon: `space_look` 0.63 ms, `asteroid_look` 0.31 ms.

Compared with 8b14d71, measured alternately in the same session: frame times, CPU and GPU time are unchanged within run-to-run noise (scene lighting costs nothing measurable), and no shader is compiled after startup. The gains are in situations these idle benchmarks don't exercise, measured separately:

- Spawning an explosion in Breakout: 0.6–1.7 ms of CPU → 0.09–0.15 ms.
- A later run of a game whose effects aren't precompiled (Breakout without its `precompile` calls): six mid-game hitches of 14–42 ms in the first run → none in the second.

New: the stress test demo (`src/demos/stress`), now part of `src/tools/benchmark.sh`. First results, the average of two runs (there is no earlier version to compare with):

| Stage | Entities | Setup ms | Frame avg ms | Frame p99 ms |
|---|---|---|---|---|
| 1. still variety | 400 | 12.8 | 26.2 | 32.6 |
| 2. animated | 800 | 10.3 | 33.3 | 40.8 |
| 3. movers and lights | 1,160 | 8.1 | 33.8 | 43.4 |
| 4. spawn churn (+120 effects/s) | 1,160 | 0 | 35.1 | 42.1 |
| 5. double load | 1,860 | 19.6 | 44.5 | 47.9 |

Over the whole run: about 1,065 draw calls per frame, 10.5 ms of GPU time per frame (all looks within 0.1–1.2 ms each; cost follows the number of draws more than pixels, roughly 9 µs per draw), 5.2 ms of CPU in `render`. On the virtual display the run is present-bound (most of each frame is spent in the buffer swap, which includes the frame copy-back), so stage frame times overstate the engine's own cost; GPU time and the CPU zones are the numbers to track.

The tower defense manifest still lists 27 shaders from earlier versions of its looks; they cost about 30 ms of startup until they've gone unused for 5 runs and are dropped.

## 8b14d71 — Add vsync options and measure FPS correctly

| Demo | FPS | Frame ms (median / p99 / worst) | Hitches | GPU ms/frame | CPU | Startup ms | Shaders compiled |
|---|---|---|---|---|---|---|---|
| Breakout | 72.5 | 13.75 / 17.35 / 28.34 | 1 | 3.46 | 100% | 66 | 20 in 24 ms |
| Tower defense | 57.1 | 16.79 / 22.97 / 28.04 | 0 | 2.05 | 92% | 71 | 27 in 30 ms |
| Galcon | 59.3 | 16.78 / 19.91 / 30.11 | 0 | 1.21 | 88% | 22 | 7 in 2 ms |

Most expensive looks (GPU ms/frame): Breakout: `brick_look` 2.90 ms, `wall_background_look` 0.43 ms; Tower defense: `enemy_look` 1.30 ms, `tree_look` 0.24 ms; Galcon: `space_look` 0.66 ms, `asteroid_look` 0.37 ms.
