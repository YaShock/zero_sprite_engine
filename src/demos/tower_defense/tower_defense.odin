package main

import eng "../../engine"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import rl "vendor:raylib"

SCREEN_WIDTH :: 1280
SCREEN_HEIGHT :: 720
MAP_WIDTH :: 1040
GRID_W :: MAP_WIDTH / CELL
GRID_H :: SCREEN_HEIGHT / CELL
PANEL_X :: MAP_WIDTH
PANEL_CENTER_X :: (MAP_WIDTH + SCREEN_WIDTH) / 2

START_GOLD :: 140
START_LIVES :: 5
TREE_COUNT :: 12
BOULDER_COUNT :: 6
WALK_STRIDE :: 0.16 // walk animation radians per unit travelled
LANE_SPREAD :: 7 // max sideways offset of a golem from the road's center line

// Road waypoints in grid cells: from the rift off the left edge to the gate.
PATH_CELLS := [?][2]f32{{-1.5, 3}, {4, 3}, {4, 13}, {10, 13}, {10, 4}, {16, 4}, {16, 14}, {21, 14}, {21, 8}, {24, 8}}

// Where projectiles leave each tower, relative to the cell center.
MUZZLE := [TowerKind]eng.Vector2 {
	.Fire      = {0, -30},
	.Ice       = {0, -34},
	.Lightning = {0, -24},
}

IMPACT_COLOR := [TowerKind]rl.Color {
	.Fire      = FLAME_ORANGE,
	.Ice       = ICE_BLUE,
	.Lightning = VOLT_BLUE,
}

// Layers, back to front.
Z_TERRAIN :: 0
Z_OVERLAY :: 1 // build grid, range circle, tile highlight
Z_WORLD :: 2 // y-sorted: trees, boulders, towers, gate, golems
Z_PROJECTILES :: 3
Z_EFFECTS :: 4
Z_GHOST :: 5
Z_UI :: 6
Z_UI_ICONS :: 7
Z_TEXT :: 8
LAYER_COUNT :: 9

CellState :: enum {
	Free,
	Road,
	Blocked,
	Tower,
}

Tower :: struct {
	id:       int,
	kind:     TowerKind,
	level:    int, // 0-based
	cell:     [2]int,
	cooldown: f32,
	spent:    int,
}

Enemy :: struct {
	id:        int,
	kind:      EnemyKind,
	hp:        f32,
	max_hp:    f32,
	dist:      f32, // along the road
	lane:      f32,
	walk:      f32,
	facing:    f32,
	slow:      f32,
	slow_time: f32,
	burn_dps:  f32,
	burn_time: f32,
}

Projectile :: struct {
	id:        int,
	kind:      TowerKind,
	level:     int,
	target:    int, // enemy entity id
	aim:       eng.Vector2,
	pos:       eng.Vector2,
	speed:     f32,
	damage:    f32,
	bounces:   int,
	hit:       [8]int,
	hit_count: int,
}

FloatingText :: struct {
	id: int,
}

Button :: struct {
	id:    int,
	label: int,
	rect:  rl.Rectangle,
}

Phase :: enum {
	Break, // countdown to the next wave
	Wave,
	Won,
	Lost,
}

Ui :: struct {
	gold, lives, wave:         int,
	shop:                      [TowerKind]Button,
	shop_cost:                 [TowerKind]int,
	info_title, info_body:     int,
	upgrade, sell, next_wave:  Button,
	message:                   int,
}

Game :: struct {
	phase:          Phase,
	paused, fast:   bool,
	gold, lives:    int,
	wave:           int, // number of the current or last wave
	countdown:      f32,
	current:        Wave,
	spawned:        int,
	spawn_timer:    f32,
	message_timer:  f32,
	cells:          [GRID_W][GRID_H]CellState,
	path:           [len(PATH_CELLS)][2]f32,
	path_length:    f32,
	towers:         [dynamic]Tower,
	enemies:        [dynamic]Enemy,
	projectiles:    [dynamic]Projectile,
	floaters:       [dynamic]FloatingText,
	placing:        bool,
	placing_kind:   TowerKind,
	selected:       int, // tower entity id, or -1
	gate, grid:     int,
	highlight:      int,
	ghost:          int,
	range_circle:   int,
	ui:             Ui,
}

game: Game

// ---------------------------------------------------------------------------------------
// Level setup

random_tones :: proc() -> Tones {
	r :: proc(bounds: [2]f32) -> f32 {return rand.float32_range(bounds[0], bounds[1])}
	hue := r(GRASS_HUE)
	saturation := r(GRASS_SATURATION)
	value := r(GRASS_VALUE)
	return Tones {
		grass = rl.ColorFromHSV(hue, saturation, value),
		grass_dry = rl.ColorFromHSV(hue - r(DRY_HUE_SHIFT), saturation * 0.75, value * 1.1),
		dirt = rl.ColorFromHSV(r(DIRT_HUE), r(DIRT_SATURATION), r(DIRT_VALUE)),
		stone = rl.ColorFromHSV(r(STONE_HUE), r(STONE_SATURATION), r(STONE_VALUE)),
		flower = rl.ColorFromHSV(rand.float32_range(0, 360), 0.55, 0.95),
		foliage = rl.ColorFromHSV(hue + rand.float32_range(-12, 12), min(saturation * 1.2, 1), value * 0.8),
		seed = rand.float32_range(0, 100),
	}
}

cell_center :: proc(cell: [2]int) -> eng.Vector2 {
	return {(f32(cell.x) + 0.5) * CELL, (f32(cell.y) + 0.5) * CELL}
}

cell_at :: proc(pos: eng.Vector2) -> (cell: [2]int, ok: bool) {
	cell = {int(math.floor(pos.x / CELL)), int(math.floor(pos.y / CELL))}
	ok = cell.x >= 0 && cell.x < GRID_W && cell.y >= 0 && cell.y < GRID_H
	return
}

distance_to_path :: proc(pos: eng.Vector2) -> f32 {
	best := f32(math.F32_MAX)
	for i in 0 ..< len(game.path) - 1 {
		a, b := game.path[i], game.path[i + 1]
		t := clamp(linalg.dot(pos - a, b - a) / linalg.dot(b - a, b - a), 0, 1)
		best = min(best, linalg.length(pos - (a + (b - a) * t)))
	}
	return best
}

// Position on the road `dist` units from the start, and the road's direction there.
path_point :: proc(dist: f32) -> (pos, dir: eng.Vector2) {
	d := dist
	for i in 0 ..< len(game.path) - 1 {
		a, b := game.path[i], game.path[i + 1]
		seg := linalg.length(b - a)
		if d <= seg || i == len(game.path) - 2 {
			dir = (b - a) / seg
			return a + dir * min(d, seg), dir
		}
		d -= seg
	}
	unreachable()
}

random_free_cell :: proc() -> (cell: [2]int, ok: bool) {
	for _ in 0 ..< 200 {
		c := [2]int{rand.int_max(GRID_W), rand.int_max(GRID_H)}
		if game.cells[c.x][c.y] == .Free {
			return c, true
		}
	}
	return {}, false
}

create_game :: proc() {
	eng.clear_scene()
	clear(&game.towers)
	clear(&game.enemies)
	clear(&game.projectiles)
	clear(&game.floaters)
	delete(game.current.enemies)
	game.current = {}
	game.phase = .Break
	game.countdown = WAVE_BREAK
	game.gold = START_GOLD
	game.lives = START_LIVES
	game.wave = 0
	game.placing = false
	game.selected = -1
	game.paused = false
	game.fast = false
	eng.set_time_scale(1)

	game.path_length = 0
	for c, i in PATH_CELLS {
		game.path[i] = (c + 0.5) * CELL
		if i > 0 {
			game.path_length += linalg.length(game.path[i] - game.path[i - 1])
		}
	}
	gate_cell := [2]int{int(PATH_CELLS[len(PATH_CELLS) - 1].x), int(PATH_CELLS[len(PATH_CELLS) - 1].y)}
	for x in 0 ..< GRID_W {
		for y in 0 ..< GRID_H {
			near_road := distance_to_path(cell_center({x, y})) < ROAD_HALF + 14
			near_gate := abs(x - gate_cell.x) <= 1 && y >= gate_cell.y - 2 && y <= gate_cell.y
			game.cells[x][y] = CellState.Road if near_road else CellState.Blocked if near_gate else CellState.Free
		}
	}

	tones := random_tones()
	eng.add_entity(terrain_look(game.path[:], tones), {MAP_WIDTH / 2, SCREEN_HEIGHT / 2}, {MAP_WIDTH, SCREEN_HEIGHT}, {z_index = Z_TERRAIN})
	game.grid = eng.add_entity(grid_look(game.path[:]), {MAP_WIDTH / 2, SCREEN_HEIGHT / 2}, {MAP_WIDTH, SCREEN_HEIGHT}, {z_index = Z_OVERLAY})

	start := game.path[0]
	eng.add_entity(rift_look({18, 34}, RIFT_DARK, RIFT_PURPLE, RIFT_PINK, f32(0)), {14, start.y - 8}, {36, 68}, {z_index = Z_WORLD, pad = 16})
	gate_pos := game.path[len(game.path) - 1] - {0, 30}
	game.gate = eng.add_entity(gate_look(), gate_pos, {64, 84}, {z_index = Z_WORLD, pad = 20})

	for i in 0 ..< TREE_COUNT + BOULDER_COUNT {
		cell := random_free_cell() or_continue
		game.cells[cell.x][cell.y] = .Blocked
		look := tree_look(tones.foliage, f32(i) * 3.7) if i < TREE_COUNT else boulder_look(tones.stone, f32(i) * 5.3)
		eng.add_entity(look, cell_center(cell), {CELL, CELL}, {z_index = Z_WORLD, pad = 24})
	}

	game.highlight = eng.add_entity(cell_highlight_look(), {}, {CELL, CELL}, {z_index = Z_OVERLAY})
	game.range_circle = eng.add_entity(range_look(), {}, {100, 100}, {z_index = Z_OVERLAY})
	game.ghost = -1

	create_ui()
	refresh_overlays()
	show_message("Build towers, then press SPACE", 4)
}

// ---------------------------------------------------------------------------------------
// Interface

make_button :: proc(rect: rl.Rectangle, label: string, font_size: f32) -> Button {
	center := eng.Vector2{rect.x + rect.width / 2, rect.y + rect.height / 2}
	return Button {
		id = eng.add_entity(button_look(), center, {rect.width, rect.height}, {z_index = Z_UI, pad = 8}),
		label = eng.add_text(label, center, font_size, TEXT_LIGHT, Z_TEXT, .Center),
		rect = rect,
	}
}

create_ui :: proc() {
	ui := &game.ui
	eng.add_entity(panel_look(), {PANEL_CENTER_X, SCREEN_HEIGHT / 2}, {SCREEN_WIDTH - MAP_WIDTH, SCREEN_HEIGHT}, {z_index = Z_UI})
	eng.add_text("GOLEM GATE", {PANEL_CENTER_X, 30}, 26, TEXT_GOLD, Z_TEXT, .Center)

	eng.add_entity(coin_look(), {PANEL_X + 28, 72}, {18, 18}, {z_index = Z_UI_ICONS, pad = 4})
	ui.gold = eng.add_text("", {PANEL_X + 44, 72}, 22, TEXT_LIGHT, Z_TEXT)
	eng.add_entity(heart_look(), {PANEL_X + 140, 72}, {18, 18}, {z_index = Z_UI_ICONS, pad = 4})
	ui.lives = eng.add_text("", {PANEL_X + 156, 72}, 22, TEXT_LIGHT, Z_TEXT)
	ui.wave = eng.add_text("", {PANEL_CENTER_X, 106}, 20, TEXT_LIGHT, Z_TEXT, .Center)

	eng.add_text("BUILD", {PANEL_X + 16, 140}, 16, TEXT_DIM, Z_TEXT)
	for kind, i in TowerKind {
		rect := rl.Rectangle{PANEL_X + 12, 156 + f32(i) * 76, 216, 68}
		b := Button {
			id   = eng.add_entity(button_look(), {rect.x + rect.width / 2, rect.y + rect.height / 2}, {rect.width, rect.height}, {z_index = Z_UI, pad = 8}),
			rect = rect,
		}
		preview := eng.add_entity(placed_tower_look(kind), {rect.x + 32, rect.y + 44}, {CELL, CELL}, {z_index = Z_UI_ICONS, pad = 34})
		eng.set_param(preview, "level", f32(TOWER_LEVELS))
		info := TOWERS[kind]
		b.label = eng.add_text(info.name, {rect.x + 66, rect.y + 16}, 20, TEXT_LIGHT, Z_TEXT)
		eng.add_text(info.description, {rect.x + 66, rect.y + 36}, 14, TEXT_DIM, Z_TEXT)
		ui.shop_cost[kind] = eng.add_text(fmt.tprintf("%dg   [%d]", info.levels[0].cost, i + 1), {rect.x + 66, rect.y + 54}, 16, TEXT_GOLD, Z_TEXT)
		ui.shop[kind] = b
	}

	eng.add_text("TOWER", {PANEL_X + 16, 396}, 16, TEXT_DIM, Z_TEXT)
	ui.info_title = eng.add_text("", {PANEL_X + 16, 422}, 20, TEXT_LIGHT, Z_TEXT)
	ui.info_body = eng.add_text("", {PANEL_X + 16, 462}, 16, TEXT_DIM, Z_TEXT)
	ui.upgrade = make_button({PANEL_X + 12, 500, 104, 40}, "", 16)
	ui.sell = make_button({PANEL_X + 124, 500, 104, 40}, "", 16)
	ui.next_wave = make_button({PANEL_X + 12, 600, 216, 52}, "", 18)
	eng.add_text("P pause   F speed   ESC cancel", {PANEL_CENTER_X, 694}, 14, TEXT_DIM, Z_TEXT, .Center)

	ui.message = eng.add_text("", {MAP_WIDTH / 2, SCREEN_HEIGHT / 2 - 40}, 34, TEXT_LIGHT, Z_TEXT, .Center)
}

show_message :: proc(text: string, seconds: f32) {
	eng.set_text(game.ui.message, text)
	game.message_timer = seconds
}

floating_text :: proc(text: string, pos: eng.Vector2, color: rl.Color) {
	id := eng.add_text(text, pos, 18, color, Z_TEXT, .Center)
	eng.get_entity(id).lifetime = 0.9
	append(&game.floaters, FloatingText{id})
}

button_hovered :: proc(b: Button) -> bool {
	return rl.CheckCollisionPointRec(eng.mouse_position(), b.rect)
}

set_button :: proc(b: Button, enabled: bool, selected := false) {
	eng.set_param(b.id, "hover", f32(1) if button_hovered(b) && enabled else 0)
	eng.set_param(b.id, "enabled", f32(1) if enabled else 0)
	eng.set_param(b.id, "selected", f32(1) if selected else 0)
}

update_ui :: proc() {
	ui := &game.ui
	eng.set_text(ui.gold, fmt.tprintf("%d", game.gold))
	eng.set_text(ui.lives, fmt.tprintf("%d", game.lives))
	eng.set_text(ui.wave, fmt.tprintf("WAVE %d / %d", game.wave, WAVE_COUNT))

	for kind in TowerKind {
		affordable := game.gold >= TOWERS[kind].levels[0].cost
		set_button(ui.shop[kind], affordable, game.placing && game.placing_kind == kind)
		eng.set_text_color(ui.shop_cost[kind], TEXT_GOLD if affordable else TEXT_RED)
	}

	tower, has_tower := selected_tower()
	can_upgrade := has_tower && tower.level < TOWER_LEVELS - 1
	upgrade_cost := TOWERS[tower.kind].levels[tower.level + 1].cost if can_upgrade else 0
	set_button(ui.upgrade, can_upgrade && game.gold >= upgrade_cost)
	set_button(ui.sell, has_tower)
	if has_tower {
		info := TOWERS[tower.kind]
		stats := info.levels[tower.level]
		eng.set_text(ui.info_title, fmt.tprintf("%s  level %d", info.name, tower.level + 1))
		effect: string
		switch tower.kind {
		case .Fire:
			effect = fmt.tprintf("burn %.0f/s for %.1fs", stats.effect, stats.duration)
		case .Ice:
			effect = fmt.tprintf("slow %.0f%% for %.1fs", stats.effect * 100, stats.duration)
		case .Lightning:
			effect = fmt.tprintf("bounces %.0f times", stats.effect)
		}
		eng.set_text(ui.info_body, fmt.tprintf("damage %.0f  range %.0f\n%s", stats.damage, stats.range, effect))
		eng.set_text(ui.upgrade.label, fmt.tprintf("UP %dg [U]", upgrade_cost) if can_upgrade else "MAX")
		eng.set_text(ui.sell.label, fmt.tprintf("SELL %dg [S]", sell_value(tower^)))
	} else {
		eng.set_text(ui.info_title, "")
		hint := "Click a free tile to build,\nright click to cancel." if game.placing else "Click a tower to upgrade\nor sell it."
		eng.set_text(ui.info_body, hint)
		eng.set_text(ui.upgrade.label, "UPGRADE")
		eng.set_text(ui.sell.label, "SELL")
	}

	set_button(ui.next_wave, game.phase == .Break)
	switch game.phase {
	case .Break:
		eng.set_text(ui.next_wave.label, fmt.tprintf("NEXT WAVE %.0fs [SPACE]", math.ceil(game.countdown)))
	case .Wave:
		eng.set_text(ui.next_wave.label, "WAVE IN PROGRESS")
	case .Won, .Lost:
		eng.set_text(ui.next_wave.label, "PLAY AGAIN [R]")
	}
}

// Shows the grid, tile highlight, ghost and range circle that match the current mode.
refresh_overlays :: proc() {
	mouse := eng.mouse_position()
	cell, on_map := cell_at(mouse)
	on_map = on_map && mouse.x < MAP_WIDTH

	eng.get_entity(game.grid).visible = game.placing
	highlight := eng.get_entity(game.highlight)
	range_circle := eng.get_entity(game.range_circle)
	highlight.visible = game.placing && on_map
	range_circle.visible = false
	if game.ghost >= 0 {
		eng.get_entity(game.ghost).visible = highlight.visible
	}

	if game.placing && on_map {
		valid := f32(1) if game.cells[cell.x][cell.y] == .Free && game.gold >= TOWERS[game.placing_kind].levels[0].cost else 0
		highlight.pos = cell_center(cell)
		eng.set_param(game.highlight, "valid", valid)
		ghost := eng.get_entity(game.ghost)
		ghost.pos = cell_center(cell)
		eng.set_param(game.ghost, "valid", valid)
		show_range(cell_center(cell), TOWERS[game.placing_kind].levels[0].range)
	} else if tower, ok := selected_tower(); ok {
		show_range(cell_center(tower.cell), TOWERS[tower.kind].levels[tower.level].range)
	}
}

show_range :: proc(center: eng.Vector2, radius: f32) {
	e := eng.get_entity(game.range_circle)
	e.visible = true
	e.pos = center
	e.size = {radius * 2, radius * 2}
}

// ---------------------------------------------------------------------------------------
// Building

begin_placing :: proc(kind: TowerKind) {
	cancel_placing()
	game.selected = -1
	game.placing = true
	game.placing_kind = kind
	game.ghost = eng.add_entity(ghost_tower_look(kind), {}, {CELL, CELL}, {z_index = Z_GHOST, pad = 34})
}

cancel_placing :: proc() {
	if game.ghost >= 0 {
		eng.remove_entity(game.ghost)
		game.ghost = -1
	}
	game.placing = false
}

try_place :: proc(cell: [2]int) {
	kind := game.placing_kind
	cost := TOWERS[kind].levels[0].cost
	if game.cells[cell.x][cell.y] != .Free || game.gold < cost {
		return
	}
	game.gold -= cost
	game.cells[cell.x][cell.y] = .Tower
	pos := cell_center(cell)
	id := eng.add_entity(placed_tower_look(kind), pos, {CELL, CELL}, {z_index = Z_WORLD, pad = 34})
	append(&game.towers, Tower{id = id, kind = kind, cell = cell, spent = cost})
	eng.add_entity(build_look(IMPACT_COLOR[kind], rand.float32() * 100), pos, {CELL, CELL}, {z_index = Z_EFFECTS, pad = 60, lifetime = 0.9})
	cancel_placing()
}

selected_tower :: proc() -> (^Tower, bool) {
	for &t in game.towers {
		if t.id == game.selected {
			return &t, true
		}
	}
	return nil, false
}

sell_value :: proc(t: Tower) -> int {
	return int(f32(t.spent) * SELL_REFUND)
}

upgrade_selected :: proc() {
	t, ok := selected_tower()
	if !ok || t.level >= TOWER_LEVELS - 1 {
		return
	}
	cost := TOWERS[t.kind].levels[t.level + 1].cost
	if game.gold < cost {
		return
	}
	game.gold -= cost
	t.spent += cost
	t.level += 1
	eng.set_param(t.id, "level", f32(t.level + 1))
	eng.add_entity(build_look(IMPACT_COLOR[t.kind], rand.float32() * 100), cell_center(t.cell), {CELL, CELL}, {z_index = Z_EFFECTS, pad = 60, lifetime = 0.9})
}

sell_selected :: proc() {
	for t, i in game.towers {
		if t.id != game.selected {
			continue
		}
		game.gold += sell_value(t)
		game.cells[t.cell.x][t.cell.y] = .Free
		pos := cell_center(t.cell)
		floating_text(fmt.tprintf("+%d", sell_value(t)), pos - {0, 30}, TEXT_GOLD)
		eng.add_entity(dust_puff({0, 10}, TOWER_STONE, rand.float32() * 100), pos, {CELL, CELL}, {z_index = Z_EFFECTS, pad = 40, lifetime = 1})
		eng.remove_entity(t.id)
		unordered_remove(&game.towers, i)
		game.selected = -1
		return
	}
}

// ---------------------------------------------------------------------------------------
// Waves and golems

start_wave :: proc() {
	game.wave += 1
	delete(game.current.enemies)
	game.current = make_wave(game.wave)
	game.spawned = 0
	game.spawn_timer = 0
	game.phase = .Wave
	show_message(fmt.tprintf("WAVE %d", game.wave), 2)
}

spawn_enemy :: proc(kind: EnemyKind) {
	info := ENEMIES[kind]
	hp := info.hp * game.current.health_scale
	id := eng.add_entity(enemy_look(kind), {-100, -100}, info.size, {z_index = Z_WORLD, pad = 14})
	append(
		&game.enemies,
		Enemy {
			id = id,
			kind = kind,
			hp = hp,
			max_hp = hp,
			lane = rand.float32_range(-LANE_SPREAD, LANE_SPREAD),
			walk = rand.float32_range(0, math.TAU),
			facing = 1,
		},
	)
}

update_waves :: proc(dt: f32) {
	switch game.phase {
	case .Break:
		game.countdown -= dt
		if game.countdown <= 0 {
			start_wave()
		}
	case .Wave:
		game.spawn_timer -= dt
		if game.spawned < len(game.current.enemies) && game.spawn_timer <= 0 {
			spawn_enemy(game.current.enemies[game.spawned])
			game.spawned += 1
			game.spawn_timer = game.current.interval
		}
		if game.spawned == len(game.current.enemies) && len(game.enemies) == 0 {
			bonus := game.current.clear_bonus
			game.gold += bonus
			if game.wave == WAVE_COUNT {
				game.phase = .Won
				show_message("VICTORY!  R to play again", 1e9)
			} else {
				game.phase = .Break
				game.countdown = WAVE_BREAK
				show_message(fmt.tprintf("Wave cleared  +%d gold", bonus), 2.5)
			}
		}
	case .Won, .Lost:
	}
}

find_enemy :: proc(id: int) -> int {
	for e, i in game.enemies {
		if e.id == id {
			return i
		}
	}
	return -1
}

hurt :: proc(index: int, amount: f32) {
	e := &game.enemies[index]
	e.hp -= amount
	eng.set_param(e.id, "hit_time", eng.time())
}

kill_enemy :: proc(index: int) {
	e := game.enemies[index]
	ent := eng.get_entity(e.id)
	reward := ENEMIES[e.kind].reward
	game.gold += reward
	floating_text(fmt.tprintf("+%d", reward), ent.pos - {0, ent.size.y * 0.6}, TEXT_GOLD)
	eng.add_entity(
		golem_death_look(e.kind, e.walk, e.facing, rand.float32() * 100),
		ent.pos,
		ent.size,
		{z_index = Z_EFFECTS, pad = 70, lifetime = 1.1},
	)
	if e.kind == .Magma {
		eng.add_shake(6)
	}
	eng.remove_entity(e.id)
	unordered_remove(&game.enemies, index)
}

enemy_escaped :: proc(index: int) {
	e := game.enemies[index]
	eng.remove_entity(e.id)
	unordered_remove(&game.enemies, index)
	game.lives -= 1
	eng.set_param(game.gate, "hit_time", eng.time())
	eng.add_shake(5)
	floating_text("-1 life", eng.get_entity(game.gate).pos - {0, 60}, TEXT_RED)
	if game.lives <= 0 && game.phase != .Lost {
		game.phase = .Lost
		show_message("DEFEAT!  R to try again", 1e9)
	}
}

update_enemies :: proc(dt: f32) {
	for i := 0; i < len(game.enemies); {
		e := &game.enemies[i]
		info := ENEMIES[e.kind]
		speed := info.speed
		if e.slow_time > 0 {
			e.slow_time -= dt
			speed *= 1 - e.slow
		}
		if e.burn_time > 0 {
			e.burn_time -= dt
			e.hp -= e.burn_dps * dt
		}
		e.dist += speed * dt
		e.walk += speed * dt * WALK_STRIDE

		if e.hp <= 0 {
			kill_enemy(i)
			continue
		}
		if e.dist >= game.path_length {
			enemy_escaped(i)
			continue
		}

		pos, dir := path_point(e.dist)
		if abs(dir.x) > 0.3 {
			e.facing = math.sign(dir.x)
		}
		// Feet on the road; the entity's center is the body.
		eng.get_entity(e.id).pos = pos + eng.Vector2{-dir.y, dir.x} * e.lane - {0, info.size.y * 0.42}
		eng.set_param(e.id, "walk", e.walk)
		eng.set_param(e.id, "facing", e.facing)
		eng.set_param(e.id, "health", max(e.hp / e.max_hp, 0))
		eng.set_param(e.id, "frost", clamp(e.slow_time * 3, 0, 1))
		eng.set_param(e.id, "burn", clamp(e.burn_time * 2, 0, 1))
		i += 1
	}
}

// ---------------------------------------------------------------------------------------
// Towers and projectiles

// The enemy furthest along the road within `range`, or -1.
find_target :: proc(center: eng.Vector2, range: f32) -> int {
	best, best_dist := -1, f32(-1)
	for e, i in game.enemies {
		if e.hp > 0 && e.dist > best_dist && linalg.length(eng.get_entity(e.id).pos - center) <= range {
			best, best_dist = i, e.dist
		}
	}
	return best
}

update_towers :: proc(dt: f32) {
	for &t in game.towers {
		t.cooldown -= dt
		if t.cooldown > 0 {
			continue
		}
		stats := TOWERS[t.kind].levels[t.level]
		target := find_target(cell_center(t.cell), stats.range)
		if target < 0 {
			continue
		}
		t.cooldown = stats.cooldown
		launch(t, game.enemies[target].id)
	}
}

launch :: proc(t: Tower, target: int) {
	stats := TOWERS[t.kind].levels[t.level]
	pos := cell_center(t.cell) + MUZZLE[t.kind]
	id: int
	switch t.kind {
	case .Fire:
		id = eng.add_entity(fireball_look(), pos, {10, 10}, {z_index = Z_PROJECTILES, pad = 30})
	case .Ice:
		id = eng.add_entity(ice_shard_look(), pos, {18, 8}, {z_index = Z_PROJECTILES, pad = 30})
	case .Lightning:
		id = eng.add_entity(spark_orb_look(), pos, {8, 8}, {z_index = Z_PROJECTILES, pad = 30, blend = .Additive})
	}
	append(
		&game.projectiles,
		Projectile {
			id = id,
			kind = t.kind,
			level = t.level,
			target = target,
			aim = eng.get_entity(target).pos,
			pos = pos,
			speed = stats.speed,
			damage = stats.damage,
			bounces = int(stats.effect) if t.kind == .Lightning else 0,
		},
	)
	eng.set_param(t.id, "fire_time", eng.time())
}

update_projectiles :: proc(dt: f32) {
	for i := 0; i < len(game.projectiles); {
		pr := &game.projectiles[i]
		if find_enemy(pr.target) >= 0 {
			pr.aim = eng.get_entity(pr.target).pos
		}
		to := pr.aim - pr.pos
		dist := linalg.length(to)
		step := pr.speed * dt
		dir := to / max(dist, 1e-3)
		if dist <= step + 4 {
			pr.pos = pr.aim
			if !projectile_hit(pr) {
				eng.remove_entity(pr.id)
				unordered_remove(&game.projectiles, i)
				continue
			}
		} else {
			pr.pos += dir * step
		}

		e := eng.get_entity(pr.id)
		e.pos = pr.pos
		switch pr.kind {
		case .Ice:
			e.rotation = math.atan2(dir.y, dir.x) * math.DEG_PER_RAD
		case .Fire, .Lightning:
			eng.set_param(pr.id, "velocity", dir * pr.speed)
		}
		i += 1
	}
}

// Applies a projectile's effect at its position. Returns true if it keeps flying (lightning
// bouncing on to the next golem).
projectile_hit :: proc(pr: ^Projectile) -> bool {
	stats := TOWERS[pr.kind].levels[pr.level]
	eng.add_entity(impact_look(IMPACT_COLOR[pr.kind], rand.float32() * 100), pr.pos, {0, 0}, {z_index = Z_EFFECTS, pad = 60, lifetime = 0.5, blend = .Additive})
	index := find_enemy(pr.target)
	if index < 0 {
		return false
	}
	hurt(index, pr.damage)
	e := &game.enemies[index]
	switch pr.kind {
	case .Fire:
		e.burn_dps = max(e.burn_dps if e.burn_time > 0 else 0, stats.effect)
		e.burn_time = max(e.burn_time, stats.duration)
	case .Ice:
		e.slow = max(e.slow if e.slow_time > 0 else 0, stats.effect)
		e.slow_time = max(e.slow_time, stats.duration)
	case .Lightning:
		pr.hit[pr.hit_count] = pr.target
		pr.hit_count += 1
		if pr.bounces == 0 {
			return false
		}
		next := bounce_target(pr.pos, pr.hit[:pr.hit_count])
		if next < 0 {
			return false
		}
		next_pos := eng.get_entity(game.enemies[next].id).pos
		spawn_bolt(pr.pos, next_pos)
		pr.target = game.enemies[next].id
		pr.bounces -= 1
		pr.damage *= BOUNCE_FALLOFF
		return true
	}
	return false
}

// Closest living golem within BOUNCE_RANGE that this projectile hasn't struck yet.
bounce_target :: proc(from: eng.Vector2, exclude: []int) -> int {
	best, best_dist := -1, f32(BOUNCE_RANGE)
	outer: for e, i in game.enemies {
		for id in exclude {
			if id == e.id {
				continue outer
			}
		}
		d := linalg.length(eng.get_entity(e.id).pos - from)
		if e.hp > 0 && d < best_dist {
			best, best_dist = i, d
		}
	}
	return best
}

spawn_bolt :: proc(from, to: eng.Vector2) {
	delta := to - from
	eng.add_entity(
		bolt_look(rand.float32() * 100),
		(from + to) / 2,
		{linalg.length(delta), 40},
		{z_index = Z_EFFECTS, lifetime = 0.22, blend = .Additive, rotation = math.atan2(delta.y, delta.x) * math.DEG_PER_RAD},
	)
}

update_floaters :: proc(dt: f32) {
	for i := 0; i < len(game.floaters); {
		if !eng.entity_exists(game.floaters[i].id) {
			unordered_remove(&game.floaters, i)
			continue
		}
		eng.get_entity(game.floaters[i].id).pos.y -= 30 * dt
		i += 1
	}
}

// ---------------------------------------------------------------------------------------
// Input and main loop

handle_input :: proc() {
	if rl.IsKeyPressed(.R) && (game.phase == .Won || game.phase == .Lost) {
		create_game()
		return
	}
	if rl.IsKeyPressed(.P) {
		game.paused = !game.paused
		show_message("PAUSED" if game.paused else "", 1e9 if game.paused else 0)
	}
	if rl.IsKeyPressed(.F) {
		game.fast = !game.fast
	}
	eng.set_time_scale(0 if game.paused else 2 if game.fast else 1)
	if game.paused || game.phase == .Won || game.phase == .Lost {
		return
	}

	for kind, i in TowerKind {
		if rl.IsKeyPressed(rl.KeyboardKey(int(rl.KeyboardKey.ONE) + i)) || (rl.IsMouseButtonPressed(.LEFT) && button_hovered(game.ui.shop[kind])) {
			if game.placing && game.placing_kind == kind {
				cancel_placing()
			} else {
				begin_placing(kind)
			}
			return
		}
	}
	if rl.IsKeyPressed(.ESCAPE) || rl.IsMouseButtonPressed(.RIGHT) {
		cancel_placing()
		game.selected = -1
	}
	if rl.IsKeyPressed(.U) || (rl.IsMouseButtonPressed(.LEFT) && button_hovered(game.ui.upgrade)) {
		upgrade_selected()
	}
	if rl.IsKeyPressed(.S) || (rl.IsMouseButtonPressed(.LEFT) && button_hovered(game.ui.sell)) {
		sell_selected()
	}
	if game.phase == .Break && (rl.IsKeyPressed(.SPACE) || (rl.IsMouseButtonPressed(.LEFT) && button_hovered(game.ui.next_wave))) {
		start_wave()
	}

	mouse := eng.mouse_position()
	if rl.IsMouseButtonPressed(.LEFT) && mouse.x < MAP_WIDTH {
		cell, ok := cell_at(mouse)
		if !ok {
			return
		}
		if game.placing {
			try_place(cell)
			return
		}
		game.selected = -1
		for t in game.towers {
			if t.cell == cell {
				game.selected = t.id
			}
		}
	}
}

on_update :: proc(dt: f32) {
	handle_input()
	if game.message_timer > 0 {
		game.message_timer -= rl.GetFrameTime()
		if game.message_timer <= 0 {
			eng.set_text(game.ui.message, "")
		}
	}
	if game.phase != .Won && game.phase != .Lost {
		update_waves(dt)
		update_enemies(dt)
		update_towers(dt)
	}
	update_projectiles(dt)
	update_floaters(dt)
	refresh_overlays()
	update_ui()
}

main :: proc() {
	eng.init_context(
		eng.InitOptions {
			width = SCREEN_WIDTH,
			height = SCREEN_HEIGHT,
			fps = 60,
			title = "Tower Defense",
			num_layers = LAYER_COUNT,
			bg_color = rl.BLACK,
			resizable = true,
		},
	)
	eng.set_layer_y_sorted(Z_WORLD, true)
	create_game()
	eng.run(on_update)
}
