package main

// Game state and rules, ported from AlgoGame (index-pixi.html, CORE section) so that a seed
// gives the same cave and, with the same input, the same flight. Everything here is f64
// and the noise uses the same integer hashing as the JavaScript.

import "core:math"

VIEW_HEIGHT :: 20.0 // visible world height; width follows the aspect ratio
STEP :: 1.0 / 120 // fixed simulation timestep
MAX_FRAME :: 0.25 // cap on real time simulated per frame

// Underwater ship movement
SINK_ACCELERATION :: 9.0
THRUST :: 32.0
WATER_DRAG :: 2.2
CURRENT_STRENGTH :: 1.6
CURRENT_PERIOD :: 3.0
TILT_PER_SPEED :: 0.05
TILT_STIFFNESS :: 40.0
TILT_DAMPING :: 7.0
SCROLL_SPEED :: 7.0
SCROLL_SURGE :: 0.12
SCROLL_SURGE_PERIOD :: 5.0
WALL_DRAG_SPEED :: 0.3
WALL_DRAG_RECOVER_DELAY :: 1.0
WALL_DRAG_BRAKE :: 8.0
WALL_DRAG_RECOVER :: 2.0
SPARK_RATE :: 70.0
SPARK_SPEED :: 5.0
SPARK_LIFE :: 0.3
SPARK_MAX :: 60
SHIP_X :: 5.0
SHIP_SIZE :: 0.9

// Ship tendrils: a double helix behind it, in ship units (40 make one SHIP_SIZE)
HELIX_LENGTH :: 58.0
HELIX_RADIUS :: 14.0
HELIX_TURNS :: 1.2
HELIX_TAPER :: 0.45
HELIX_EASE :: 0.35
HELIX_WIDTH :: 2.4
HELIX_SPIN :: 2.2
HELIX_SPIN_THRUST :: 9.0

// Cave shape: a wandering center line plus a varying gap, both from noise
CAVE_CENTER_WANDER :: 3.5
CAVE_CENTER_SCALE :: 14.0
CAVE_GAP_MIN :: 9.5
CAVE_GAP_MAX :: 14.5
CAVE_GAP_SCALE :: 25.0
CAVE_MIN_WALL :: 0.6
CAVE_SAMPLE_STEP :: 0.25 // horizontal spacing of wall points when drawing

// ---------------------------------------------------------------------------------------
// Noise: integer hashing only, bit for bit the same as the JavaScript (Math.imul is a
// wrapping 32-bit multiply, `>>>` a logical shift)

hash :: proc(seed, i: i64) -> f64 {
	h := (u32(seed) ~ (u32(i) * 0x27d4eb2d)) * 0x165667b1
	h ~= h >> 15
	h *= 0x85ebca6b
	h ~= h >> 13
	h *= 0xc2b2ae35
	h ~= h >> 16
	return f64(h) / 4294967296 // [0, 1)
}

// 1D value noise: random values at integer points, smoothly blended between them
value_noise :: proc(seed: i64, x: f64) -> f64 {
	i := math.floor(x)
	f := x - i
	t := f * f * (3 - 2 * f)
	a, b := hash(seed, i64(i)), hash(seed, i64(i) + 1)
	return a + (b - a) * t
}

// Large smooth waves plus smaller, weaker detail on top
fractal_noise :: proc(seed: i64, x: f64, octaves: int) -> f64 {
	sum, amp, freq, norm: f64 = 0, 1, 1, 0
	for o in 0 ..< octaves {
		sum += value_noise(seed + i64(o) * 1013, x * freq) * amp
		norm += amp
		amp *= 0.5
		freq *= 2
	}
	return sum / norm
}

// 2D value noise on a grid, used with (position, time)
value_noise2 :: proc(seed: i64, x, y: f64) -> f64 {
	i, j := math.floor(x), math.floor(y)
	fx, fy := x - i, y - j
	tx, ty := fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
	row0 := i64(u32(seed) ~ (u32(i64(j)) * 0x632be5ab))
	row1 := i64(u32(seed) ~ (u32(i64(j) + 1) * 0x632be5ab))
	a, b := hash(row0, i64(i)), hash(row0, i64(i) + 1)
	c, d := hash(row1, i64(i)), hash(row1, i64(i) + 1)
	top, bottom := a + (b - a) * tx, c + (d - c) * tx
	return top + (bottom - top) * ty
}

// ---------------------------------------------------------------------------------------
// State

Ship :: struct {
	y, prev_y, vy:                         f64,
	angle, prev_angle, angular_velocity:   f64,
	spin, prev_spin:                       f64, // how far the tendril helix has turned
}

Spark :: struct {
	x, y, vx, vy, life, age: f64,
	used:                    bool,
}

State :: struct {
	seed:                    i64,
	distance, prev_distance: f64, // how far the world has scrolled
	time, prev_time:         f64, // game time
	score:                   int,
	ship_vx:                 f64, // ship's forward speed through the world
	speed_factor:            f64, // 1 = full speed; drops while scraping a wall
	last_wall_contact:       f64,
	can_cut:                 bool, // false while slowed: goo is shoved, not cut
	sparks:                  [SPARK_MAX]Spark, // a fixed pool, reused in turn
	spark_next:              int,
	spark_budget:            f64,
	ship:                    Ship,
	thrusting:               bool,
	clusters:                map[i64]^Cluster, // goo blob key -> its particle cluster
	droplets:                [dynamic]Droplet, // goo pieces carried away by the current
}

Cave :: struct {
	top, bottom: f64,
}

create_state :: proc(seed: i64) -> State {
	start := cave_at(seed, SHIP_X)
	start_y := (start.top + start.bottom) / 2
	return State {
		seed = seed,
		speed_factor = 1,
		last_wall_contact = -1e9,
		can_cut = true,
		ship = {y = start_y, prev_y = start_y},
		clusters = make(map[i64]^Cluster),
	}
}

// Cave walls at world position x
cave_at :: proc(seed: i64, x: f64) -> Cave {
	h := VIEW_HEIGHT
	center := h / 2 + (fractal_noise(seed, x / CAVE_CENTER_SCALE, 3) * 2 - 1) * CAVE_CENTER_WANDER
	gap := CAVE_GAP_MIN + fractal_noise(seed + 7919, x / CAVE_GAP_SCALE, 2) * (CAVE_GAP_MAX - CAVE_GAP_MIN)
	top, bottom := center - gap / 2, center + gap / 2
	if top < CAVE_MIN_WALL {
		bottom += CAVE_MIN_WALL - top
		top = CAVE_MIN_WALL
	}
	if bottom > h - CAVE_MIN_WALL {
		top -= bottom - (h - CAVE_MIN_WALL)
		bottom = h - CAVE_MIN_WALL
	}
	return {top, bottom}
}

// The ship's hull as a triangle in world units: nose, top-back, bottom-back
ship_hull :: proc(state: ^State) -> [3][2]f64 {
	s := SHIP_SIZE
	cx, cy := state.distance + SHIP_X, state.ship.y
	c, n := math.cos(state.ship.angle), math.sin(state.ship.angle)
	corners := [3][2]f64{{0.85 * s, 0}, {-0.45 * s, -0.28 * s}, {-0.45 * s, 0.28 * s}}
	hull: [3][2]f64
	for p, k in corners {
		hull[k] = {cx + p.x * c - p.y * n, cy + p.x * n + p.y * c}
	}
	return hull
}

// Scraping a wall throws short-lived sparks from the contact point
emit_sparks :: proc(state: ^State, x, y, away, dt: f64) {
	state.spark_budget += SPARK_RATE * dt
	for state.spark_budget >= 1 {
		state.spark_budget -= 1
		i := state.spark_next
		state.spark_next += 1
		r1 := hash(state.seed + 4242, i64(i))
		r2 := hash(state.seed + 4243, i64(i))
		r3 := hash(state.seed + 4244, i64(i))
		state.sparks[i % SPARK_MAX] = Spark {
			x    = x,
			y    = y,
			// Mostly thrown backward (the ship is sliding forward) and away from the rock
			vx   = state.ship_vx - SPARK_SPEED * (0.4 + 0.8 * r1),
			vy   = away * SPARK_SPEED * (0.3 + 0.9 * r2),
			life = SPARK_LIFE * (0.6 + 0.8 * r3),
			used = true,
		}
	}
}

step_sparks :: proc(state: ^State, dt: f64) {
	keep := math.exp(-4 * dt) // water slows them quickly
	for &s in state.sparks {
		if !s.used || s.age >= s.life {
			continue
		}
		s.age += dt
		s.vx *= keep
		s.vy *= keep
		s.x += s.vx * dt
		s.y += s.vy * dt
	}
}

update :: proc(state: ^State, thrust: bool, dt: f64) {
	ship := &state.ship
	ship.prev_y = ship.y
	ship.prev_angle = ship.angle
	ship.prev_spin = ship.spin
	ship.spin += (HELIX_SPIN_THRUST if thrust else HELIX_SPIN) * dt // the tendrils drive the ship
	state.prev_distance = state.distance
	state.prev_time = state.time
	state.thrusting = thrust
	state.time += dt

	// Wall drag: touching a wall brakes the ship hard; speed only returns after a delay
	scraping := state.time - state.last_wall_contact < WALL_DRAG_RECOVER_DELAY
	target_speed := WALL_DRAG_SPEED if scraping else 1
	rate := WALL_DRAG_BRAKE if target_speed < state.speed_factor else WALL_DRAG_RECOVER
	state.speed_factor += (target_speed - state.speed_factor) * (1 - math.exp(-rate * dt))
	state.can_cut = !scraping && state.speed_factor > 0.9

	surge := (value_noise2(state.seed + 31, 0, state.time / SCROLL_SURGE_PERIOD) * 2 - 1) * SCROLL_SURGE
	state.ship_vx = SCROLL_SPEED * (1 + surge) * state.speed_factor
	state.distance += state.ship_vx * dt

	// Vertical: sinking, thrust and the current push; drag pulls speed back toward zero
	current := (value_noise2(state.seed + 37, 0, state.time / CURRENT_PERIOD) * 2 - 1) * CURRENT_STRENGTH
	accel := SINK_ACCELERATION - (THRUST if thrust else 0) + current - WATER_DRAG * ship.vy
	ship.vy += accel * dt
	ship.y += ship.vy * dt

	// The nose follows the vertical speed through a damped spring
	target_angle := ship.vy * TILT_PER_SPEED
	ship.angular_velocity += ((target_angle - ship.angle) * TILT_STIFFNESS - ship.angular_velocity * TILT_DAMPING) * dt
	ship.angle += ship.angular_velocity * dt

	// Walls: if any corner of the hull is inside the rock, push the ship back out, stop
	// its motion into the wall, and note the contact (which starts the drag). The walls
	// have no ripple or warp styles, so their edges are the cave's.
	push_down, push_up: f64
	contact: Maybe([3]f64) // x, y, away
	for corner in ship_hull(state) {
		edges := cave_at(state.seed, corner.x)
		if edges.top - corner.y > push_down {
			push_down = edges.top - corner.y
			contact = [3]f64{corner.x, edges.top, 1}
		}
		if corner.y - edges.bottom > push_up {
			push_up = corner.y - edges.bottom
			contact = [3]f64{corner.x, edges.bottom, -1}
		}
	}
	if push_down > 0 {
		ship.y += push_down
		ship.vy = math.max(ship.vy, 0)
	}
	if push_up > 0 {
		ship.y -= push_up
		ship.vy = math.min(ship.vy, 0)
	}
	if c, ok := contact.?; ok {
		state.last_wall_contact = state.time
		emit_sparks(state, c.x, c.y, c.z, dt)
	}
	step_sparks(state, dt)
	if has_stage(3) {
		step_goo(state, dt) // the goo came in stage 3
	}
	step_droplets(state)
}

// Benchmark input, the same rule as autopilot() in index-pixi.html: thrust decided from
// the state alone, aiming at a line that weaves between the cave's middle and close to
// its walls.
autopilot :: proc(state: ^State) -> bool {
	cave := cave_at(state.seed, state.distance + SHIP_X)
	middle, half := (cave.top + cave.bottom) / 2, (cave.bottom - cave.top) / 2
	target := middle + math.sin(state.time * 0.9) * half * 0.85
	return state.ship.y + state.ship.vy * 0.25 > target // y grows downward: below it, thrust
}
