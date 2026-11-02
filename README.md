# Zero Sprite Engine

This project aims to make a 2D engine with **purely** procedurally generated content. This means no more sprite sheets and fixed resolution artwork! Every single visible object shall be described as a mathematical formula.

## Tools

- Profiler
    - Measure the RAM, CPU and graphics usage for a specific demo
    - Should be able to show bottle-necks, hot paths, FPS consistency

- Stress test demo (`src/demos/stress`)
    - Adds load in stages: many entities, many different shaders, animation, moving lights, spawning
    - Prints frame times per stage, for comparing engine changes

- Entity editor
    - A tool that lets the user to compose visual effects, characters from the same composable functions that make up the visual entities in the demos
    - The tools lets the user set parameters and see animations if some parameters are variables (between certain set intervals)
    - Give a few presets like fire/terrain/brick that already give a composition of functions describing the entity with tweakable parameters

## First demos to accomplish

- Breakout
    - Increase complexity of brick and ball texture as project evolves, "bricked wall" background
    - Add brick explosions

![Breakout](screenshots/breakout.png)

- A simple tower defense
    - One preexisting level
        - A road from starting to end point
        - Around it terrain
        - Terrain & road textures procedurally generated (and a bit randomized)
        - The color tone also randomly generated between sensible values
    - Shop with 3 different types
        - Fire (burn damage over time)
        - Ice (slows)
        - Lightning (projectiles bounce to closest enemy)
        - Each can be upgraded twice
    - Get gold for each enemy killed
    - Enemies come in waves
    - You can buy towers or upgrade them, however each occupies space, can't stack them
    - Enemies are animated characters which can be constructed from VFX (golems for example)
    - Enemies get progressively stronger
    - Each enemy getting to the end point reduces our lives (let's say 5), but disappear when they get there
    - End point should be some kind of gate
    - Showcase different buildings and projectiles as project evolves

![TowerDefense](screenshots/tower-defense.png)

- Space fighting game
    - Galcon Fusion clone
    - The background is space with stars, space debris, asteroids etc
    - Randomly generated map with one or multiple opponents (bots)
    - Each player (or bot) starts with one planet which generated ships that you can send to another planet to capture
    - Planets are also randomly generated
    - Spaceships can be simple but still resemble a triangular spaceship

![TowerDefense](screenshots/galcon.png)

- "Flappy Bird" clone
    - Sky generation
    - Bird generation
- Large game project
    - TD wars with logistics, "heroes", minions
    - Robotic synthwave style
    - Infinite zooming

## TODO

Engine enhancements proposed so far, roughly in order of value for effort. Each should be checked with the profiler (see `CHANGELOG.md`).

- Shading cost
    - Noise detail by screen size: fade out fbm layers finer than a pixel, so small or zoomed-out looks get cheaper and stop shimmering
    - A `cached()` node that renders only the still part of a look into a texture (e.g. a brick's surface, while its hit flash and cracks stay live)
    - A cheaper `lit` option using screen-space derivatives (one height evaluation instead of four)
    - Render expensive layers such as backgrounds at reduced resolution
- Draw calls
    - Group entities by shader within a layer where they don't overlap, so mixed layers batch too (the stress test still needs 1,006 calls for 1,860 entities)
    - Read the parameters that are equal across a draw call from uniforms instead of the instance block, for large heavy looks (Breakout's wall costs 18% more per pixel since instancing)
- Particles
    - CPU-simulated particles (velocity, drag, gravity, lifetime, collisions) drawn with instancing
    - GPU particle simulation with transform feedback, colliding with any look's distance field
- Lighting
    - Tower defense: fire towers and lightning orbs as scene lights on the golems
    - Deferred 2D lighting: color, height and glow buffers lit in one pass, for many lights, glowing objects lighting their neighbours, and soft shadows
- Text as visual effects (text is the last thing still drawn with a fixed-resolution bitmap font)
    - Glyphs as distance fields, so every existing node works on text
        - Vector stroke font first: each glyph a few line segments and arcs (e.g. the public-domain Hershey simplex font as data), its distance the union of `sd_segment`s minus the stroke width
        - Later, if typographic quality is needed: TrueType Bézier outlines evaluated in the shader (as the Slug library does)
    - A `text` node, keeping structure in the shader and content in parameters
        - The font compiles once into a GLSL function `glyph(code, p)`; the string's character codes are parameter slots, padded to a maximum length fixed when the look is built
        - Changing the text only rewrites parameter values, so a score updated every frame never recompiles
        - Monospace first (the character under a pixel is `floor(x / advance)`, one glyph evaluated per pixel); proportional spacing later, from a width table on the CPU passing per-character offsets
        - ASCII only at first, no kerning
    - `add_text` keeps its signature but becomes a material entity, so the `Text` drawable can go; raylib text stays for debug output such as `show_fps`
    - Effects for free once text is a distance field
        - Outlines and drop shadows (`stroke`, `glow`) for readability over busy backgrounds, e.g. Galcon's planet labels and the tower defense panel
        - Gradient fills, owner-colored glow, embossing with `lit` to match each game's style
        - Numbers that pop when they change (a `changed_time` param, like `hit_time`), text writing itself on (`age()` and the character index), wobble (`at`), shattering "VICTORY" (`shatter`)
        - Crisp at any window size, anti-aliased through `u_px`
    - Risks
        - Thin strokes shimmer below about 10 px: enforce a minimum stroke width in pixels
        - Each glyph is evaluated over its whole quad: fine for HUD-length strings, long paragraphs would want one quad per line
    - Order: stroke font with the monospace `text` node, then point `add_text` at it and outline the demos' labels, then proportional widths, then text animations
- Tooling
    - Hot-reload `.look` files into running demos
    - A tree view of a look in the editor, with the profiler's cost per node
- Platform
    - Move to a modern graphics API only once a feature needs compute shaders
