package main

// Looks: every visual in the demo is a composition of vfx functions and parameters.

import fx "../../engine/vfx"
import "core:math"
import rl "vendor:raylib"

// Height ramp from 0 at the shape's edge to 1 at `width` units inside it.
bevel :: proc(d: fx.Expr, width: f32) -> ^fx.Node {
	return fx.sub(1, fx.smoothstep(-width, 0, d))
}

// Coverage of random dots on a jittered grid; `density` is the fraction of cells with a dot.
scatter :: proc(p: fx.Expr, cell, radius, density, seed: f32) -> ^fx.Node {
	id := fx.cell_id(p, cell)
	jitter := fx.vec2(fx.hash(fx.add(id, seed)), fx.hash(fx.add(id, seed + 7.7)))
	local := fx.sub(fx.tile(p, cell), fx.mul(fx.sub(jitter, 0.5), cell - 2 * radius))
	present := fx.step(1 - density, fx.hash(fx.add(id, seed + 3.3)))
	return fx.mul(present, fx.fill(fx.sub(fx.length(local), radius)))
}

// ---------------------------------------------------------------------------------------
// Space

// One layer of twinkling stars: soft points on a jittered grid, each between 0.4 and 1x
// `radius` (most of them small).
star_layer :: proc(p: fx.Expr, cell, radius, density, seed: f32, color: rl.Color) -> ^fx.Node {
	id := fx.cell_id(p, cell)
	jitter := fx.vec2(fx.hash(fx.add(id, seed)), fx.hash(fx.add(id, seed + 7.7)))
	local := fx.sub(fx.tile(p, cell), fx.mul(fx.sub(jitter, 0.5), cell - 8 * radius))
	size := fx.mul(fx.add(0.4, fx.mul(fx.pow(fx.hash(fx.add(id, seed + 5.9)), 3), 0.6)), radius)
	present := fx.step(1 - density, fx.hash(fx.add(id, seed + 3.3)))
	rate := fx.hash(fx.add(id, seed + 9.1))
	twinkle := fx.add(0.65, fx.mul(fx.sin(fx.add(fx.mul(fx.time(), fx.add(1.5, fx.mul(rate, 3))), fx.mul(rate, 6.28))), 0.35))
	d := fx.div(fx.length(local), size)
	brightness := fx.add(fx.exp(fx.neg(fx.mul(d, d))), fx.mul(fx.exp(fx.div(d, -2)), 0.12))
	return fx.mask(color, fx.saturate(fx.mul(fx.mul(present, twinkle), brightness)))
}

// Deep space: warped nebula clouds with dark dust lanes, three star layers and a sun
// glowing in from off-screen.
space_look :: proc(nebula_a, nebula_b: rl.Color, sun: [2]f32, seed: f32) -> ^fx.Node {
	p := fx.world()
	q := fx.add(p, [2]f32{seed * 91.7, seed * 37.3})

	warp := fx.mul(fx.vec2(fx.fbm(fx.mul(q, 0.002), 4), fx.fbm(fx.add(fx.mul(q, 0.002), 5.2), 4)), 300)
	clouds := fx.smoothstep(0.42, 0.8, fx.fbm(fx.mul(fx.add(q, warp), 0.003), 5))
	dust := fx.smoothstep(0.55, 0.72, fx.fbm(fx.mul(q, 0.006), 3))
	tint := fx.mix(nebula_a, nebula_b, fx.fbm(fx.mul(q, 0.006), 3))
	nebula := fx.mask(tint, fx.mul(fx.mul(clouds, fx.sub(1, fx.mul(dust, 0.8))), 0.4))

	to_sun := fx.sub(fx.length(fx.sub(p, sun)), 40)
	sun_glow := fx.mask(SUN_GLOW, fx.mul(fx.glow(to_sun, 260), 0.35))
	sun_core := fx.mask(SUN_CORE, fx.mul(fx.glow(to_sun, 60), 0.6))

	return fx.stack(
		SPACE_BLACK,
		nebula,
		star_layer(q, 23, 0.8, 0.35, 1.1, STAR_WHITE),
		star_layer(q, 53, 1.3, 0.3, 4.7, STAR_BLUE),
		star_layer(q, 97, 1.8, 0.3, 8.3, STAR_GOLD),
		sun_glow,
		sun_core,
	)
}

// Lumpy cratered rock; `light` is the light direction in the rock's own (rotating) frame.
asteroid_look :: proc(radius, seed: f32) -> ^fx.Node {
	p := fx.coord()
	q := fx.add(p, seed * 17.3)
	lumps := fx.add(fx.mul(fx.sub(fx.noise(fx.mul(q, 2.4 / radius)), 0.5), radius * 0.5), fx.mul(fx.sub(fx.noise(fx.mul(q, 6 / radius)), 0.5), radius * 0.15))
	d := fx.add(fx.sd_circle(p, radius), lumps)
	craters := fx.sub(1, fx.smoothstep(0, 0.3, fx.voronoi(fx.mul(q, 2.5 / radius))))
	color := fx.mix(ASTEROID_DARK, ASTEROID_ROCK, fx.fbm(fx.mul(q, 0.15), 3))
	color = fx.shade(color, fx.sub(1, fx.mul(craters, 0.35)))
	height := fx.sub(fx.mul(bevel(d, radius * 0.8), radius * 0.6), fx.mul(craters, radius * 0.15))
	light := fx.param("light", [2]f32{-0.6, -0.8})
	return fx.mask(fx.lit(color, height, {specular = 0.1, direction = light}), fx.fill(d))
}

// A torn metal plate with a glinting edge.
debris_look :: proc(seed: f32) -> ^fx.Node {
	p := fx.coord()
	d := fx.sd_convex_polygon(p, {{-5, -3}, {4, -4}, {6, 1}, {1, 4}, {-6, 2}})
	plate := fx.shade(DEBRIS_METAL, fx.add(0.7, fx.mul(fx.noise(fx.mul(fx.add(p, seed), [2]f32{0.2, 1.4})), 0.4)))
	light := fx.param("light", [2]f32{-0.6, -0.8})
	return fx.mask(fx.lit(plate, fx.mul(bevel(d, 1.5), 1.5), {specular = 1.2, shininess = 20, direction = light}), fx.fill(d))
}

// Icy head with a long tail trailing along -x; the entity is rotated to its flight direction.
comet_look :: proc() -> ^fx.Node {
	p := fx.coord()
	length := fx.mul(fx.swizzle(fx.size(), "x"), 0.5)
	head := [2]f32{0, 0}
	x := fx.swizzle(p, "x")
	along := fx.saturate(fx.div(fx.neg(x), fx.mul(length, 1.9)))
	tail_d := fx.sub(fx.sd_segment(p, head, fx.vec2(fx.mul(length, -1.9), f32(0))), fx.mul(along, 10))
	streaks := fx.fbm(fx.vec2(fx.mul(x, 0.02), fx.mul(fx.swizzle(p, "y"), 0.4)), 3)
	tail := fx.mul(fx.mul(fx.glow(tail_d, 5), fx.sub(1, along)), fx.add(0.5, streaks))
	core := fx.glow(fx.sd_circle(p, 2.5), 3)
	return fx.stack(fx.mask(COMET_ICE, fx.saturate(fx.mul(tail, 0.8))), fx.mask(WHITE, fx.saturate(core)))
}

// ---------------------------------------------------------------------------------------
// Planets

PlanetKind :: enum {
	Terran,
	Desert,
	Ice,
	Lava,
	Gas,
	Barren,
	Toxic,
}

PlanetStyle :: struct {
	kind:       PlanetKind,
	a, b, c:    rl.Color, // randomized palette, meaning depends on the kind
	atmosphere: rl.Color,
	haze:       f32, // atmosphere strength
	rings:      bool,
	spin:       f32, // surface scroll speed, units/s
	seed:       f32,
}

// A lit globe seen head-on: rotating surface coordinates (longitude/latitude scaled to
// units, so features keep their size on any planet) and how much daylight each point gets.
Sphere :: struct {
	d:       ^fx.Node, // distance to the disc's edge
	r2:      ^fx.Node, // squared distance from the center, in radii
	lat:     ^fx.Node, // -1 (top) .. 1 (bottom)
	surface: ^fx.Node,
	day:     ^fx.Node, // 0 on the night side .. 1 in full light
}

sphere :: proc(radius, spin, seed: f32, light: [3]f32) -> Sphere {
	p := fx.coord()
	n := fx.div(p, radius)
	r2 := fx.dot(n, n)
	z := fx.sqrt(fx.sub(1, r2))
	y := fx.swizzle(n, "y")
	ring_radius := fx.sqrt(fx.sub(1, fx.mul(y, y)))
	lon := fx.asin(fx.div(fx.swizzle(n, "x"), fx.max(ring_radius, 0.001)))
	surface := fx.add(fx.vec2(fx.add(fx.mul(lon, radius), fx.mul(fx.time(), spin)), fx.mul(fx.asin(y), radius)), [2]f32{seed * 53.1, seed * 17.3})
	lambert := fx.add(fx.dot(n, [2]f32{light.x, light.y}), fx.mul(z, light.z))
	return {d = fx.sd_circle(p, radius), r2 = r2, lat = y, surface = surface, day = fx.smoothstep(-0.12, 0.4, lambert)}
}

// Surface albedo and self-lit color (lava, city lights) for each kind of planet.
planet_surface :: proc(s: Sphere, style: PlanetStyle) -> (albedo, emissive: ^fx.Node) {
	q := s.surface
	switch style.kind {
	case .Terran:
		h := fx.fbm(fx.mul(q, 0.045), 5)
		land := fx.smoothstep(0.5, 0.53, h)
		ocean := fx.mix(fx.shade(style.a, 0.55), style.a, fx.saturate(fx.mul(fx.sub(h, 0.3), 4)))
		ground := fx.mix(style.b, style.c, fx.saturate(fx.mul(fx.sub(h, 0.52), 5)))
		albedo = fx.mix(ocean, ground, land)
		albedo = fx.mix(albedo, ICE_WHITE, fx.smoothstep(0.78, 0.9, fx.abs(s.lat)))
		cloud := fx.smoothstep(0.52, 0.72, fx.fbm(fx.add(fx.mul(fx.add(q, fx.mul(fx.time(), [2]f32{3, 0})), 0.06), 31.7), 4))
		albedo = fx.mix(albedo, CLOUD_WHITE, fx.mul(cloud, 0.85))
		cities := fx.mul(fx.mul(scatter(q, 4, 0.6, 0.35, style.seed), land), fx.mul(fx.sub(1, cloud), fx.sub(1, s.day)))
		emissive = fx.mask(CITY_LIGHT, cities)
	case .Desert:
		dunes := fx.sin(fx.mul(fx.add(fx.swizzle(q, "y"), fx.mul(fx.fbm(fx.mul(q, 0.03), 4), 30)), 0.25))
		albedo = fx.ramp(fx.saturate(fx.add(fx.mul(dunes, 0.35), fx.fbm(fx.mul(q, 0.08), 4))), style.a, style.b, style.c)
	case .Ice:
		cracks := fx.sub(1, fx.smoothstep(0.02, 0.08, fx.voronoi_edge(fx.mul(q, 0.05))))
		albedo = fx.mix(ICE_WHITE, ICE_BLUE, fx.saturate(fx.add(fx.mul(fx.fbm(fx.mul(q, 0.06), 4), 0.8), fx.mul(cracks, 0.6))))
	case .Lava:
		warp := fx.mul(fx.fbm(fx.add(fx.mul(q, 0.03), fx.mul(fx.time(), 0.1)), 3), 2)
		cracks := fx.voronoi_edge(fx.add(fx.mul(q, 0.04), warp))
		heat := fx.exp(fx.mul(cracks, -16))
		albedo = fx.mix(LAVA_DARK, LAVA_ROCK, fx.fbm(fx.mul(q, 0.1), 4))
		pulse := fx.add(0.75, fx.mul(fx.sin(fx.add(fx.mul(fx.time(), 2), style.seed)), 0.25))
		emissive = fx.mask(fx.gradient(heat, LAVA_RED, LAVA_YELLOW), fx.mul(heat, pulse))
	case .Gas:
		turbulence := fx.fbm(fx.add(fx.mul(q, [2]f32{0.012, 0.05}), fx.mul(fx.time(), 0.05)), 4)
		bands := fx.add(0.5, fx.mul(fx.sin(fx.add(fx.mul(fx.swizzle(q, "y"), 0.2), fx.mul(turbulence, 5))), 0.5))
		albedo = fx.ramp(bands, style.a, style.b, style.c)
	case .Barren:
		cells := fx.voronoi(fx.mul(q, 0.06))
		bowl := fx.sub(1, fx.smoothstep(0, 0.32, cells))
		rim := fx.exp(fx.mul(fx.abs(fx.sub(cells, 0.36)), -18))
		albedo = fx.mix(style.a, style.b, fx.fbm(fx.mul(q, 0.08), 4))
		albedo = fx.shade(fx.mix(albedo, CRATER_DARK, fx.mul(bowl, 0.5)), fx.add(1, fx.mul(rim, 0.35)))
	case .Toxic:
		swirl := fx.fbm(fx.add(fx.mul(q, 0.04), fx.mul(fx.vec2(fx.fbm(fx.mul(q, 0.03), 3), fx.time()), [2]f32{3, 0.08})), 5)
		albedo = fx.ramp(swirl, style.a, style.b, style.c)
	}
	return
}

// Planetary rings: a tilted elliptic band; `front` picks the half that passes before the globe.
planet_rings :: proc(radius: f32, color: rl.Color, seed: f32, front: bool) -> ^fx.Node {
	p := fx.rotate(fx.coord(), -0.35)
	e := fx.length(fx.mul(p, [2]f32{1, 3.4}))
	band := fx.mul(fx.smoothstep(radius * 1.3, radius * 1.4, e), fx.sub(1, fx.smoothstep(radius * 1.8, radius * 1.95, e)))
	stripes := fx.add(0.45, fx.mul(fx.fbm(fx.vec2(fx.mul(e, 0.25), seed), 3), 0.7))
	half := fx.step(0, fx.swizzle(p, "y")) if front else fx.step(fx.swizzle(p, "y"), 0)
	return fx.mask(color, fx.mul(fx.mul(band, stripes), fx.mul(half, 0.75)))
}

// A procedural planet lit from `light` (3D unit vector), driven by params: owner (color),
// tint (how strongly the surface takes the owner's color), selected, hover (0/1) and
// capture_time.
planet_look :: proc(radius: f32, style: PlanetStyle, light: [3]f32) -> ^fx.Node {
	s := sphere(radius, style.spin, style.seed, light)
	albedo, emissive := planet_surface(s, style)
	// Recolor the surface in the owner's color, keeping its light and dark detail.
	owner := fx.param("owner", NEUTRAL_GRAY)
	tint := fx.param("tint", f32(0))
	luminance := fx.dot(albedo, [4]f32{0.3, 0.59, 0.11, 0})
	albedo = fx.mix(albedo, fx.shade(owner, fx.add(0.3, fx.mul(luminance, 1.2))), tint)
	atmosphere := fx.mix(style.atmosphere, owner, tint)
	haze := fx.max(style.haze, fx.mul(tint, 0.8))
	limb := fx.add(0.75, fx.mul(fx.sqrt(fx.sub(1, s.r2)), 0.25))
	surface := fx.shade(albedo, fx.mul(fx.add(0.05, s.day), limb))
	if emissive != nil {
		surface = fx.over(emissive, surface)
	}
	rim := fx.mask(atmosphere, fx.mul(fx.mul(fx.pow(s.r2, 4), fx.add(0.1, s.day)), haze))
	globe := fx.mask(fx.stack(surface, rim), fx.fill(s.d))
	halo := fx.mask(atmosphere, fx.mul(fx.mul(fx.glow(s.d, radius * 0.15), fx.add(0.15, s.day)), fx.mul(haze, 0.8)))

	p := fx.coord()
	selected := fx.param("selected", f32(0))
	hover := fx.param("hover", f32(0))
	ring_d := fx.sub(fx.length(p), radius + 7)
	dash := fx.step(0.35, fx.fract(fx.sub(fx.mul(fx.angle(p), 24 / (2 * math.PI)), fx.mul(fx.time(), 0.5))))
	strength := fx.mul(fx.mix(0.45, 1, fx.max(selected, fx.mul(hover, 0.7))), fx.mix(1, dash, selected))
	ring := fx.mask(owner, fx.mul(fx.stroke(ring_d, fx.add(1.5, selected)), strength))
	flash := fx.exp(fx.mul(fx.sub(fx.time(), fx.param("capture_time", f32(-100))), -2.5))
	capture := fx.mask(owner, fx.mul(fx.glow(s.d, 12), flash))

	if style.rings {
		ring_color := style.c
		return fx.stack(halo, capture, planet_rings(radius, ring_color, style.seed, false), globe, planet_rings(radius, ring_color, style.seed, true), ring)
	}
	return fx.stack(halo, capture, globe, ring)
}

// ---------------------------------------------------------------------------------------
// Ships and effects

// A small arrowhead ship pointing along +x with a flickering engine.
ship_look :: proc(color: rl.Color, seed: f32) -> ^fx.Node {
	p := fx.coord()
	hull := fx.max(fx.sd_convex_polygon(p, {{7, 0}, {-5, 4.5}, {-5, -4.5}}), fx.neg(fx.sd_circle(fx.sub(p, [2]f32{-7, 0}), 3)))
	body := fx.gradient(fx.swizzle(fx.uv(), "y"), fx.mix(color, WHITE, f32(0.45)), fx.shade(color, 0.7))
	flicker := fx.add(0.7, fx.mul(fx.noise(fx.vec2(fx.mul(fx.time(), 25), seed)), 0.6))
	exhaust := fx.mul(fx.glow(fx.sub(fx.sd_segment(p, [2]f32{-4, 0}, [2]f32{-11, 0}), 0.6), 2), flicker)
	return fx.stack(
		fx.mask(color, fx.mul(fx.glow(hull, 3), 0.45)),
		fx.mask(ENGINE_HOT, fx.saturate(exhaust)),
		fx.mask(BLACK, fx.mul(fx.fill(fx.sub(hull, 1)), 0.6)),
		fx.mask(body, fx.fill(hull)),
	)
}

// Little burst where a ship hits an enemy planet's defenses.
hit_look :: proc(color: rl.Color, seed: f32) -> ^fx.Node {
	return fx.sparks({seed = seed, speed = 90, gravity = 0, life = 0.35, radius = 1.1, color = color, count = 6, spread = math.PI})
}

// Expanding ring in the new owner's color when a planet is captured.
capture_look :: proc(color: rl.Color, radius: f32) -> ^fx.Node {
	t := fx.age()
	ring := fx.stroke(fx.sub(fx.length(fx.coord()), fx.add(radius, fx.mul(t, 120))), fx.mul(fx.exp(fx.mul(t, -3)), 6))
	return fx.mask(color, fx.mul(ring, fx.exp(fx.mul(t, -2.5))))
}

// ---------------------------------------------------------------------------------------
// Interface

// Marching dashes along the entity's x axis, fading at the far end.
send_line_look :: proc() -> ^fx.Node {
	p := fx.coord()
	x := fx.swizzle(p, "x")
	half := fx.mul(fx.swizzle(fx.size(), "x"), 0.5)
	dash := fx.step(0.45, fx.fract(fx.div(fx.sub(x, fx.mul(fx.time(), 60)), 14)))
	fade := fx.sub(1, fx.smoothstep(fx.sub(half, 10), half, x))
	line := fx.mul(fx.mul(fx.stroke(fx.swizzle(p, "y"), 2), dash), fade)
	return fx.mask(fx.param("color", PLAYER_BLUE), fx.mul(line, 0.85))
}

selection_box_look :: proc() -> ^fx.Node {
	d := fx.sd_box(fx.coord(), fx.sub(fx.mul(fx.size(), 0.5), 1))
	return fx.mask(SELECT_BOX, fx.max(fx.mul(fx.stroke(d, 1.5), 0.9), fx.mul(fx.fill(d), 0.08)))
}

// Rounded bar filled up to the `fraction` param, with tick marks every 10%.
meter_look :: proc(color: rl.Color) -> ^fx.Node {
	p := fx.coord()
	half := fx.mul(fx.size(), 0.5)
	frame := fx.sd_box(p, half, 4)
	inner := fx.sd_box(p, fx.sub(half, 3), 2)
	x := fx.swizzle(fx.uv(), "x")
	filled := fx.mul(fx.step(x, fx.param("fraction", f32(0.5))), fx.fill(inner))
	tick_spacing := fx.mul(fx.swizzle(fx.size(), "x"), 0.1)
	cell_x := fx.swizzle(fx.tile(p, fx.vec2(tick_spacing, f32(100))), "x")
	ticks := fx.mul(fx.stroke(fx.sub(fx.abs(cell_x), fx.mul(tick_spacing, 0.5)), 1), 0.35)
	fill_color := fx.gradient(fx.swizzle(fx.uv(), "y"), fx.mix(color, WHITE, f32(0.3)), fx.shade(color, 0.7))
	return fx.stack(fx.mask(BAR_BACK, fx.mul(fx.fill(frame), 0.85)), fx.mask(fill_color, filled), fx.mask(BLACK, fx.mul(ticks, fx.fill(inner))))
}

// Strength comparison bar: segments in player order, split at the cumulative shares
// `split1`..`split3` (0..1).
power_bar_look :: proc(colors: [4]rl.Color) -> ^fx.Node {
	p := fx.coord()
	frame := fx.sd_box(p, fx.mul(fx.size(), 0.5), 4)
	inner := fx.sd_box(p, fx.sub(fx.mul(fx.size(), 0.5), 2), 3)
	x := fx.swizzle(fx.uv(), "x")
	names := [4]string{"", "split1", "split2", "split3"}
	color := fx.to_node(colors[0])
	for i in 1 ..< 4 {
		color = fx.mix(color, colors[i], fx.step(fx.param(names[i], f32(1)), x))
	}
	shine := fx.add(0.75, fx.mul(fx.sub(1, fx.swizzle(fx.uv(), "y")), 0.4))
	return fx.stack(fx.mask(BAR_BACK, fx.mul(fx.fill(frame), 0.85)), fx.mask(fx.shade(color, shine), fx.fill(inner)))
}
