package main

import fx "../../engine/vfx"

// The flood's looks (flood.odin). Every lit look reads the param `water`: the level, the
// radius the flood's front has spread to from the hatch, seconds since the burst, and 1 once
// there is water (0 before: everything here is gated off). Murky water is nearly opaque: a
// surface under it fades into the murk within a few centimeters of it, so the water needs no
// geometry of its own; each look sees its surface through it (with_water), the surface of
// the flood drawn where the ray crosses it.

HATCH_XZ :: [2]f32{ROOM_CENTER.x, ROOM_CENTER.z}

water_param :: proc() -> ^fx.Node {return fx.param("water", [4]f32{0, 0, 0, 0})}

// How far across the floor a point is from the hatch's middle, and the way out from it (xz)
from_hatch :: proc(pos: ^fx.Node) -> (rr, out: ^fx.Node) {
	v := fx.sub(fx.swizzle(pos, "xz"), HATCH_XZ)
	rr = fx.length(v)
	return rr, fx.div(v, fx.max(rr, 0.01))
}

// Whether the flood has spread to rr from the hatch (0..1, its front sloping over FRONT_SLOPE)
flooded :: proc(water, rr: ^fx.Node) -> ^fx.Node {
	front := component(water, "y")
	return fx.mul(fx.sub(1, fx.smoothstep(fx.sub(front, FRONT_SLOPE), front, rr)), component(water, "w"))
}

// A surface `t` along the ray as seen through the flood, or in the deep through the sea
// (param sea: 1 there)
with_water :: proc(light: ^fx.Node, ray: Ray, t: ^fx.Node) -> ^fx.Node {
	water := water_param()
	flood := fx.add(light, fx.gate(component(water, "w"), fx.sub(through_water(light, ray, t, water), light)))
	sea := fx.param("sea", f32(0))
	return fx.add(flood, fx.gate(sea, fx.sub(sea_fog(flood, ray, t), flood)))
}

// The light of a surface `t` along the ray after the stretch of it under water (from where
// the ray goes in, or from the camera if it is under): it fades into the murk, darker deeper
// down. Where the ray goes in from above, the flood's surface shows over it (water_surface).
through_water :: proc(light: ^fx.Node, ray: Ray, t, water: ^fx.Node) -> ^fx.Node {
	level := component(water, "x")
	o, d := ray.origin, ray.dir
	oy, dy := component(o, "y"), component(d, "y")
	above := fx.step(level, oy) // the camera above the water
	rise := fx.sub(level, oy)
	down := fx.div(rise, fx.min(dy, -1e-5)) // to the surface going down from above (far off if going up)
	upward := fx.div(rise, fx.max(dy, 1e-5)) // going up from below
	cross := fx.mix(upward, down, above)
	at := fx.add(o, fx.mul(d, cross))
	rr, out := from_hatch(at)
	wet := fx.mix(1, flooded(water, rr), above)
	under := fx.mul(fx.mix(fx.min(t, upward), fx.max(fx.sub(t, down), 0), above), wet)
	// The murk's light comes from its first stretch along the ray (1 / WATER_MURK), lit less
	// deeper down: the same for whatever lies behind it, so drowned things fade into it alike
	seen_to := fx.min(t, fx.add(fx.mul(down, above), 1 / f32(WATER_MURK)))
	depth := fx.max(fx.sub(level, component(fx.add(o, fx.mul(d, seen_to)), "y")), 0)
	murk := fx.mul(MURK, fx.add(0.3, fx.mul(fx.exp(fx.mul(depth, -0.8)), 0.7)))
	seen := fx.mix(murk, light, fx.exp(fx.mul(under, -WATER_MURK)))
	surface := fx.mul(fx.mul(above, fx.step(down, t)), wet)
	return fx.add(seen, fx.gate(surface, fx.mul(fx.sub(water_surface(seen, at, rr, out, ray, water), seen), surface)))
}

// The flood's surface at `at` over what is seen through it: choppy, rougher near the jet,
// with foam carried out from the jet, boiling round it and churned up along the front. It
// shows the lamp's highlight and, at grazing angles, a dull sheen of the room.
water_surface :: proc(seen, at, rr, out: ^fx.Node, ray: Ray, water: ^fx.Node) -> ^fx.Node {
	s := component(water, "z")
	front := component(water, "y")
	x, z := component(at, "x"), component(at, "z")
	wave :: proc(x, z, s: ^fx.Node, k: [3]f32) -> ^fx.Node {
		return fx.sin(fx.sum(fx.mul(x, k[0]), fx.mul(z, k[1]), fx.mul(s, k[2])))
	}
	rough := fx.add(0.12, fx.mul(fx.exp(fx.mul(rr, -0.6)), 0.3))
	tilt_x := fx.sum(wave(x, z, s, {5.1, 1.7, -4.3}), fx.mul(wave(x, z, s, {-2.3, 7.7, 5.1}), 0.6), fx.mul(wave(x, z, s, {13.3, -6.1, 9.2}), 0.45), fx.mul(wave(x, z, s, {-9.7, 17.9, -11.4}), 0.3))
	tilt_z := fx.sum(wave(x, z, s, {-1.9, 4.7, 3.7}), fx.mul(wave(x, z, s, {3.1, -8.3, -6.2}), 0.6), fx.mul(wave(x, z, s, {-7.9, 12.7, -8.8}), 0.45), fx.mul(wave(x, z, s, {16.1, 5.3, 12.6}), 0.3))
	normal := normalize3(fx.rgba(fx.mul(tilt_x, rough), 1, fx.mul(tilt_z, rough), 0))
	// Foam in patches of fine froth and thin lace, carried out from the jet: the pattern
	// spreads out from it, in two copies half a period apart, each starting afresh (at a new
	// place in the noise) as the other is at its full, so it never stretches too far. Its
	// detail fades to its average where a pixel would hold many of its cells (far, grazing).
	v := fx.sub(fx.swizzle(at, "xz"), HATCH_XZ)
	patches: ^fx.Node
	carried: ^fx.Node
	for k in 0 ..< 2 {
		cycle := fx.add(fx.div(s, FOAM_PERIOD), f32(k) * 0.5)
		phase := fx.fract(cycle)
		q := fx.add(fx.mul(v, fx.mul(fx.exp(fx.mul(phase, -FOAM_SPREAD)), 1.6)), fx.mul(fx.floor(cycle), [2]f32{17.3, 29.1}))
		froth := fx.noise(fx.mul(q, 4.3))
		lumps := fx.noise(fx.mul(q, 0.9))
		lace := fx.noise(fx.add(fx.mul(q, 2.9), 7.7))
		k_carried := fx.add(fx.mul(fx.smoothstep(0.55, 0.8, froth), fx.smoothstep(0.35, 0.65, lumps)), fx.mul(fx.mul(fx.sub(1, fx.smoothstep(0.02, 0.05, fx.abs(fx.sub(lace, 0.5)))), lumps), 0.35))
		weight := fx.sub(1, fx.abs(fx.sub(fx.mul(phase, 2), 1)))
		k_carried, lumps = fx.mul(k_carried, weight), fx.mul(lumps, weight)
		carried = k_carried if carried == nil else fx.add(carried, k_carried)
		patches = lumps if patches == nil else fx.add(patches, lumps)
	}
	detail := fx.sub(1, fx.smoothstep(0.15, 0.6, fx.mul(fx.mul(fx.length(fx.sub(at, ray.origin)), camera_pixel()), 9)))
	carried = fx.mul(fx.mix(0.2, carried, detail), fx.add(0.4, fx.mul(fx.exp(fx.mul(rr, -0.4)), 0.6)))
	boil := fx.exp(fx.div(fx.max(fx.sub(rr, JET_RADIUS), 0), -0.5))
	churned := fx.mul(fx.smoothstep(fx.sub(front, FRONT_SLOPE + 0.6), fx.sub(front, 0.2), rr), fx.smoothstep(0.3, 0.6, patches))
	foam := fx.saturate(fx.sum(carried, boil, churned))
	albedo := fx.mul(linear(FOAM), foam)
	surface := Surface {
		pos       = at,
		normal    = normal,
		view      = fx.neg(ray.dir),
		albedo    = albedo,
		specular  = fx.mix(0.8, 0.05, foam),
		shininess = fx.mix(90, 10, foam),
	}
	lit := fx.add(shade(surface, [4]f32{1, 1, 1, 1}, f32(-1), nil), fx.mul(albedo, WATER_SCATTER))
	return fx.sum(fx.mul(seen, fx.sub(1, fx.mul(foam, 0.9))), lit, wet_sheen(ray, normal, fx.mul(fx.sub(1, foam), 0.15)))
}

// What a wet surface mirrors of the room: little straight on, more at grazing angles
wet_sheen :: proc(ray: Ray, normal: ^fx.Node, amount: fx.Expr) -> ^fx.Node {
	d := ray.dir
	facing := fx.saturate(fx.neg(fx.dot(d, normal)))
	fresnel := fx.add(0.02, fx.mul(fx.pow(fx.sub(1, facing), 5), 0.98))
	bounce := fx.sub(d, fx.mul(normal, fx.mul(fx.dot(d, normal), 2)))
	return fx.mul(room_env(bounce), fx.mul(fresnel, amount))
}

// The room's ceiling and walls where the jet's water has got to (0..1): spreading over the
// ceiling from above the hatch, then running down the walls in streaks
wet_film :: proc(pos, uv, ceiling, wall: ^fx.Node, water: ^fx.Node) -> ^fx.Node {
	s := component(water, "z")
	since := fx.sub(s, ROOM_HEIGHT / JET_SPEED) // the jet hit the ceiling
	y := component(pos, "y")
	rr, out := from_hatch(pos)
	jag := fx.mul(fx.noise(fx.mul(fx.swizzle(pos, "xz"), 1.3)), 0.6)
	reach := fx.mul(since, CEILING_SPREAD)
	spread := fx.sub(1, fx.smoothstep(fx.sub(reach, 0.5), reach, fx.add(rr, jag)))
	radial := fx.noise(fx.vec2(fx.sub(fx.mul(rr, 2.5), fx.mul(s, 5)), fx.add(fx.mul(component(out, "x"), 3), fx.mul(component(out, "y"), 5))))
	run := fx.sub(fx.mul(fx.sub(since, fx.div(rr, CEILING_SPREAD)), FILM_SPEED), fx.sub(ROOM_HEIGHT, y))
	fingers := fx.mul(fx.noise(fx.vec2(fx.mul(component(uv, "x"), 5), 0.3)), 1.5) // rivulets running ahead
	down := fx.smoothstep(0, 0.4, fx.sum(run, jag, fingers))
	streaks := fx.noise(fx.vec2(fx.mul(component(uv, "x"), 9), fx.add(fx.mul(y, 0.5), fx.mul(s, 3))))
	walls := fx.mul(fx.mul(wall, down), fx.add(0.75, fx.mul(streaks, 0.25)))
	return fx.saturate(fx.add(fx.mul(fx.mul(ceiling, spread), fx.add(0.6, fx.mul(radial, 0.4))), walls))
}

// Water falling from the wet ceiling, as streaks on a few slices across the view in front
// of the room's face (`exit` along the ray), above the flood: how much of the pixel (0..1)
rain :: proc(ray: Ray, exit, water: ^fx.Node) -> ^fx.Node {
	level, s := component(water, "x"), component(water, "z")
	total: ^fx.Node = nil
	// The camera's right and ahead, level: the streaks run straight down the screen
	cam_r := fx.param("cam_r", [4]f32{1, 0, 0, 0})
	right := fx.swizzle(cam_r, "xz")
	ahead := fx.vec2(fx.neg(component(cam_r, "z")), component(cam_r, "x"))
	dxz := fx.swizzle(ray.dir, "xz")
	for dist, k in ([?]f32{2.5, 3.8, 5.5, 8}) {
		p := fx.add(ray.origin, fx.mul(ray.dir, dist))
		y := component(p, "y")
		rr, _ := from_hatch(p)
		falling := fx.sub(fx.sub(fx.sub(s, ROOM_HEIGHT / JET_SPEED), fx.div(rr, CEILING_SPREAD)), fx.div(fx.sub(ROOM_HEIGHT, y), RAIN_SPEED))
		present := fx.mul(fx.mul(fx.step(dist, exit), fx.step(0, falling)), fx.step(level, y))
		sideways := fx.div(fx.dot(dxz, right), fx.max(fx.dot(dxz, ahead), 0.2)) // constant down a vertical line on screen
		across := fx.add(fx.mul(sideways, dist * 14), f32(k) * 7.3)
		along := fx.add(fx.mul(fx.add(y, fx.mul(s, RAIN_SPEED)), 0.35), f32(k) * 3.1)
		streak := fx.mul(fx.smoothstep(0.8, 0.95, fx.noise(fx.vec2(across, along))), present)
		total = streak if total == nil else fx.add(total, streak)
	}
	return fx.saturate(fx.mul(total, 0.35))
}

// The room's face through the flood, with the rain in front of it
room_water :: proc(light: ^fx.Node, ray: Ray, exit: ^fx.Node) -> ^fx.Node {
	water := water_param()
	wet := fx.mix(through_water(light, ray, exit, water), RAIN_LIGHT, rain(ray, exit, water))
	return fx.add(light, fx.gate(component(water, "w"), fx.sub(wet, light)))
}

// ---------------------------------------------------------------------------------------
// The jet: a column of murky water up from the hatch's opening (JET_RADIUS), wider higher up,
// its lumpy, pulsing side found in two steps (the ray against the smooth column, then
// against the lumpy one where that lands), as thick as the ray's way through it: its thin
// edges let some of the room through. Streaks of foam race up it. Params: jet = (its head's
// height, seconds since the burst), camera, lights, water.

// The jet's radius at height y: pulsing, lumpy (seen from `around`, nil for smooth), its
// head swollen while it rises and spreading against the ceiling once it is there
jet_radius :: proc(y, head, around, s: ^fx.Node) -> ^fx.Node {
	yy := fx.max(y, 0)
	r := fx.mul(fx.add(1, fx.mul(yy, JET_FLARE / ROOM_HEIGHT)), JET_RADIUS)
	r = fx.mul(r, fx.add(1, fx.mul(fx.sin(fx.sub(fx.mul(yy, 2.6), fx.mul(s, 31))), 0.06)))
	if around != nil {
		rising := fx.sub(yy, fx.mul(s, 12))
		u := fx.add(fx.mul(component(around, "x"), 3), fx.mul(rising, 1.6))
		v := fx.add(fx.mul(component(around, "y"), 3), fx.mul(yy, 1.2))
		r = fx.add(r, fx.mul(fx.sub(fx.noise(fx.vec2(u, v)), 0.5), 0.12))
	}
	below_head := fx.sub(head, yy)
	rising := fx.step(head, ROOM_HEIGHT - 0.01)
	swell := fx.sub(below_head, 0.3)
	r = fx.mul(r, fx.add(1, fx.mul(fx.exp(fx.mul(fx.mul(swell, swell), -16)), fx.mul(rising, 0.4))))
	// A round cap while it rises; once it is there, a bell spreading out against the ceiling
	r = fx.mul(r, fx.mix(1, fx.sqrt(fx.saturate(fx.div(below_head, 0.3))), rising))
	bell := fx.smoothstep(ROOM_HEIGHT - JET_BELL, ROOM_HEIGHT, yy)
	return fx.add(r, fx.mul(fx.mul(bell, bell), fx.mul(fx.sub(1, rising), JET_BELL_SPREAD)))
}

jet_look :: proc() -> ^fx.Node {
	ray := camera_ray()
	pix := camera_pixel()
	jet := fx.param("jet", [4]f32{0, 0, 0, 0})
	head, s := component(jet, "x"), component(jet, "y")
	o, d := ray.origin, ray.dir
	oxz := fx.sub(fx.swizzle(o, "xz"), HATCH_XZ)
	dxz := fx.swizzle(d, "xz")
	across := fx.sqrt(fx.max(fx.dot(dxz, dxz), 1e-6)) // how fast the ray goes across the floor
	closest := fx.div(fx.neg(fx.dot(oxz, dxz)), fx.mul(across, across))
	miss := fx.length(fx.add(oxz, fx.mul(dxz, closest))) // how near it passes the axis
	// Marching in from where the ray meets the widest the jet can be to where it passes the
	// axis closest, JET_STEPS steps: the first step that lands inside the jet's radius there
	// (the bell under the ceiling widens too fast to solve for), interpolated; the nearest it
	// comes (outside, negative) gives the edge's coverage
	widest := f32(JET_RADIUS * (1 + JET_FLARE) * 1.06 + JET_BELL_SPREAD + 0.06)
	start := fx.sub(closest, fx.div(fx.sqrt(fx.max(fx.sub(widest * widest, fx.mul(miss, miss)), 0)), across))
	outside :: proc(o, d, closest, across, miss, head, s, t: ^fx.Node) -> ^fx.Node {
		at := fx.add(o, fx.mul(d, t))
		_, around := from_hatch(at)
		off := fx.mul(across, fx.sub(t, closest))
		return fx.sub(fx.sqrt(fx.add(fx.mul(miss, miss), fx.mul(off, off))), jet_radius(component(at, "y"), head, around, s))
	}
	t := closest
	found := fx.to_node(f32(0))
	nearest := fx.to_node(f32(1e3))
	prev_t := start
	prev_gap := outside(o, d, closest, across, miss, head, s, start)
	for k in 1 ..= JET_STEPS {
		k_t := fx.mix(start, closest, f32(k) / JET_STEPS)
		gap := outside(o, d, closest, across, miss, head, s, k_t)
		crossing := fx.mul(fx.sub(1, found), fx.step(gap, 0))
		cross_t := fx.add(prev_t, fx.mul(fx.sub(k_t, prev_t), fx.div(prev_gap, fx.max(fx.sub(prev_gap, gap), 1e-4))))
		t = fx.mix(t, cross_t, crossing)
		found = fx.max(found, crossing)
		nearest = fx.min(nearest, gap)
		prev_t, prev_gap = k_t, gap
	}
	half := fx.sub(closest, t)
	_, around := from_hatch(fx.add(o, fx.mul(d, t)))
	pos := fx.add(o, fx.mul(d, t))
	y := component(pos, "y")
	aa := fx.mul(t, pix)
	fuzz := fx.add(aa, 0.02) // its edge is spray, not a line
	inside := fx.mul(fx.smoothstep(fx.neg(aa), aa, y), fx.sub(1, fx.smoothstep(fx.sub(ROOM_HEIGHT, aa), fx.add(ROOM_HEIGHT, aa), y))) // between floor and ceiling
	coverage := fx.mul(fx.smoothstep(fx.neg(fuzz), fuzz, fx.neg(nearest)), inside)
	thick := fx.sub(1, fx.exp(fx.mul(half, -2 * JET_MURK)))

	// Churning foam rising with it, more at its thin edges and where it leaves the opening;
	// aerated water scatters the lamp's light every way (WATER_SCATTER)
	cx, cz := component(around, "x"), component(around, "y")
	flow := fx.sub(y, fx.mul(s, JET_SPEED * 0.7))
	q := fx.vec2(fx.add(fx.mul(cx, 3.5), fx.mul(flow, 1.4)), fx.add(fx.mul(cz, 3.5), fx.mul(flow, 2.2)))
	coarse := fx.noise(q)
	fine := fx.noise(fx.add(fx.mul(q, 2.7), 5.2))
	churn := fx.smoothstep(0.3, 0.7, coarse)
	splash := fx.smoothstep(ROOM_HEIGHT - JET_BELL, ROOM_HEIGHT, y) // churned white where it hits the ceiling
	foam := fx.saturate(fx.sum(0.12, fx.mul(churn, 0.65), fx.mul(fine, 0.25), fx.mul(fx.sub(1, thick), 0.5), fx.mul(fx.exp(fx.div(y, -0.4)), 0.5), fx.mul(splash, 0.6)))
	alpha := fx.mul(coverage, fx.max(thick, fx.mul(foam, 0.9)))
	normal := normalize3(fx.rgba(fx.add(cx, fx.mul(fx.sub(fine, 0.5), 0.35)), fx.mul(fx.sub(coarse, 0.5), 0.35), fx.add(cz, fx.mul(fx.sub(churn, 0.5), 0.35)), 0))
	silt := fx.add(0.75, fx.mul(fx.noise(fx.mul(q, 0.5)), 0.5))
	albedo := fx.mix(fx.mul(linear(SEAWATER), silt), linear(FOAM), foam)
	surface := Surface {
		pos       = pos,
		normal    = normal,
		view      = fx.neg(d),
		albedo    = albedo,
		specular  = fx.mix(0.5, 0.05, foam),
		shininess = fx.mix(40, 8, foam),
	}
	light := fx.add(shade(surface, [4]f32{1, 1, 1, 1}, f32(-1), nil), fx.mul(albedo, WATER_SCATTER))
	light = fx.add(light, wet_sheen(ray, normal, fx.mul(fx.sub(1, foam), 0.12)))
	light = with_water(light, ray, t)
	return finish(fx.gate(coverage, light), alpha)
}

// Drops of spray, one instanced quad each (records of DROP_RECORD: quad | a.xyz, radius |
// b.xyz, foam), each smeared from a to b (where it was DROP_BLUR seconds ago): murky water,
// foamier for some, wet and shiny
drops_look :: proc() -> ^fx.Node {
	records := fx.instances("drops", DROP_RECORD, MAX_DROPS)
	ray := camera_ray()
	a4, b4 := fx.instance4(records, 4), fx.instance4(records, 8)
	a, b := xyz(a4), xyz(b4)
	_, t, coverage := tube_approach(ray, a, b, component(a4, "w"))
	pos := fx.add(ray.origin, fx.mul(ray.dir, t))
	ba := fx.sub(b, a)
	along := fx.saturate(fx.div(fx.dot(fx.sub(pos, a), ba), fx.max(fx.dot(ba, ba), 1e-8)))
	normal := normalize3(fx.add(fx.sub(pos, fx.add(a, fx.mul(ba, along))), [4]f32{0, 1e-5, 0, 0}))
	foam := component(b4, "w")
	surface := Surface {
		pos       = pos,
		normal    = normal,
		view      = fx.neg(ray.dir),
		albedo    = fx.mix(linear(SEAWATER), linear(FOAM), foam),
		specular  = 0.8,
		shininess = 60,
	}
	light := shade(surface, [4]f32{1, 1, 1, 1}, f32(-1), nil)
	light = fx.sum(light, fx.mul(surface.albedo, WATER_SCATTER), wet_sheen(ray, normal, 0.6))
	light = with_water(light, ray, t)
	return finish(fx.gate(coverage, light), fx.mul(coverage, 0.85))
}

// ---------------------------------------------------------------------------------------
// The lens going under: below its waterline (lens.x: 0 at the bottom of the screen, 1 at the
// top, waving) the murk, swirling, lighter just under the surface, darker as the water
// rises over the camera; bubbles of all sizes, a few of them big, crowding along the
// waterline and rising, then a steady stream of them once it is under; froth on the
// waterline. As scene 2 begins the murk clears (lens.w) and the stream stops: no bubble
// comes in from the bottom after lens.z, and the last ones rush up and away (their clock,
// lens.y, runs faster). Params: lens = (waterline, the bubbles' seconds, when the stream
// stops, how clear it is), exposure.

// The steady stream's density, under the band crowding along the waterline
BUBBLE_STREAM :: 0.45

// One layer of bubbles of about `cell` (screen heights) rising at about `rise` screen heights
// a second: a bubble in some cells of a grid, `share` of as many as `density` asks for where
// it is (density(center) in 0..1); a silvery ring with a highlight, wobbling out of round, the
// big ones by up to `stretch`. No grid shows: every column of cells rises at a speed of its
// own from a place of its own, and a bubble's size, place in its cell and wobble are its own.
BubbleLayer :: struct {
	cell, rise, seed, share, stretch: f32,
}

BUBBLE_LAYERS :: [?]BubbleLayer {
	{0.24, 0.3, 1.7, 1, 0},
	{0.12, 0.45, 5.3, 1, 0},
	{0.06, 0.6, 9.1, 1, 0},
	{0.04, 0.4, 21.7, 1, 0},
	{0.025, 0.25, 13.9, 1, 0},
	{0.48, 0.38, 27.1, 0.35, 0.06}, // twice and three times the biggest above, fewer of them
	{0.72, 0.42, 33.3, 0.22, 0.08},
}

// Returns the layer's light (w 0) and how much it covers
bubble_layer :: proc(p, s, stream_end: ^fx.Node, layer: BubbleLayer, density: proc(center: ^fx.Node, data: [2]^fx.Node) -> ^fx.Node, data: [2]^fx.Node) -> (light, cover: ^fx.Node) {
	cell := layer.cell
	column := fx.floor(fx.div(component(p, "x"), cell))
	rise := fx.mul(fx.add(0.7, fx.mul(fx.hash(fx.vec2(column, layer.seed + 3.7)), 0.6)), layer.rise)
	lift := fx.add(fx.mul(s, rise), fx.mul(fx.hash(fx.vec2(column, layer.seed + 9.1)), 37 * cell))
	g := fx.div(fx.add(p, fx.vec2(0, lift)), cell)
	id := fx.floor(g)
	f := fx.sub(fx.fract(g), 0.5)
	h1 := fx.hash(fx.add(id, layer.seed))
	h2 := fx.hash(fx.add(id, layer.seed + 17.3))
	h3 := fx.hash(fx.add(id, layer.seed + 31.1))
	h4 := fx.hash(fx.add(id, layer.seed + 47.9))
	h5 := fx.hash(fx.add(id, layer.seed + 61.3))
	r := fx.add(0.07, fx.mul(fx.mul(h2, h2), 0.28)) // in cells: many small, a few big
	wobble := fx.mul(fx.sin(fx.add(fx.mul(s, fx.add(4, fx.mul(h1, 5))), fx.mul(h3, 50))), fx.mul(h5, 0.07))
	center := fx.add(fx.mul(fx.sub(fx.vec2(h1, h3), 0.5), fx.mul(fx.max(fx.sub(0.44, r), 0), 2)), fx.vec2(wobble, 0)) // ring and all within its cell
	middle := fx.sub(fx.mul(fx.add(fx.add(id, 0.5), center), cell), fx.vec2(0, lift))
	// When it came in at the bottom of the screen: none after the stream stopped
	came_in := fx.add(s, fx.div(fx.sub(component(middle, "y"), 1.1), rise))
	present := fx.mul(fx.step(h4, fx.mul(density(middle, data), layer.share)), fx.step(came_in, stream_end))
	off := fx.sub(f, center)
	// Out of round: squeezed and stretched, each its own way and pace
	stretch := fx.mul(fx.sin(fx.add(fx.mul(s, fx.add(3, fx.mul(h2, 4))), fx.mul(h1, 40))), fx.mul(fx.add(0.3, fx.mul(h3, 0.7)), max(layer.stretch, 0.05)))
	off = fx.mul(off, fx.vec2(fx.add(1, stretch), fx.sub(1, stretch)))
	// The ring and the edge as thin on screen in every layer as in the 0.24 one
	thin := max(cell / 0.24, 1)
	dist := fx.sub(fx.length(off), r)
	ring := fx.exp(fx.neg(fx.mul(fx.mul(dist, dist), 800 * thin * thin)))
	inside := fx.sub(1, fx.smoothstep(-0.02 / thin, 0.01 / thin, dist))
	spot := fx.sub(1, fx.smoothstep(0, 0.07, fx.length(fx.add(off, fx.mul(r, 0.4)))))
	light = fx.mul(BUBBLE_LIGHT, fx.mul(fx.sum(fx.mul(ring, 0.8), fx.mul(spot, 1.5), fx.mul(inside, 0.12)), present))
	cover = fx.mul(fx.max(ring, fx.mul(inside, 0.3)), present)
	return
}

// The lens's waterline at x (screen heights from the left): `line` and its waves
lens_waterline :: proc(line, s, x: ^fx.Node) -> ^fx.Node {
	return fx.sum(
		line,
		fx.mul(fx.sin(fx.add(fx.mul(x, 6.3), fx.mul(s, 4.1))), 0.035),
		fx.mul(fx.sin(fx.sub(fx.mul(x, 13.7), fx.mul(s, 6.3))), 0.025),
		fx.mul(fx.sub(fx.noise(fx.vec2(fx.add(fx.mul(x, 3), fx.mul(s, 0.7)), fx.mul(s, 1.3))), 0.5), 0.05),
	)
}

lens_look :: proc() -> ^fx.Node {
	lens := fx.param("lens", [4]f32{-1, 0, 1e6, 0})
	line, s, stream_end, clear := component(lens, "x"), component(lens, "y"), component(lens, "z"), component(lens, "w")
	size := fx.size()
	p := fx.div(fx.add(fx.coord(), fx.mul(size, 0.5)), component(size, "y")) // screen heights from the top left
	x := component(p, "x")
	up := fx.sub(1, component(p, "y"))
	waterline := lens_waterline(line, s, x)
	below := fx.sub(1, fx.smoothstep(fx.sub(waterline, 0.003), fx.add(waterline, 0.003), up))
	swirl := fx.add(p, fx.mul(fx.vec2(fx.sin(fx.sum(fx.mul(component(p, "y"), 7), fx.mul(s, 1.9), fx.sin(fx.mul(x, 3)))), fx.cos(fx.sub(fx.mul(x, 6), fx.mul(s, 1.6)))), 0.03))
	clouds := fx.fbm(fx.add(fx.mul(swirl, 3.2), fx.vec2(fx.mul(s, 0.15), fx.mul(s, -0.25))), 3)
	near_surface := fx.exp(fx.mul(fx.max(fx.sub(waterline, up), 0), -2.2))
	murk := fx.mul(MURK, fx.mul(fx.add(0.45, fx.mul(near_surface, 0.9)), fx.add(0.7, fx.mul(clouds, 0.6))))

	// Bubbles crowd along the waterline and fill the water below it in a steady stream;
	// whether a bubble is there goes by its middle (and the waterline there), so it is whole
	density :: proc(at: ^fx.Node, data: [2]^fx.Node) -> ^fx.Node {
		line, s := data[0], data[1]
		up := fx.sub(1, component(at, "y"))
		waterline := lens_waterline(line, s, component(at, "x"))
		gap := fx.div(fx.sub(up, waterline), 0.16)
		crowd := fx.add(fx.mul(fx.exp(fx.neg(fx.mul(gap, gap))), 0.9), fx.mul(fx.step(up, waterline), BUBBLE_STREAM))
		return fx.mul(crowd, fx.sub(1, fx.smoothstep(waterline, fx.add(waterline, 0.02), up)))
	}
	data := [2]^fx.Node{line, s}
	in_water := fx.sub(1, fx.smoothstep(waterline, fx.add(waterline, 0.01), up)) // none over the surface
	murky := fx.mul(below, fx.sub(1, clear))
	light := fx.mul(murk, below)
	cover := murky
	layers := BUBBLE_LAYERS
	for layer in layers {
		l, c := bubble_layer(swirl, s, stream_end, layer, density, data)
		light = fx.add(light, fx.mul(l, in_water))
		cover = fx.max(cover, fx.mul(c, in_water))
	}
	froth := fx.mul(fx.sub(1, fx.smoothstep(0, 0.03, fx.abs(fx.sub(up, waterline)))), fx.smoothstep(0.3, 0.7, fx.noise(fx.vec2(fx.mul(x, 30), fx.mul(s, 4)))))
	light = fx.add(light, fx.mul(linear(FOAM), fx.mul(froth, 0.12)))
	return finish(light, fx.saturate(fx.max(cover, fx.mul(froth, 0.85))))
}
