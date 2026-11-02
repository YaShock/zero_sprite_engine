package main

// Looks for the stress test: many families of different shader features. Each family comes
// in two structural variants (`detail` 3 or 5: noise octaves or particle counts), so the
// scene uses many distinct shaders; `hue` and `seed` only change parameter values.

import fx "../../engine/vfx"
import "core:math"

Family :: enum {
	// Still
	Brick,
	Gem,
	Rings,
	Mosaic,
	Marble,
	Blob,
	// Animated
	Flame,
	Plasma,
	Crackle,
	Ripple,
	Pulse,
	Radar,
	Fountain,
	Shards,
	// Lit by the scene lights; used for movers
	Plate,
	Rock,
}

STILL := [?]Family{.Brick, .Gem, .Rings, .Mosaic, .Marble, .Blob}
ANIMATED := [?]Family{.Flame, .Plasma, .Crackle, .Ripple, .Pulse, .Radar, .Fountain, .Shards}
MOVING := [?]Family{.Plate, .Rock}
DETAILS := [2]int{3, 5}

// Height ramp from 0 at the shape's edge to 1 at `width` units inside it.
bevel :: proc(d: fx.Expr, width: f32) -> ^fx.Node {
	return fx.sub(1, fx.smoothstep(-width, 0, d))
}

// A color from a cosine palette; shifting `hue` varies colors without new shaders.
tint :: proc(t, hue: fx.Expr) -> ^fx.Node {
	return fx.palette(fx.add(t, hue), [4]f32{0.55, 0.5, 0.45, 1}, [4]f32{0.35, 0.35, 0.35, 1}, [4]f32{1, 1, 1, 1}, [4]f32{0, 0.33, 0.67, 1})
}

// One function per family, so the profiler reports each family on its own line.
look :: proc(family: Family, detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	switch family {
	case .Brick:
		return brick_look(detail, hue, seed, size)
	case .Gem:
		return gem_look(detail, hue, seed, size)
	case .Rings:
		return rings_look(detail, hue, seed, size)
	case .Mosaic:
		return mosaic_look(detail, hue, seed, size)
	case .Marble:
		return marble_look(detail, hue, seed, size)
	case .Blob:
		return blob_look(detail, hue, seed, size)
	case .Flame:
		return flame_look(detail, hue, seed, size)
	case .Plasma:
		return plasma_look(detail, hue, seed, size)
	case .Crackle:
		return crackle_look(detail, hue, seed, size)
	case .Ripple:
		return ripple_look(detail, hue, seed, size)
	case .Pulse:
		return pulse_look(detail, hue, seed, size)
	case .Radar:
		return radar_look(detail, hue, seed, size)
	case .Fountain:
		return fountain_look(detail, hue, seed, size)
	case .Shards:
		return shards_look(detail, hue, seed, size)
	case .Plate:
		return plate_look(detail, hue, seed, size)
	case .Rock:
		return rock_look(detail, hue, seed, size)
	}
	unreachable()
}

brick_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	p := fx.coord()
	half := fx.sub(fx.mul(fx.size(), 0.5), 2)
	d := fx.sd_box(p, half, 5)
	q := fx.add(p, seed * 13)
	grain := fx.fbm(fx.mul(q, 0.12), detail)
	cracks := fx.sub(1, fx.smoothstep(0.02, 0.06, fx.voronoi_edge(fx.mul(q, 0.09))))
	color := fx.shade(tint(fx.mul(grain, 0.35), hue), fx.sub(1, fx.mul(cracks, 0.6)))
	return fx.mask(fx.lit(color, fx.add(fx.mul(bevel(d, 5), 3), fx.mul(grain, 2)), {specular = 0.2}), fx.fill(d))
}

gem_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	p := fx.coord()
	r := min(size.x, size.y) * 0.45
	corners: [6][2]f32
	for &c, i in corners {
		a := f32(i) * math.PI / 3
		c = {math.cos(a), math.sin(a)} * r
	}
	d := fx.sd_convex_polygon(p, corners[:])
	depth := fx.saturate(fx.div(fx.neg(d), r * 0.6))
	glint := fx.fbm(fx.mul(fx.add(p, seed), 0.08), detail)
	color := tint(fx.add(fx.mul(depth, 0.3), fx.mul(glint, 0.2)), hue)
	body := fx.mask(fx.lit(color, fx.mul(depth, 8), {specular = 1.1, shininess = 40}), fx.fill(d))
	return fx.stack(fx.mask(OUTLINE, fx.fill(fx.sub(d, 1.5))), body)
}

rings_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	p := fx.coord()
	r := min(size.x, size.y) * 0.45
	grain := fx.fbm(fx.mul(fx.add(p, seed), 0.05), detail)
	rings := fx.fract(fx.add(fx.mul(fx.length(p), 0.18), fx.mul(grain, 2)))
	color := fx.mix(tint(0.1, hue), tint(0.35, hue), fx.smoothstep(0.3, 0.7, rings))
	d := fx.sd_circle(p, r)
	return fx.mask(fx.lit(color, fx.add(fx.mul(bevel(d, 6), 4), fx.mul(rings, 0.8))), fx.fill(d))
}

mosaic_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	p := fx.coord()
	half := fx.sub(fx.mul(fx.size(), 0.5), 2)
	cell: f32 = 9
	tile_d := fx.sd_box(fx.tile(p, cell), cell * 0.5 - 1, 1.5)
	piece := tint(fx.mul(fx.hash(fx.add(fx.cell_id(p, cell), seed)), 0.8), hue)
	piece = fx.shade(piece, fx.add(0.8, fx.mul(fx.fbm(fx.mul(p, 0.1), detail), 0.4)))
	return fx.mask(fx.mix(GROUT, piece, fx.fill(tile_d)), fx.fill(fx.sd_box(p, half, 3)))
}

marble_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	p := fx.coord()
	half := fx.sub(fx.mul(fx.size(), 0.5), 2)
	q := fx.mul(fx.add(p, seed * 7), 0.04)
	warp := fx.fbm(q, detail)
	veins := fx.abs(fx.sin(fx.mul(fx.add(fx.swizzle(q, "x"), fx.mul(warp, 6)), 3)))
	stone := fx.mix(MARBLE_WHITE, tint(0.2, hue), f32(0.25))
	color := fx.mix(MARBLE_VEIN, stone, fx.smoothstep(0.05, 0.4, veins))
	d := fx.sd_box(p, half, 8)
	return fx.mask(fx.lit(color, fx.mul(bevel(d, 4), 2), {specular = 0.5, shininess = 30}), fx.fill(d))
}

blob_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	p := fx.coord()
	r := min(size.x, size.y) * 0.45
	lobe :: proc(p: fx.Expr, seed, angle, r: f32) -> ^fx.Node {
		a := seed + angle
		return fx.sd_circle(fx.sub(p, [2]f32{math.cos(a), math.sin(a)} * r * 0.45), r * 0.5)
	}
	d := fx.min(fx.min(lobe(p, seed, 0, r), lobe(p, seed, 2.1, r)), lobe(p, seed, 4.2, r))
	color := tint(fx.add(fx.mul(fx.fbm(fx.mul(p, 0.1), detail), 0.3), 0.5), hue)
	return fx.stack(fx.mask(color, fx.mul(fx.glow(d, 6), 0.5)), fx.mask(fx.lit(color, fx.mul(bevel(d, 8), 5), {specular = 0.6}), fx.fill(d)))
}

flame_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	p := fx.coord()
	fp := fx.sub(p, [2]f32{0, size.y * 0.45})
	up := fx.neg(fx.swizzle(fp, "y"))
	k := fx.saturate(fx.div(up, size.y * 0.9))
	turbulence := fx.fbm(fx.vec2(fx.mul(fx.swizzle(fp, "x"), 0.15), fx.mul(fx.sub(up, fx.mul(fx.time(), 40)), 0.1)), detail)
	sway := fx.mul(fx.sub(turbulence, 0.5), fx.mul(k, 10))
	half_width := fx.mul(fx.sub(1, fx.pow(k, 1.5)), size.x * 0.35)
	body := fx.mul(fx.saturate(fx.sub(1, fx.div(fx.abs(fx.add(fx.swizzle(fp, "x"), sway)), fx.max(half_width, 0.5)))), fx.step(0, up))
	heat := fx.saturate(fx.mul(fx.mul(body, fx.add(fx.mul(turbulence, 1.4), 0.2)), fx.sub(1.2, k)))
	return fx.mask(fx.ramp(heat, FLAME_RED, FLAME_ORANGE, FLAME_YELLOW, WHITE), fx.smoothstep(0.08, 0.3, heat))
}

plasma_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	p := fx.coord()
	r := min(size.x, size.y) * 0.45
	radius := r * 0.8
	d := fx.sd_circle(p, radius)
	swirl := fx.fbm(fx.add(fx.mul(p, 0.15), fx.mul(fx.time(), [2]f32{1.5, -1})), detail)
	hot := fx.gradient(fx.saturate(fx.add(swirl, fx.sub(0.6, fx.div(fx.length(p), radius)))), tint(0, hue), WHITE)
	return fx.stack(fx.mask(tint(0, hue), fx.mul(fx.glow(d, radius * 0.6), 0.6)), fx.mask(hot, fx.fill(d)))
}

crackle_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	p := fx.coord()
	r := min(size.x, size.y) * 0.45
	d := fx.sub(fx.length(p), r * 0.35)
	flicker := fx.floor(fx.mul(fx.time(), 14))
	field := fx.fbm(fx.add(fx.mul(p, 0.07), fx.mul(fx.vec2(flicker, fx.mul(flicker, 1.7)), 0.37)), detail)
	filament := fx.exp(fx.mul(fx.abs(fx.sub(field, 0.5)), -45))
	k := fx.saturate(fx.mul(fx.mul(filament, fx.exp(fx.div(fx.neg(fx.max(d, 0)), 8))), 1.4))
	return fx.stack(fx.mask(VOLT_VIOLET, fx.mul(fx.glow(d, 8), 0.6)), fx.mask(fx.mix(VOLT_VIOLET, VOLT_WHITE, k), k), fx.mask(VOLT_WHITE, fx.fill(d)))
}

ripple_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	p := fx.coord()
	half := fx.sub(fx.mul(fx.size(), 0.5), 2)
	r := min(size.x, size.y) * 0.45
	center := [2]f32{math.cos(seed), math.sin(seed)} * r * 0.3
	wave := fx.sin(fx.sub(fx.mul(fx.length(fx.sub(p, center)), 0.6), fx.mul(fx.time(), 5)))
	height := fx.add(fx.mul(wave, 1.5), fx.fbm(fx.mul(p, 0.08), detail))
	color := fx.mix(WATER_DEEP, WATER_LIGHT, fx.saturate(fx.add(fx.mul(wave, 0.3), 0.4)))
	d := fx.sd_box(p, half, 6)
	return fx.mask(fx.lit(color, height, {strength = 2, specular = 0.8, shininess = 30}), fx.fill(d))
}

pulse_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	p := fx.coord()
	r := min(size.x, size.y) * 0.45
	t := fx.fract(fx.add(fx.mul(fx.time(), 0.8), seed))
	ring := fx.mul(fx.stroke(fx.sub(fx.length(p), fx.mul(t, r)), 3), fx.sub(1, t))
	haze := fx.mul(fx.mul(fx.fbm(fx.mul(p, 0.1), detail), 0.3), fx.sub(1, t))
	return fx.mask(tint(0.6, hue), fx.saturate(fx.add(ring, haze)))
}

radar_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	p := fx.coord()
	r := min(size.x, size.y) * 0.45
	dist := fx.length(p)
	disc := fx.fill(fx.sub(dist, r))
	sweep := fx.fract(fx.add(fx.sub(fx.div(fx.angle(p), 2 * math.PI), fx.mul(fx.time(), 0.5)), seed))
	beam := fx.mul(fx.pow(sweep, 6), disc)
	rings := fx.max(fx.stroke(fx.sub(dist, r * 0.66), 1), fx.stroke(fx.sub(dist, r * 0.33), 1))
	blips := fx.mul(fx.step(0.7, fx.fbm(fx.mul(fx.add(p, seed), 0.2), detail)), beam)
	return fx.stack(fx.mask(OUTLINE, fx.mul(disc, 0.8)), fx.mask(RADAR_GREEN, fx.saturate(fx.sum(beam, fx.mul(rings, 0.5), blips))))
}

fountain_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	return fx.sparks({
		progress = fx.mul(fx.fract(fx.add(fx.mul(fx.time(), 0.7), seed)), 1.2),
		origin = [2]f32{0, size.y * 0.4},
		direction = -math.PI / 2,
		spread = 0.5,
		speed = size.y * 3,
		gravity = size.y * 6,
		radius = 1.3,
		life = 0.9,
		seed = seed,
		color = SPARK_GOLD,
		count = detail * 4,
	})
}

shards_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	progress := fx.mul(fx.fract(fx.add(fx.mul(fx.time(), 0.4), seed)), 1.2)
	inner := brick_look(detail, hue, seed, size)
	shards := fx.shatter(inner, {progress = progress, impact = [2]f32{0, size.y * 0.3}, seed = seed, speed = 40, gravity = 120, spin = 4, cols = 3, rows = 2})
	return fx.mask(shards, fx.sub(1, fx.smoothstep(0.7, 1.2, progress)))
}

plate_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	p := fx.coord()
	half := fx.sub(fx.mul(fx.size(), 0.5), 2)
	d := fx.sd_box(p, half, 4)
	brushed := fx.noise(fx.mul(fx.add(p, seed), [2]f32{0.15, 1.2}))
	color := fx.shade(fx.mix(STEEL, tint(0.3, hue), f32(0.3)), fx.add(0.8, fx.mul(brushed, 0.3)))
	height := fx.add(fx.mul(bevel(d, 3), 3), fx.mul(fx.fbm(fx.mul(p, 0.2), detail), 0.8))
	body := fx.mask(fx.lit_scene(color, height, {specular = 0.9, shininess = 24}), fx.fill(d))
	edge := fx.mask(tint(0.8, hue), fx.mul(fx.stroke(d, 2), fx.param("glow", f32(0))))
	return fx.stack(body, edge)
}

rock_look :: proc(detail: int, hue, seed: f32, size: [2]f32) -> ^fx.Node {
	p := fx.coord()
	r := min(size.x, size.y) * 0.45
	q := fx.add(p, seed * 17)
	d := fx.add(fx.sd_circle(p, r * 0.9), fx.mul(fx.sub(fx.noise(fx.mul(q, 2.4 / r)), 0.5), r * 0.4))
	color := fx.mix(OUTLINE, ROCK, fx.fbm(fx.mul(q, 0.15), detail))
	return fx.mask(fx.lit_scene(color, fx.mul(bevel(d, r * 0.8), r * 0.5), {specular = 0.15}), fx.fill(d))
}

// Short-lived effects spawned during the churn stage.
EffectKind :: enum {
	Burst,
	Ring,
	Shatter,
}

effect_look :: proc(kind: EffectKind, hue, seed: f32) -> ^fx.Node {
	switch kind {
	case .Burst:
		return burst_look(seed)
	case .Ring:
		return ring_look(hue)
	case .Shatter:
		return gem_shatter_look(hue, seed)
	}
	unreachable()
}

burst_look :: proc(seed: f32) -> ^fx.Node {
	return fx.sparks({seed = seed, speed = 220, gravity = 400, life = 0.6, radius = 1.4, color = SPARK_GOLD, count = 16})
}

ring_look :: proc(hue: f32) -> ^fx.Node {
	t := fx.age()
	ring := fx.stroke(fx.sub(fx.length(fx.coord()), fx.mul(t, 120)), fx.mul(fx.exp(fx.mul(t, -3)), 5))
	return fx.mask(tint(0.5, hue), fx.mul(ring, fx.exp(fx.mul(t, -3))))
}

gem_shatter_look :: proc(hue, seed: f32) -> ^fx.Node {
	gem := gem_look(3, hue, seed, {40, 40})
	fade := fx.sub(1, fx.smoothstep(0.4, 0.8, fx.age()))
	return fx.mask(fx.shatter(gem, {seed = seed, speed = 160, gravity = 500, spin = 6, cols = 3, rows = 2}), fade)
}
