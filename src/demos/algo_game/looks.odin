package main

// Looks: every visual is a composition of vfx functions and parameters. Positions that the
// game works out every frame (the cave's edge, the tendrils, the sparks) reach the shaders
// as param arrays.

import fx "../../engine/vfx"
import "core:fmt"
import rl "vendor:raylib"

EDGE_SAMPLES :: 256 // wall edge points per wall (one per CAVE_SAMPLE_STEP across the screen)
HELIX_POINTS :: 46 // points per tendril
HELIX_PIECES :: 2 * HELIX_POINTS
SHIP_UNITS :: 40 // ship units per SHIP_SIZE

// Gradient through colors at uneven positions `at` (ascending, 0..1) as t goes from 0 to 1.
stops :: proc(t: fx.Expr, at: []f32, colors: []rl.Color) -> ^fx.Node {
	acc := fx.to_node(colors[0])
	for i in 1 ..< len(at) {
		k := fx.saturate(fx.div(fx.sub(t, at[i - 1]), at[i] - at[i - 1]))
		acc = fx.mix(acc, colors[i], k)
	}
	return acc
}

// ---------------------------------------------------------------------------------------
// Rock

// One fragment per cell of a jittered grid (world units): an irregular ellipse whose size,
// squash and turn come from the cell's hash. Returns the fragment's distance (world units)
// at `p` shifted by `offset`, scaled around its center by `scale`, and the cell's id.
fragment :: proc(p: fx.Expr, cell, r_min, r_extra, squash_min, squash_extra, turn, seed: f32, offset: fx.Expr = [2]f32{0, 0}, scale: f32 = 1) -> (d: ^fx.Node, id: ^fx.Node) {
	id = fx.cell_id(p, cell)
	r := fx.hash(fx.add(id, seed))
	rx := fx.add(r_min, fx.mul(fx.mul(r, r), r_extra)) // many small, few larger
	ry := fx.mul(rx, fx.add(squash_min, fx.mul(fx.hash(fx.add(id, seed + 1.3)), squash_extra)))
	margin := 2 * (r_min + r_extra)
	jitter := fx.vec2(fx.hash(fx.add(id, seed + 2.9)), fx.hash(fx.add(id, seed + 4.1)))
	local := fx.sub(fx.tile(p, cell), fx.mul(fx.sub(jitter, 0.5), cell - margin))
	local = fx.rotate(fx.sub(local, offset), fx.mul(fx.sub(fx.hash(fx.add(id, seed + 6.7)), 0.5), turn))
	// Uneven outline: the radius wobbles with the direction
	wobble := fx.add(0.85, fx.mul(fx.noise(fx.add(fx.mul(local, 1 / (cell * 0.12)), fx.mul(id, 3.7))), 0.3))
	d = fx.sub(fx.length(fx.div(local, fx.vec2(rx, ry))), fx.mul(scale, wobble))
	d = fx.mul(d, fx.min(rx, ry)) // back to (roughly) world units
	return
}

// The cave rock above (side 1) or below (side -1) the tunnel: fine rubble of small pebbles
// and pores in sandy rock, fading to almost black toward the screen's top and bottom.
// The edge is the `edges` curve (screen pixels); the texture scrolls with the cave.
rock_look :: proc(side: f32) -> ^fx.Node {
	wp := fx.world() // screen pixels: the camera never moves
	x, y := fx.swizzle(wp, "x"), fx.swizzle(wp, "y")
	unit := fx.param("unit", f32(36)) // pixels per world unit
	edges := fx.param_array("edges", EDGE_SAMPLES)
	edge := fx.curve(edges, fx.div(fx.sub(x, fx.param("edge_x0", f32(0))), fx.param("edge_step", f32(9))))
	inside := fx.fill(fx.mul(fx.sub(y, edge), side))

	// World units, moving with the cave
	tp := fx.div(fx.add(wp, fx.vec2(fx.param("scroll", f32(0)), 0)), unit)
	px := fx.mul(unit, 1) // world units → pixels for anti-aliasing

	// Pores: small dark fragments with a faint lit lower lip (sizes in sketch pixels of the
	// original, 16 per world unit; matched to its look on screen)
	pore, _ := fragment(tp, 0.44, 0.2 / 16, 0.7 / 16, 0.6, 0.4, 3.14, 11.0)
	pore_rim, _ := fragment(tp, 0.44, 0.2 / 16, 0.7 / 16, 0.6, 0.4, 3.14, 11.0, [2]f32{0, 0.3 / 16})
	// Pebbles: larger, in grays a little above the rock's, with a drop shadow and a soft
	// shine; a quarter of the cells have none, so they don't look ruled
	pebble, pebble_id := fragment(tp, 0.62, 0.5 / 16, 1.5 / 16, 0.55, 0.35, 1.2, 23.0)
	shadow, _ := fragment(tp, 0.62, 0.5 / 16, 1.5 / 16, 0.55, 0.35, 1.2, 23.0, [2]f32{0.3 / 16, 0.45 / 16})
	shine, _ := fragment(tp, 0.62, 0.5 / 16, 1.5 / 16, 0.55, 0.35, 1.2, 23.0, [2]f32{-0.04, -0.03}, 0.45)
	gray := fx.mix(rl.Color{28, 26, 23, 255}, rl.Color{42, 40, 37, 255}, fx.hash(fx.add(pebble_id, 8.8)))
	present := fx.step(0.25, fx.hash(fx.add(pebble_id, 3.3)))

	// Fine sand speckle, one grain per screen pixel at most, moving with the cave
	grain := fx.hash(fx.floor(fx.mul(tp, unit)))
	sand_light := fx.step(grain, 0.02)
	sand_dark := fx.step(0.976, grain)

	// The vignette toward the screen's top and bottom edges
	sy := fx.div(y, fx.param("screen_h", f32(720)))
	near := fx.min(sy, fx.sub(1, sy))
	fade := fx.mul(fx.pow(fx.saturate(fx.sub(1, fx.div(near, 0.32))), 2.2), 0.96)

	rock := fx.stack(
		WALL,
		fx.mask(PORE_RIM, fx.fill(fx.mul(pore_rim, px))),
		fx.mask(PORE, fx.fill(fx.mul(pore, px))),
		fx.mask(PEBBLE_SHADOW, fx.mul(present, fx.fill(fx.mul(shadow, px)))),
		fx.mask(gray, fx.mul(present, fx.fill(fx.mul(pebble, px)))),
		fx.mask(PEBBLE_SHINE, fx.mul(present, fx.fill(fx.mul(shine, px)))),
		fx.mask(SAND_LIGHT, sand_light),
		fx.mask(SAND_DARK, sand_dark),
		fx.mask(VIGNETTE, fade),
	)
	// Drawn in vertical slices (screen pixels, the entity at 0, 0), each reaching only as deep
	// as its edge; within a slice, the open water in front of the edge would be masked away,
	// so the texture isn't computed there
	return fx.instanced(fx.gate(inside, fx.mask(rock, inside)), fx.instances("slices", 4, MAX_ROCK_SLICES))
}

// ---------------------------------------------------------------------------------------
// Ship: a sleek nanobot in ship units (SHIP_UNITS make one SHIP_SIZE), turned with the
// entity. The tendril helix is a param array of capsules, back pieces first.

// A cubic Bézier sampled into points (start excluded)
bezier :: proc(points: ^[dynamic][2]f32, p0, p1, p2, p3: [2]f32, steps: int) {
	for i in 1 ..= steps {
		t := f32(i) / f32(steps)
		u := 1 - t
		append(points, u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3)
	}
}

ship_look :: proc() -> ^fx.Node {
	unit := fx.param("ship_px", f32(0.81)) // pixels per ship unit
	sp := fx.div(fx.coord(), unit)
	cover :: proc(d: fx.Expr, unit: ^fx.Node) -> ^fx.Node {return fx.fill(fx.mul(d, unit))}

	// Tendrils, back to front
	helix := fx.param_array("helix", HELIX_PIECES * fx.CAPSULE_STRIDE)
	n_back, n_mid := fx.param("n_back", f32(0)), fx.param("n_mid", f32(0))
	back := fx.mask(SHIP_HELIX_BACK, cover(fx.sd_capsules(sp, helix, 0, n_back), unit))
	mid := fx.mask(SHIP_HELIX_MID, cover(fx.sd_capsules(sp, helix, n_back, n_mid), unit))
	front := fx.mask(SHIP, cover(fx.sd_capsules(sp, helix, fx.add(n_back, n_mid), -1), unit))

	// The body squashes a little while thrusting
	bp := fx.div(sp, fx.param("squash", [2]f32{1, 1}))
	outline := make([dynamic][2]f32, context.temp_allocator)
	append(&outline, [2]f32{34, 0})
	bezier(&outline, {34, 0}, {22, -3}, {14, -11}, {0, -11}, 8)
	bezier(&outline, {0, -11}, {-12, -10}, {-18, -5}, {-20, 0}, 8)
	bezier(&outline, {-20, 0}, {-18, 5}, {-12, 10}, {0, 11}, 8)
	bezier(&outline, {0, 11}, {14, 11}, {22, 3}, {34, 0}, 8)
	pop(&outline) // back at the start: a zero-length edge would have no direction
	body := fx.sd_convex_polygon(bp, outline[:])
	// Side protrusions: soft paddles ending in rounded tips, where the tendrils are rooted
	fin_top := fx.sub(fx.sd_segment(bp, [2]f32{-5, -8}, [2]f32{-16, -11.5}), 2.6)
	fin_bottom := fx.sub(fx.sd_segment(bp, [2]f32{-5, 8}, [2]f32{-16, 11.5}), 2.6)
	hull := fx.min(body, fx.min(fin_top, fin_bottom))

	by := fx.swizzle(bp, "y")
	steel := stops(
		fx.div(fx.add(by, 13), 26),
		{0, 0.2, 0.45, 0.78, 0.92, 1},
		{SHIP_HIGHLIGHT, SHIP_LIGHT, SHIP_MID, SHIP_DARK, SHIP_BOUNCE, SHIP_DARK},
	)
	// Brushed grain: faint lines along the body, each row starting and ending unevenly
	row := fx.floor(by)
	bx := fx.swizzle(bp, "x")
	along := fx.mul(fx.step(fx.add(-20, fx.mul(fx.hash(fx.add(row, 4.711)), 8)), bx), fx.step(bx, fx.sub(34, fx.mul(fx.hash(fx.add(row, 4.712)), 12))))
	line := fx.sub(1, fx.smoothstep(0.1, 0.25, fx.abs(fx.sub(fx.fract(fx.sub(by, fx.mul(fx.hash(fx.add(row, 4.713)), 0.3))), 0.5))))
	grain := fx.mask(SHIP_GRAIN, fx.mul(along, line))
	// Panel seam, highlight streak and the glass visor
	seam_points := make([dynamic][2]f32, context.temp_allocator)
	append(&seam_points, [2]f32{-3, -10.4})
	bezier(&seam_points, {-3, -10.4}, {-0.333, -3.467}, {-0.333, 3.467}, {-3, 10.4}, 6)
	seam := fx.sub(fx.sd_polyline(bp, seam_points[:]), 0.3)
	streak_points := make([dynamic][2]f32, context.temp_allocator)
	append(&streak_points, [2]f32{26, -2.6})
	bezier(&streak_points, {26, -2.6}, {18, -6}, {10, -9}, {0, -9.2}, 8)
	streak := fx.sub(fx.sd_polyline(bp, streak_points[:]), 0.45)
	visor_local := fx.rotate(fx.sub(bp, [2]f32{10, -3.2}), 0.12)
	visor := fx.mul(fx.sub(fx.length(fx.div(visor_local, [2]f32{8, 2.4})), 1), 2.4)
	glass := stops(fx.div(fx.add(by, 5.6), 4.8), {0, 0.5, 1}, {SHIP_HIGHLIGHT, SHIP_VISOR, SHIP_MID})

	inner := fx.stack(
		steel,
		grain,
		fx.mask(SHIP_SEAM, cover(seam, unit)),
		fx.mask(SHIP_HIGHLIGHT, cover(streak, unit)),
		fx.mask(glass, cover(visor, unit)),
	)
	return fx.stack(
		back,
		mid,
		front,
		// Dark rim: only its outer half shows around the steel
		fx.mask(SHIP_EDGE, cover(fx.sub(hull, 0.7), unit)),
		fx.mask(inner, cover(hull, unit)),
	)
}

// ---------------------------------------------------------------------------------------
// Sparks: short streaks in three age groups, fainter as they age (capsules in screen
// pixels, youngest group first)

sparks_look :: proc() -> ^fx.Node {
	wp := fx.world()
	sparks := fx.param_array("sparks", SPARK_MAX * fx.CAPSULE_STRIDE)
	n0, n1, n2 := fx.param("n0", f32(0)), fx.param("n1", f32(0)), fx.param("n2", f32(0))
	group :: proc(d: ^fx.Node, alpha: f32) -> ^fx.Node {return fx.mask(SPARK, fx.mul(fx.fill(d), alpha))}
	return fx.stack(
		group(fx.sd_capsules(wp, sparks, 0, n0), 1),
		group(fx.sd_capsules(wp, sparks, n0, n1), 0.6),
		group(fx.sd_capsules(wp, sparks, fx.add(n0, n1), n2), 0.3), // only the live ones, not the whole pool
	)
}


// ---------------------------------------------------------------------------------------
// Corals and sea fans: one entity each, drawn with premultiplied color so that the solid
// branches cover what is behind and their glow adds light to it. Positions are screen
// pixels in arrays (uniforms for corals, the data texture with bins for the much bigger sea
// fans), grouped by drawing step; counts per group are params.

MAX_CORAL_SEGMENTS :: 120 // 240 uniform registers (common GPUs have 1024)
MAX_CORAL_TIPS :: 84
MAX_FAN_PIECES :: 1600 // branches, links and the glow's copies of them
MAX_FAN_BINS :: 24576 // lookup grids (see engine.bin_shapes)
BIN_CELL :: 16 // pixels
FAN_LEVELS :: 8 // a lace fan's levels 0..7
FAN_GLOW_STEPS :: 8 // brightness steps of the light wave (0.2 apart)

// `color` (straight alpha) with premultiplied alpha, plus `light` of `light_color` added
premultiplied :: proc(color: ^fx.Node, light_color: rl.Color, light: fx.Expr, loc := #caller_location) -> ^fx.Node {
	a := fx.swizzle(color, "a")
	lc := [4]f32{f32(light_color.r), f32(light_color.g), f32(light_color.b), 0} / 255
	return fx.add(fx.mul(color, fx.rgba(a, a, a, 1)), fx.mul(lc, light), loc) // named after the look that called it
}

// `look`, except where the rock drawn after it surely covers it: a growth standing behind
// the rock skips the pixels beyond its line (see hide_behind_rock). behind_side 1: the
// ceiling's rock (above the line), -1 the floor's (below it), 0 nothing is skipped.
unless_hidden :: proc(look: ^fx.Node) -> ^fx.Node {
	y := fx.swizzle(fx.world(), "y")
	side := fx.param("behind_side", f32(0))
	shown := fx.step(0, fx.mul(fx.sub(y, fx.param("behind_line", f32(0))), side))
	return fx.gate(shown, look)
}

// Coral branch color at a level: trunk to tip, rounded like the original's CSS colors
coral_color :: proc(level: int) -> rl.Color {
	f := f32(level) / f32(FRACTAL_DEPTH - 1)
	rgb := CORAL_TRUNK + (CORAL_TIP - CORAL_TRUNK) * f
	return {u8(rgb.r + 0.5), u8(rgb.g + 0.5), u8(rgb.b + 0.5), 255}
}

// Values per branch of coral_look: its quad | ax, ay, bx, by | radius, level, then the
// records of up to CORAL_NEIGHBORS branches of its level that come close enough to share
// pixels with it (-1: none)
CORAL_RECORD :: 16
CORAL_NEIGHBORS :: 6

// A coral, one quad per branch (an instanced look), level by level (trunk first),
// premultiplied; each level covers the ones before it, as drawing them in turn does. Where
// branches of a level overlap (forks, crowded tips), a pixel is drawn only by the nearest
// of them (the one listed first if they are as near), so each level's outline is the union
// of its branches, edge pixels included, not two half-covered pixels on top of each other.
// (The soft glow on the outermost tips is drawn right after the coral, one quad per tip:
// see new_growth.)
coral_look :: proc() -> ^fx.Node {
	branches := fx.instances("branches", CORAL_RECORD, MAX_CORAL_SEGMENTS)
	p := fx.world()
	capsule :: proc(p: fx.Expr, ends: ^fx.Node, radius: fx.Expr) -> ^fx.Node {
		return fx.sub(fx.sd_segment(p, fx.swizzle(ends, "xy"), fx.swizzle(ends, "zw")), radius)
	}
	about := fx.instance4(branches, 8) // radius, level, two neighbors
	more := fx.instance4(branches, 12) // four more neighbors
	d := capsule(p, fx.instance4(branches, 4), fx.swizzle(about, "x"))
	self := fx.instance_index()
	neighbors := [CORAL_NEIGHBORS]^fx.Node {
		fx.swizzle(about, "z"),
		fx.swizzle(about, "w"),
		fx.swizzle(more, "x"),
		fx.swizzle(more, "y"),
		fx.swizzle(more, "z"),
		fx.swizzle(more, "w"),
	}
	drawn: fx.Expr = f32(1) // 0 where a neighbor draws the pixel instead
	for other in neighbors {
		at := fx.max(other, 0)
		od := capsule(p, fx.instance4_of(branches, at, 4), fx.swizzle(fx.instance4_of(branches, at, 8), "x"))
		nearer := fx.sub(1, fx.step(d, od)) // od < d
		tied_first := fx.mul(fx.mul(fx.step(d, od), fx.step(od, d)), fx.sub(1, fx.step(self, other))) // od == d, listed before
		drawn = fx.mul(drawn, fx.sub(1, fx.mul(fx.step(0, other), fx.add(nearer, tied_first))))
	}
	cover := fx.mul(fx.fill(d), drawn)
	level := fx.swizzle(about, "y")
	color: fx.Expr = coral_color(0)
	for l in 1 ..< FRACTAL_DEPTH {
		color = fx.mix(color, coral_color(l), fx.step(f32(l) - 0.5, level))
	}
	return unless_hidden(fx.mul(color, fx.rgba(cover, cover, cover, cover)))
}

// A sea fan: branches level by level, the net of links, and the glow. The glow follows the
// wave of light: each branch and link is copied into one of FAN_GLOW_STEPS brightness
// groups, and every group glows in three passes (wide and faint to thin and strong) around
// its nearest piece, as the original paints it.
fan_look :: proc() -> ^fx.Node {
	p := fx.world()
	pieces := fx.data_array("pieces", MAX_FAN_PIECES * fx.CAPSULE_STRIDE)
	bins := fx.data_array("bins", MAX_FAN_BINS) // the branches and links
	glow_bins := fx.data_array("glow_bins", MAX_FAN_BINS) // their glow copies, listed as far as the glow reaches
	depth := fx.param("depth", f32(6))
	unit := fx.param("unit", f32(36)) // pixels per world unit
	// Distances to each group's nearest piece, four groups per walk down the list (the same
	// as one sd_capsules per group, for a quarter of the walks)
	groups :: proc(p: fx.Expr, pieces, bins: ^fx.Node, first: ^fx.Expr, names: []string) -> [8]^fx.Node {
		out: [8]^fx.Node
		xyzw := [4]string{"x", "y", "z", "w"}
		for at := 0; at < len(names); at += 4 {
			counts: [4]fx.Expr
			for k in 0 ..< 4 {
				counts[k] = fx.param(names[at + k], f32(0))
			}
			d := fx.sd_capsule_groups(p, pieces, first^, counts, bins)
			for k in 0 ..< 4 {
				out[at + k] = fx.swizzle(d, xyzw[k])
				first^ = fx.add(first^, counts[k])
			}
		}
		return out
	}
	layers := make([dynamic]fx.Expr, context.temp_allocator)
	first: fx.Expr = f32(0)
	branches := groups(p, pieces, bins, &first, LEVEL_PARAMS[:])
	for level in 0 ..< FAN_LEVELS {
		color := fx.mix(SEA_FAN_BASE, SEA_FAN_TIP, fx.saturate(fx.div(f32(level), depth)))
		append(&layers, fx.mask(color, fx.fill(branches[level])))
	}
	links := fx.param("n_links", f32(0))
	append(&layers, fx.mask(SEA_FAN_LINK, fx.fill(fx.sd_capsules(p, pieces, first, links, bins))))
	first = fx.add(first, links)

	soft := fx.mul(fx.px(), 2) // the original paints the glow at half resolution: softer edges
	widths := [3]f32{1, 0.5, 0.2}
	alphas := [3]f32{0.07, 0.13, 0.3}
	light: fx.Expr = f32(0)
	glows := groups(p, pieces, glow_bins, &first, GLOW_PARAMS[1:])
	for step in 1 ..= FAN_GLOW_STEPS {
		d := glows[step - 1]
		for pass in 0 ..< 3 {
			half := fx.mul(unit, SEA_FAN_GLOW_WIDTH * widths[pass] / 2)
			strength := min(1, alphas[pass] * SEA_FAN_GLOW_STRENGTH * f32(step) / 5)
			light = fx.add(light, fx.mul(fx.saturate(fx.add(fx.div(fx.sub(half, d), soft), 0.5)), strength))
		}
	}
	return unless_hidden(premultiplied(fx.stack(..layers[:]), SEA_FAN_GLOW, light))
}

// ---------------------------------------------------------------------------------------
// Tentacles, goo and droplets

MAX_GOO_BLOBS :: 160 // per wall: seeded blobs plus the particles of clusters
GOO_BLOB_STRIDE :: 8 // per blob of goo_field_look: x, y, radius, radius | strength, 0, 0, 0

// Coverage of a stroke of half width `half` at distance `d` (pixels), as the original's band()
band :: proc(half, d: fx.Expr) -> ^fx.Node {
	return fx.saturate(fx.add(fx.div(fx.sub(half, d), fx.px()), 0.5))
}

// A tentacle: the tapered chain filled, a thin lighter outline, and a glow along the outline
// in three passes (wide and faint to thin and strong). Distances to the outline come from
// the chain's own distance field.
tentacle_look :: proc() -> ^fx.Node {
	p := fx.world()
	unit := fx.param("unit", f32(36))
	d := fx.sd_capsules(p, fx.param_array("chain", TENTACLE_SEGMENTS * fx.CAPSULE_STRIDE))
	near := fx.abs(d)
	body := fx.stack(fx.mask(TENTACLE, fx.fill(d)), fx.mask(TENTACLE_EDGE, band(fx.mul(unit, 0.025), near)))
	widths := [3]f32{1, 0.5, 0.18}
	alphas := [3]f32{0.3, 0.5, 1}
	light: fx.Expr = f32(0)
	for k in 0 ..< 3 {
		half := fx.mul(unit, TENTACLE_GLOW_WIDTH * widths[k] / 2)
		light = fx.add(light, fx.mul(band(half, near), min(1, TENTACLE_GLOW_STRENGTH * alphas[k])))
	}
	return unless_hidden(premultiplied(body, TENTACLE_GLOW, light))
}

// One wall's goo blobs as a metaball field, one quad per blob (an instanced look), added up
// in a buffer layer: rgb = the field (each blob adds strength·(1 − d²/r²)² inside its
// radius) and its slope along x and y, as vfx.metaballs gives them. Alpha 0: premultiplied,
// it only adds.
goo_field_look :: proc() -> ^fx.Node {
	blobs := fx.instances("blobs", GOO_BLOB_STRIDE, MAX_GOO_BLOBS)
	q := fx.coord()
	r := fx.instance(blobs, 2)
	r2 := fx.mul(r, r)
	k := fx.max(fx.sub(1, fx.div(fx.dot(q, q), r2)), 0)
	strength := fx.instance(blobs, 4)
	slope := fx.mul(q, fx.mul(strength, fx.div(fx.mul(k, -4), r2)))
	return fx.rgba(fx.mul(strength, fx.mul(k, k)), fx.swizzle(slope, "x"), fx.swizzle(slope, "y"), 0)
}

// The goo on one wall (side 1 ceiling, -1 floor): the blobs' field (read from the wall's
// buffer layer, see goo_field_look) plus the wall's own pull, which is just below the
// threshold inside the rock and fades out into the tunnel, so blobs near the wall grow a
// neck into it. The distance to the outline comes from the field and its slope; the outline
// itself gets the edge color.
goo_look :: proc(side: f32, field_layer: int) -> ^fx.Node {
	p := fx.world()
	x, y := fx.swizzle(p, "x"), fx.swizzle(p, "y")
	unit := fx.param("unit", f32(36))
	balls := fx.layer_sample(field_layer, p) // field, slope x, slope y
	edge := fx.curve(fx.param_array("edges", EDGE_SAMPLES), fx.div(fx.sub(x, fx.param("edge_x0", f32(0))), fx.param("edge_step", f32(9))))
	into := fx.mul(fx.sub(y, edge), side) // distance into the tunnel
	reach := fx.mul(unit, METABALL_WALL_REACH)
	strength :: METABALL_THRESHOLD * 0.95
	w := fx.saturate(fx.sub(1, fx.div(fx.max(into, 0), reach)))
	field := fx.add(fx.swizzle(balls, "x"), fx.mul(fx.mul(w, w), strength))
	slope_y := fx.sub(fx.swizzle(balls, "z"), fx.mul(fx.div(fx.mul(w, 2 * strength * side), reach), fx.step(0, into)))
	slope := fx.length(fx.vec2(fx.swizzle(balls, "y"), slope_y))
	away := fx.div(fx.sub(field, METABALL_THRESHOLD), fx.max(slope, 1e-4)) // pixels, positive inside
	half := fx.mul(unit, 0.03) // the outline is 0.06 units wide
	cover := fx.saturate(fx.add(fx.add(away, half), 0.5))
	on_edge := fx.saturate(fx.add(fx.sub(half, away), 0.5))
	// Only where some blob reaches: the wall's pull alone stays just below the threshold, and
	// its outline would otherwise trace the whole wall
	near_blob := fx.step(1e-6, fx.swizzle(balls, "x"))
	// Drawn before the rock: more than a pixel inside it, the rock covers it all
	return fx.gate(fx.step(-1, into), fx.mask(fx.mix(GOO, GOO_EDGE, on_edge), fx.mul(cover, near_blob)))
}

// A droplet carried away by the current: one or two particles, each a stretched ellipse
// along its flight (two capsules), with a rim; colors turn from goo to gold
droplet_look :: proc() -> ^fx.Node {
	p := fx.world()
	d := fx.sd_capsules(p, fx.param_array("shape", DROPLET_MAX_PARTICLES * fx.CAPSULE_STRIDE))
	rim := fx.mask(fx.param("edge", [4]f32{0, 0, 0, 1}), fx.fill(fx.sub(d, fx.param("rim", f32(2)))))
	return fx.stack(rim, fx.mask(fx.param("fill", [4]f32{0, 0, 0, 1}), fx.fill(d)))
}
