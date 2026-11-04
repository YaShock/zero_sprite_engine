package main

// Wall growths and goo on screen: every tentacle, coral and sea fan in view gets an entity
// from a pool for its drawing layer, filled from the shapes worked out this frame. Entities
// are made at startup and reused (hidden when not needed), so growths scrolling in never
// compile anything. Each wall's goo is one entity; droplets come from a pool too.

import eng "../../engine"
import fx "../../engine/vfx"
import "core:fmt"
import "core:math"
import "core:math/linalg"

// Drawing groups, back to front, as the original draws them: the growths at the rock's edge
// (behind the rock), split by whether they stand behind or in front of the goo, then the
// two tiers standing lower, in front of the rock and the ship
GrowthGroup :: enum {
	Edge_Behind_Goo,
	Edge_Before_Goo,
	Low,
	Lowest,
}

// Tentacles hang from the ceiling (drawn first, as the original draws the upper wall
// first); on the floor, sea fans behind the corals, the corals, then the other sea fans
GrowthKind :: enum {
	Tentacles,
	Fans_Behind,
	Corals,
	Fans_Front,
}

growth_layer :: proc(group: GrowthGroup, kind: GrowthKind) -> int {
	if kind == .Tentacles {
		tentacles := [GrowthGroup]int {
			.Edge_Behind_Goo = LAYER_UPPER_BEHIND_GOO,
			.Edge_Before_Goo = LAYER_UPPER_BEFORE_GOO,
			.Low             = LAYER_LOW,
			.Lowest          = LAYER_LOWEST,
		}
		return tentacles[group]
	}
	plants := [GrowthGroup]int {
		.Edge_Behind_Goo = LAYER_LOWER_BEHIND_GOO,
		.Edge_Before_Goo = LAYER_LOWER_BEFORE_GOO,
		.Low             = LAYER_LOW + 1,
		.Lowest          = LAYER_LOWEST + 1,
	}
	return plants[group] + int(kind) - int(GrowthKind.Fans_Behind)
}

growth_group :: proc(tier: int, id: i64) -> GrowthGroup {
	switch tier {
	case 0:
		return .Edge_Before_Goo if growth_in_front(id) else .Edge_Behind_Goo
	case 1:
		return .Low
	}
	return .Lowest
}

Pool :: struct {
	ids:    [dynamic]int,
	lights: [dynamic]int, // corals: the glow on each one's tips (one quad per tip), made right after it so it draws before the next coral
	used:   int,
}

Growths :: struct {
	pools:         [GrowthGroup][GrowthKind]Pool,
	goo:           [2]int, // ceiling, floor
	goo_fields:    [2]int, // their blobs, splatted into buffer layers
	droplets:      Pool,
	droplet_texts: Pool,
	segments:      [MAX_FAN_PIECES * fx.CAPSULE_STRIDE]f32, // scratch for one growth's data
	tips:          [MAX_CORAL_TIPS * SPLAT_STRIDE]f32,
	bins:          [MAX_FAN_BINS]f32,
	blobs:         [MAX_GOO_BLOBS * GOO_BLOB_STRIDE]f32,
}

growths: Growths

// Adds a hidden entity to a growth pool (and a coral's tip glow)
new_growth :: proc(pool: ^Pool, group: GrowthGroup, kind: GrowthKind) {
	look: ^fx.Node
	switch kind {
	case .Tentacles:
		look = tentacle_look()
	case .Corals:
		look = coral_look()
	case .Fans_Behind, .Fans_Front:
		look = fan_look()
	}
	id := eng.add_entity(look, {}, {1, 1}, {z_index = growth_layer(group, kind), blend = .Premultiplied})
	eng.get_entity(id).visible = false
	append(&pool.ids, id)
	if kind == .Corals {
		light := eng.add_entity(light_splats_look("tips", MAX_CORAL_TIPS, .Soft), {}, {1, 1}, {z_index = growth_layer(group, kind), blend = .Premultiplied})
		eng.get_entity(light).visible = false
		append(&pool.lights, light)
	}
}

new_droplet :: proc() -> int {
	id := eng.add_entity(droplet_look(), {}, {1, 1}, {z_index = LAYER_DROPLETS})
	eng.get_entity(id).visible = false
	return id
}

new_droplet_text :: proc() -> int {
	id := eng.add_text("+0", {}, 16, DROPLET_TEXT, LAYER_TEXT, .Center)
	eng.get_entity(id).visible = false
	return id
}

// Makes the entities a usual screen needs up front
init_growths :: proc() {
	for group in GrowthGroup {
		for kind in GrowthKind {
			pool := &growths.pools[group][kind]
			for _ in 0 ..< (6 if kind == .Corals || kind == .Tentacles else 2) {
				new_growth(pool, group, kind)
			}
		}
	}
	// Each wall's goo: its blobs added up into a buffer layer, then the outline from it
	for k in 0 ..< 2 {
		field_layer := LAYER_GOO_FIELD + k
		eng.set_layer_buffer(field_layer)
		growths.goo_fields[k] = eng.add_entity(goo_field_look(), {}, {1, 1}, {z_index = field_layer, blend = .Premultiplied})
		side: f32 = 1 if k == 0 else -1
		growths.goo[k] = eng.add_entity(goo_look(side, field_layer), {}, {1, 1}, {z_index = LAYER_UPPER_GOO if k == 0 else LAYER_LOWER_GOO})
	}
	for _ in 0 ..< 4 {
		append(&growths.droplets.ids, new_droplet())
		append(&growths.droplet_texts.ids, new_droplet_text())
	}
}

// The next free entity of a pool (a new one if all are taken), and its index there
take :: proc(group: GrowthGroup, kind: GrowthKind) -> (id, index: int) {
	pool := &growths.pools[group][kind]
	if pool.used == len(pool.ids) {
		new_growth(pool, group, kind)
	}
	pool.used += 1
	return pool.ids[pool.used - 1], pool.used - 1
}

// Screen-pixel bounds of what an entity draws
Bounds :: struct {
	lo, hi: [2]f32,
}

grow :: proc(b: ^Bounds, x, y, margin: f32) {
	b.lo = {math.min(b.lo.x, x - margin), math.min(b.lo.y, y - margin)}
	b.hi = {math.max(b.hi.x, x + margin), math.max(b.hi.y, y + margin)}
}

place :: proc(id: int, b: Bounds) {
	e := eng.get_entity(id)
	e.visible = true
	e.pos = (b.lo + b.hi) / 2
	e.size = b.hi - b.lo + 2
}

sync_growths :: proc(state: ^State, distance, time, s, width_units: f64) -> (lights: []Light) {
	for group in GrowthGroup {
		for kind in GrowthKind {
			growths.pools[group][kind].used = 0
		}
	}
	// The range is widened so growths rooted just off screen can still lean in
	x0, x1 := distance - 5, distance + width_units + 5
	side := -1.0 // corals grow on the floor
	corals := make([dynamic]Coral, context.temp_allocator)
	fans := make([dynamic]SeaFan, context.temp_allocator)
	if has_stage(2) {
		spots := make([dynamic]PlantSpot, context.temp_allocator)
		plant_spots(state.seed, side, x0, x1, &spots)
		corals_in_range(state.seed, side, x0, x1, time, spots[:], &corals)
		sea_fans_in_range(state.seed, side, x0, x1, time, spots[:], &fans)
	}
	for &coral in corals {
		group := growth_group(coral.tier, coral.id)
		id, index := take(group, .Corals)
		sync_coral(id, growths.pools[group][.Corals].lights[index], &coral, distance, s)
	}
	for &fan in fans {
		id, _ := take(growth_group(fan.tier, fan.id), .Fans_Behind if fan.behind else .Fans_Front)
		sync_fan(id, &fan, distance, s)
	}
	tentacles := make([dynamic]Tentacle, context.temp_allocator)
	if has_stage(3) {
		tentacles_in_range(state.seed, 1, x0, x1, time, &tentacles)
	}
	for &tentacle in tentacles {
		id, _ := take(growth_group(tentacle.tier, tentacle.key), .Tentacles)
		sync_tentacle(id, &tentacle, distance, s)
	}

	for group in GrowthGroup {
		for kind in GrowthKind {
			pool := growths.pools[group][kind]
			for id in pool.ids[pool.used:] {
				eng.get_entity(id).visible = false
			}
			for id in pool.lights[math.min(pool.used, len(pool.lights)):] {
				eng.get_entity(id).visible = false
			}
		}
	}

	for side, k in ([2]f64{1, -1}) {
		if has_stage(3) {
			sync_goo(growths.goo[k], growths.goo_fields[k], state, side, x0, x1, distance, time, s, k)
		} else {
			eng.get_entity(growths.goo[k]).visible = false
			eng.get_entity(growths.goo_fields[k]).visible = false
		}
	}
	sync_droplets(state, distance, time, s)
	sources := make([dynamic]Light, context.temp_allocator)
	light_sources(corals[:], fans[:], tentacles[:], &sources)
	return sources[:]
}

// A growth standing at the rock's edge (tier 0) is drawn before the rock, which covers its
// root: it skips what lies beyond its wall's edge, more than a pixel in, everywhere across
// its width x0..x1 (screen pixels; wall 0 ceiling, 1 floor). Growths standing lower are in
// front of the rock and skip nothing.
hide_behind_rock :: proc(id, tier, wall: int, x0, x1: f32) {
	if tier != 0 {
		eng.set_param(id, "behind_side", f32(0))
		return
	}
	lo, hi := edge_range(wall, x0, x1)
	if wall == 0 {
		eng.set_param(id, "behind_side", f32(1))
		eng.set_param(id, "behind_line", lo - 1) // above the edge's highest point
	} else {
		eng.set_param(id, "behind_side", f32(-1))
		eng.set_param(id, "behind_line", hi + 1) // below the edge's lowest point
	}
}

// The tentacle's chain as tapered capsules (screen pixels)
sync_tentacle :: proc(id: int, tentacle: ^Tentacle, distance, s: f64) {
	out := growths.segments[:TENTACLE_SEGMENTS * fx.CAPSULE_STRIDE]
	bounds := Bounds{{1e9, 1e9}, {-1e9, -1e9}}
	reach := f32(TENTACLE_GLOW_WIDTH * s / 2 + 1)
	for i in 0 ..< TENTACLE_SEGMENTS {
		a, b := tentacle.points[i], tentacle.points[i + 1]
		k := i * fx.CAPSULE_STRIDE
		ax, ay := f32((a.x - distance) * s), f32(a.y * s)
		bx, by := f32((b.x - distance) * s), f32(b.y * s)
		ra, rb := f32(a.width / 2 * s), f32(b.width / 2 * s)
		out[k], out[k + 1], out[k + 2], out[k + 3], out[k + 4], out[k + 5] = ax, ay, bx, by, ra, rb
		grow(&bounds, ax, ay, ra + reach)
		grow(&bounds, bx, by, rb + reach)
	}
	eng.set_param_array(id, "chain", out)
	eng.set_param(id, "unit", f32(s))
	hide_behind_rock(id, tentacle.tier, 0, bounds.lo.x, bounds.hi.x)
	place(id, bounds)
}

// One wall's goo: the blobs (and cluster particles) as metaballs in screen pixels, splatted
// into the wall's field buffer by `field`; the wall's edge for its pull, and a quad covering
// just where the blobs reach
sync_goo :: proc(id, field: int, state: ^State, side, x0, x1, distance, time, s: f64, wall: int) {
	blobs := make([dynamic]Blob, context.temp_allocator)
	goo_blobs(state, side, x0, x1, time, &blobs)
	bounds := Bounds{{1e9, 1e9}, {-1e9, -1e9}}
	n := math.min(len(blobs), MAX_GOO_BLOBS)
	for blob, i in blobs[:n] {
		x, y, r := f32((blob.x - distance) * s), f32(blob.y * s), f32(blob.radius * s)
		out := growths.blobs[i * GOO_BLOB_STRIDE:]
		out[0], out[1], out[2], out[3], out[4] = x, y, r, r, 1
		grow(&bounds, x, y, r + 2)
	}
	e := eng.get_entity(id)
	e.visible = n > 0
	f := eng.get_entity(field)
	f.pos, f.visible = {}, n > 0
	if n == 0 {
		return
	}
	first_x := math.floor(distance / CAVE_SAMPLE_STEP) * CAVE_SAMPLE_STEP
	eng.set_instances(field, "blobs", growths.blobs[:n * GOO_BLOB_STRIDE])
	eng.set_param_array(id, "edges", game.edges[wall][:])
	eng.set_param(id, "edge_x0", f32((first_x - distance) * s))
	eng.set_param(id, "edge_step", f32(CAVE_SAMPLE_STEP * s))
	eng.set_param(id, "unit", f32(s))
	place(id, bounds)
}

// Caught droplets on their flight, each stretched along its motion, with its points
sync_droplets :: proc(state: ^State, distance, time, s: f64) {
	growths.droplets.used, growths.droplet_texts.used = 0, 0
	visible := math.sqrt(1 - math.sqrt(f64(METABALL_THRESHOLD))) // a lone particle's outline
	lerp :: proc(a, b: [4]f32, t: f32) -> [4]f32 {return a + (b - a) * t}
	color :: proc(c: eng.Color) -> [4]f32 {return [4]f32{f32(c.r), f32(c.g), f32(c.b), f32(c.a)} / 255}
	for &drop in state.droplets {
		x, y := droplet_position(state, &drop, time, distance) or_continue
		ax, ay, ahead := droplet_position(state, &drop, time + 0.02, distance)
		if !ahead {
			ax, ay = x, y
		}
		vx, vy := (ax - x) / 0.02, (ay - y) / 0.02
		stretch := 1 + math.min(0.35, math.hypot(vx, vy) * 0.02)
		gold := f32(math.min(1, math.max(0, (time - drop.t) / DROPLET_COLOR_TIME)))
		r := drop.radius * visible
		angle := math.atan2(vy, vx)
		// An ellipse of semi-axes r·stretch and r/stretch, as a capsule along the motion
		half := (r * stretch - r / stretch)
		dx, dy := math.cos(angle) * half, math.sin(angle) * half
		if growths.droplets.used == len(growths.droplets.ids) {
			append(&growths.droplets.ids, new_droplet())
			append(&growths.droplet_texts.ids, new_droplet_text())
		}
		id := growths.droplets.ids[growths.droplets.used]
		growths.droplets.used += 1
		shape: [DROPLET_MAX_PARTICLES * fx.CAPSULE_STRIDE]f32
		bounds := Bounds{{1e9, 1e9}, {-1e9, -1e9}}
		for i in 0 ..< DROPLET_MAX_PARTICLES {
			o := drop.offsets[math.min(i, drop.n - 1)] // a single particle is drawn twice
			cx, cy := (x + o.x) * s, (y + o.y) * s
			k := i * fx.CAPSULE_STRIDE
			shape[k], shape[k + 1] = f32(cx - dx * s), f32(cy - dy * s)
			shape[k + 2], shape[k + 3] = f32(cx + dx * s), f32(cy + dy * s)
			shape[k + 4], shape[k + 5] = f32(r / stretch * s), f32(r / stretch * s)
			grow(&bounds, f32(cx), f32(cy), f32((r * stretch + 0.06) * s + 1))
		}
		eng.set_param_array(id, "shape", shape[:])
		eng.set_param(id, "fill", lerp(color(GOO), color(GOLD), gold))
		eng.set_param(id, "edge", lerp(color(GOO_EDGE), color(GOLD_EDGE), gold))
		eng.set_param(id, "rim", f32(0.06 * s)) // the original strokes 0.12 wide under the fill
		place(id, bounds)
		// Its points, at least 13 pixels tall
		text := growths.droplet_texts.ids[growths.droplet_texts.used]
		growths.droplet_texts.used += 1
		eng.set_text(text, fmt.tprintf("+%d", drop.points))
		te := eng.get_entity(text)
		te.visible = true
		te.pos = {f32(x * s), f32(y * s)}
		(&te.drawable.(eng.Text)).font_size = f32(math.max(r * 1.05 * s, 13))
	}
	for id in growths.droplets.ids[growths.droplets.used:] {
		eng.get_entity(id).visible = false
	}
	for id in growths.droplet_texts.ids[growths.droplet_texts.used:] {
		eng.get_entity(id).visible = false
	}
}

// Branches level by level as capsules, with the original's widths (thinner toward the tips,
// thicker on bigger plants), and a glow on each outermost tip (the `light` entity, drawn
// right after the coral)
sync_coral :: proc(id, light: int, coral: ^Coral, distance, s: f64) {
	scale := math.round(coral.size * 20) / 20 // sizes in steps of 5%, as the original batches them
	glow_r := f32(CORAL_GLOW_RADIUS * s)
	glow := light_color(CORAL_GLOW) * CORAL_GLOW_STRENGTH
	n := len(coral.segments)
	record := make([]int, n, context.temp_allocator) // each branch's record, -1 if left out
	k, tips := 0, 0
	x_lo, x_hi: f32 = 1e9, -1e9 // what the branches cover
	for level in 0 ..< FRACTAL_DEPTH {
		base := FRACTAL_WIDTH * math.pow(1 - f64(level) / FRACTAL_DEPTH, 1.2)
		half := f32((base * scale + 0.03) * s / 2)
		for sg, i in coral.segments {
			if sg.level != level {
				continue
			}
			record[i] = -1
			if k >= MAX_CORAL_SEGMENTS {
				continue
			}
			record[i] = k
			ax, ay := f32((sg.x1 - distance) * s), f32(sg.y1 * s)
			bx, by := f32((sg.x2 - distance) * s), f32(sg.y2 * s)
			out := growths.segments[k * CORAL_RECORD:]
			reach := half + 1 // anti-aliasing covers up to half a pixel past the edge
			out[0], out[1] = (ax + bx) / 2, (ay + by) / 2
			x_lo, x_hi = math.min(x_lo, ax - reach, bx - reach), math.max(x_hi, ax + reach, bx + reach)
			out[2], out[3] = abs(bx - ax) / 2 + reach, abs(by - ay) / 2 + reach
			out[4], out[5], out[6], out[7] = ax, ay, bx, by
			out[8], out[9] = half, f32(level)
			for &slot in out[10:CORAL_RECORD] {
				slot = -1
			}
			k += 1
			if level == FRACTAL_DEPTH - 1 && tips < MAX_CORAL_TIPS {
				splat(growths.tips[tips * SPLAT_STRIDE:], bx, by, glow_r, glow)
				tips += 1
			}
		}
	}
	// Neighbors: branches of the same level whose covered pixels can meet (closer than their
	// radii plus a pixel), so that only one of them draws such a pixel
	for a in 0 ..< k {
		ra := growths.segments[a * CORAL_RECORD:]
		slot := 10
		for b in 0 ..< k {
			rb := growths.segments[b * CORAL_RECORD:]
			if b == a || rb[9] != ra[9] || slot >= CORAL_RECORD {
				continue
			}
			// Quads apart: too far (the cheap test first)
			if abs(ra[0] - rb[0]) > ra[2] + rb[2] || abs(ra[1] - rb[1]) > ra[3] + rb[3] {
				continue
			}
			if segment_distance({ra[4], ra[5]}, {ra[6], ra[7]}, {rb[4], rb[5]}, {rb[6], rb[7]}) < ra[8] + rb[8] + 1 {
				ra[slot] = f32(b)
				slot += 1
			}
		}
	}
	hide_behind_rock(id, coral.tier, 1, x_lo, x_hi)
	e := eng.get_entity(id)
	e.pos, e.visible = {}, true
	eng.set_instances(id, "branches", growths.segments[:k * CORAL_RECORD])
	e = eng.get_entity(light)
	e.pos, e.visible = {}, true
	eng.set_instances(light, "tips", growths.tips[:tips * SPLAT_STRIDE])
}

// The shortest distance between segments a0-a1 and b0-b1 (0 if they cross)
segment_distance :: proc(a0, a1, b0, b1: [2]f32) -> f32 {
	cross :: proc(o, a, b: [2]f32) -> f32 {return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)}
	if cross(a0, a1, b0) * cross(a0, a1, b1) < 0 && cross(b0, b1, a0) * cross(b0, b1, a1) < 0 {
		return 0
	}
	to_segment :: proc(p, a, b: [2]f32) -> f32 {
		ab := b - a
		t := clamp(linalg.dot(p - a, ab) / math.max(linalg.dot(ab, ab), 1e-6), 0, 1)
		return linalg.length(p - (a + ab * t))
	}
	return math.min(to_segment(a0, b0, b1), to_segment(a1, b0, b1), to_segment(b0, a0, a1), to_segment(b1, a0, a1))
}

LEVEL_PARAMS := [FAN_LEVELS]string{"n0", "n1", "n2", "n3", "n4", "n5", "n6", "n7"}
GLOW_PARAMS := [FAN_GLOW_STEPS + 1]string{"", "g1", "g2", "g3", "g4", "g5", "g6", "g7", "g8"}

// Branches level by level, the links, then every piece again in its glow brightness group
sync_fan :: proc(id: int, fan: ^SeaFan, distance, s: f64) {
	out := growths.segments[:]
	bounds := Bounds{{1e9, 1e9}, {-1e9, -1e9}}
	glow_reach := f32(SEA_FAN_GLOW_WIDTH * s / 2 + 2)
	k := 0
	add :: proc(out: []f32, k: ^int, sg: Segment, distance, s: f64, half: f32) {
		if k^ / fx.CAPSULE_STRIDE >= MAX_FAN_PIECES {
			return
		}
		i := k^
		out[i], out[i + 1] = f32((sg.x1 - distance) * s), f32(sg.y1 * s)
		out[i + 2], out[i + 3] = f32((sg.x2 - distance) * s), f32(sg.y2 * s)
		out[i + 4], out[i + 5] = half, half
		k^ += fx.CAPSULE_STRIDE
	}
	w0 := SEA_FAN_WIDTH * fan.size
	for level in 0 ..< FAN_LEVELS {
		start := k
		if level <= fan.depth {
			half := f32(math.max(0.025, w0 - f64(level) * (w0 - 0.025) / f64(fan.depth)) * s / 2)
			for sg in fan.segments {
				if sg.level == level {
					add(out, &k, sg, distance, s, half)
					grow(&bounds, f32((sg.x1 - distance) * s), f32(sg.y1 * s), glow_reach)
					grow(&bounds, f32((sg.x2 - distance) * s), f32(sg.y2 * s), glow_reach)
				}
			}
		}
		eng.set_param(id, LEVEL_PARAMS[level], f32((k - start) / fx.CAPSULE_STRIDE))
	}
	start := k
	for sg in fan.links {
		add(out, &k, sg, distance, s, f32(0.025 * s / 2))
	}
	eng.set_param(id, "n_links", f32((k - start) / fx.CAPSULE_STRIDE))
	strokes := k / fx.CAPSULE_STRIDE

	// The glow follows the wave: each piece's brightness, rounded to steps of 0.2
	glow_step :: proc(fan: ^SeaFan, sg: Segment, share: f64) -> int {
		wave := math.exp(-math.pow(sg.d / fan.max_d - fan.pulse, 2) / 0.012)
		return int(math.min(8, math.floor((0.25 + 1.3 * wave) * share * 5 + 0.5)))
	}
	segment_steps := make([]int, len(fan.segments), context.temp_allocator)
	for sg, i in fan.segments {
		segment_steps[i] = glow_step(fan, sg, 1)
	}
	link_steps := make([]int, len(fan.links), context.temp_allocator)
	for sg, i in fan.links {
		link_steps[i] = glow_step(fan, sg, 0.8)
	}
	for step in 1 ..= FAN_GLOW_STEPS {
		start := k
		for sg, i in fan.segments {
			if segment_steps[i] == step {
				add(out, &k, sg, distance, s, 0)
			}
		}
		for sg, i in fan.links {
			if link_steps[i] == step {
				add(out, &k, sg, distance, s, 0)
			}
		}
		eng.set_param(id, GLOW_PARAMS[step], f32((k - start) / fx.CAPSULE_STRIDE))
	}
	eng.set_param_array(id, "pieces", out[:k])
	// Strokes are listed as far as they cover, their glow copies as far as the glow reaches
	eng.set_param_array(id, "bins", growths.bins[:eng.bin_shapes(growths.bins[:], out[:k], .Capsules, 1, BIN_CELL, 0, strokes)])
	eng.set_param_array(id, "glow_bins", growths.bins[:eng.bin_shapes(growths.bins[:], out[:k], .Capsules, glow_reach + 1, BIN_CELL, strokes)])
	eng.set_param(id, "depth", f32(fan.depth))
	eng.set_param(id, "unit", f32(s))
	hide_behind_rock(id, fan.tier, 1, bounds.lo.x, bounds.hi.x)
	place(id, bounds)
}
