package main

// Stress test: a scripted, deterministic scene that adds load in stages: many entities, a wide
// variety of shaders, animation, per-frame parameter and text updates, moving scene lights and
// constant spawning. The frame rate is uncapped, so frame times show the real cost of each
// stage. After every stage a line with its entity count, setup time and frame times is
// printed (src/tools/benchmark.sh keeps it next to the profiler report).

import eng "../../engine"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:slice"
import "core:time"
import rl "vendor:raylib"

SCREEN_WIDTH :: 1600
SCREEN_HEIGHT :: 900
SEED :: 20261102
STAGE_SECONDS :: 3.6 // five stages fit into the benchmark's 20 s
WARMUP_SECONDS :: 0.5 // frames right after a stage starts are left out of its statistics

GRID_COLS :: 25
GRID_ROWS :: 16
CELL :: eng.Vector2{SCREEN_WIDTH / GRID_COLS, SCREEN_HEIGHT / GRID_ROWS}
STILL_SIZE :: eng.Vector2{58, 50}
ANIMATED_SIZE :: eng.Vector2{44, 44}
MOVER_SIZE :: eng.Vector2{34, 34}
MOVERS_PER_STAGE :: 300
LABELS :: 60
LIGHTS :: 6
EFFECTS_PER_SECOND :: 120

Z_STILL :: 0
Z_ANIMATED :: 1
Z_MOVERS :: 2 // y-sorted
Z_EFFECTS :: 3
Z_TEXT :: 4

Stage :: struct {
	name:  string,
	setup: proc(),
}

STAGES := [?]Stage {
	{"still variety", add_still_tiles},
	{"animated", add_animated_tiles},
	{"movers and lights", add_movers_and_lights},
	{"spawn churn", start_churn},
	{"double load", double_load},
}

Mover :: struct {
	id:      int,
	vel:     eng.Vector2,
	spin:    f32, // degrees/s
	glowing: bool, // its "glow" param is updated every frame
}

StageResult :: struct {
	entities: int,
	setup_ms: f64,
	avg_ms:   f64,
	p99_ms:   f64,
	frames:   int,
}

Stress :: struct {
	stage:       int, // index into STAGES; len(STAGES) once finished
	stage_start: f64,
	frame_ms:    [dynamic]f32, // this stage, after warm-up
	results:     [len(STAGES)]StageResult,
	entities:    int, // persistent entities; effects are counted separately
	movers:      [dynamic]Mover,
	lights:      [LIGHTS]int,
	labels:      [dynamic]int,
	effects:     [dynamic]f64, // expiry times of live effects
	churn:       bool,
	spawn_debt:  f32,
	hud:         int,
}

stress: Stress

hue_for :: proc(i: int) -> f32 {
	return f32(i) * 0.137
}

// One tile per grid cell, cycling through the families and both variants of each.
add_tiles :: proc(families: []Family, size, offset: eng.Vector2, z: int, pad: f32, cache_every: int) {
	for i in 0 ..< GRID_COLS * GRID_ROWS {
		family := families[i % len(families)]
		detail := DETAILS[(i / len(families)) % 2]
		pos := eng.Vector2{(f32(i % GRID_COLS) + 0.5) * CELL.x, (f32(i / GRID_COLS) + 0.5) * CELL.y} + offset
		cache := cache_every > 0 && i % cache_every == 0
		eng.add_entity(look(family, detail, hue_for(i), f32(i) * 1.618, size), pos, size, {z_index = z, pad = pad, cache = cache})
	}
	stress.entities += GRID_COLS * GRID_ROWS
}

add_still_tiles :: proc() {
	add_tiles(STILL[:], STILL_SIZE, {}, Z_STILL, 8, 4)
}

add_animated_tiles :: proc() {
	add_tiles(ANIMATED[:], ANIMATED_SIZE, CELL / 2, Z_ANIMATED, 20, 0)
}

add_movers :: proc() {
	for i in 0 ..< MOVERS_PER_STAGE {
		family := MOVING[i % len(MOVING)]
		detail := DETAILS[(i / len(MOVING)) % 2]
		pos := eng.Vector2{rand.float32_range(0, SCREEN_WIDTH), rand.float32_range(0, SCREEN_HEIGHT)}
		heading := rand.float32_range(0, math.TAU)
		id := eng.add_entity(look(family, detail, hue_for(i), rand.float32_range(0, 100), MOVER_SIZE), pos, MOVER_SIZE, {z_index = Z_MOVERS, pad = 4})
		vel := eng.Vector2{math.cos(heading), math.sin(heading)} * rand.float32_range(40, 160)
		append(&stress.movers, Mover{id = id, vel = vel, spin = rand.float32_range(-180, 180), glowing = family == .Plate})
	}
	stress.entities += MOVERS_PER_STAGE
}

add_movers_and_lights :: proc() {
	add_movers()
	eng.clear_lights()
	eng.set_ambient(AMBIENT, 0.25)
	for i in 0 ..< LIGHTS {
		stress.lights[i] = eng.add_light({kind = .Point, height = 80, color = LIGHT_COLORS[i], intensity = 1.2, radius = 420})
	}
	for i in 0 ..< LABELS {
		pos := eng.Vector2{f32(i % 10) * 160 + 30, f32(i / 10) * 150 + 90}
		append(&stress.labels, eng.add_text("", pos, 16, TEXT_DIM, Z_TEXT))
	}
	stress.entities += LABELS
}

start_churn :: proc() {
	stress.churn = true
}

double_load :: proc() {
	add_animated_tiles()
	add_movers()
}

// Compiles every shader the stages use, so stage setup times measure entity creation only.
precompile_all :: proc() {
	for list in ([3][]Family{STILL[:], ANIMATED[:], MOVING[:]}) {
		for family in list {
			for detail in DETAILS {
				eng.precompile(look(family, detail, 0, 0, STILL_SIZE))
			}
		}
	}
	for kind in EffectKind {
		eng.precompile(effect_look(kind, 0, 0))
	}
}

update_movers :: proc(dt: f32) {
	eng.profile_scope("update_movers")
	t := eng.time()
	for &m, i in stress.movers {
		e := eng.get_entity(m.id)
		e.pos += m.vel * dt
		if e.pos.x < 0 || e.pos.x > SCREEN_WIDTH {
			m.vel.x = -m.vel.x
		}
		if e.pos.y < 0 || e.pos.y > SCREEN_HEIGHT {
			m.vel.y = -m.vel.y
		}
		e.rotation += m.spin * dt
		if m.glowing {
			eng.set_param(m.id, "glow", 0.5 + 0.5 * math.sin(t * 3 + f32(i)))
		}
	}
}

update_lights :: proc() {
	t := eng.time()
	center := eng.Vector2{SCREEN_WIDTH, SCREEN_HEIGHT} / 2
	for id, i in stress.lights {
		a := t * (0.3 + 0.1 * f32(i)) + f32(i) * math.TAU / LIGHTS
		eng.get_light(id).pos = center + {math.cos(a) * (300 + 60 * f32(i)), math.sin(a) * (180 + 30 * f32(i))}
	}
}

update_churn :: proc(dt: f32) {
	eng.profile_scope("update_churn")
	now := f64(eng.time())
	for i := 0; i < len(stress.effects); {
		if stress.effects[i] <= now {
			unordered_remove(&stress.effects, i)
		} else {
			i += 1
		}
	}
	stress.spawn_debt += dt * EFFECTS_PER_SECOND
	for stress.spawn_debt >= 1 {
		stress.spawn_debt -= 1
		kind := rand.choice_enum(EffectKind)
		lifetime: f32 = 0.6 if kind == .Burst else 0.8
		pos := eng.Vector2{rand.float32_range(0, SCREEN_WIDTH), rand.float32_range(0, SCREEN_HEIGHT)}
		blend := eng.BlendMode.Additive if kind != .Shatter else .Alpha
		eng.add_entity(effect_look(kind, rand.float32(), rand.float32_range(0, 100)), pos, {40, 40}, {z_index = Z_EFFECTS, pad = 120, lifetime = lifetime, blend = blend})
		append(&stress.effects, now + f64(lifetime))
	}
}

// Ends the current stage: its statistics, then the next stage's setup.
next_stage :: proc() {
	if stress.stage >= 0 {
		r := &stress.results[stress.stage]
		r.frames = len(stress.frame_ms)
		if r.frames > 0 {
			sorted := slice.clone(stress.frame_ms[:], context.temp_allocator)
			slice.sort(sorted)
			total: f64
			for ms in sorted {
				total += f64(ms)
			}
			r.avg_ms = total / f64(r.frames)
			r.p99_ms = f64(sorted[min(len(sorted) - 1, len(sorted) * 99 / 100)])
		}
		fmt.printf(
			"stress: stage %d/%d %-18s % 5d entities   setup % 7.2f ms   frame avg % 6.2f ms   p99 % 6.2f ms   (%d frames)\n",
			stress.stage + 1,
			len(STAGES),
			STAGES[stress.stage].name,
			r.entities,
			r.setup_ms,
			r.avg_ms,
			r.p99_ms,
			r.frames,
		)
	}
	clear(&stress.frame_ms)
	stress.stage += 1
	stress.stage_start = rl.GetTime()
	if stress.stage >= len(STAGES) {
		fmt.println("stress: done")
		return
	}
	start := time.tick_now()
	STAGES[stress.stage].setup()
	r := &stress.results[stress.stage]
	r.setup_ms = time.duration_milliseconds(time.tick_diff(start, time.tick_now()))
	r.entities = stress.entities
}

on_update :: proc(dt: f32) {
	if stress.stage < len(STAGES) {
		since := rl.GetTime() - stress.stage_start
		if since >= WARMUP_SECONDS {
			append(&stress.frame_ms, rl.GetFrameTime() * 1000)
		}
		if since >= STAGE_SECONDS {
			next_stage()
		}
	}

	update_movers(dt)
	if len(stress.movers) > 0 {
		update_lights()
	}
	for id, i in stress.labels {
		eng.set_text(id, fmt.tprintf("label %02d: %d", i, int(eng.time() * 100) + i))
	}
	if stress.churn {
		update_churn(dt)
	}

	stage := STAGES[min(stress.stage, len(STAGES) - 1)].name
	if stress.stage >= len(STAGES) {
		stage = "done (holding the last stage's load)"
	}
	eng.set_text(
		stress.hud,
		fmt.tprintf("stage %d/%d: %s   entities %d + %d effects   frame %.2f ms", min(stress.stage + 1, len(STAGES)), len(STAGES), stage, stress.entities, len(stress.effects), rl.GetFrameTime() * 1000),
	)
}

main :: proc() {
	rand.reset(SEED)
	eng.init_context(
		eng.InitOptions {
			width = SCREEN_WIDTH,
			height = SCREEN_HEIGHT,
			fps = 0, // uncapped: frame times show the real cost
			title = "Stress Test",
			num_layers = 5,
			bg_color = BACKGROUND,
			resizable = true,
		},
	)
	eng.set_layer_y_sorted(Z_MOVERS, true)
	precompile_all()
	stress.hud = eng.add_text("", {16, 18}, 20, TEXT_LIGHT, Z_TEXT)
	stress.stage = -1
	next_stage()
	eng.run(on_update)
}
