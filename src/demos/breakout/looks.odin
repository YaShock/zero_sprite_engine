package main

// Looks: every visual in the demo is a composition of vfx functions and parameters.

import fx "../../engine/vfx"
import rl "vendor:raylib"

BrickKind :: enum {
	Crystal,
	Metal,
	Lava,
	Moss,
	Sandstone,
	Clay,
}

// Color of the debris, sparks and dust a brick produces when it breaks.
// A variable rather than a constant: Odin can't index a constant array with a runtime value.
BRICK_DEBRIS_COLOR := [BrickKind]rl.Color {
	.Crystal   = ICE_BLUE,
	.Metal     = AMBER,
	.Lava      = LAVA_ORANGE,
	.Moss      = LIME,
	.Sandstone = SAND,
	.Clay      = SALMON,
}

// Albedo and relief of a brick material, before the shared bevel, cracks and lighting.
Surface :: struct {
	color:    ^fx.Node,
	height:   ^fx.Node,
	light:    fx.Light,
	emissive: ^fx.Node, // optional; composited on top after lighting
}

// Height ramp from 0 at the shape's edge to 1 at `width` units inside it.
bevel :: proc(d: fx.Expr, width: f32) -> ^fx.Node {
	return fx.sub(1, fx.smoothstep(-width, 0, d))
}

brick_surface :: proc(kind: BrickKind, seed: f32) -> Surface {
	// Every brick samples a different region of the same infinite pattern.
	p := fx.add(fx.coord(), [2]f32{seed * 37.1, seed * 11.3})

	switch kind {
	case .Crystal:
		cells := fx.mul(p, 0.06)
		facets := fx.mul(fx.saturate(fx.mul(fx.voronoi_edge(cells), 3)), 4)
		hue := fx.sum(fx.mul(fx.voronoi(cells), 0.5), fx.mul(fx.time(), 0.05), seed * 0.1)
		return {
			color = fx.palette(hue, [4]f32{0.45, 0.55, 0.85, 1}, [4]f32{0.25, 0.3, 0.2, 1}, [4]f32{1, 1, 1, 1}, [4]f32{0, 0.1, 0.2, 1}),
			height = facets,
			light = {strength = 1.2, specular = 1.2, shininess = 48},
		}

	case .Metal:
		steel := fx.gradient(fx.swizzle(fx.uv(), "y"), STEEL_LIGHT, STEEL_DARK)
		brushed := fx.noise(fx.mul(p, [2]f32{0.02, 1.1}))
		steel = fx.shade(steel, fx.add(0.85, fx.mul(brushed, 0.3)))
		rust := fx.smoothstep(0.5, 0.62, fx.fbm(fx.mul(p, 0.045)))
		rust_color := fx.gradient(fx.fbm(fx.mul(p, 0.2), 3), RUST_DARK, RUST_LIGHT)
		// A rivet dome near each corner.
		corner := fx.sub(fx.abs(fx.coord()), fx.sub(fx.mul(fx.size(), 0.5), 7))
		rivet := fx.sub(1, fx.smoothstep(0, 3, fx.length(corner)))
		return {
			color = fx.mix(steel, rust_color, rust),
			height = fx.sum(fx.mul(rivet, 3), fx.mul(rust, 0.8), fx.mul(brushed, 0.2)),
			light = {specular = fx.mix(0.9, 0.05, rust), shininess = 30},
		}

	case .Lava:
		drift := fx.mul(fx.time(), 0.15)
		warp := fx.mul(fx.vec2(fx.fbm(fx.add(fx.mul(p, 0.03), drift), 3), fx.fbm(fx.add(fx.mul(p, 0.03), 7.3), 3)), 2)
		cracks := fx.voronoi_edge(fx.add(fx.mul(p, 0.05), warp))
		heat := fx.exp(fx.mul(cracks, -14))
		pulse := fx.add(0.8, fx.mul(fx.sin(fx.add(fx.mul(fx.time(), 3), seed)), 0.2))
		rock := fx.shade(BASALT, fx.add(0.6, fx.fbm(fx.mul(p, 0.15), 4)))
		return {
			color = rock,
			height = fx.add(fx.mul(fx.saturate(fx.mul(cracks, 6)), 2.5), fx.fbm(fx.mul(p, 0.2), 3)),
			light = {specular = 0.2},
			emissive = fx.mask(fx.gradient(heat, MAGMA_RED, MAGMA_YELLOW), fx.mul(heat, pulse)),
		}

	case .Moss:
		grain := fx.fbm(fx.mul(p, 0.08))
		stone := fx.shade(STONE_GRAY, fx.add(0.65, fx.mul(grain, 0.6)))
		// Moss gathers towards the top edge.
		lean := fx.mul(fx.sub(0.5, fx.swizzle(fx.uv(), "y")), 0.6)
		moss := fx.smoothstep(0.45, 0.6, fx.add(fx.fbm(fx.mul(p, 0.07)), lean))
		tufts := fx.noise(fx.mul(p, 0.5))
		moss_color := fx.gradient(tufts, MOSS_DARK, MOSS_LIGHT)
		return {
			color = fx.mix(stone, moss_color, moss),
			height = fx.sum(fx.mul(grain, 2), fx.mul(moss, 1.5), fx.mul(fx.mul(tufts, moss), 0.8)),
			light = {specular = 0.1},
		}

	case .Sandstone:
		// Sediment layers, bent by low-frequency noise.
		y := fx.add(fx.swizzle(p, "y"), fx.mul(fx.fbm(fx.mul(p, 0.04), 4), 18))
		strata := fx.add(0.5, fx.mul(fx.sin(fx.mul(y, 0.55)), 0.5))
		grain := fx.noise(fx.mul(p, 0.9))
		color := fx.gradient(strata, SANDSTONE_DARK, SANDSTONE_LIGHT)
		return {
			color = fx.shade(color, fx.add(0.9, fx.mul(grain, 0.15))),
			height = fx.add(strata, fx.mul(grain, 0.4)),
			light = {specular = 0.05},
		}

	case .Clay:
		base := fx.gradient(fx.hash(seed), CLAY_DARK, CLAY_LIGHT)
		speck := fx.step(0.8, fx.noise(fx.mul(p, 0.6)))
		grain := fx.fbm(fx.mul(p, 0.1), 4)
		color := fx.shade(base, fx.add(0.8, fx.mul(grain, 0.3)))
		return {
			color = fx.mix(color, CLAY_SPECK, fx.mul(speck, 0.6)),
			height = fx.sub(fx.mul(grain, 1.5), fx.mul(speck, 0.5)),
			light = {specular = 0.1},
		}
	}
	unreachable()
}

// A rounded, bevelled brick that cracks with `damage` (0..1) and flashes white at `hit_time`.
brick_look :: proc(kind: BrickKind, seed: f32, damage, hit_time: fx.Expr) -> ^fx.Node {
	d := fx.sd_box(fx.coord(), fx.sub(fx.mul(fx.size(), 0.5), 1.5), 4)
	s := brick_surface(kind, seed)

	color := fx.lit(s.color, fx.add(fx.mul(bevel(d, 5), 3), s.height), s.light)
	if s.emissive != nil {
		color = fx.over(s.emissive, color)
	}

	// Cracks: borders of a noise-warped cellular pattern.
	warped := fx.add(fx.mul(fx.coord(), 0.07), fx.mul(fx.fbm(fx.mul(fx.coord(), 0.1), 3), 0.8))
	crack_lines := fx.sub(1, fx.smoothstep(0.02, 0.07, fx.voronoi_edge(fx.add(warped, seed))))
	color = fx.shade(color, fx.sub(1, fx.mul(fx.mul(crack_lines, damage), 0.8)))

	flash := fx.exp(fx.mul(fx.sub(fx.time(), hit_time), -9))
	color = fx.mix(color, FLASH_WHITE, fx.mul(flash, 0.8))
	return fx.mask(color, fx.fill(d))
}

// The brick bursting into shards, dust, sparks and a shock ring, all driven by age().
explosion_look :: proc(kind: BrickKind, seed: f32, impact: [2]f32) -> ^fx.Node {
	t := fx.age()
	debris := BRICK_DEBRIS_COLOR[kind]
	fade := fx.sub(1, fx.smoothstep(0.5, 1.1, t))

	brick := brick_look(kind, seed, f32(0.6), f32(-100))
	shards := fx.shatter(brick, {impact = impact, seed = seed, speed = 230, gravity = 900, spin = 6, cols = 4, rows = 2})
	flash := fx.add(1, fx.mul(fx.exp(fx.mul(t, -14)), 1.5))
	shards = fx.mask(fx.shade(shards, flash), fade)

	dist := fx.length(fx.sub(fx.coord(), impact))
	puff_radius := fx.add(14, fx.mul(t, 90))
	puff := fx.sub(1, fx.smoothstep(0, puff_radius, dist))
	density := fx.mul(fx.mul(puff, fx.fbm(fx.add(fx.mul(fx.coord(), 0.05), fx.add(seed, fx.mul(t, 0.8))), 4)), fx.exp(fx.mul(t, -3)))
	dust := fx.mask(fx.shade(debris, 0.6), fx.mul(density, 0.9))

	sparks := fx.sparks({origin = impact, seed = seed, speed = 380, gravity = 700, life = 0.7, radius = 1.6, color = debris, count = 28})

	ring_radius := fx.mul(t, 320)
	ring := fx.mul(fx.stroke(fx.sd_circle(fx.sub(fx.coord(), impact), ring_radius), 5), fx.exp(fx.mul(t, -7)))

	return fx.stack(dust, shards, sparks, fx.mask(WARM_WHITE, ring))
}

// Running-bond brick wall in world space, lit by a point light (the ball).
wall_background_look :: proc() -> ^fx.Node {
	p := fx.world()
	cell := [2]f32{64, 28}
	local := fx.brick_local(p, cell)
	d := fx.sd_box(local, [2]f32{29.5, 11.5}, 3)

	tone := fx.hash(fx.brick_id(p, cell))
	brick := fx.gradient(tone, WALL_BRICK_DARK, WALL_BRICK_LIGHT)
	brick = fx.shade(brick, fx.add(0.55, fx.mul(fx.fbm(fx.mul(p, 0.012)), 0.7)))
	mortar := fx.shade(MORTAR, fx.add(0.6, fx.mul(fx.noise(fx.mul(p, 0.3)), 0.4)))
	color := fx.mix(mortar, brick, fx.fill(d))

	light := fx.param("light", [2]f32{480, 400})
	to_light := fx.sub(light, p)
	dist := fx.length(to_light)
	height := fx.add(fx.mul(bevel(d, 4), 3), fx.mul(fx.fbm(fx.mul(p, 0.09), 4), 1.5))
	color = fx.lit(color, height, {strength = 1.5, specular = 0.15, direction = fx.div(to_light, fx.max(dist, 1))})

	falloff := fx.add(0.2, fx.mul(fx.exp(fx.mul(dist, -1.0 / 260)), 0.9))
	centered := fx.sub(fx.uv(), 0.5)
	vignette := fx.sub(1, fx.mul(fx.dot(centered, centered), 1.2))
	return fx.shade(color, fx.mul(falloff, vignette))
}

// Riveted steel pipe; `vertical` picks the axis it runs along.
pipe_look :: proc(vertical: bool) -> ^fx.Node {
	p := fx.coord()
	half := fx.mul(fx.size(), 0.5)
	across_axis, along_axis := "y", "x"
	if vertical {
		across_axis, along_axis = "x", "y"
	}
	across := fx.div(fx.swizzle(p, across_axis), fx.swizzle(half, across_axis)) // -1..1
	along := fx.swizzle(p, along_axis)

	tube := fx.pow(fx.saturate(fx.sub(1, fx.mul(across, across))), 0.5)
	joint := fx.sub(1, fx.smoothstep(2, 4, fx.abs(fx.swizzle(fx.tile(fx.vec2(along, 0), [2]f32{90, 1}), "x"))))
	color := fx.shade(PIPE_STEEL, fx.add(0.7, fx.mul(fx.fbm(fx.mul(p, 0.08), 4), 0.5)))
	return fx.lit(color, fx.add(fx.mul(tube, 6), fx.mul(joint, 2)), {specular = 0.7, shininess = 28})
}

// Steel capsule with a flowing energy core that surges at `hit_time`.
paddle_look :: proc() -> ^fx.Node {
	p := fx.coord()
	half := fx.mul(fx.size(), 0.5)
	d := fx.sd_box(p, half, fx.swizzle(half, "y"))

	shell := fx.gradient(fx.swizzle(fx.uv(), "y"), CHROME_LIGHT, CHROME_DARK)
	height := fx.add(fx.mul(bevel(d, 7), 4), fx.mul(fx.noise(fx.mul(p, [2]f32{0.03, 1.5})), 0.3))
	body := fx.mask(fx.lit(shell, height, {specular = 1, shininess = 36}), fx.fill(d))

	hit := fx.exp(fx.mul(fx.sub(fx.time(), fx.param("hit_time", f32(-100))), -6))
	slot := fx.sd_box(p, fx.sub(half, [2]f32{16, 6}), 2)
	flow := fx.noise(fx.vec2(fx.sub(fx.mul(fx.swizzle(p, "x"), 0.12), fx.mul(fx.time(), 6)), fx.mul(fx.swizzle(p, "y"), 0.5)))
	energy := fx.gradient(fx.saturate(fx.add(flow, hit)), ENERGY_BLUE, ENERGY_WHITE)
	core := fx.mask(energy, fx.fill(slot))

	aura := fx.mask(ENERGY_AURA, fx.mul(fx.glow(d, 7), fx.add(0.25, fx.mul(hit, 0.5))))
	return fx.stack(aura, body, core)
}

// Swirling plasma orb with a halo and a motion trail opposite to `velocity`.
ball_look :: proc(radius: f32) -> ^fx.Node {
	p := fx.coord()
	d := fx.sd_circle(p, radius)

	velocity := fx.param("velocity", [2]f32{0, 0})
	trail_d := fx.sub(fx.sd_segment(p, [2]f32{0, 0}, fx.mul(velocity, -0.05)), radius * 0.5)
	trail := fx.mask(TRAIL_ORANGE, fx.mul(fx.glow(trail_d, 4), 0.55))

	r := fx.div(fx.length(p), radius)
	swirl := fx.fbm(fx.add(fx.mul(p, 0.25), fx.mul(fx.time(), [2]f32{1.7, -1.1})), 4)
	hot := fx.gradient(fx.saturate(fx.add(swirl, fx.sub(0.6, r))), PLASMA_OUTER, PLASMA_CORE)
	dome := fx.mul(fx.pow(fx.saturate(fx.sub(1, fx.mul(r, r))), 0.5), radius * 0.8)
	body := fx.mask(fx.lit(hot, dome, {specular = 0.9, shininess = 32}), fx.fill(d))

	halo := fx.mask(PLASMA_HALO, fx.mul(fx.glow(d, radius * 0.8), 0.7))
	return fx.stack(trail, halo, body)
}

// Expanding ring, e.g. when the ball is lost.
shockwave_look :: proc(color: rl.Color, speed: f32) -> ^fx.Node {
	fade := fx.exp(fx.mul(fx.age(), -3))
	ring := fx.stroke(fx.sd_circle(fx.coord(), fx.mul(fx.age(), speed)), fx.mul(fade, 14))
	return fx.mask(color, fx.mul(ring, fade))
}

spark_burst_look :: proc(color: rl.Color, direction, spread, seed: f32, count: int) -> ^fx.Node {
	return fx.sparks({direction = direction, spread = spread, seed = seed, speed = 260, gravity = 700, life = 0.5, radius = 1.4, color = color, count = count})
}

hud_band_look :: proc() -> ^fx.Node {
	fade := fx.smoothstep(0.7, 1, fx.swizzle(fx.uv(), "y"))
	return fx.mask(NIGHT_BLACK, fx.sub(0.85, fx.mul(fade, 0.5)))
}
