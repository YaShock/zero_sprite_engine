package main

// The atmosphere on screen: the fog (in an out-of-focus layer), the jellyfish (pooled
// entities in three out-of-focus layers, one per depth), the spores, the wall light and
// the sand glints, filled every frame from the shapes worked out in atmosphere.odin.

import eng "../../engine"
import fx "../../engine/vfx"
import "core:math"
import "core:slice"

FOG_DIVISOR :: 8 // the fog is drawn into an image this many times smaller (the original's grid is coarser still)

Scenery :: struct {
	fog:          int,
	jellies:      [len(JELLY_LAYERS)]Pool,
	spores:       int,
	front_spores: int,
	wall_light:   [2]int, // ceiling, floor
	glints:       [2]int, // ceiling, floor
	values:       [MAX_JELLY_CAPSULES * fx.CAPSULE_STRIDE]f32, // scratch
	bins:         [MAX_JELLY_BINS]f32,
}

scenery: Scenery

new_jelly :: proc(li: int) -> int {
	id := eng.add_entity(jelly_look(), {}, {1, 1}, {z_index = LAYER_JELLY + li, blend = .Premultiplied})
	eng.get_entity(id).visible = false
	return id
}

init_scenery :: proc() {
	eng.set_layer_resolution(LAYER_FOG, FOG_DIVISOR)
	scenery.fog = eng.add_entity(fog_look(), {}, {1, 1}, {z_index = LAYER_FOG})
	for layer, li in JELLY_LAYERS {
		// Drawn small and stretched, which blurs it, then added as light
		// (softened first by a Gaussian of 1.2 small pixels, as the original's blur filter)
		eng.set_layer_resolution(LAYER_JELLY + li, layer.blur, f32(layer.alpha), 1.2)
		for _ in 0 ..< 3 {
			append(&scenery.jellies[li].ids, new_jelly(li))
		}
	}
	// Spores and wall light are lights drawn one quad each, at 0, 0 so their positions are
	// screen pixels
	scenery.spores = eng.add_entity(light_splats_look("spores", MAX_SPORES, .Dot), {}, {1, 1}, {z_index = LAYER_SPORES, blend = .Premultiplied})
	scenery.front_spores = eng.add_entity(front_spores_look(), {}, {1, 1}, {z_index = LAYER_FRONT_SPORES, blend = .Premultiplied})
	// The wall light is wide and soft: drawn at half resolution (float, so its many
	// overlapping glows add up without rounding), it looks the same
	eng.set_layer_resolution(LAYER_WALL_LIGHT, 2, precise = true)
	for &id in scenery.wall_light {
		id = eng.add_entity(light_splats_look("glows", MAX_WALL_GLOWS, .Soft), {}, {1, 1}, {z_index = LAYER_WALL_LIGHT, blend = .Premultiplied})
	}
	scenery.glints = {
		eng.add_entity(glint_look(1), {}, {1, 1}, {z_index = LAYER_GLINTS, blend = .Premultiplied}),
		eng.add_entity(glint_look(-1), {}, {1, 1}, {z_index = LAYER_GLINTS, blend = .Premultiplied}),
	}
}

// Writes one light record of light_splats_look: its center and radius (screen pixels) and
// its light, `color` times its strength (alpha left at 0: it only adds light)
splat :: proc(out: []f32, x, y, radius: f32, color: [4]f32) {
	out[0], out[1], out[2], out[3] = x, y, radius, radius
	out[4], out[5], out[6], out[7] = color.r, color.g, color.b, 0
}

full_screen :: proc(id: int) {
	screen := eng.screen_size()
	e := eng.get_entity(id)
	e.pos, e.size, e.visible = screen / 2, screen, true
}

// edge_count: how many of game.edges' points are in use (the rest repeat the last)
sync_scenery :: proc(state: ^State, distance, time, s, width_units: f64, lights: []Light, edge_count: int) {
	screen := eng.screen_size()
	first_x := math.floor(distance / CAVE_SAMPLE_STEP) * CAVE_SAMPLE_STEP
	edge_x0, edge_step := f32((first_x - distance) * s), f32(CAVE_SAMPLE_STEP * s)

	// Fog
	full_screen(scenery.fog)
	seed := u32(state.seed)
	eng.set_param(scenery.fog, "unit", f32(s))
	eng.set_param(scenery.fog, "seed_hi", f32(seed >> 16))
	eng.set_param(scenery.fog, "seed_lo", f32(seed & 0xffff))
	eng.set_param(scenery.fog, "fog_t", f32(time / FOG_PERIOD))
	eng.set_param(scenery.fog, "fog_x", f32(distance * FOG_PARALLAX))

	eng.profile_begin("jellyfish")
	for li in 0 ..< len(JELLY_LAYERS) {
		sync_jellies(state, li, distance, time, s, width_units)
	}

	eng.profile_end()
	eng.profile_begin("spores")
	// Spores, the cool ones first; the front ones only inside the tunnel
	for front in ([2]bool{false, true}) {
		id := scenery.front_spores if front else scenery.spores
		spores := make([dynamic]Spore, context.temp_allocator)
		spores_in_view(state.seed, distance, time, width_units, front, &spores)
		if !front {
			// The back spores are drawn before the rock: those wholly inside it (more than a
			// pixel past its edge all across their width) would not show
			kept := 0
			for sp in spores {
				x, y, r := f32(sp.x * s), f32(sp.y * s), f32(sp.radius * s)
				top, _ := edge_range(0, x - r, x + r)
				_, bottom := edge_range(1, x - r, x + r)
				if y + r < top - 1 || y - r > bottom + 1 {
					continue
				}
				spores[kept] = sp
				kept += 1
			}
			resize(&spores, kept)
		}
		// Past the limit the warm ones are left out first
		slice.stable_sort_by(spores[:], proc(a, b: Spore) -> bool {return !a.warm && b.warm})
		limit := MAX_FRONT_SPORES if front else MAX_SPORES
		n := math.min(len(spores), limit)
		for sp, i in spores[:n] {
			color := light_color(SPORE_WARM if sp.warm else SPORE) * f32(sp.alpha)
			r := f32(sp.radius * s)
			splat(scenery.values[i * SPLAT_STRIDE:], f32(sp.x * s), f32(sp.y * s), r, color)
		}
		e := eng.get_entity(id)
		e.pos, e.visible = {}, true
		eng.set_instances(id, "spores", scenery.values[:n * SPLAT_STRIDE])
		if front {
			eng.set_param_array(id, "top", game.edges[0][:])
			eng.set_param_array(id, "bottom", game.edges[1][:])
			eng.set_param(id, "edge_x0", edge_x0)
			eng.set_param(id, "edge_step", edge_step)
		}
	}

	eng.profile_end()
	eng.profile_begin("wall light and glints")
	defer eng.profile_end()
	// The walls' edge points in screen-fixed world units, as the original's light code sees them
	edges: [2][][2]f64
	for wall in 0 ..< 2 {
		points := make([][2]f64, edge_count, context.temp_allocator)
		for i in 0 ..< edge_count {
			points[i] = {f64(edge_x0 + f32(i) * edge_step) / s, f64(game.edges[wall][i]) / s}
		}
		edges[wall] = points
	}

	// Wall light: one entity per wall, each glow a quad in its light's color (by kind first,
	// so that past the limit the same ones are left out as before)
	glows := make([dynamic]WallGlow, context.temp_allocator)
	wall_glows(edges, lights, distance, &glows)
	slice.stable_sort_by(glows[:], proc(a, b: WallGlow) -> bool {return a.kind < b.kind})
	counts: [LightKind]int
	for wall in 0 ..< 2 {
		id := scenery.wall_light[wall]
		n := 0
		for g in glows {
			if g.wall != wall || n >= MAX_WALL_GLOWS {
				continue
			}
			color := light_color(LIGHT_COLORS[g.kind]) * f32(g.alpha)
			splat(scenery.values[n * SPLAT_STRIDE:], f32(g.x * s), f32(g.y * s), f32(WALL_LIGHT_GLOW_RADIUS * s), color)
			n += 1
		}
		e := eng.get_entity(id)
		e.pos, e.visible = {}, n > 0
		eng.set_instances(id, "glows", scenery.values[:n * SPLAT_STRIDE])
	}

	// Sand glints: each wall's spots, grouped by color; the entity covers just around them
	spots := make([dynamic]GlintSpot, context.temp_allocator)
	glint_spots(edges, lights, distance, &spots)
	slice.stable_sort_by(spots[:], proc(a, b: GlintSpot) -> bool {return a.kind < b.kind})
	for wall in 0 ..< 2 {
		id := scenery.glints[wall]
		counts = {}
		bounds := Bounds{{1e9, 1e9}, {-1e9, -1e9}}
		k := 0
		for spot in spots {
			if spot.wall != wall || k >= MAX_GLINT_SPOTS * fx.GLOW_STRIDE {
				continue
			}
			x, y := f32((spot.x - distance) * s), f32(spot.y * s)
			scenery.values[k], scenery.values[k + 1] = x, y
			scenery.values[k + 2], scenery.values[k + 3] = f32(GLINT_RADIUS * s), f32(spot.strength)
			k += fx.GLOW_STRIDE
			counts[spot.kind] += 1
			// Grains glint within GLINT_RADIUS of the spot, on its rock side, at most
			// GLINT_DEPTH deep (plus a grain cell, as grains sit anywhere in theirs)
			reach, deep, cell := f32(GLINT_RADIUS * s), f32((GLINT_DEPTH + GLINT_CELL) * s), f32(GLINT_CELL * s)
			grow(&bounds, x - reach, y - (deep if wall == 0 else cell), 0)
			grow(&bounds, x + reach, y + (cell if wall == 0 else deep), 0)
		}
		e := eng.get_entity(id)
		e.visible = k > 0
		if k == 0 {
			continue
		}
		bounds.lo = {math.max(bounds.lo.x, 0), math.max(bounds.lo.y, 0)}
		bounds.hi = {math.min(bounds.hi.x, screen.x), math.min(bounds.hi.y, screen.y)}
		eng.set_param_array(id, "spots", scenery.values[:k])
		for kind in LightKind {
			eng.set_param(id, LEVEL_PARAMS[int(kind)], f32(counts[kind]))
		}
		bins := eng.bin_shapes(scenery.bins[:MAX_GLINT_BINS], scenery.values[:k], .Glow_Points, 1, BIN_CELL)
		eng.set_param_array(id, "bins", scenery.bins[:bins])
		eng.set_param_array(id, "edges", game.edges[wall][:])
		eng.set_param(id, "edge_x0", edge_x0)
		eng.set_param(id, "edge_step", edge_step)
		eng.set_param(id, "unit", f32(s))
		eng.set_param(id, "scroll", f32(distance * s))
		place(id, bounds)
	}
}

// One depth layer's jellyfish: each an entity turned by its tilt, its strands as capsules in
// the entity's own pixels
sync_jellies :: proc(state: ^State, li: int, distance, time, s, width_units: f64) {
	pool := &scenery.jellies[li]
	pool.used = 0
	jellies := make([dynamic]Jelly, context.temp_allocator)
	jellies_in_view(state.seed, li, distance, time, width_units, &jellies)
	blur := f64(JELLY_LAYERS[li].blur)
	for &j in jellies {
		if pool.used == len(pool.ids) {
			append(&pool.ids, new_jelly(li))
		}
		id := pool.ids[pool.used]
		pool.used += 1
		sync_jelly(id, &j, time, s, blur)
	}
	for id in pool.ids[pool.used:] {
		eng.get_entity(id).visible = false
	}
}

sync_jelly :: proc(id: int, j: ^Jelly, time, s, blur: f64) {
	f, w := &j.features, j.size
	shape := jelly_shape(f, w, time)
	out := scenery.values[:]
	k := 0
	// A line through `points` (world units around the jellyfish), drawn at least one pixel of
	// the small image wide; returns how faint it is for being thinner than that
	lo, hi := [2]f64{-shape.bw, -shape.bh}, [2]f64{shape.bw, shape.bw * f.lobe_depth}
	line :: proc(out: []f32, k: ^int, points: [][2]f64, width, s, blur: f64, lo, hi: ^[2]f64) {
		radius := math.max(width * s / 2, 0.5 * blur) // screen pixels
		for i in 0 ..< len(points) - 1 {
			if k^ >= len(out) {
				return
			}
			a, b := points[i], points[i + 1]
			c := k^
			out[c], out[c + 1], out[c + 2], out[c + 3] = f32(a.x * s), f32(a.y * s), f32(b.x * s), f32(b.y * s)
			out[c + 4], out[c + 5] = f32(radius), f32(radius)
			k^ += fx.CAPSULE_STRIDE
			for p in ([2][2]f64{a, b}) {
				lo^ = {math.min(lo.x, p.x), math.min(lo.y, p.y)}
				hi^ = {math.max(hi.x, p.x), math.max(hi.y, p.y)}
			}
		}
	}
	thin :: proc(width, s, blur: f64) -> f32 {return f32(math.min(1, width * s / blur))}

	// Strands: the bell's outline, the canals, the ribbons' edges and the filaments
	strand_width := w * 0.022
	line(out, &k, shape.dome[:], strand_width, s, blur, &lo, &hi)
	for i in 0 ..< f.canals {
		m := shape.rim[js_round((f64(i) + 0.5) / f64(f.canals) * 24)]
		p0, c, p1 := [2]f64{m.x * 0.15, -shape.bh * 0.55}, [2]f64{m.x * 0.6, -shape.bh * 0.45}, m
		pts: [13][2]f64
		for q in 0 ..= 12 {
			t := f64(q) / 12
			u := 1 - t
			pts[q] = u * u * p0 + 2 * u * t * c + t * t * p1
		}
		line(out, &k, pts[:], strand_width, s, blur, &lo, &hi)
	}
	arms := math.min(f.arms, MAX_JELLY_ARMS)
	for i in 0 ..< arms {
		for side in ([2]f64{-1, 1}) {
			pts: [15][2]f64
			for q in 0 ..= 14 {
				pts[q] = jelly_arm_edge(f, shape.arms[i], i, w, time, f64(q) / 14, side)
			}
			line(out, &k, pts[:], strand_width, s, blur, &lo, &hi)
		}
	}
	for i in 0 ..< f.filaments {
		pts: [13][2]f64
		for q in 0 ..= 12 {
			pts[q] = jelly_filament_point(f, &shape, i, w, time, q)
		}
		line(out, &k, pts[:], strand_width, s, blur, &lo, &hi)
	}
	strands := k / fx.CAPSULE_STRIDE
	// The wide faint outline glow along the dome and the rim, then the bright rim
	line(out, &k, shape.dome[:], w * 0.16, s, blur, &lo, &hi)
	line(out, &k, shape.rim[:], w * 0.16, s, blur, &lo, &hi)
	outline := k / fx.CAPSULE_STRIDE - strands
	line(out, &k, shape.rim[:], w * 0.06, s, blur, &lo, &hi)

	// The entity covers the jellyfish's frame (unturned); its center, from the jellyfish's
	// origin, is where the capsules and the look's coordinates are measured from
	margin := w * 0.1 + 2 * blur / s
	lo -= margin
	hi += margin
	center := (lo + hi) / 2 * s
	for c := 0; c < k; c += fx.CAPSULE_STRIDE {
		out[c] -= f32(center.x)
		out[c + 1] -= f32(center.y)
		out[c + 2] -= f32(center.x)
		out[c + 3] -= f32(center.y)
	}
	eng.set_param_array(id, "capsules", out[:k])
	// Coarse cells: the small image has few pixels per cell anyway
	bins := eng.bin_shapes(scenery.bins[:MAX_JELLY_BINS], out[:k], .Capsules, f32(blur + 1), f32(BIN_CELL * blur / 2))
	eng.set_param_array(id, "bins", scenery.bins[:bins])
	eng.set_param(id, "n_strands", f32(strands))
	eng.set_param(id, "n_outline", f32(outline))

	// Shape and paints
	a :: proc(f: ^JellyFeatures, alpha: f64) -> f32 {return f32(math.min(1, alpha * f.gain))}
	edge_hue := (f.hue + f.rim_hue) / 2
	sat := f.saturation / 100
	color :: proc(rgb: [3]f32, alpha: f32 = 1) -> [4]f32 {return {rgb.r * alpha, rgb.g * alpha, rgb.b * alpha, 0}}
	eng.set_param(id, "unit", f32(s))
	eng.set_param(id, "origin", eng.Vector2{f32(-center.x), f32(-center.y)})
	eng.set_param(id, "bw", f32(shape.bw))
	eng.set_param(id, "bh", f32(shape.bh))
	eng.set_param(id, "w", f32(w))
	eng.set_param(id, "t", f32(time))
	eng.set_param(id, "phase", f32(f.phase))
	eng.set_param(id, "peak", f32(f.peak))
	eng.set_param(id, "lobes", f32(f.lobes))
	eng.set_param(id, "lobe_depth", f32(f.lobe_depth))
	for i in 0 ..< MAX_JELLY_ARMS {
		arm := shape.arms[i]
		eng.set_param(id, ARM_PARAMS[i], [4]f32{f32(arm.x0), f32(arm.length), f32(arm.width), 1 if i < arms else 0})
	}
	eng.set_param(id, "body_color", color(hsl(f.hue, sat, 0.5)))
	eng.set_param(id, "body_at", [4]f32{f32(-shape.bh), 0, f32(w * 0.3), f32(w * 1.5)})
	eng.set_param(id, "body_alpha", [4]f32{a(f, f.body * 0.45), a(f, f.body * 1.35), a(f, f.body * 0.9), a(f, f.body * 0.7)})
	eng.set_param(id, "strand_color", color(hsl(edge_hue, sat, 0.63)))
	eng.set_param(id, "strand_at", [4]f32{f32(-shape.bh), f32(-shape.bh * 0.8), f32(-w * 0.04), f32(w * 0.15)})
	eng.set_param(id, "strand_alpha", [4]f32{a(f, 0.5), a(f, 0.3), a(f, 0.3), a(f, 0.62)})
	eng.set_param(id, "strand_thin", thin(strand_width, s, blur))
	eng.set_param(id, "outline_color", color(hsl(edge_hue, sat, 0.63), a(f, 0.14)))
	eng.set_param(id, "outline_thin", thin(w * 0.16, s, blur))
	eng.set_param(id, "rim_color", color(hsl(f.rim_hue, 1, 0.73), a(f, 0.95)))
	eng.set_param(id, "rim_thin", thin(w * 0.06, s, blur))

	// Placed so that turning the entity around its center turns the jellyfish around its origin
	e := eng.get_entity(id)
	c, n := math.cos(f.tilt), math.sin(f.tilt)
	e.visible = true
	e.size = {f32((hi.x - lo.x) * s), f32((hi.y - lo.y) * s)}
	e.pos = {f32(j.x * s + center.x * c - center.y * n), f32(j.y * s + center.x * n + center.y * c)}
	e.rotation = f32(f.tilt * math.DEG_PER_RAD)
}

ARM_PARAMS := [MAX_JELLY_ARMS]string{"arm0", "arm1", "arm2", "arm3", "arm4"}
