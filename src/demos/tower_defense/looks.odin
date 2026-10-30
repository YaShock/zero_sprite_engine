package main

// Looks: every visual in the demo is a composition of vfx functions and parameters.

import fx "../../engine/vfx"
import "core:math"
import rl "vendor:raylib"

CELL :: 40
ROAD_HALF :: 22

// Height ramp from 0 at the shape's edge to 1 at `width` units inside it.
bevel :: proc(d: fx.Expr, width: f32) -> ^fx.Node {
	return fx.sub(1, fx.smoothstep(-width, 0, d))
}

// Smooth 0..1 inside mask of a distance field.
inside :: proc(d: fx.Expr) -> ^fx.Node {
	return fx.sub(1, fx.smoothstep(-0.5, 0.5, d))
}

// Approximate distance to an axis-aligned ellipse.
sd_ellipse :: proc(p: fx.Expr, center, radii: [2]f32) -> ^fx.Node {
	q := fx.div(fx.sub(p, center), radii)
	return fx.mul(fx.sub(fx.length(q), 1), min(radii.x, radii.y))
}

// Distance to a rhombus with the given half extents.
sd_diamond :: proc(p: fx.Expr, half: [2]f32) -> ^fx.Node {
	edge := math.sqrt(half.x * half.x + half.y * half.y)
	return fx.div(fx.sub(fx.dot(fx.abs(p), [2]f32{half.y, half.x}), half.x * half.y), edge)
}

// Coverage of random dots on a jittered grid; `density` is the fraction of cells with a dot.
scatter :: proc(p: fx.Expr, cell, radius, density, seed: f32) -> ^fx.Node {
	id := fx.cell_id(p, cell)
	jitter := fx.vec2(fx.hash(fx.add(id, seed)), fx.hash(fx.add(id, seed + 7.7)))
	local := fx.sub(fx.tile(p, cell), fx.mul(fx.sub(jitter, 0.5), cell - 2 * radius))
	present := fx.step(1 - density, fx.hash(fx.add(id, seed + 3.3)))
	return fx.mul(present, fx.fill(fx.sub(fx.length(local), radius)))
}

// Soft contact shadow under an object.
ground_shadow :: proc(center, radii: [2]f32, strength: f32) -> ^fx.Node {
	d := sd_ellipse(fx.coord(), center, radii)
	return fx.mask(SHADOW, fx.mul(fx.sub(1, fx.smoothstep(-radii.y, radii.y * 0.6, d)), strength))
}

// A lit solid with a dark outline.
solid :: proc(d: fx.Expr, color, height: fx.Expr, light := fx.Light{}) -> ^fx.Node {
	return fx.stack(fx.mask(OUTLINE, fx.fill(fx.sub(d, 1.2))), fx.mask(fx.lit(color, height, light), fx.fill(d)))
}

// Stone blocks in running bond: albedo and relief.
masonry :: proc(p: fx.Expr, block: [2]f32, stone, mortar: fx.Expr, seed: f32) -> (color, height: ^fx.Node) {
	d := fx.sd_box(fx.brick_local(p, block), [2]f32{block.x / 2 - 1.1, block.y / 2 - 1.1}, 1.2)
	tone := fx.add(0.8, fx.mul(fx.hash(fx.add(fx.brick_id(p, block), seed)), 0.35))
	grain := fx.noise(fx.mul(p, 0.4))
	stone_color := fx.shade(stone, fx.mul(tone, fx.add(0.85, fx.mul(grain, 0.3))))
	color = fx.mix(mortar, stone_color, inside(d))
	height = fx.add(fx.mul(bevel(d, 2), 1.5), fx.mul(grain, 0.4))
	return
}

// ---------------------------------------------------------------------------------------
// Level

Tones :: struct {
	grass, grass_dry, dirt, stone, flower, foliage: rl.Color,
	seed:                                         f32,
}

// Meadow with flowers and pebbles, crossed by a cobbled road with dirt shoulders.
terrain_look :: proc(path: [][2]f32, tones: Tones) -> ^fx.Node {
	p := fx.world()
	q := fx.add(p, [2]f32{tones.seed * 13.7, tones.seed * 7.3})

	patches := fx.fbm(fx.mul(q, 0.005), 4)
	detail := fx.fbm(fx.mul(q, 0.045), 4)
	blades := fx.noise(fx.mul(q, [2]f32{0.5, 0.12}))
	grass := fx.mix(tones.grass, tones.grass_dry, fx.smoothstep(0.42, 0.68, patches))
	grass = fx.shade(grass, fx.sum(0.72, fx.mul(detail, 0.35), fx.mul(blades, 0.16)))
	grass = fx.mix(grass, tones.flower, scatter(q, 13, 1.8, 0.07, 1.3))
	grass = fx.mix(grass, FLOWER_WHITE, scatter(q, 17, 1.5, 0.05, 5.1))

	center := fx.sd_polyline(p, path)
	jagged := fx.add(center, fx.mul(fx.sub(fx.fbm(fx.mul(q, 0.035), 3), 0.5), 12))
	road := fx.sub(1, fx.smoothstep(-1.5, 1.5, fx.sub(jagged, ROAD_HALF - 4)))
	shoulder := fx.sub(1, fx.smoothstep(-3, 3, fx.sub(jagged, ROAD_HALF + 6)))

	dirt := fx.shade(tones.dirt, fx.add(0.7, fx.mul(detail, 0.5)))
	cobble := fx.smoothstep(0.03, 0.14, fx.voronoi_edge(fx.mul(q, 0.08)))
	cobble_tone := fx.add(0.7, fx.mul(fx.noise(fx.mul(q, 0.25)), 0.4))
	stones := fx.mix(fx.shade(tones.dirt, 0.55), fx.shade(tones.stone, cobble_tone), cobble)
	pebbles := fx.mul(scatter(q, 23, 2.6, 0.25, 9.7), fx.sub(1, road))

	ground := fx.mix(fx.mix(grass, dirt, shoulder), stones, road)
	ground = fx.mix(ground, fx.shade(tones.stone, 0.85), pebbles)
	height := fx.sum(
		fx.mul(detail, 2),
		fx.mul(fx.mul(cobble, road), 2.2),
		fx.mul(pebbles, 1.5),
		fx.mul(fx.sub(1, shoulder), 0.8),
	)
	color := fx.lit(ground, height, {strength = 1.2, specular = 0.06})

	centered := fx.sub(fx.uv(), 0.5)
	return fx.shade(color, fx.sub(1, fx.mul(fx.dot(centered, centered), 0.7)))
}

// Faint build grid that stays off the road.
grid_look :: proc(path: [][2]f32) -> ^fx.Node {
	p := fx.world()
	line := fx.stroke(fx.sd_box(fx.tile(p, CELL), CELL / 2 - 1.5, 4), 1.2)
	off_road := fx.smoothstep(ROAD_HALF + 8, ROAD_HALF + 16, fx.sd_polyline(p, path))
	return fx.mask(GRID_LINE, fx.mul(fx.mul(line, off_road), 0.22))
}

// Swirling elliptic portal; `heat` brightens it.
rift_look :: proc(radii: [2]f32, dark, mid, bright: rl.Color, heat: fx.Expr) -> ^fx.Node {
	n := fx.div(fx.coord(), radii)
	r := fx.length(n)
	twisted := fx.rotate(n, fx.sub(fx.mul(r, 5), fx.mul(fx.time(), 1.6)))
	swirl := fx.fbm(fx.mul(twisted, 2.5), 4)
	t := fx.saturate(fx.sum(fx.mul(swirl, 0.9), fx.mul(fx.sub(1, r), 0.5), fx.mul(heat, 0.5)))
	rim := fx.mul(fx.exp(fx.mul(fx.abs(fx.sub(r, 0.95)), -12)), 0.8)
	color := fx.mix(fx.ramp(t, dark, mid, bright, WHITE), bright, rim)
	return fx.mask(color, fx.max(fx.sub(1, fx.smoothstep(0.8, 1, r)), rim))
}

// Stone archway around a portal; flashes when a golem gets through (`hit_time`).
gate_look :: proc() -> ^fx.Node {
	p := fx.coord()
	outer := fx.min(fx.sd_box(fx.sub(p, [2]f32{0, 12}), [2]f32{30, 30}, 2), fx.sd_circle(fx.sub(p, [2]f32{0, -14}), 30))
	opening := fx.min(fx.sd_box(fx.sub(p, [2]f32{0, 18}), [2]f32{17, 24}), fx.sd_circle(fx.sub(p, [2]f32{0, -6}), 17))
	frame := fx.max(outer, fx.neg(opening))

	stone, relief := masonry(p, {13, 8}, TOWER_STONE, MORTAR, 3.1)
	arch := solid(frame, stone, fx.add(fx.mul(bevel(frame, 4), 3), relief), {specular = 0.15})

	flash := fx.exp(fx.mul(fx.sub(fx.time(), fx.param("hit_time", f32(-100))), -4))
	portal := fx.at(rift_look({17, 30}, GATE_DARK, GATE_TEAL, GATE_GLOW, flash), fx.sub(fx.coord(), [2]f32{0, 6}))
	aura := fx.mask(GATE_TEAL, fx.mul(fx.glow(opening, 8), fx.add(0.35, flash)))
	gem_d := fx.sd_circle(fx.sub(p, [2]f32{0, -38}), 4)
	gem := fx.mask(GATE_GLOW, fx.max(fx.fill(gem_d), fx.mul(fx.glow(gem_d, 4), 0.7)))

	return fx.stack(ground_shadow({0, 40}, {34, 6}, 0.45), aura, fx.mask(portal, fx.fill(opening)), arch, gem)
}

tree_look :: proc(foliage: rl.Color, seed: f32) -> ^fx.Node {
	p := fx.coord()
	trunk := fx.sd_box(fx.sub(p, [2]f32{0, 8}), [2]f32{3.5, 9}, 1.5)
	bark := fx.shade(BARK, fx.add(0.7, fx.mul(fx.noise(fx.mul(p, [2]f32{0.8, 0.12})), 0.5)))

	canopy := fx.min(
		fx.min(fx.sd_circle(fx.sub(p, [2]f32{0, -14}), 15), fx.sd_circle(fx.sub(p, [2]f32{-10, -6}), 11)),
		fx.min(fx.sd_circle(fx.sub(p, [2]f32{10, -5}), 12), fx.sd_circle(fx.sub(p, [2]f32{2, -24}), 9)),
	)
	q := fx.add(p, seed)
	clumps := fx.sub(1, fx.voronoi(fx.mul(q, 0.13)))
	leaves := fx.shade(foliage, fx.add(0.6, fx.mul(fx.fbm(fx.mul(q, 0.14), 4), 0.6)))
	height := fx.add(fx.mul(bevel(canopy, 10), 6), fx.mul(clumps, 3))

	return fx.stack(
		ground_shadow({4, 16}, {20, 6}, 0.45),
		solid(trunk, bark, fx.mul(bevel(trunk, 3), 2)),
		solid(canopy, leaves, height, {specular = 0.05}),
	)
}

boulder_look :: proc(stone: rl.Color, seed: f32) -> ^fx.Node {
	p := fx.coord()
	q := fx.add(p, seed)
	d := fx.add(sd_ellipse(p, {0, 4}, {15, 11}), fx.mul(fx.sub(fx.noise(fx.mul(q, 0.15)), 0.5), 6))
	cracks := fx.sub(1, fx.smoothstep(0.02, 0.06, fx.voronoi_edge(fx.mul(q, 0.09))))
	color := fx.shade(stone, fx.mul(fx.add(0.7, fx.mul(fx.fbm(fx.mul(q, 0.1), 4), 0.5)), fx.sub(1, fx.mul(cracks, 0.4))))
	height := fx.add(fx.mul(bevel(d, 9), 6), fx.mul(fx.noise(fx.mul(q, 0.3)), 1.2))
	return fx.stack(ground_shadow({3, 14}, {18, 5}, 0.4), solid(d, color, height, {specular = 0.1}))
}

// ---------------------------------------------------------------------------------------
// Golems

GolemStyle :: struct {
	light, dark, glow: rl.Color,
	crack_glow:        f32, // how much the cracks emit `glow`
	seed:              f32,
}

GOLEM_STYLES := [EnemyKind]GolemStyle {
	.Mud     = {MUD_LIGHT, MUD_DARK, MUD_GLOW, 0, 1.3},
	.Stone   = {STONE_LIGHT, STONE_DARK, STONE_GLOW, 0, 4.1},
	.Crystal = {CRYSTAL_LIGHT, CRYSTAL_DARK, CRYSTAL_GLOW, 0.6, 7.7},
	.Iron    = {IRON_GOLEM_LIGHT, IRON_GOLEM_DARK, IRON_GLOW, 0.15, 2.9},
	.Magma   = {MAGMA_LIGHT, MAGMA_DARK, MAGMA_GLOW, 1, 5.3},
}

// A walking golem facing right. `walk` is the stride phase in radians. Returns the colored
// figure and the distance field of its silhouette.
golem_body :: proc(size: [2]f32, style: GolemStyle, walk: fx.Expr) -> (figure, silhouette: ^fx.Node) {
	w, h := size.x, size.y
	p := fx.coord()
	swing := fx.sin(walk)
	lift_back := fx.max(swing, 0)
	lift_front := fx.max(fx.neg(swing), 0)
	bob := fx.vec2(f32(0), fx.mul(fx.abs(fx.cos(walk)), -h * 0.035))
	body :: proc(bob: ^fx.Node, offset: [2]f32) -> ^fx.Node {return fx.add(bob, offset)}

	hip_y, foot_y, stride := h * 0.1, h * 0.4, w * 0.14
	back_leg := fx.sub(
		fx.sd_segment(p, body(bob, {-w * 0.14, hip_y}), fx.vec2(fx.add(-w * 0.14, fx.mul(swing, stride)), fx.sub(foot_y, fx.mul(lift_back, h * 0.07)))),
		w * 0.12,
	)
	front_leg := fx.sub(
		fx.sd_segment(p, body(bob, {w * 0.12, hip_y}), fx.vec2(fx.sub(w * 0.12, fx.mul(swing, stride)), fx.sub(foot_y, fx.mul(lift_front, h * 0.07)))),
		w * 0.12,
	)
	torso := fx.sd_box(fx.sub(p, body(bob, {0, -h * 0.05})), [2]f32{w * 0.3, h * 0.2}, w * 0.14)
	head_center := body(bob, {w * 0.06, -h * 0.3})
	head := fx.sd_circle(fx.sub(p, head_center), w * 0.15)

	arm :: proc(p, shoulder, hand: fx.Expr, w: f32) -> ^fx.Node {
		return fx.min(fx.sub(fx.sd_segment(p, shoulder, hand), w * 0.09), fx.sd_circle(fx.sub(p, hand), w * 0.13))
	}
	arm_swing := fx.mul(swing, w * 0.1)
	back_arm := arm(p, body(bob, {-w * 0.26, -h * 0.15}), fx.add(bob, fx.vec2(fx.sub(-w * 0.34, arm_swing), h * 0.08)), w)
	front_arm := arm(p, body(bob, {w * 0.26, -h * 0.15}), fx.add(bob, fx.vec2(fx.add(w * 0.36, arm_swing), h * 0.08)), w)

	back := fx.min(back_leg, back_arm)
	front := fx.min(front_leg, fx.min(torso, head))
	front_all := fx.min(front, front_arm)
	silhouette = fx.min(back, front_all)

	// One lighting pass over stacked part heights: overlaps form creases between parts.
	part :: proc(d: ^fx.Node, raise: f32) -> ^fx.Node {
		return fx.mul(fx.add(fx.mul(bevel(d, 4), 3), raise), fx.fill(d))
	}
	height := fx.max(
		fx.max(fx.max(part(back_leg, 0), part(back_arm, 0)), fx.max(part(front_leg, 0.5), part(torso, 1))),
		fx.max(part(head, 1.5), part(front_arm, 2.5)),
	)

	// Texture coordinates scale with the golem, so big golems aren't covered in tiny cracks.
	q := fx.add(fx.mul(p, 40 / h), [2]f32{style.seed * 31.1, style.seed * 17.7})
	cracks := fx.sub(1, fx.smoothstep(0.02, 0.06, fx.voronoi_edge(fx.mul(q, 0.065))))
	color := fx.mix(style.dark, style.light, fx.saturate(fx.mul(fx.fbm(fx.mul(q, 0.09), 3), 1.3)))
	color = fx.shade(color, fx.sub(1, fx.mul(cracks, 0.55)))
	color = fx.shade(color, fx.sub(1, fx.mul(fx.mul(inside(back), fx.sub(1, inside(front_all))), 0.3)))
	color = fx.lit(color, fx.add(height, fx.mul(fx.noise(fx.mul(q, 0.22)), 1.2)), {strength = 1.1, specular = 0.15})
	edges := fx.max(fx.stroke(fx.add(silhouette, 0.6), 1.4), fx.mul(fx.stroke(front_arm, 1.2), inside(front)))
	color = fx.shade(color, fx.sub(1, fx.mul(edges, 0.6)))

	glowing_cracks := fx.mask(style.glow, fx.mul(fx.mul(cracks, style.crack_glow), inside(silhouette)))
	eye_r := max(w * 0.035, 1.2)
	eyes := fx.min(
		fx.sd_circle(fx.sub(p, fx.add(head_center, [2]f32{w * 0.08, -h * 0.01})), eye_r),
		fx.sd_circle(fx.sub(p, fx.add(head_center, [2]f32{-w * 0.02, -h * 0.01})), eye_r),
	)
	core := fx.sd_circle(fx.sub(p, body(bob, {w * 0.05, -h * 0.06})), w * 0.07)
	pulse := fx.add(0.7, fx.mul(fx.sin(fx.add(fx.mul(fx.time(), 4), style.seed)), 0.3))
	lights := fx.mask(style.glow, fx.saturate(fx.max(fx.glow(eyes, 2), fx.mul(fx.glow(core, 3), pulse))))

	figure = fx.stack(ground_shadow({0, h * 0.43}, {w * 0.42, h * 0.07}, 0.4), fx.mask(color, fx.fill(silhouette)), glowing_cracks, lights)
	return
}

// Flames licking around a silhouette, rising in screen space.
burning_overlay :: proc(silhouette: fx.Expr, amount: fx.Expr) -> ^fx.Node {
	p := fx.coord()
	rise := fx.add(fx.swizzle(p, "y"), fx.mul(fx.time(), 55))
	turbulence := fx.fbm(fx.vec2(fx.mul(fx.swizzle(p, "x"), 0.16), fx.mul(rise, 0.09)), 4)
	reach := fx.sub(1, fx.smoothstep(-1, 5, silhouette))
	heat := fx.mul(fx.mul(fx.saturate(fx.sub(fx.mul(turbulence, 2), 0.95)), reach), amount)
	return fx.mask(fx.ramp(heat, FLAME_RED, FLAME_ORANGE, FLAME_YELLOW), fx.saturate(fx.mul(heat, 3)))
}

// Hidden while `health` is full.
health_bar :: proc(size: [2]f32) -> ^fx.Node {
	health := fx.param("health", f32(1))
	half := size.x * 0.4
	bp := fx.sub(fx.coord(), [2]f32{0, -size.y * 0.5 - 5})
	frame := fx.sd_box(bp, [2]f32{half + 1.5, 3}, 1.5)
	filled := fx.step(fx.swizzle(bp, "x"), fx.sub(fx.mul(health, 2 * half), half))
	inner := fx.fill(fx.sd_box(bp, [2]f32{half, 1.6}, 0.8))
	bar := fx.mix(OUTLINE, fx.gradient(health, HEALTH_LOW, HEALTH_HIGH), fx.mul(filled, inner))
	return fx.mask(bar, fx.mul(fx.fill(frame), fx.step(health, 0.999)))
}

// Live golem driven by params: walk, facing (±1), health, hit_time, frost, burn.
enemy_look :: proc(kind: EnemyKind) -> ^fx.Node {
	size := ENEMIES[kind].size
	figure, silhouette := golem_body(size, GOLEM_STYLES[kind], fx.param("walk", f32(0)))

	frost := fx.param("frost", f32(0))
	hit := fx.exp(fx.mul(fx.sub(fx.time(), fx.param("hit_time", f32(-100))), -12))
	icing := fx.mask(FROST_TINT, fx.mul(fx.mul(frost, 0.5), fx.swizzle(figure, "a")))
	rime := fx.mask(ICE_BLUE, fx.mul(fx.mul(fx.glow(silhouette, 3), fx.sub(1, inside(silhouette))), fx.mul(frost, 0.8)))
	figure = fx.stack(rime, figure, icing)
	figure = fx.shade(figure, fx.add(1, fx.mul(hit, 1.2)))
	figure = fx.stack(figure, burning_overlay(silhouette, fx.param("burn", f32(0))))

	mirrored := fx.at(figure, fx.mul(fx.coord(), fx.vec2(fx.param("facing", f32(1)), f32(1))))
	return fx.stack(mirrored, health_bar(size))
}

// The golem frozen mid-stride, crumbling into shards and dust.
golem_death_look :: proc(kind: EnemyKind, walk, facing, seed: f32) -> ^fx.Node {
	size := ENEMIES[kind].size
	style := GOLEM_STYLES[kind]
	figure, _ := golem_body(size, style, walk)
	mirrored := fx.at(figure, fx.mul(fx.coord(), [2]f32{facing, 1}))
	fade := fx.sub(1, fx.smoothstep(0.5, 1, fx.age()))
	shards := fx.shatter(mirrored, {impact = [2]f32{0, size.y * 0.4}, seed = seed, speed = 90, gravity = 500, spin = 4, cols = 3, rows = 4})
	return fx.stack(fx.mask(shards, fade), dust_puff({0, size.y * 0.3}, style.dark, seed))
}

// ---------------------------------------------------------------------------------------
// Towers

tower_base :: proc(seed: f32) -> ^fx.Node {
	p := fx.coord()
	slab := fx.sd_box(fx.sub(p, [2]f32{0, 9}), [2]f32{17, 9}, 3)
	stone, relief := masonry(fx.add(p, seed), {10, 6}, TOWER_STONE, MORTAR, seed)
	return fx.stack(ground_shadow({0, 15}, {21, 5}, 0.45), solid(slab, stone, fx.add(fx.mul(bevel(slab, 3), 3), relief), {specular = 0.1}))
}

// One gem per level on the base's front face; unlit gems are dark.
level_pips :: proc(level: fx.Expr, color: rl.Color) -> ^fx.Node {
	p := fx.coord()
	acc: ^fx.Node
	for i in 0 ..< TOWER_LEVELS {
		d := fx.sd_circle(fx.sub(p, [2]f32{f32(i - 1) * 8, 13}), 2.4)
		lit := fx.step(f32(i) + 0.5, level)
		gem := fx.stack(fx.mask(color, fx.mul(fx.glow(d, 2.5), fx.mul(lit, 0.6))), fx.mask(fx.mix(OUTLINE, color, lit), fx.fill(d)))
		acc = gem if acc == nil else fx.over(gem, acc)
	}
	return acc
}

// Turbulent flame rising from `base`; `boost` makes it flare.
flame :: proc(base: [2]f32, width: f32, height, boost: fx.Expr) -> ^fx.Node {
	p := fx.sub(fx.coord(), base)
	x := fx.swizzle(p, "x")
	up := fx.neg(fx.swizzle(p, "y"))
	k := fx.saturate(fx.div(up, height))
	turbulence := fx.fbm(fx.vec2(fx.mul(x, 0.18), fx.mul(fx.add(up, fx.mul(fx.time(), -45)), 0.11)), 4)
	sway := fx.mul(fx.sub(turbulence, 0.5), fx.mul(k, 10))
	half_width := fx.mul(fx.sub(1, fx.pow(k, 1.6)), width)
	across := fx.div(fx.abs(fx.add(x, sway)), fx.max(half_width, 0.5))
	body := fx.mul(fx.saturate(fx.sub(1, across)), fx.step(0, up))
	heat := fx.saturate(fx.mul(fx.mul(body, fx.add(fx.mul(turbulence, 1.4), 0.2)), fx.add(fx.sub(1.2, k), boost)))
	return fx.mask(fx.ramp(heat, FLAME_RED, FLAME_ORANGE, FLAME_YELLOW, FLAME_WHITE), fx.smoothstep(0.08, 0.3, heat))
}

// Brazier on a stone pillar; the flame grows with each level.
fire_tower_look :: proc(level, fire_time: fx.Expr) -> ^fx.Node {
	p := fx.coord()
	flare := fx.exp(fx.mul(fx.sub(fx.time(), fire_time), -6))

	pillar := fx.sd_box(fx.sub(p, [2]f32{0, -2}), [2]f32{8, 10}, 2)
	stone, relief := masonry(p, {8, 5}, TOWER_STONE, MORTAR, 2.7)
	bowl := sd_ellipse(p, {0, -13}, {14, 6})
	iron := fx.gradient(fx.swizzle(fx.uv(), "y"), IRON_LIGHT, IRON)
	coals_d := sd_ellipse(p, {0, -15}, {11, 3.2})
	coal_heat := fx.fbm(fx.add(fx.mul(p, 0.3), fx.mul(fx.time(), 0.5)), 3)
	coals := fx.mask(fx.ramp(fx.add(coal_heat, fx.mul(flare, 0.3)), EMBER, FLAME_RED, FLAME_ORANGE), fx.fill(coals_d))
	glow := fx.mask(FLAME_ORANGE, fx.mul(fx.glow(coals_d, 10), fx.add(0.25, fx.mul(flare, 0.5))))
	flame_height := fx.sum(12, fx.mul(level, 6), fx.mul(flare, 8))

	return fx.stack(
		tower_base(1.7),
		solid(pillar, stone, fx.add(fx.mul(bevel(pillar, 3), 3), relief), {specular = 0.1}),
		glow,
		solid(bowl, iron, fx.mul(bevel(bowl, 4), 3), {specular = 0.6, shininess = 30}),
		coals,
		flame({0, -15}, 10, flame_height, flare),
		level_pips(level, FLAME_ORANGE),
	)
}

// Cluster of faceted ice crystals; levels 2 and 3 grow extra crystals.
ice_tower_look :: proc(level, fire_time: fx.Expr) -> ^fx.Node {
	p := fx.coord()
	flare := fx.exp(fx.mul(fx.sub(fx.time(), fire_time), -6))
	crystal :: proc(p: fx.Expr, center, half: [2]f32, tilt: f32) -> ^fx.Node {
		return sd_diamond(fx.rotate(fx.sub(p, center), tilt), half)
	}
	// Crystals of higher levels are pushed far away until the tower reaches that level.
	grown :: proc(d: ^fx.Node, level: fx.Expr, min_level: f32) -> ^fx.Node {
		return fx.add(d, fx.mul(fx.sub(1, fx.step(min_level - 0.5, level)), 1000))
	}
	crystals := fx.min(
		fx.min(crystal(p, {0, -12}, {9, 24}, 0), grown(crystal(p, {-11, -2}, {5, 14}, -0.45), level, 2)),
		fx.min(
			grown(crystal(p, {11, -2}, {5, 14}, 0.45), level, 2),
			fx.min(grown(crystal(p, {-6, 5}, {3.5, 9}, -0.9), level, 3), grown(crystal(p, {7, 5}, {3.5, 9}, 0.8), level, 3)),
		),
	)
	depth := fx.saturate(fx.div(fx.neg(crystals), 10))
	frost := fx.fbm(fx.mul(p, 0.12), 3)
	color := fx.ramp(fx.saturate(fx.add(fx.mul(frost, 0.7), fx.mul(depth, 0.6))), ICE_DEEP, ICE_BLUE, ICE_WHITE)
	facets := fx.mul(fx.saturate(fx.div(fx.neg(crystals), 6)), 6)
	aura := fx.mask(ICE_BLUE, fx.mul(fx.glow(crystals, 6), fx.add(0.25, fx.mul(flare, 0.6))))

	return fx.stack(
		tower_base(2.3),
		aura,
		solid(crystals, color, facets, {strength = 1.3, specular = 1.2, shininess = 40}),
		level_pips(level, ICE_BLUE),
	)
}

// Crackling field around an orb center: thin filaments where animated noise crosses 0.5.
crackle :: proc(center: fx.Expr, orb_d: fx.Expr, reach, intensity: fx.Expr) -> ^fx.Node {
	flicker := fx.floor(fx.mul(fx.time(), 14))
	field := fx.fbm(fx.add(fx.mul(fx.sub(fx.coord(), center), 0.09), fx.mul(fx.vec2(flicker, fx.mul(flicker, 1.7)), 0.37)), 3)
	filament := fx.exp(fx.mul(fx.abs(fx.sub(field, 0.5)), -45))
	falloff := fx.exp(fx.div(fx.neg(fx.max(orb_d, 0)), reach))
	k := fx.saturate(fx.mul(fx.mul(filament, falloff), intensity))
	return fx.mask(fx.mix(VOLT_BLUE, VOLT_WHITE, k), k)
}

// Tesla coil: iron pole, copper rings and a crackling orb that grows with each level.
lightning_tower_look :: proc(level, fire_time: fx.Expr) -> ^fx.Node {
	p := fx.coord()
	flare := fx.exp(fx.mul(fx.sub(fx.time(), fire_time), -8))

	pole := fx.sd_box(fx.sub(p, [2]f32{0, -6}), [2]f32{3.5, 14}, 1.5)
	iron := fx.gradient(fx.swizzle(fx.uv(), "x"), IRON_LIGHT, IRON)
	rings := fx.min(sd_ellipse(p, {0, 6}, {9, 2.6}), fx.min(sd_ellipse(p, {0, -2}, {8, 2.4}), sd_ellipse(p, {0, -10}, {7, 2.2})))
	copper := fx.gradient(fx.swizzle(fx.uv(), "x"), COPPER_LIGHT, COPPER)

	orb_center := [2]f32{0, -24}
	orb_offset := fx.sub(p, orb_center)
	orb_r := fx.add(4, level)
	orb_d := fx.sub(fx.length(orb_offset), orb_r)
	swirl := fx.fbm(fx.add(fx.mul(orb_offset, 0.4), fx.mul(fx.time(), [2]f32{2, -3})), 3)
	core := fx.ramp(fx.saturate(fx.add(swirl, fx.sub(0.6, fx.div(fx.length(orb_offset), orb_r)))), VOLT_VIOLET, VOLT_BLUE, VOLT_WHITE)
	halo := fx.mask(VOLT_VIOLET, fx.mul(fx.glow(orb_d, 6), fx.add(0.5, flare)))

	return fx.stack(
		tower_base(3.9),
		solid(pole, iron, fx.mul(bevel(pole, 3), 3), {specular = 0.7}),
		solid(rings, copper, fx.mul(bevel(rings, 2), 2), {specular = 0.9, shininess = 30}),
		halo,
		fx.mask(core, fx.fill(orb_d)),
		crackle(orb_center, orb_d, fx.mix(5, 10, flare), fx.add(0.8, fx.mul(flare, 1.5))),
		level_pips(level, VOLT_BLUE),
	)
}

tower_look :: proc(kind: TowerKind, level, fire_time: fx.Expr) -> ^fx.Node {
	switch kind {
	case .Fire:
		return fire_tower_look(level, fire_time)
	case .Ice:
		return ice_tower_look(level, fire_time)
	case .Lightning:
		return lightning_tower_look(level, fire_time)
	}
	unreachable()
}

// A placed (or shop preview) tower, driven by params: level (1..3), fire_time.
placed_tower_look :: proc(kind: TowerKind) -> ^fx.Node {
	return tower_look(kind, fx.param("level", f32(1)), fx.param("fire_time", f32(-100)))
}

// Translucent preview while placing; tinted red where it can't be built (`valid` = 0).
ghost_tower_look :: proc(kind: TowerKind) -> ^fx.Node {
	tint := fx.mix(INVALID_RED, WHITE, fx.param("valid", f32(1)))
	return fx.mask(fx.shade(tower_look(kind, f32(1), f32(-100)), tint), 0.6)
}

cell_highlight_look :: proc() -> ^fx.Node {
	d := fx.sd_box(fx.coord(), CELL / 2 - 2, 5)
	color := fx.mix(INVALID_RED, VALID_GREEN, fx.param("valid", f32(1)))
	return fx.stack(fx.mask(color, fx.mul(fx.fill(d), 0.18)), fx.mask(color, fx.mul(fx.stroke(d, 2), 0.9)))
}

// Translucent disc with a slowly turning dashed rim; the radius follows the entity size.
range_look :: proc() -> ^fx.Node {
	p := fx.coord()
	d := fx.sub(fx.length(p), fx.mul(fx.swizzle(fx.size(), "x"), 0.5))
	dash := fx.step(0.5, fx.fract(fx.add(fx.mul(fx.angle(p), 48 / (2 * math.PI)), fx.mul(fx.time(), 0.6))))
	ring := fx.mul(fx.stroke(d, 2), fx.add(0.35, fx.mul(dash, 0.65)))
	return fx.mask(RANGE_WHITE, fx.max(ring, fx.mul(fx.fill(d), 0.08)))
}

// ---------------------------------------------------------------------------------------
// Projectiles and effects

// Glowing streak behind a projectile, opposite to its `velocity` param.
trail :: proc(color: rl.Color, length, width: f32) -> ^fx.Node {
	velocity := fx.param("velocity", [2]f32{0, 0})
	d := fx.sub(fx.sd_segment(fx.coord(), [2]f32{0, 0}, fx.mul(velocity, -length)), width)
	return fx.mask(color, fx.mul(fx.glow(d, 4), 0.7))
}

fireball_look :: proc() -> ^fx.Node {
	p := fx.coord()
	d := fx.sd_circle(p, 5)
	swirl := fx.fbm(fx.add(fx.mul(p, 0.4), fx.mul(fx.time(), [2]f32{3, -2})), 3)
	core := fx.ramp(fx.saturate(fx.add(swirl, fx.sub(0.8, fx.div(fx.length(p), 5)))), FLAME_RED, FLAME_ORANGE, FLAME_YELLOW, FLAME_WHITE)
	return fx.stack(trail(FLAME_ORANGE, 0.06, 2.5), fx.mask(FLAME_ORANGE, fx.mul(fx.glow(d, 5), 0.8)), fx.mask(core, fx.fill(d)))
}

// Points along +x; the entity is rotated to its flight direction.
ice_shard_look :: proc() -> ^fx.Node {
	p := fx.coord()
	d := sd_diamond(p, {9, 3.2})
	color := fx.gradient(fx.swizzle(fx.uv(), "y"), ICE_WHITE, ICE_BLUE)
	streak := fx.sub(fx.sd_segment(p, [2]f32{0, 0}, [2]f32{-24, 0}), 1)
	return fx.stack(
		fx.mask(ICE_BLUE, fx.mul(fx.glow(streak, 3), 0.5)),
		fx.mask(ICE_BLUE, fx.mul(fx.glow(d, 4), 0.6)),
		solid(d, color, fx.mul(fx.saturate(fx.div(fx.neg(d), 3)), 3), {specular = 1.2, shininess = 40}),
	)
}

spark_orb_look :: proc() -> ^fx.Node {
	p := fx.coord()
	d := fx.sd_circle(p, 4)
	core := fx.mix(VOLT_BLUE, VOLT_WHITE, fx.saturate(fx.sub(1, fx.div(fx.length(p), 4))))
	return fx.stack(
		trail(VOLT_VIOLET, 0.03, 1.5),
		fx.mask(VOLT_VIOLET, fx.mul(fx.glow(d, 5), 0.9)),
		crackle([2]f32{0, 0}, d, f32(5), f32(1.2)),
		fx.mask(core, fx.fill(d)),
	)
}

// Jagged arc along the entity's x axis, pinned at both ends; flickers and fades fast.
bolt_look :: proc(seed: f32) -> ^fx.Node {
	p := fx.coord()
	x := fx.swizzle(p, "x")
	half := fx.mul(fx.swizzle(fx.size(), "x"), 0.5)
	taper := fx.saturate(fx.sub(1, fx.pow(fx.div(fx.abs(x), half), 4)))
	jitter := fx.floor(fx.mul(fx.time(), 30))
	offset := fx.mul(fx.sub(fx.fbm(fx.vec2(fx.mul(x, 0.05), fx.add(fx.mul(jitter, 1.3), seed)), 4), 0.5), fx.mul(taper, 26))
	d := fx.abs(fx.sub(fx.swizzle(p, "y"), offset))
	core := fx.exp(fx.mul(fx.mul(d, d), -0.8))
	glow := fx.exp(fx.div(d, -5))
	fade := fx.sub(1, fx.smoothstep(0.05, 0.2, fx.age()))
	return fx.mask(fx.mix(VOLT_VIOLET, VOLT_WHITE, fx.saturate(core)), fx.saturate(fx.mul(fx.add(core, fx.mul(glow, 0.6)), fade)))
}

// Burst of sparks with an expanding ring.
impact_look :: proc(color: rl.Color, seed: f32) -> ^fx.Node {
	t := fx.age()
	sparks := fx.sparks({seed = seed, speed = 160, gravity = 260, life = 0.45, radius = 1.3, color = color, count = 12})
	ring := fx.mul(fx.stroke(fx.sd_circle(fx.coord(), fx.mul(t, 110)), 2.5), fx.exp(fx.mul(t, -9)))
	return fx.stack(sparks, fx.mask(color, ring))
}

dust_puff :: proc(center: [2]f32, color: rl.Color, seed: f32) -> ^fx.Node {
	t := fx.age()
	dist := fx.length(fx.sub(fx.coord(), center))
	puff := fx.sub(1, fx.smoothstep(0, fx.add(8, fx.mul(t, 70)), dist))
	billow := fx.fbm(fx.add(fx.mul(fx.coord(), 0.06), fx.add(seed, fx.mul(t, 0.7))), 4)
	return fx.mask(color, fx.saturate(fx.mul(fx.mul(fx.mul(puff, billow), fx.exp(fx.mul(t, -3))), 1.3)))
}

// Dust and rising sparkles when a tower is built or upgraded.
build_look :: proc(color: rl.Color, seed: f32) -> ^fx.Node {
	sparkles := fx.sparks({origin = [2]f32{0, 10}, spread = 0.9, seed = seed, speed = 200, gravity = 150, life = 0.7, radius = 1.4, color = color, count = 18})
	return fx.stack(dust_puff({0, 14}, TOWER_STONE, seed), sparkles)
}

// ---------------------------------------------------------------------------------------
// Interface

panel_look :: proc() -> ^fx.Node {
	p := fx.coord()
	texture := fx.fbm(fx.mul(p, 0.03), 4)
	base := fx.shade(fx.gradient(fx.swizzle(fx.uv(), "y"), PANEL_LIGHT, PANEL_DARK), fx.add(0.8, fx.mul(texture, 0.4)))
	frame := fx.sd_box(p, fx.mul(fx.size(), 0.5))
	return fx.lit(base, fx.add(fx.mul(bevel(frame, 6), 4), fx.mul(texture, 1.5)), {specular = 0.05})
}

// Bevelled button driven by params: hover, enabled, selected.
button_look :: proc() -> ^fx.Node {
	p := fx.coord()
	d := fx.sd_box(p, fx.sub(fx.mul(fx.size(), 0.5), 1), 6)
	hover := fx.param("hover", f32(0))
	selected := fx.param("selected", f32(0))
	brightness := fx.mul(fx.mix(0.45, 1, fx.param("enabled", f32(1))), fx.add(1, fx.mul(hover, 0.25)))
	base := fx.shade(fx.gradient(fx.swizzle(fx.uv(), "y"), BUTTON_TOP, BUTTON_BOTTOM), brightness)
	body := fx.mask(fx.lit(base, fx.mul(bevel(d, 4), 3), {specular = 0.25}), fx.fill(d))
	border := fx.mask(fx.mix(OUTLINE, SELECTED_GOLD, selected), fx.stroke(d, fx.mix(1.5, 2.5, selected)))
	halo := fx.mask(SELECTED_GOLD, fx.mul(fx.mul(fx.glow(d, 6), selected), 0.5))
	return fx.stack(halo, body, border)
}

coin_look :: proc() -> ^fx.Node {
	p := fx.coord()
	d := fx.sd_circle(p, 8)
	color := fx.gradient(fx.swizzle(fx.uv(), "y"), COIN_GOLD, COIN_DARK)
	height := fx.add(fx.mul(bevel(d, 2), 2), fx.mul(fx.stroke(fx.add(d, 3), 1.2), 1.2))
	return solid(d, color, height, {specular = 1, shininess = 30})
}

heart_look :: proc() -> ^fx.Node {
	p := fx.coord()
	lobes := fx.min(fx.sd_circle(fx.sub(p, [2]f32{-3.6, -2.2}), 4.4), fx.sd_circle(fx.sub(p, [2]f32{3.6, -2.2}), 4.4))
	d := fx.min(lobes, sd_diamond(fx.sub(p, [2]f32{0, 0.8}), {7.8, 7.6}))
	return solid(d, HEART_RED, fx.mul(bevel(d, 4), 3), {specular = 0.8, shininess = 30})
}
