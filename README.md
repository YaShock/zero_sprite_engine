# Zero Sprite Engine

This project aims to make a 2D engine with **purely** procedurally generated content. This means no more sprite sheets and fixed resolution artwork! Every single visible object shall be described as a mathematical formula.

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
