package main

import eng "../../engine"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import rl "vendor:raylib"

SCREEN_WIDTH :: 1280
SCREEN_HEIGHT :: 720
HUD_TOP :: 44 // planets stay clear of the HUD strips
HUD_BOTTOM :: 40

MAX_BOTS :: 3
NEUTRAL :: 0
HUMAN :: 1
OWNER_COLORS := [MAX_BOTS + 2]rl.Color{NEUTRAL_GRAY, PLAYER_BLUE, BOT_RED, BOT_GREEN, BOT_PURPLE}

PLANET_RADIUS :: [2]f32{16, 46}
PLANET_GAP :: 46 // minimum empty space between two planets
HOME_RADIUS :: 36
HOME_SHIPS :: 100
PRODUCTION_PER_RADIUS :: 0.045 // ships per second per unit of radius
SHIP_SPEED :: 85
SHIPS_PER_SEND :: 24 // ship entities per launch; bigger fleets pack several ships into one
ASTEROIDS :: 16
DEBRIS :: 14
COMET_INTERVAL :: [2]f32{10, 25}

// Layers, back to front.
Z_SPACE :: 0
Z_DRIFT :: 1 // asteroids, debris, comets
Z_LINES :: 2
Z_PLANETS :: 3
Z_SHIPS :: 4
Z_EFFECTS :: 5
Z_UI :: 6
Z_TEXT :: 7
LAYER_COUNT :: 8

Planet :: struct {
	id, label:  int,
	pos:        eng.Vector2,
	radius:     f32,
	owner:      int,
	ships:      f32,
	production: f32, // ships per second while owned by a player
	selected:   bool,
}

Ship :: struct {
	id:      int,
	owner:   int,
	target:  int, // planet index
	pos:     eng.Vector2,
	heading: eng.Vector2,
	speed:   f32,
	value:   int, // ships this one stands for
}

// Decorative space objects; asteroids and debris wrap around the screen, comets don't.
Drifter :: struct {
	id:    int,
	vel:   eng.Vector2,
	spin:  f32, // degrees/s
	wraps: bool,
}

State :: enum {
	Title,
	Playing,
	Won,
	Lost,
}

Game :: struct {
	state:             State,
	bot_count:         int,
	paused, fast:      bool,
	planets:           [dynamic]Planet,
	ships:             [dynamic]Ship,
	drifters:          [dynamic]Drifter,
	bots:              [MAX_BOTS]Bot,
	sun:               eng.Vector2,
	send_fraction:     f32,
	comet_timer:       f32,
	// Pointer interaction
	pressing:          bool,
	press_pos:         eng.Vector2,
	press_planet:      int,
	last_click_time:   f64,
	last_click_planet: int,
	lines:             [dynamic]int, // send-line entities, one per source planet
	box:               int,
	// HUD
	power_bar:         int,
	meter:             int,
	meter_text:        int,
	status:            int,
	message:           int,
}

game: Game

// ---------------------------------------------------------------------------------------
// Galaxy generation

hsv :: proc(hue: [2]f32, saturation, value: f32) -> rl.Color {
	return rl.ColorFromHSV(rand.float32_range(hue[0], hue[1]), saturation, value)
}

random_style :: proc(radius: f32) -> PlanetStyle {
	kinds := [?]PlanetKind{.Terran, .Desert, .Ice, .Lava, .Barren, .Toxic, .Gas, .Gas}
	kind := rand.choice(kinds[:] if radius >= 30 else kinds[:6])
	s := PlanetStyle {
		kind = kind,
		spin = rand.float32_range(3, 7),
		seed = rand.float32_range(0, 100),
	}
	switch kind {
	case .Terran:
		s.a, s.b, s.c = hsv(OCEAN_HUE, 0.65, 0.6), hsv(LAND_HUE, 0.5, 0.42), hsv(LAND_HUE, 0.25, 0.68)
		s.atmosphere, s.haze = hsv(OCEAN_HUE, 0.35, 1), 0.9
	case .Desert:
		s.a, s.b, s.c = hsv(DESERT_HUE, 0.55, 0.45), hsv(DESERT_HUE, 0.5, 0.7), hsv(DESERT_HUE, 0.35, 0.88)
		s.atmosphere, s.haze = hsv(DESERT_HUE, 0.4, 1), 0.4
	case .Ice:
		s.atmosphere, s.haze = ICE_BLUE, 0.5
	case .Lava:
		s.atmosphere, s.haze = LAVA_RED, 0.35
	case .Gas:
		hue := rand.float32_range(GAS_HUE[0], GAS_HUE[1])
		s.a, s.b, s.c = hsv({hue, hue}, 0.5, 0.45), hsv({hue + 20, hue + 30}, 0.35, 0.75), hsv({hue - 30, hue - 15}, 0.2, 0.92)
		s.atmosphere, s.haze = hsv({hue, hue}, 0.3, 1), 0.6
		s.rings = rand.float32() < 0.5
		s.spin *= 2
	case .Barren:
		s.a, s.b = hsv(BARREN_HUE, 0.12, 0.32), hsv(BARREN_HUE, 0.1, 0.62)
	case .Toxic:
		s.a, s.b, s.c = hsv(TOXIC_HUE, 0.7, 0.35), hsv(TOXIC_HUE, 0.6, 0.65), hsv(TOXIC_HUE, 0.45, 0.9)
		s.atmosphere, s.haze = hsv(TOXIC_HUE, 0.5, 1), 0.8
	}
	return s
}

// Direction towards the off-screen sun, lifted a little off the screen plane.
light_from_sun :: proc(pos: eng.Vector2) -> [3]f32 {
	d := linalg.normalize(game.sun - pos)
	return linalg.normalize([3]f32{d.x * 0.85, d.y * 0.85, 0.45})
}

overlaps_planet :: proc(pos: eng.Vector2, radius: f32) -> bool {
	for p in game.planets {
		if linalg.length(p.pos - pos) < p.radius + radius + PLANET_GAP {
			return true
		}
	}
	return false
}

// The planet furthest from every planet in `taken`.
farthest_planet :: proc(taken: []int) -> int {
	best, best_dist := -1, f32(-1)
	for p, i in game.planets {
		nearest := f32(math.F32_MAX)
		for t in taken {
			nearest = min(nearest, linalg.length(p.pos - game.planets[t].pos))
		}
		if nearest > best_dist {
			best, best_dist = i, nearest
		}
	}
	return best
}

create_space :: proc() {
	eng.clear_scene()
	clear(&game.planets)
	clear(&game.ships)
	clear(&game.drifters)
	clear(&game.lines)
	corners := [?]eng.Vector2{{-220, -160}, {SCREEN_WIDTH + 220, -160}, {-220, SCREEN_HEIGHT + 160}, {SCREEN_WIDTH + 220, SCREEN_HEIGHT + 160}}
	game.sun = rand.choice(corners[:])
	// The sun lights the asteroids and debris; planets shade their globes from it themselves.
	eng.clear_lights()
	eng.set_ambient(SPACE_AMBIENT, 0.12)
	eng.add_light({kind = .Point, pos = game.sun, height = 500, color = SUN_CORE, intensity = 1.5, radius = 4000})
	nebula_hue := rand.float32_range(NEBULA_HUE[0], NEBULA_HUE[1])
	nebula_a := rl.ColorFromHSV(nebula_hue, 0.7, 0.55)
	nebula_b := rl.ColorFromHSV(nebula_hue + rand.float32_range(40, 120), 0.6, 0.45)
	eng.add_entity(space_look(nebula_a, nebula_b, game.sun, rand.float32_range(0, 100)), {SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2}, {SCREEN_WIDTH, SCREEN_HEIGHT}, {z_index = Z_SPACE})

	for i in 0 ..< ASTEROIDS + DEBRIS {
		pos := eng.Vector2{rand.float32_range(0, SCREEN_WIDTH), rand.float32_range(0, SCREEN_HEIGHT)}
		heading := rand.float32_range(0, math.TAU)
		dir := eng.Vector2{math.cos(heading), math.sin(heading)}
		if i < ASTEROIDS {
			r := rand.float32_range(5, 18)
			id := eng.add_entity(asteroid_look(r, rand.float32_range(0, 100)), pos, {2 * r, 2 * r}, {z_index = Z_DRIFT, pad = r * 0.4 + 2})
			append(&game.drifters, Drifter{id = id, vel = dir * rand.float32_range(4, 14), spin = rand.float32_range(-20, 20), wraps = true})
		} else {
			id := eng.add_entity(debris_look(rand.float32_range(0, 100)), pos, {14, 10}, {z_index = Z_DRIFT, pad = 2})
			append(&game.drifters, Drifter{id = id, vel = dir * rand.float32_range(10, 25), spin = rand.float32_range(-90, 90), wraps = true})
		}
	}
	game.comet_timer = rand.float32_range(2, 6)

	// Looks spawned mid-game, compiled now so they don't stall the first launch or capture.
	eng.precompile(ship_look(PLAYER_BLUE, 0))
	eng.precompile(hit_look(PLAYER_BLUE, 0))
	eng.precompile(capture_look(PLAYER_BLUE, 30))
	eng.precompile(comet_look())
}

start_game :: proc(bots: int) {
	create_space()
	game.state = .Playing
	game.bot_count = bots
	game.send_fraction = 0.5
	game.pressing = false
	game.last_click_planet = -1

	target := 16 + 3 * bots
	for attempt := 0; attempt < 4000 && len(game.planets) < target; attempt += 1 {
		r := PLANET_RADIUS[0] + (PLANET_RADIUS[1] - PLANET_RADIUS[0]) * math.pow(rand.float32(), 1.6)
		pos := eng.Vector2 {
			rand.float32_range(r + 24, SCREEN_WIDTH - r - 24),
			rand.float32_range(HUD_TOP + r + 16, SCREEN_HEIGHT - HUD_BOTTOM - r - 16),
		}
		if !overlaps_planet(pos, r) {
			append(&game.planets, Planet{pos = pos, radius = r})
		}
	}

	// Homes: the human anywhere, every bot as far as possible from the homes taken so far.
	// Resizing to HOME_RADIUS stays clear of neighbours thanks to PLANET_GAP.
	homes: [dynamic]int
	defer delete(homes)
	for player in HUMAN ..= bots + 1 {
		index := rand.int_max(len(game.planets)) if player == HUMAN else farthest_planet(homes[:])
		p := &game.planets[index]
		p.owner = player
		p.radius = HOME_RADIUS
		p.ships = HOME_SHIPS
		p.selected = player == HUMAN
		append(&homes, index)
	}

	for &p in game.planets {
		if p.owner == NEUTRAL {
			p.ships = math.round(4 + p.radius * 0.5 + rand.float32_range(0, 16))
		}
		p.production = p.radius * PRODUCTION_PER_RADIUS
		p.id = eng.add_entity(planet_look(p.radius, random_style(p.radius), light_from_sun(p.pos)), p.pos, {2 * p.radius, 2 * p.radius}, {z_index = Z_PLANETS, pad = p.radius + 16})
		show_owner(p)
		p.label = eng.add_text("", p.pos, clamp(p.radius * 0.55, 12, 20), TEXT_LIGHT, Z_TEXT, .Center)
	}

	for b in 0 ..< bots {
		game.bots[b] = {player = HUMAN + 1 + b, timer = rand.float32_range(1, 3)}
	}
	create_hud()
	show_message("Drag from your blue planet to another to send ships")
}

create_hud :: proc() {
	game.power_bar = eng.add_entity(power_bar_look({PLAYER_BLUE, BOT_RED, BOT_GREEN, BOT_PURPLE}), {196, 22}, {360, 14}, {z_index = Z_UI})
	game.status = eng.add_text("", {392, 22}, 18, TEXT_LIGHT, Z_TEXT)
	game.meter = eng.add_entity(meter_look(PLAYER_BLUE), {136, SCREEN_HEIGHT - 20}, {240, 14}, {z_index = Z_UI})
	game.meter_text = eng.add_text("", {268, SCREEN_HEIGHT - 20}, 18, TEXT_LIGHT, Z_TEXT)
	eng.add_text("wheel / 1-0 fleet size   ctrl+A or double click: all   P pause   F speed   R new galaxy", {SCREEN_WIDTH - 16, SCREEN_HEIGHT - 20}, 14, TEXT_DIM, Z_TEXT, .Right)
	game.box = eng.add_entity(selection_box_look(), {}, {1, 1}, {z_index = Z_UI})
	eng.get_entity(game.box).visible = false
	game.message = eng.add_text("", {SCREEN_WIDTH / 2, 70}, 22, TEXT_GOLD, Z_TEXT, .Center)
}

show_message :: proc(text: string) {
	eng.set_text(game.message, text)
}

show_title :: proc() {
	create_space()
	game.state = .Title
	eng.add_text("GALCON", {SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2 - 80}, 72, TEXT_LIGHT, Z_TEXT, .Center)
	eng.add_text("Conquer the galaxy, one planet at a time", {SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2}, 22, TEXT_DIM, Z_TEXT, .Center)
	eng.add_text("Press 1, 2 or 3 to choose the number of opponents", {SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2 + 60}, 22, TEXT_GOLD, Z_TEXT, .Center)
}

// ---------------------------------------------------------------------------------------
// Fleets

// Launches `fraction` of a planet's ships towards another planet, fanned out across the
// side facing the target.
send_fleet :: proc(from, to: int, fraction: f32) {
	src := &game.planets[from]
	count := int(src.ships * fraction)
	if count < 1 || from == to {
		return
	}
	src.ships -= f32(count)
	per_ship := max(1, (count + SHIPS_PER_SEND - 1) / SHIPS_PER_SEND)
	dir := linalg.normalize(game.planets[to].pos - src.pos)
	color := OWNER_COLORS[src.owner]
	for remaining := count; remaining > 0; {
		value := min(per_ship, remaining)
		remaining -= value
		spread := rand.float32_range(-1.1, 1.1)
		out := eng.Vector2{dir.x * math.cos(spread) - dir.y * math.sin(spread), dir.x * math.sin(spread) + dir.y * math.cos(spread)}
		pos := src.pos + out * (src.radius + 6)
		id := eng.add_entity(ship_look(color, rand.float32_range(0, 100)), pos, {16, 12}, {z_index = Z_SHIPS, pad = 10, rotation = math.atan2(out.y, out.x) * math.DEG_PER_RAD})
		append(&game.ships, Ship{id = id, owner = src.owner, target = to, pos = pos, heading = out, speed = SHIP_SPEED * rand.float32_range(0.9, 1.1), value = value})
	}
}

// Owned planets take on their owner's color; neutral ones keep their natural look.
show_owner :: proc(p: Planet) {
	eng.set_param(p.id, "owner", OWNER_COLORS[p.owner])
	eng.set_param(p.id, "tint", f32(0) if p.owner == NEUTRAL else 0.65)
}

capture :: proc(index, owner: int) {
	p := &game.planets[index]
	if p.owner == HUMAN || owner == HUMAN {
		eng.add_shake(3)
	}
	p.owner = owner
	p.ships = -p.ships
	p.selected = p.selected && owner == HUMAN
	show_owner(p^)
	eng.set_param(p.id, "capture_time", eng.time())
	eng.add_entity(capture_look(OWNER_COLORS[owner], p.radius), p.pos, {0, 0}, {z_index = Z_EFFECTS, pad = p.radius + 170, lifetime = 1.4, blend = .Additive})
}

arrive :: proc(index: int) {
	s := game.ships[index]
	p := &game.planets[s.target]
	if p.owner == s.owner {
		p.ships += f32(s.value)
	} else {
		p.ships -= f32(s.value)
		if rand.float32() < 0.5 {
			eng.add_entity(hit_look(OWNER_COLORS[s.owner], rand.float32_range(0, 100)), s.pos, {0, 0}, {z_index = Z_EFFECTS, pad = 40, lifetime = 0.4, blend = .Additive})
		}
		if p.ships < 0 {
			capture(s.target, s.owner)
		}
	}
	eng.remove_entity(s.id)
	unordered_remove(&game.ships, index)
}

// Ships home in on their target, sliding around any planet in the way.
update_ships :: proc(dt: f32) {
	eng.profile_scope("update_ships")
	for i := 0; i < len(game.ships); {
		s := &game.ships[i]
		target := game.planets[s.target]
		to := target.pos - s.pos
		dist := linalg.length(to)
		if dist <= target.radius + 1 {
			arrive(i)
			continue
		}
		desired := to / dist
		avoid: eng.Vector2
		for p, j in game.planets {
			if j == s.target {
				continue
			}
			away := s.pos - p.pos
			d := linalg.length(away)
			reach := p.radius + 26
			if d < reach && d > 0.01 {
				n := away / d
				tangent := eng.Vector2{-n.y, n.x}
				if linalg.dot(tangent, desired) < 0 {
					tangent = -tangent
				}
				avoid += (n * 1.2 + tangent) * ((reach - d) / 26)
			}
		}
		s.heading = linalg.normalize(linalg.lerp(s.heading, linalg.normalize(desired + avoid), min(dt * 4, 1)))
		s.pos += s.heading * s.speed * dt
		e := eng.get_entity(s.id)
		e.pos = s.pos
		e.rotation = math.atan2(s.heading.y, s.heading.x) * math.DEG_PER_RAD
		i += 1
	}
}

update_planets :: proc(dt: f32) {
	eng.profile_scope("update_planets")
	for &p in game.planets {
		if p.owner != NEUTRAL {
			p.ships += p.production * dt
		}
		eng.set_text(p.label, fmt.tprintf("%d", int(p.ships)))
		eng.set_text_color(p.label, TEXT_LIGHT if p.owner == NEUTRAL else rl.ColorBrightness(OWNER_COLORS[p.owner], 0.5))
	}
}

update_drifters :: proc(dt: f32) {
	eng.profile_scope("update_drifters")
	game.comet_timer -= dt
	if game.comet_timer <= 0 {
		game.comet_timer = rand.float32_range(COMET_INTERVAL[0], COMET_INTERVAL[1])
		spawn_comet()
	}
	for i := 0; i < len(game.drifters); {
		d := game.drifters[i]
		if !eng.entity_exists(d.id) {
			unordered_remove(&game.drifters, i)
			continue
		}
		e := eng.get_entity(d.id)
		e.pos += d.vel * dt
		e.rotation += d.spin * dt
		if d.wraps {
			margin :: 40
			if e.pos.x < -margin {e.pos.x += SCREEN_WIDTH + 2 * margin}
			if e.pos.x > SCREEN_WIDTH + margin {e.pos.x -= SCREEN_WIDTH + 2 * margin}
			if e.pos.y < -margin {e.pos.y += SCREEN_HEIGHT + 2 * margin}
			if e.pos.y > SCREEN_HEIGHT + margin {e.pos.y -= SCREEN_HEIGHT + 2 * margin}
		}
		i += 1
	}
}

// A comet streaking across the whole screen from one side to the other.
spawn_comet :: proc() {
	from_left := rand.float32() < 0.5
	start := eng.Vector2{-150 if from_left else SCREEN_WIDTH + 150, rand.float32_range(0, SCREEN_HEIGHT)}
	end := eng.Vector2{SCREEN_WIDTH + 150 if from_left else -150, rand.float32_range(0, SCREEN_HEIGHT)}
	dir := linalg.normalize(end - start)
	speed := rand.float32_range(160, 240)
	id := eng.add_entity(
		comet_look(),
		start,
		{180, 30},
		{z_index = Z_DRIFT, pad = 20, lifetime = linalg.length(end - start) / speed, blend = .Additive, rotation = math.atan2(dir.y, dir.x) * math.DEG_PER_RAD},
	)
	append(&game.drifters, Drifter{id = id, vel = dir * speed})
}

// ---------------------------------------------------------------------------------------
// Player input

planet_at :: proc(pos: eng.Vector2) -> int {
	for p, i in game.planets {
		if linalg.length(pos - p.pos) <= p.radius + 10 {
			return i
		}
	}
	return -1
}

deselect_all :: proc() {
	for &p in game.planets {
		p.selected = false
	}
}

select_all_own :: proc() {
	for &p in game.planets {
		p.selected = p.owner == HUMAN
	}
}

send_selected :: proc(target: int) {
	for p, i in game.planets {
		if p.selected && i != target {
			send_fleet(i, target, game.send_fraction)
		}
	}
	show_message("")
}

// Click rules: with a selection, clicking any other planet sends ships there (shift-click on
// your own adds it to the selection instead); otherwise clicking your planet selects it.
click_planet :: proc(index: int, shift: bool) {
	if index < 0 {
		deselect_all()
		return
	}
	p := &game.planets[index]
	now := rl.GetTime()
	double := index == game.last_click_planet && now - game.last_click_time < 0.35
	game.last_click_time, game.last_click_planet = now, index
	if p.owner == HUMAN && double {
		select_all_own()
		return
	}
	has_selection := false
	for q in game.planets {
		has_selection ||= q.selected
	}
	switch {
	case p.owner == HUMAN && shift:
		p.selected = !p.selected
	case has_selection && !p.selected:
		send_selected(index)
	case p.owner == HUMAN:
		deselect_all()
		p.selected = true
	}
}

box_select :: proc(a, b: eng.Vector2, shift: bool) {
	if !shift {
		deselect_all()
	}
	lo, hi := linalg.min(a, b), linalg.max(a, b)
	for &p in game.planets {
		if p.owner == HUMAN && p.pos.x >= lo.x && p.pos.x <= hi.x && p.pos.y >= lo.y && p.pos.y <= hi.y {
			p.selected = true
		}
	}
}

handle_pointer :: proc() {
	eng.profile_scope("handle_pointer")
	mouse := eng.mouse_position()
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	hovered := planet_at(mouse)
	if rl.IsMouseButtonPressed(.LEFT) {
		game.pressing = true
		game.press_pos = mouse
		game.press_planet = hovered
	}
	dragging := game.pressing && linalg.length(mouse - game.press_pos) > 6
	drag_send := dragging && game.press_planet >= 0 && game.planets[game.press_planet].owner == HUMAN
	if rl.IsMouseButtonReleased(.LEFT) && game.pressing {
		game.pressing = false
		switch {
		case !dragging:
			click_planet(hovered, shift)
		case drag_send:
			source := &game.planets[game.press_planet]
			if !source.selected {
				if !shift {
					deselect_all()
				}
				source.selected = true
			}
			if hovered >= 0 && hovered != game.press_planet {
				send_selected(hovered)
			}
		case:
			box_select(game.press_pos, mouse, shift)
		}
	}
	if (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)) && rl.IsKeyPressed(.A) {
		select_all_own()
	}
	if rl.IsMouseButtonPressed(.RIGHT) || rl.IsKeyPressed(.ESCAPE) {
		deselect_all()
	}

	wheel := rl.GetMouseWheelMove()
	if wheel != 0 {
		game.send_fraction = clamp(math.round(game.send_fraction * 10 + math.sign(wheel)) / 10, 0.1, 1)
	}
	for i in 0 ..< 10 {
		if rl.IsKeyPressed(rl.KeyboardKey(int(rl.KeyboardKey.ZERO) + i)) {
			game.send_fraction = 1 if i == 0 else f32(i) / 10
		}
	}

	// Planet highlights
	for p, i in game.planets {
		eng.set_param(p.id, "selected", f32(1) if p.selected else 0)
		eng.set_param(p.id, "hover", f32(1) if i == hovered else 0)
	}

	// Send lines: while dragging from an owned planet, or hovering a target with a selection.
	sources := make([dynamic]int, context.temp_allocator)
	if drag_send || (!game.pressing && hovered >= 0) {
		for p, i in game.planets {
			if (p.selected || (drag_send && i == game.press_planet)) && i != hovered {
				append(&sources, i)
			}
		}
		if !drag_send && (hovered < 0 || game.planets[hovered].selected) {
			clear(&sources)
		}
	}
	for len(game.lines) < len(sources) {
		append(&game.lines, eng.add_entity(send_line_look(), {}, {1, 1}, {z_index = Z_LINES}))
	}
	end := game.planets[hovered].pos if hovered >= 0 else mouse
	for id, i in game.lines {
		e := eng.get_entity(id)
		e.visible = i < len(sources)
		if !e.visible {
			continue
		}
		src := game.planets[sources[i]]
		delta := end - src.pos
		length := linalg.length(delta)
		dir := delta / max(length, 1)
		from := src.pos + dir * (src.radius + 10)
		to := end - dir * (game.planets[hovered].radius + 10 if hovered >= 0 else 0)
		e.pos = (from + to) / 2
		e.size = {max(linalg.length(to - from), 1), 8}
		e.rotation = math.atan2(dir.y, dir.x) * math.DEG_PER_RAD
	}

	box := eng.get_entity(game.box)
	box.visible = dragging && !drag_send
	if box.visible {
		box.pos = (game.press_pos + mouse) / 2
		box.size = linalg.abs(mouse - game.press_pos)
	}
}

// ---------------------------------------------------------------------------------------
// Main loop

player_alive :: proc(player: int) -> bool {
	for p in game.planets {
		if p.owner == player {
			return true
		}
	}
	for s in game.ships {
		if s.owner == player {
			return true
		}
	}
	return false
}

update_hud :: proc() {
	eng.profile_scope("update_hud")
	totals: [MAX_BOTS + 2]f32
	planets: [MAX_BOTS + 2]int
	for p in game.planets {
		totals[p.owner] += p.ships
		planets[p.owner] += 1
	}
	for s in game.ships {
		totals[s.owner] += f32(s.value)
	}
	all: f32
	for player in HUMAN ..= game.bot_count + 1 {
		all += totals[player]
	}
	names := [?]string{"split1", "split2", "split3"}
	share: f32
	for split, i in names {
		share += totals[HUMAN + i] / max(all, 1)
		eng.set_param(game.power_bar, split, share if HUMAN + i <= game.bot_count else 1)
	}
	eng.set_text(game.status, fmt.tprintf("You: %d ships, %d planets", int(totals[HUMAN]), planets[HUMAN]))
	eng.set_param(game.meter, "fraction", game.send_fraction)
	eng.set_text(game.meter_text, fmt.tprintf("SEND %d%%", int(math.round(game.send_fraction * 100))))
}

on_update :: proc(dt: f32) {
	update_drifters(dt)
	if game.state == .Title {
		for i in 1 ..= MAX_BOTS {
			if rl.IsKeyPressed(rl.KeyboardKey(int(rl.KeyboardKey.ZERO) + i)) {
				start_game(i)
			}
		}
		return
	}

	if rl.IsKeyPressed(.R) {
		start_game(game.bot_count)
		return
	}
	if rl.IsKeyPressed(.P) && game.state == .Playing {
		game.paused = !game.paused
		show_message("PAUSED" if game.paused else "")
	}
	if rl.IsKeyPressed(.F) {
		game.fast = !game.fast
	}
	eng.set_time_scale(0 if game.paused else 2 if game.fast else 1)
	if game.paused {
		return
	}

	if game.state == .Playing {
		handle_pointer()
		update_bots(dt)
	}
	update_planets(dt)
	update_ships(dt)
	update_hud()

	if game.state == .Playing {
		if !player_alive(HUMAN) {
			game.state = .Lost
			show_message("DEFEAT  -  press R for a new galaxy")
		} else {
			any_bot := false
			for b in 0 ..< game.bot_count {
				any_bot ||= player_alive(game.bots[b].player)
			}
			if !any_bot {
				game.state = .Won
				show_message("VICTORY!  The galaxy is yours  -  press R for a new one")
			}
		}
	}
}

main :: proc() {
	eng.init_context(
		eng.InitOptions {
			width = SCREEN_WIDTH,
			height = SCREEN_HEIGHT,
			fps = 60,
			title = "Galcon",
			num_layers = LAYER_COUNT,
			bg_color = rl.BLACK,
			resizable = true,
		},
	)
	show_title()
	eng.run(on_update)
}
