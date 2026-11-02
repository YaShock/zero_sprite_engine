# Changelog

Each entry records a commit with the engine's own profiler results, so performance changes are visible commit by commit.

**How the numbers are measured.** `src/tools/benchmark.sh <label>` runs every demo for 20 s with `ZSE_PROFILE_SECONDS=20` on a virtual X display (see "Run headlessly" in `CLAUDE.md`). To compare two versions, run them alternately, twice each, in one session (the previous commit from a `git worktree`): the laptop heats up over a session, and runs taken minutes apart differ more than most changes do. Tables show the average of both runs and the worst frame of either. Breakout and Galcon get no input, so they measure the serve scene and the title screen; the tower defense run includes its first wave (at 12 s).

- GPU time per frame, startup time and shader compiles are representative, though GPU time drifts with the GPU's clock speed (by up to 2× within one session so far), so only compare entries measured side by side.
- FPS and CPU usage are not representative: presenting through the virtual display copies every frame back to system memory, which caps Breakout (set to 120 FPS) at about 75 FPS and keeps a CPU core busy. They are still comparable between versions measured the same way.
- Startup and compile times also depend on the graphics driver's own shader cache.

Hardware for all entries so far: NVIDIA GeForce RTX 3070 Laptop GPU.

## Structure-keyed shader cache, shader manifest, scene lights

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
