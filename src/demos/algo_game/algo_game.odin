package main

// AlgoGame, rebuilt on the Zero Sprite Engine: an underwater cave flyer. Hold Space (or
// W / Up, or a mouse button) to thrust. Ported from index-pixi.html in stages; this stage
// has the cave, the ship and its physics, scrape sparks, the text, corals, sea fans,
// tentacles, and the goo with its physics and scoring droplets.
//
//   odin run src/demos/algo_game                       random cave
//   ALGO_SEED=123 odin run src/demos/algo_game         a given cave
//   ALGO_SIZE=1600x900 odin run src/demos/algo_game    window size (default 1280x720)
//   ALGO_FULLSCREEN=on odin run src/demos/algo_game     borderless window over the whole screen
//   Escape opens the quit menu (Yes / No; Enter or Y quits, Escape or N plays on)
//   ZSE_PROFILE_SECONDS=20 odin run src/demos/algo_game
//       benchmark: seed 12345 on autopilot (as index-pixi.html?bench=20), then a report
//   ALGO_VSYNC=off ...                                  frames as fast as possible (no display pacing)
//   ALGO_STAGE=2 ...                                    only the features of port stage 1, 2 or 3
//   ALGO_SHOT=8 ZSE_FIXED_DT=0.016667 ...               save algo_game.png at game time 8 s and quit
//                                                       (fixed frame steps: the same frame in every build)

import eng "../../engine"
import fx "../../engine/vfx"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

// Drawing layers, back to front, as the original draws them: the fog, the jellyfish and the
// spores behind the cave; the growths at the rock's edge and the goo (ceiling, then floor;
// tentacles one layer, plants three: fans behind, corals, fans in front); the rock with its
// glints and wall light; the ship and its sparks; the growths standing lower (tentacles,
// then plants); the near spores, droplets and text
LAYER_FOG :: 0 // out of focus (see init_scenery)
LAYER_JELLY :: 1 // three out-of-focus layers, one per depth
LAYER_SPORES :: 4
LAYER_UPPER_BEHIND_GOO :: 5
LAYER_UPPER_GOO :: 6
LAYER_UPPER_BEFORE_GOO :: 7
LAYER_LOWER_BEHIND_GOO :: 8
LAYER_LOWER_GOO :: 11
LAYER_LOWER_BEFORE_GOO :: 12
LAYER_ROCK :: 15
LAYER_GLINTS :: 16
LAYER_WALL_LIGHT :: 17
LAYER_SHIP :: 18
LAYER_FX :: 19
LAYER_LOW :: 20
LAYER_LOWEST :: 24
LAYER_FRONT_SPORES :: 28
LAYER_DROPLETS :: 29
LAYER_TEXT :: 30
LAYER_GOO_FIELD :: 31 // buffers, never shown: each wall's goo field (ceiling, floor), read by its goo
LAYER_MENU :: 33 // the quit menu (Escape): its panel and buttons, then their text
LAYER_MENU_TEXT :: 34
LAYER_COUNT :: 35

BENCH_SEED :: 12345
ROCK_SLICE :: 32 // pixels: the width of the rock's slices (see sync_scene)
MAX_ROCK_SLICES :: 256
SHIP_FIN_X :: -16.0 // tip of each side protrusion, ship units
SHIP_FIN_Y :: 12.0

Game :: struct {
	state:         State,
	accumulator:   f64,
	autopilot:     bool,
	press_pending: bool, // a press not yet seen by the simulation
	rock:          [2]int, // ceiling, floor
	ship:          int,
	sparks:        int,
	score_text:    int,
	shown_score:   int, // the score the text shows (it starts as "Score 0")
	hint_text:     int,
	edges:         [2][EDGE_SAMPLES]f32, // ceiling, floor (screen pixels), for the rock and the goo
	edge_x0:       f32, // screen x of edges[_][0]
	edge_step:     f32, // pixels between edge points
	slices:        [MAX_ROCK_SLICES * 4]f32, // scratch for one wall's rock slices
	helix:         [HELIX_PIECES * fx.CAPSULE_STRIDE]f32,
	spark_data:    [SPARK_MAX * fx.CAPSULE_STRIDE]f32,
	shot_at:       f64, // ALGO_SHOT: game time at which to save a screenshot; 0 = none
}

// Saves algo_game.png once the game time reaches ALGO_SHOT seconds (an overlay, so the
// frame is complete when it's read back), then quits. With ZSE_FIXED_DT the frame is the
// same in every build, for comparing their pictures.
take_shot :: proc() {
	if game.shot_at > 0 && game.state.time >= game.shot_at {
		// Starting a scissor area draws what raylib has batched so far (the text)
		rl.BeginScissorMode(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight())
		rl.TakeScreenshot("algo_game.png")
		os.exit(0)
	}
}

game: Game

// ALGO_STAGE=1..3 keeps only what that stage of the port added up to (as
// index-pixi.html?stage=N), to measure each stage again; 0 = everything
stage: int

has_stage :: proc(n: int) -> bool {
	return stage == 0 || stage >= n
}

THRUST_KEYS :: [?]rl.KeyboardKey{.SPACE, .UP, .W}

thrust_held :: proc() -> bool {
	for key in THRUST_KEYS {
		if rl.IsKeyDown(key) {
			return true
		}
	}
	return rl.IsMouseButtonDown(.LEFT)
}

thrust_pressed :: proc() -> bool {
	for key in THRUST_KEYS {
		if rl.IsKeyPressed(key) {
			return true
		}
	}
	return rl.IsMouseButtonPressed(.LEFT)
}

on_update :: proc(dt: f32) {
	if update_menu() {
		// The game stands still behind the menu (time scale 0), and its clicks aren't thrust
		game.press_pending = false
		eng.profile_scope("sync")
		sync_scene(game.accumulator / STEP)
		return
	}
	{
		eng.profile_scope("simulate")
		// A press always reaches the simulation, even a tap released before the next step
		game.press_pending ||= thrust_pressed()
		game.accumulator += math.min(f64(dt), MAX_FRAME)
		for game.accumulator >= STEP {
			thrust := autopilot(&game.state) if game.autopilot else thrust_held() || game.press_pending
			update(&game.state, thrust, STEP)
			game.press_pending = false
			game.accumulator -= STEP
		}
	}
	eng.profile_scope("sync")
	sync_scene(game.accumulator / STEP)
}

// Moves the entities and fills their params from the state, interpolated between the last
// two simulation steps for smooth motion.
sync_scene :: proc(alpha: f64) {
	state := &game.state
	screen := eng.screen_size()
	s := f64(screen.y) / VIEW_HEIGHT // pixels per world unit
	width_units := f64(screen.x) / s
	distance := state.prev_distance + (state.distance - state.prev_distance) * alpha

	// Rock: wall points on a fixed grid in world x, so the shape slides past smoothly
	first_x := math.floor(distance / CAVE_SAMPLE_STEP) * CAVE_SAMPLE_STEP
	count := math.min(EDGE_SAMPLES, int(math.ceil((width_units + CAVE_SAMPLE_STEP) / CAVE_SAMPLE_STEP)) + 1)
	game.edge_x0, game.edge_step = f32((first_x - distance) * s), f32(CAVE_SAMPLE_STEP * s)
	for side, k in ([2]f64{1, -1}) {
		for i in 0 ..< EDGE_SAMPLES {
			if i < count {
				cave := cave_at(state.seed, first_x + f64(i) * CAVE_SAMPLE_STEP)
				edge := cave.top if side > 0 else cave.bottom
				game.edges[k][i] = f32(edge * s)
			} else {
				game.edges[k][i] = game.edges[k][count - 1]
			}
		}
		id := game.rock[k]
		eng.set_param_array(id, "edges", game.edges[k][:])
		eng.set_param(id, "edge_x0", game.edge_x0)
		eng.set_param(id, "edge_step", game.edge_step)
		eng.set_param(id, "scroll", f32(distance * s))
		eng.set_param(id, "unit", f32(s))
		eng.set_param(id, "screen_h", screen.y)
		// Slices of the screen's width, each covering only its rock: from the screen edge to
		// its own deepest edge point (plus the anti-aliasing), so the open water isn't drawn
		slices := 0
		for x0: f32 = 0; x0 < screen.x && slices < MAX_ROCK_SLICES; x0 += ROCK_SLICE {
			x1 := math.min(x0 + ROCK_SLICE, screen.x)
			lo, hi := edge_range(k, x0, x1)
			y0, y1: f32 = 0, hi + 2
			if side < 0 {
				y0, y1 = lo - 2, screen.y
			}
			out := game.slices[slices * 4:]
			out[0], out[1], out[2], out[3] = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, math.max(y1 - y0, 0) / 2
			slices += 1
		}
		eng.get_entity(id).pos = {}
		eng.set_instances(id, "slices", game.slices[:slices * 4])
	}

	// Ship
	ship := state.ship
	y := ship.prev_y + (ship.y - ship.prev_y) * alpha
	tilt := ship.prev_angle + (ship.angle - ship.prev_angle) * alpha
	spin := ship.prev_spin + (ship.spin - ship.prev_spin) * alpha
	unit := s * SHIP_SIZE / SHIP_UNITS
	n_back, n_mid := helix_pieces(spin, game.helix[:])
	e := eng.get_entity(game.ship)
	e.pos = {f32(SHIP_X * s), f32(y * s)}
	e.size = {f32(160 * unit), f32(52 * unit)}
	e.rotation = f32(tilt * math.DEG_PER_RAD)
	eng.set_param_array(game.ship, "helix", game.helix[:])
	eng.set_param(game.ship, "n_back", f32(n_back))
	eng.set_param(game.ship, "n_mid", f32(n_mid))
	eng.set_param(game.ship, "ship_px", f32(unit))
	eng.set_param(game.ship, "squash", eng.Vector2{0.95, 1.05} if state.thrusting else eng.Vector2{1, 1})

	sync_sparks(state, distance, s)
	time := state.prev_time + (state.time - state.prev_time) * alpha
	eng.profile_begin("growths")
	lights := sync_growths(state, distance, time, s, width_units)
	eng.profile_end()
	if has_stage(4) {
		eng.profile_scope("scenery")
		sync_scenery(state, distance, time, s, width_units, lights, count)
	}

	// Text
	if state.score != game.shown_score {
		eng.set_text(game.score_text, fmt.tprintf("Score %d", state.score))
		game.shown_score = state.score
	}
	place_text(game.score_text, {screen.x / 2, f32(1.0 * s)}, f32(0.8 * s))
	place_text(game.hint_text, {f32(0.4 * s), f32(0.2 * s)}, f32(0.6 * s))
}

// The highest and lowest point (screen pixels) of a wall's edge (0 ceiling, 1 floor) between
// screen x0 and x1, as the looks' curve reads it: straight between its points, so the
// extremes are at points inside the range or at its ends
edge_range :: proc(wall: int, x0, x1: f32) -> (lo, hi: f32) {
	edges := game.edges[wall][:]
	n := len(edges)
	at :: proc(edges: []f32, t: f32) -> f32 {
		t := clamp(t, 0, f32(len(edges) - 1))
		i := math.min(int(t), len(edges) - 2)
		return edges[i] + (edges[i + 1] - edges[i]) * (t - f32(i))
	}
	t0, t1 := (x0 - game.edge_x0) / game.edge_step, (x1 - game.edge_x0) / game.edge_step
	a, b := at(edges, t0), at(edges, t1)
	lo, hi = math.min(a, b), math.max(a, b)
	for i in math.max(int(math.ceil(t0)), 0) ..= math.min(int(math.floor(t1)), n - 1) {
		lo, hi = math.min(lo, edges[i]), math.max(hi, edges[i])
	}
	return
}

// Puts a text's top edge at `top` (texts are positioned by their middle)
place_text :: proc(id: int, top: eng.Vector2, size: f32) {
	e := eng.get_entity(id)
	(&e.drawable.(eng.Text)).font_size = size
	e.pos = top + {0, size / 2}
}

// The two tendrils, as in drawShipHelix: each starts at its protrusion's tip and eases into
// a wide helix around the ship's axis; the strands are half a turn apart. Every piece goes
// into the back, middle or front group by how far "in front" it is, and is written into
// `out` as a capsule (ship units), back pieces first. Returns the group sizes.
helix_pieces :: proc(spin: f64, out: []f32) -> (n_back, n_mid: int) {
	Point :: struct {
		x, y, z, w: f64,
	}
	Piece :: [fx.CAPSULE_STRIDE]f32
	groups: [3][HELIX_PIECES]Piece
	counts: [3]int
	n :: HELIX_POINTS
	for side in ([2]f64{-1, 1}) {
		pts: [n + 1]Point
		for i in 0 ..= n {
			s := f64(i) / n
			e := math.min(1, s / HELIX_EASE)
			blend := e * e * (3 - 2 * e) // 0 at the root → 1 in the helix
			phase := side * math.PI / 2 + s * HELIX_TURNS * math.PI * 2 - spin
			r := HELIX_RADIUS * (1 - s * HELIX_TAPER)
			hy := math.sin(phase) * r + math.sin(spin * 0.3 - s * 2) * 2 * s // the helix also sways softly
			z := math.cos(phase) * blend
			pts[i] = {
				x = SHIP_FIN_X - s * HELIX_LENGTH,
				y = side * SHIP_FIN_Y * (1 - blend) + hy * blend,
				z = z,
				w = (HELIX_WIDTH * math.pow(1 - s, 0.7) + 0.5) * (0.75 + 0.25 * z),
			}
		}
		for i in 0 ..< n {
			a, b := pts[i], pts[i + 1]
			z := (a.z + b.z) / 2
			g := 0 if z < -0.33 else 1 if z < 0.33 else 2
			// The original also strokes each piece 0.4 wide in its color, closing hairline gaps
			groups[g][counts[g]] = {f32(a.x), f32(a.y), f32(b.x), f32(b.y), f32(a.w / 2 + 0.2), f32(b.w / 2 + 0.2), 0, 0}
			counts[g] += 1
		}
	}
	k := 0
	for g in 0 ..< 3 {
		for &piece in groups[g][:counts[g]] {
			copy(out[k:], piece[:])
			k += fx.CAPSULE_STRIDE
		}
	}
	return counts[0], counts[1]
}

// Sparks as streaks in screen pixels, grouped by age into three brightness steps; the
// entity covers just the sparks alive this frame
sync_sparks :: proc(state: ^State, distance, s: f64) {
	Piece :: [fx.CAPSULE_STRIDE]f32
	groups: [3][SPARK_MAX]Piece
	counts: [3]int
	radius := f32(0.04 * s) // the original strokes them 0.08 wide
	lo, hi := eng.Vector2{1e9, 1e9}, eng.Vector2{-1e9, -1e9}
	for sp in state.sparks {
		if !sp.used || sp.age >= sp.life {
			continue
		}
		g := math.min(2, int(math.floor(sp.age / sp.life * 3)))
		x := sp.x - distance
		a := eng.Vector2{f32(x * s), f32(sp.y * s)}
		b := eng.Vector2{f32((x - (sp.vx - state.ship_vx) * 0.05) * s), f32((sp.y - sp.vy * 0.05) * s)} // tail behind it
		groups[g][counts[g]] = {a.x, a.y, b.x, b.y, radius, radius, 0, 0}
		counts[g] += 1
		lo = {math.min(lo.x, a.x, b.x), math.min(lo.y, a.y, b.y)}
		hi = {math.max(hi.x, a.x, b.x), math.max(hi.y, a.y, b.y)}
	}
	e := eng.get_entity(game.sparks)
	e.visible = counts[0] + counts[1] + counts[2] > 0
	if !e.visible {
		return
	}
	k := 0
	for g in 0 ..< 3 {
		for &piece in groups[g][:counts[g]] {
			copy(game.spark_data[k:], piece[:])
			k += fx.CAPSULE_STRIDE
		}
	}
	eng.set_param_array(game.sparks, "sparks", game.spark_data[:k])
	eng.set_param(game.sparks, "n0", f32(counts[0]))
	eng.set_param(game.sparks, "n1", f32(counts[1]))
	eng.set_param(game.sparks, "n2", f32(counts[2]))
	margin := radius + 2
	e.pos = (lo + hi) / 2
	e.size = hi - lo + 2 * margin
}

// "1280x720" → 1280, 720
parse_size :: proc(s: string) -> (w, h: i32, ok: bool) {
	parts := strings.split(s, "x", context.temp_allocator)
	if len(parts) != 2 {
		return
	}
	pw, okw := strconv.parse_int(parts[0])
	ph, okh := strconv.parse_int(parts[1])
	return i32(pw), i32(ph), okw && okh && pw > 0 && ph > 0
}

main :: proc() {
	width, height: i32 = 1280, 720
	if w, h, ok := parse_size(os.get_env("ALGO_SIZE", context.temp_allocator)); ok {
		width, height = w, h
	}
	benchmark := os.get_env("ZSE_PROFILE_SECONDS", context.temp_allocator) != ""
	seed := i64(time.now()._nsec % 1_000_000_000)
	if benchmark {
		seed = BENCH_SEED
	}
	if s, ok := strconv.parse_i64(os.get_env("ALGO_SEED", context.temp_allocator)); ok {
		seed = s
	}

	eng.init_context(
		eng.InitOptions {
			width = width,
			height = height,
			vsync = .Off if os.get_env("ALGO_VSYNC", context.temp_allocator) == "off" else .On, // On: like the browser
			title = "AlgoGame",
			num_layers = LAYER_COUNT,
			bg_color = BACKGROUND,
			resizable = true,
			match_window = true,
			bake_constants = true, // every look here is made the same way for all its entities
		},
	)
	if os.get_env("ALGO_FULLSCREEN", context.temp_allocator) == "on" {
		rl.ToggleBorderlessWindowed() // the game follows the window (match_window)
	}
	game.state = create_state(seed)
	if s, ok := strconv.parse_int(os.get_env("ALGO_STAGE", context.temp_allocator)); ok {
		stage = s
	}
	init_goo()
	init_growths()
	if has_stage(4) {
		init_scenery()
	}
	game.autopilot = benchmark
	game.rock[0] = eng.add_entity(rock_look(1), {}, {1, 1}, {z_index = LAYER_ROCK})
	game.rock[1] = eng.add_entity(rock_look(-1), {}, {1, 1}, {z_index = LAYER_ROCK})
	game.ship = eng.add_entity(ship_look(), {}, {1, 1}, {z_index = LAYER_SHIP})
	game.sparks = eng.add_entity(sparks_look(), {}, {1, 1}, {z_index = LAYER_FX})
	game.score_text = eng.add_text("Score 0", {}, 20, SCORE, LAYER_TEXT, .Center)
	hint := fmt.tprintf("Hold Space, click or touch to thrust   -   seed %d", seed)
	game.hint_text = eng.add_text(hint, {}, 14, TEXT, LAYER_TEXT, .Left)
	init_menu()
	if s, ok := strconv.parse_f64(os.get_env("ALGO_SHOT", context.temp_allocator)); ok {
		game.shot_at = s
		eng.set_overlay(take_shot)
	}
	eng.run(on_update)
}
