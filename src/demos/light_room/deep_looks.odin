package main

import fx "../../engine/vfx"
import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

// Scene 2's looks (deep.odin): the room as a cave under the sea, its plants AlgoGame's. The
// water is clear: across the room it hardly shows; it fades everything by SEA_FOG per meter
// (sea_fog; the other looks get it through with_water, param `sea`) into its own light: dark
// in the cave, AlgoGame's dark water past it. Beyond the cave is AlgoGame's background: its
// fog on the dark water all round (sea_backdrop_look, out of focus), its jellyfish
// (jelly_look, jelly.odin) and spores, seen where the room broke open.

// A surface `t` along the ray, seen through the water: in the cave (the room's box, which the
// ray leaves `exit` along it) the water is dark, little light getting in; past it, AlgoGame's
// dark water (SEA_FAR: the light `finish` shows as that color)
sea_fog :: proc(light: ^fx.Node, ray: Ray, t: fx.Expr, exit: ^fx.Node = nil) -> ^fx.Node {
	exit := exit if exit != nil else room_hit(ray).exit
	inside := fx.min(t, exit)
	beyond := fx.max(fx.sub(t, exit), 0)
	far := fx.mix(glowing(SEA_FAR), light, fx.exp(fx.mul(beyond, -SEA_FOG)))
	return fx.mix(CAVE_MURK, far, fx.exp(fx.mul(inside, -SEA_FOG)))
}

// AlgoGame's background (its fog_look) on the sky round the scene, as display light: the
// dark water, and over it fog of domain-warped noise (AlgoGame's own, with its integer
// hashing) tinted between its two hues, thinned to its upper range, slowly changing. The
// noise is laid out by the ray's direction, FOG_ANGLE radians a cell, as big on screen as
// AlgoGame's; round the horizon it starts again at +x (where the right wall stands), the
// first BACKDROP_SEAM cells fading from the noise past the end into its own, so no seam
// shows. Drawn into a small image (LAYER_SEA), as AlgoGame does. Params: deep (the clock in y).
sea_backdrop_look :: proc() -> ^fx.Node {
	d := camera_ray().dir
	x, y, z := component(d, "x"), component(d, "y"), component(d, "z")
	// The direction's angle round the horizon, from +x round through +z, -x and -z (0 .. 2π)
	flat := fx.max(fx.length(fx.vec2(x, z)), 1e-4)
	across := fx.asin(fx.max(fx.min(fx.div(fx.neg(x), flat), 1), -1)) // -π/2 at +x .. π/2 at -x
	around := fx.add(fx.mix(fx.sub(math.PI, across), across, fx.step(0, z)), math.PI / 2)
	u := fx.div(around, FOG_ANGLE)
	v := fx.div(fx.asin(fx.max(fx.min(y, 1), -1)), -FOG_ANGLE) // down the screen, as AlgoGame's y
	t := fx.div(component(fx.param("deep", [4]f32{0, 0, 0, 0}), "y"), FOG_PERIOD)
	fog :: proc(u, v, t: fx.Expr) -> ^fx.Node {
		hi, lo := f32(BACKDROP_SEED >> 16), f32(BACKDROP_SEED & 0xffff)
		wx := fx.sub(fx.mul(fx.int_fbm(fx.vec2(u, fx.add(v, fx.mul(t, 0.5))), hi, lo, 2, 11), 2), 1)
		wy := fx.sub(fx.mul(fx.int_fbm(fx.vec2(fx.add(u, fx.mul(t, 0.3)), v), hi, lo, 2, 12), 2), 1)
		n := fx.int_fbm(fx.vec2(fx.add(fx.add(u, fx.mul(wx, FOG_WARP)), fx.mul(t, 0.2)), fx.add(v, fx.mul(wy, FOG_WARP))), hi, lo, 3, 13)
		k := fx.saturate(fx.div(fx.sub(n, 0.35), 0.5))
		alpha := fx.min(fx.mul(fx.mul(fx.mul(k, k), fx.sub(3, fx.mul(k, 2))), FOG_INTENSITY), 1)
		tint := fx.mix(display(FOG_A), display(FOG_B), fx.div(fx.add(wx, 1), 2))
		return fx.mix(display(SEA_BACKGROUND), tint, alpha)
	}
	period := f32(2 * math.PI / FOG_ANGLE)
	own := fog(u, v, t)
	seam := fx.sub(1, fx.smoothstep(0, BACKDROP_SEAM, u))
	return fx.add(fx.add(own, fx.gate(seam, fx.mul(fx.sub(fog(fx.add(u, period), v, t), own), seam))), W1)
}

// The light that `finish` turns back into the sRGB color c: AlgoGame's plants are drawn in
// their colors as they are, so here they glow with that light, unlit
glowing :: proc(c: rl.Color) -> [4]f32 {
	out: [4]f32
	for k in 0 ..< 3 {
		v := math.pow(f32(c[k]) / 255, 2.2)
		out[k] = -math.ln(1 - min(v, 0.995)) / DEEP_EXPOSURE
	}
	return out
}

// An sRGB color as display light, to add after `finish`
display :: proc(c: rl.Color) -> [4]f32 {return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, 0}}

// ---------------------------------------------------------------------------------------
// The cave. The ray leaves the room's box through a face (room_hit), but where the room broke
// open there is none: the near wall, the left wall short of left_break, the right wall short
// of right_break, the ceiling along those sides (ceiling_left); there the ray goes on into
// the sea: the seabed where it comes down to it (fading out far off, BED_NEAR to BED_FAR),
// else nothing (premultiplied: the background drawn before shows). The faces left are rock,
// lumpy and pitted; the floor is silted over, its tiles showing here and there, the hatch's
// opening black. No lights: the water's
// ambient light and the sea's through the openings, and on the floor round the plants
// AlgoGame's light on the rock, sand grains sparkling in it (plant_glow). Params: the
// camera, exposure, deep = (seconds into scene 2, the clock, 0, 0), the plants' pools of
// light and glint spots.

// Where the left wall still stands (beyond this z), by height: ragged
left_break :: proc(y: fx.Expr) -> ^fx.Node {
	return fx.sum(LEFT_BREAK, fx.mul(fx.noise(fx.vec2(fx.mul(y, 0.8), 3.7)), 1.8), fx.mul(fx.noise(fx.vec2(fx.mul(y, 3.9), 8.3)), 0.45))
}

// The same for the right wall, whose near end broke off with the near wall
right_break :: proc(y: fx.Expr) -> ^fx.Node {
	return fx.sum(0.3, fx.mul(fx.noise(fx.vec2(fx.mul(y, 0.9), 5.1)), 1.1), fx.mul(fx.noise(fx.vec2(fx.mul(y, 4.3), 2.2)), 0.35))
}

// How much of a face is there `gap` meters past its broken edge (anti-aliased over aa)
standing :: proc(gap, aa: fx.Expr) -> ^fx.Node {return fx.smoothstep(fx.neg(aa), aa, gap)}

// How much of the ceiling is left at (x, z): broken off along the near side, and along the
// left side where the left wall below it is gone
ceiling_left :: proc(x, z, aa: ^fx.Node) -> ^fx.Node {
	near := fx.sub(z, fx.sum(0.5, fx.mul(fx.noise(fx.vec2(fx.mul(x, 0.45), 1.3)), 1.4), fx.mul(fx.noise(fx.vec2(fx.mul(x, 2.3), 5.1)), 0.35)))
	side := fx.sub(x, fx.sum(-ROOM_HALF_WIDTH + 0.3, fx.mul(fx.noise(fx.vec2(fx.mul(z, 0.5), 2.9)), 1.3), fx.mul(fx.noise(fx.vec2(fx.mul(z, 2.1), 7.7)), 0.3)))
	return fx.mul(standing(near, aa), fx.max(standing(side, aa), standing(fx.sub(z, left_break(f32(ROOM_HEIGHT))), aa)))
}

cave_look :: proc() -> ^fx.Node {
	ray := camera_ray()
	hit := room_hit(ray)
	face, ahead := hit.face, hit.ahead
	aa := fx.mul(hit.exit, camera_pixel())
	x, y, z := component(hit.pos, "x"), component(hit.pos, "y"), component(hit.pos, "z")
	floor := fx.mul(component(face, "y"), fx.sub(1, component(ahead, "y")))
	ceiling := fx.mul(component(face, "y"), component(ahead, "y"))
	left := fx.mul(component(face, "x"), fx.sub(1, component(ahead, "x")))
	right := fx.mul(component(face, "x"), component(ahead, "x"))
	far := fx.mul(component(face, "z"), component(ahead, "z"))
	solid := fx.saturate(fx.sum(
		floor,
		far,
		fx.gate(left, fx.mul(left, standing(fx.sub(z, left_break(y)), aa))), // each edge worked out on its own face only
		fx.gate(right, fx.mul(right, standing(fx.sub(z, right_break(y)), aa))),
		fx.gate(ceiling, fx.mul(ceiling, ceiling_left(x, z, aa))),
	))
	// Where it is open: the seabed where the ray comes down to it, fading out far off into the
	// background drawn before (premultiplied: elsewhere nothing covers it)
	dy := component(ray.dir, "y")
	t_bed := fx.div(fx.neg(component(ray.origin, "y")), fx.min(dy, -1e-4))
	bed := fx.mul(fx.mul(fx.sub(1, solid), fx.step(dy, -1e-4)), fx.smoothstep(BED_FAR, BED_NEAR, t_bed))
	seen := fx.add(fx.gate(solid, fx.mul(cave_face(ray, hit), solid)), fx.gate(bed, fx.mul(seabed(ray, t_bed), bed)))
	return fx.add(seen, fx.mul(W1, fx.add(solid, bed)))
}

// The light every face of the cave gets without the plants' lights: the water's from above
// and below, and the sea's coming in where the room broke open
cave_ambient :: proc(normal: fx.Expr, pos: ^fx.Node) -> ^fx.Node {
	up := fx.add(fx.mul(component(normal, "y"), 0.5), 0.5)
	x, z := component(pos, "x"), component(pos, "z")
	open := fx.add(fx.exp(fx.div(z, -OPEN_REACH)), fx.mul(fx.exp(fx.div(fx.add(x, ROOM_HALF_WIDTH), -OPEN_REACH)), fx.smoothstep(LEFT_BREAK + 2, LEFT_BREAK, z)))
	return fx.add(fx.mix(SEA_AMBIENT_GROUND, SEA_AMBIENT_SKY, up), fx.mul(OPEN_LIGHT, open))
}

// A face of the cave where the ray lands, seen through the water, as display light (w 0)
cave_face :: proc(ray: Ray, hit: RoomHit) -> ^fx.Node {
	pos, face, ahead := hit.pos, hit.face, hit.ahead
	floor := fx.mul(component(face, "y"), fx.sub(1, component(ahead, "y")))
	fx_, fy, fz := component(face, "x"), component(face, "y"), component(face, "z")
	// Surface coordinates in meters, as room_look's
	uv := fx.sum(fx.mul(fx.swizzle(pos, "zy"), fx_), fx.mul(fx.swizzle(pos, "xz"), fy), fx.mul(fx.swizzle(pos, "xy"), fz))
	aa := fx.mul(hit.exit, camera_pixel())
	// Rock: lumps and hollows, dark in the hollows, pitted with small dark pores
	h := fx.add(fx.mul(fx.fbm(fx.mul(uv, 1.1), 3), 0.75), fx.mul(fx.noise(fx.mul(uv, 4.7)), 0.25))
	pores := fx.smoothstep(0.7, 0.78, fx.noise(fx.add(fx.mul(uv, 6.3), 11.1)))
	rock := fx.mul(fx.mix(linear(ROCK_DARK), linear(ROCK), fx.smoothstep(0.3, 0.75, h)), fx.sub(1, fx.mul(pores, 0.7)))
	// Floor: the tiles under silt, which lies thicker in the hollows; the hatch's opening black
	tile := [2]f32{TILE_SIZE, TILE_SIZE}
	tone := fx.mix(linear(FLOOR_TILE_A), linear(FLOOR_TILE_B), fx.mul(fx.hash(fx.cell_id(uv, tile)), 0.8))
	tiles := fx.mul(fx.mix(tone, linear(GROUT), floor_grout(uv, aa)), 0.55)
	silted := fx.smoothstep(0.3, 0.6, fx.add(h, fx.mul(fx.noise(fx.mul(uv, 0.35)), 0.4)))
	rr, _ := from_hatch(pos)
	opening := fx.sub(1, fx.smoothstep(fx.sub(HATCH_LID - 0.03, aa), fx.add(HATCH_LID - 0.03, aa), rr))
	ground := fx.mul(fx.mix(tiles, linear(SILT), silted), fx.sub(1, opening))
	albedo := fx.mix(rock, ground, floor)
	light := fx.mul(fx.mul(albedo, cave_ambient(hit.normal, pos)), corner_occlusion(hit))
	seen := finish(sea_fog(light, ray, hit.exit, hit.exit), 0)
	bare := fx.mul(floor, fx.sub(1, opening)) // the floor round the opening
	return fx.add(seen, fx.gate(bare, fx.mul(plant_glow(pos, aa), fx.mul(bare, fx.exp(fx.mul(hit.exit, -SEA_FOG))))))
}

// The seabed's sand `t` along the ray, as display light: rippled, AlgoGame's light on it
// round the plants out there, through the water
seabed :: proc(ray: Ray, t: ^fx.Node) -> ^fx.Node {
	at := fx.add(ray.origin, fx.mul(ray.dir, t))
	uv := fx.swizzle(at, "xz")
	ripple := fx.add(fx.mul(fx.dot(uv, [2]f32{1.7, 0.9}), 3.5), fx.mul(fx.noise(fx.mul(uv, 0.7)), 5))
	shading := fx.add(0.85, fx.mul(fx.sin(ripple), 0.15))
	albedo := fx.mul(fx.mul(linear(SAND), fx.add(0.7, fx.mul(fx.fbm(fx.mul(uv, 0.5), 3), 0.6))), shading)
	light := fx.mul(albedo, cave_ambient([4]f32{0, 1, 0, 0}, at))
	seen := finish(sea_fog(light, ray, t), 0)
	return fx.add(seen, fx.mul(plant_glow(at, fx.mul(t, camera_pixel())), fx.exp(fx.mul(t, -SEA_FOG))))
}

// AlgoGame's light of the plants on the rock round them, as display light added over the
// floor: a soft pool of each plant's glow color round its foot, and sand grains sparkling in
// it, as glint_look draws them: on a grid, half the cells holding one, a grain 1.5 to 3
// pixels across, catching the light near it (GLINT_FROM_POOL times the pool's) in the
// brightest plant's color brightened toward white, in four brightness steps, sparkling now
// and then. Params: pools (x, z, radius, strength each: the corals' first, pool_split of
// them, then the fans', pool_count in all), deep (the clock in y).
plant_glow :: proc(pos, aa: ^fx.Node) -> ^fx.Node {
	uv := fx.swizzle(pos, "xz")
	pools := fx.param_array("pools", len(plants) * fx.GLOW_STRIDE)
	split, count := fx.param("pool_split", f32(0)), fx.param("pool_count", f32(0))
	coral_lit := fx.glow_points(uv, pools, 0, split)
	fan_lit := fx.glow_points(uv, pools, split, fx.sub(count, split))
	pool := fx.add(fx.mul(display(CORAL_GLOW), coral_lit), fx.mul(display(SEA_FAN_GLOW), fan_lit))
	brightest := fx.mul(fx.max(coral_lit, fan_lit), GLINT_FROM_POOL)
	glint :: proc(c: rl.Color) -> [4]f32 {
		v := display(c)
		return {v.r + (1 - v.r) * 0.55, v.g + (1 - v.g) * 0.55, v.b + (1 - v.b) * 0.55, 0}
	}
	color := fx.mix(glint(CORAL_GLOW), glint(SEA_FAN_GLOW), fx.step(coral_lit, fan_lit))
	sparkle_time := fx.mul(component(fx.param("deep", [4]f32{0, 0, 0, 0}), "y"), 2.3)
	cells := fx.div(uv, GLINT_CELL)
	c0 := fx.floor(fx.sub(cells, 0.5))
	grains: ^fx.Node
	for offset in ([4][2]f32{{0, 0}, {1, 0}, {0, 1}, {1, 1}}) {
		cell := fx.add(c0, offset)
		present := fx.step(fx.hash(cell), 0.5)
		grain := fx.mul(fx.add(cell, fx.vec2(fx.hash(fx.add(cell, 1.3)), fx.hash(fx.add(cell, 2.7)))), GLINT_CELL)
		pixels := fx.div(fx.length(fx.sub(uv, grain)), aa)
		half := fx.add(0.75, fx.mul(fx.hash(fx.add(cell, 4.4)), 0.75))
		cover := fx.mul(present, fx.saturate(fx.sub(fx.add(half, 0.5), pixels)))
		phase := fx.add(0.5, fx.mul(fx.sin(fx.add(sparkle_time, fx.mul(fx.hash(fx.add(cell, 3.1)), 6.28))), 0.5))
		best := fx.mul(brightest, fx.add(0.25, fx.mul(fx.mul(fx.mul(phase, phase), phase), 0.75)))
		steps := fx.mul(fx.step(0.125, best), fx.div(fx.min(fx.floor(fx.add(fx.mul(best, 4), 0.5)), 4), 4))
		k := fx.mul(steps, cover)
		grains = k if grains == nil else fx.add(grains, k)
	}
	// Grains closer together on screen than a few pixels would only flicker: they fade out
	apart := fx.smoothstep(2.5, 6, fx.div(GLINT_CELL, aa))
	return fx.add(pool, fx.gate(fx.mul(fx.step(0.125, brightest), apart), fx.mul(color, fx.mul(grains, apart))))
}

// ---------------------------------------------------------------------------------------
// A coral: AlgoGame's branching coral grown in 3D (grow_coral), each branch a tapering tube
// (a round cone: exact ray hit), one instanced quad per branch, ordered far to near. A record
// (CORAL_RECORD): quad | a.xyz, radius at a | b.xyz, radius at b | branching level, 0, 0, 0.
// Unlit, in AlgoGame's colors by level (trunk to tip), a little brighter where it faces the
// eye, so it looks round; the tips' soft glow is drawn over it (tip glows, deep.odin).

// Where a ray enters the round cone a-b with radii ra, rb (iquilezles.org/articles/
// intersectors): its side, else the nearer of its end spheres; hit is 1 if it does at all
round_cone_hit :: proc(ray: Ray, a, b, ra, rb: ^fx.Node) -> (t, hit: ^fx.Node) {
	ba := fx.sub(b, a)
	oa := fx.sub(ray.origin, a)
	ob := fx.sub(ray.origin, b)
	rr := fx.sub(ra, rb)
	m0 := fx.dot(ba, ba)
	m1 := fx.dot(ba, oa)
	m2 := fx.dot(ba, ray.dir)
	m3 := fx.dot(ray.dir, oa)
	m5 := fx.dot(oa, oa)
	m6 := fx.dot(ob, ray.dir)
	m7 := fx.dot(ob, ob)
	d2 := fx.sub(m0, fx.mul(rr, rr))
	k2 := fx.sub(d2, fx.mul(m2, m2))
	k1 := fx.add(fx.sub(fx.mul(d2, m3), fx.mul(m1, m2)), fx.mul(fx.mul(m2, rr), ra))
	k0 := fx.sub(fx.add(fx.sub(fx.mul(d2, m5), fx.mul(m1, m1)), fx.mul(fx.mul(fx.mul(m1, rr), ra), 2)), fx.mul(fx.mul(m0, ra), ra))
	h := fx.sub(fx.mul(k1, k1), fx.mul(k0, k2))
	side_t := fx.div(fx.sub(fx.neg(fx.sqrt(fx.max(h, 0))), k1), k2)
	along := fx.add(fx.sub(m1, fx.mul(ra, rr)), fx.mul(side_t, m2))
	side := fx.mul(fx.mul(fx.step(0, h), fx.step(0, along)), fx.step(along, d2))
	h1 := fx.add(fx.sub(fx.mul(m3, m3), m5), fx.mul(ra, ra))
	h2 := fx.add(fx.sub(fx.mul(m6, m6), m7), fx.mul(rb, rb))
	t1 := fx.mix(1e6, fx.sub(fx.neg(m3), fx.sqrt(fx.max(h1, 0))), fx.step(0, h1))
	t2 := fx.mix(1e6, fx.sub(fx.neg(m6), fx.sqrt(fx.max(h2, 0))), fx.step(0, h2))
	ends := fx.min(t1, t2)
	t = fx.mix(ends, side_t, side)
	hit = fx.mul(fx.max(side, fx.step(ends, 1e5)), fx.step(0, t))
	return
}

coral_look :: proc() -> ^fx.Node {
	records := fx.instances("branches", CORAL_RECORD, MAX_BRANCHES)
	ray := camera_ray()
	hit := cone_hit(records, ray)
	facing := fx.saturate(fx.neg(fx.dot(hit.normal, ray.dir)))
	color := fx.mix(glowing(CORAL_TRUNK), glowing(CORAL_TIP), fx.saturate(fx.div(component(hit.info, "x"), CORAL_DEPTH - 1)))
	light := fx.mul(color, fx.add(0.7, fx.mul(facing, 0.4)))
	return finish(fx.gate(hit.coverage, with_water(light, ray, hit.t)), hit.coverage)
}

// Where the ray meets the round cone of an instanced record (CORAL_RECORD): how far along the
// ray (the hit, or on a miss its closest pass), the cone's normal there, the pixel's coverage
// and the record's last four values (level, 0, 0, 0)
ConeHit :: struct {
	t, normal, coverage, info: ^fx.Node,
}

cone_hit :: proc(records: ^fx.Node, ray: Ray) -> (out: ConeHit) {
	pix := camera_pixel()
	ra4, rb4 := fx.instance4(records, 4), fx.instance4(records, 8)
	out.info = fx.instance4(records, 12)
	a, b := xyz(ra4), xyz(rb4)
	ra, rb := component(ra4, "w"), component(rb4, "w")
	hit_t, hit := round_cone_hit(ray, a, b, ra, rb)
	// The closest pass of its axis, for the anti-aliased outline (the radius there)
	near_t, gap := segment_approach(ray.origin, ray.dir, a, b)
	ba := fx.sub(b, a)
	pass := fx.add(ray.origin, fx.mul(ray.dir, near_t))
	pass_s := fx.saturate(fx.div(fx.dot(fx.sub(pass, a), ba), fx.dot(ba, ba)))
	miss := fx.sub(gap, fx.mix(ra, rb, pass_s))
	out.coverage = fx.saturate(fx.sub(0.5, fx.div(miss, fx.mul(fx.max(near_t, 0.1), pix))))
	out.t = fx.mix(near_t, hit_t, hit)
	pos := fx.add(ray.origin, fx.mul(ray.dir, out.t))
	// Its surface's way round its axis (it tapers too little to matter), round at its ends
	s := fx.saturate(fx.div(fx.dot(fx.sub(pos, a), ba), fx.dot(ba, ba)))
	out.normal = normalize3(fx.sub(pos, fx.add(a, fx.mul(ba, s))))
	return
}

// ---------------------------------------------------------------------------------------
// A sea fan: AlgoGame's fan (a dome of branches, a net of lace between their ends, sunk into
// the floor), grown flat (grow_fan) and bent round into a deep cup: a part of an upright
// cylinder (radius fan_cup) whose middle is the fan's root and whose sides come forward round
// its facing (fan_cup_point). The ray meets the cylinder twice; at each the fan's capsules (in
// centimeters across the cup and up from its root, data array `fan`, binned) give the distance
// to the nearest branch and to the nearest lace, and the nearer is drawn over the farther, so
// the cup's far side shows through its lace. Unlit, in AlgoGame's colors: rusty at the root to
// orange at the tips, the lace orange and half see-through; its glow round every piece,
// faint, and bright where the wave of light running up it is, as AlgoGame's three passes
// (wide and faint to thin and strong). Premultiplied: the glow is light added round it.
// Params: fan_o (its root), fan_u (across it, level), fan_n (the way its cup opens), fan_cup
// (the cup's radius, meters), fan_shape = (its height, the wave: 0 at the root, 1 at the
// tips, how many of the capsules are branches, its first branch's length in centimeters),
// the capsules and their bins.

fan_look :: proc() -> ^fx.Node {
	ray := camera_ray()
	root := fx.param("fan_o", [4]f32{0, 0, 0, 0})
	along := fx.param("fan_u", [4]f32{1, 0, 0, 0})
	opens := fx.param("fan_n", [4]f32{0, 0, 1, 0})
	radius := fx.param("fan_cup", f32(1))
	center := fx.add(root, fx.mul(opens, radius))
	// Where the ray meets the cylinder (upright, round `center`): nearer and farther
	oc := fx.swizzle(fx.sub(ray.origin, center), "xz")
	dxz := fx.swizzle(ray.dir, "xz")
	qa := fx.max(fx.dot(dxz, dxz), 1e-6)
	qb := fx.dot(oc, dxz)
	disc := fx.sub(fx.mul(qb, qb), fx.mul(qa, fx.sub(fx.dot(oc, oc), fx.mul(radius, radius))))
	root_disc := fx.sqrt(fx.max(disc, 0))
	meets := fx.step(0, disc)
	near := fan_layer(ray, fx.div(fx.sub(fx.neg(qb), root_disc), qa), meets, root, along, opens, center, radius)
	far := fan_layer(ray, fx.div(fx.sub(root_disc, qb), qa), meets, root, along, opens, center, radius)
	clear := fx.sub(1, component(near, "w"))
	return fx.add(near, fx.gate(clear, fx.mul(far, clear)))
}

// The fan where the ray meets its cup `t` along it (premultiplied: rgb, coverage)
fan_layer :: proc(ray: Ray, t, meets, root, along, opens, center, radius: ^fx.Node) -> ^fx.Node {
	info := fx.param("fan_shape", [4]f32{1, 0, 0, 30})
	height, wave, branches, first := component(info, "x"), component(info, "y"), component(info, "z"), component(info, "w")
	pos := fx.add(ray.origin, fx.mul(ray.dir, t))
	q := fx.sub(pos, center)
	across := fx.dot(q, along)
	back := fx.neg(fx.dot(q, opens)) // > 0 on the cup's own side of the cylinder
	angle := fx.asin(fx.max(fx.min(fx.div(across, radius), 1), -1))
	uv := fx.mul(fx.vec2(fx.mul(radius, angle), fx.sub(component(pos, "y"), component(root, "y"))), 100) // centimeters
	capsules := fx.data_array("fan", MAX_FAN_CAPSULES * fx.CAPSULE_STRIDE)
	bins := fx.data_array("fan_bins", MAX_FAN_BINS)
	// A pixel's width across the cup, wider where it turns side-on
	normal := normalize3(fx.mul(q, [4]f32{1, 0, 1, 0}))
	facing := fx.abs(fx.dot(ray.dir, normal))
	footprint := fx.div(fx.mul(fx.mul(t, camera_pixel()), 100), fx.max(facing, 0.2))
	cover :: proc(d, half, soft: fx.Expr) -> ^fx.Node {return fx.saturate(fx.add(fx.div(fx.sub(half, d), soft), 0.5))}
	d_branch := fx.sd_capsules(uv, capsules, 0, branches, bins)
	d_lace := fx.sd_capsules(uv, capsules, branches, -1, bins)
	branch := cover(d_branch, f32(0), footprint)
	lace := fx.mul(cover(d_lace, f32(0), footprint), FAN_LACE)
	// Only on the cup's side, above the floor (it is sunk into it), in front of the camera;
	// seen edge-on it fades out (a line there, which the surface can't draw)
	there := fx.mul(fx.mul(meets, fx.step(0, t)), fx.mul(fx.step(0, back), fx.smoothstep(0, fx.mul(t, camera_pixel()), component(pos, "y"))))
	there = fx.mul(there, fx.smoothstep(0.06, 0.2, facing))
	coverage := fx.mul(fx.max(branch, lace), there)
	up_fan := fx.saturate(fx.div(fx.length(uv), fx.mul(height, 100))) // 0 at the root, about 1 at the tips
	color := fx.mix(fx.to_node(glowing(SEA_FAN_TIP)), fx.mix(glowing(SEA_FAN_BASE), glowing(SEA_FAN_TIP), up_fan), fx.step(lace, branch))
	body := finish(fx.gate(coverage, with_water(color, ray, t)), coverage)
	// Its glow: AlgoGame's three passes round the nearest piece, brighter in the wave
	pulse := fx.add(0.25, fx.mul(fx.exp(fx.div(fx.mul(fx.sub(up_fan, wave), fx.sub(up_fan, wave)), -0.012)), 1.3))
	d := fx.min(d_branch, d_lace)
	soft := fx.mul(footprint, 2)
	glow: ^fx.Node
	for pass in ([3][2]f32{{1, 0.07}, {0.5, 0.13}, {0.2, 0.3}}) {
		half := fx.mul(first, FAN_GLOW_WIDTH * pass[0])
		k := fx.mul(cover(d, half, soft), fx.min(fx.mul(pulse, pass[1] * FAN_GLOW_STRENGTH), 1))
		glow = k if glow == nil else fx.add(glow, k)
	}
	return fx.add(fx.mul(body, fx.rgba(coverage, coverage, coverage, 1)), fx.mul(display(SEA_FAN_GLOW), fx.mul(glow, there)))
}

// ---------------------------------------------------------------------------------------
// The "ZSE" letters in the deep: scene 1's letters standing on the floor, made of pipes (each
// stroke a tube LOGO_TUBE thick, bent round the corners), hollow and open at the ends of the
// strokes (where an end is buried in another stroke of the letter, it is closed): there the
// ray sees the cut rim of the pipe's wall and its inside, darkening deeper in. Rusty all
// over, streaked by rust running down, grey metal showing in patches, lumps of crusted
// growth with dark pits; lit as the objects are (the plants' lights that reach it: param
// mask, the water's light). Params: ca<k>/cb<k> (its capsules), pivot (its middle).

// A stroke's tube a-b with open ends (`open`: at a, at b): as tube_approach, plus what the
// ray sees through an open end: kind 1 the cut rim (normal: out of the end), kind 2 the
// pipe's inside (normal: inwards), `depth` meters in from the end
open_pipe :: proc(ray: Ray, a, b: ^fx.Node, open: [2]bool) -> (key, t, coverage, kind, normal, depth: ^fx.Node) {
	o, d := ray.origin, ray.dir
	pix := camera_pixel()
	outer_r := f32(LOGO_TUBE)
	inner_r := outer_r * (1 - PIPE_WALL)
	hit_t, hit := capsule_hit(ray, a, b, outer_r)
	ba := fx.sub(b, a)
	length := fx.length(ba)
	axis := fx.div(ba, length)
	s := fx.dot(fx.sub(fx.add(o, fx.mul(d, hit_t)), a), axis)
	// The outside, cut off at the open ends
	outside := hit
	near_t, gap := segment_approach(o, d, a, b)
	s_pass := fx.dot(fx.sub(fx.add(o, fx.mul(d, near_t)), a), axis)
	foot := fx.mul(fx.max(near_t, 0.1), pix)
	coverage = fx.saturate(fx.sub(0.5, fx.div(fx.sub(gap, outer_r), foot)))
	if open[0] {
		outside = fx.mul(outside, fx.step(0, s))
		coverage = fx.mul(coverage, fx.saturate(fx.add(0.5, fx.div(s_pass, foot))))
	}
	if open[1] {
		outside = fx.mul(outside, fx.step(s, length))
		coverage = fx.mul(coverage, fx.saturate(fx.sub(0.5, fx.div(fx.sub(s_pass, length), foot))))
	}
	key = fx.mix(fx.add(fx.sub(gap, outer_r), 100), hit_t, outside)
	t = fx.mix(near_t, hit_t, outside)
	kind, normal, depth = fx.to_node(f32(0)), fx.to_node([4]f32{0, 0, 0, 0}), fx.to_node(f32(0))
	// Where the inside's wall is: where the ray leaves the inner tube's cylinder
	oc := fx.sub(o, a)
	dd := fx.sub(d, fx.mul(axis, fx.dot(d, axis)))
	oo := fx.sub(oc, fx.mul(axis, fx.dot(oc, axis)))
	qa := fx.max(fx.dot(dd, dd), 1e-6)
	qb := fx.dot(oo, dd)
	qc := fx.sub(fx.dot(oo, oo), inner_r * inner_r)
	t_in := fx.div(fx.add(fx.neg(qb), fx.sqrt(fx.max(fx.sub(fx.mul(qb, qb), fx.mul(qa, qc)), 0))), qa)
	in_pos := fx.add(o, fx.mul(d, t_in))
	in_s := fx.dot(fx.sub(in_pos, a), axis)
	in_normal := normalize3(fx.sub(fx.add(a, fx.mul(axis, in_s)), in_pos))
	for end in 0 ..< 2 {
		if !open[end] {
			continue
		}
		e := a if end == 0 else b
		out := fx.neg(axis) if end == 0 else axis
		// Where the ray crosses the end's plane, coming in, and how far from the axis
		dn := fx.dot(d, out)
		facing := fx.step(dn, -1e-4)
		tp := fx.div(fx.dot(fx.sub(e, o), out), fx.min(dn, -1e-4))
		rho := fx.length(fx.sub(fx.add(o, fx.mul(d, tp)), e))
		through := fx.mul(fx.mul(facing, fx.step(0, tp)), fx.sub(1, outside))
		rim := fx.mul(through, fx.mul(fx.step(inner_r, rho), fx.step(rho, outer_r)))
		into := fx.mul(through, fx.step(rho, inner_r))
		// The end seen as a disc, for the outline
		disc := fx.saturate(fx.add(fx.div(fx.sub(outer_r, rho), fx.mul(fx.max(tp, 0.1), pix)), 0.5))
		coverage = fx.max(coverage, fx.mul(fx.mul(facing, fx.step(0, tp)), disc))
		seen := fx.add(rim, into)
		key = fx.mix(key, tp, seen)
		t = fx.mix(fx.mix(t, tp, rim), t_in, into)
		kind = fx.sum(kind, rim, fx.mul(into, 2))
		normal = fx.sum(normal, fx.mul(out, rim), fx.mul(in_normal, into))
		depth = fx.add(depth, fx.mul(into, in_s if end == 0 else fx.sub(length, in_s)))
	}
	return
}

pipe_letter_look :: proc(capsules: []Capsule) -> ^fx.Node {
	ray := camera_ray()
	// Which ends are open: those that end a stroke, unless buried in another stroke of the letter
	buried :: proc(capsules: []Capsule, k: int, p: Vec3) -> bool {
		for c, j in capsules {
			if j == k || j == capsules[k].prev || j == capsules[k].next {
				continue
			}
			ab := c.b - c.a
			s := math.saturate(linalg.dot(p - c.a, ab) / linalg.dot(ab, ab))
			if linalg.distance(p, c.a + ab * s) < LOGO_TUBE {
				return true
			}
		}
		return false
	}
	key, shade_t, coverage, kind, special, depth: ^fx.Node
	seg_a, seg_b, before, after, free: ^fx.Node
	for c, k in capsules {
		a, b := fx.param(logo_a_names[k], [4]f32{0, 0, 0, 0}), fx.param(logo_b_names[k], [4]f32{0, 1, 0, 0})
		open := [2]bool{c.prev < 0 && !buried(capsules, k, c.a), c.next < 0 && !buried(capsules, k, c.b)}
		k_before := fx.param(logo_a_names[c.prev], [4]f32{0, 0, 0, 0}) if c.prev >= 0 else a
		k_after := fx.param(logo_b_names[c.next], [4]f32{0, 1, 0, 0}) if c.next >= 0 else b
		k_free := fx.to_node([2]f32{1 if c.prev < 0 && !open[0] else 0, 1 if c.next < 0 && !open[1] else 0})
		k_key, k_t, cover, k_kind, k_special, k_depth: ^fx.Node
		if open[0] || open[1] {
			k_key, k_t, cover, k_kind, k_special, k_depth = open_pipe(ray, a, b, open)
		} else {
			k_key, k_t, cover = tube_approach(ray, a, b, LOGO_TUBE)
			k_kind, k_special, k_depth = fx.to_node(f32(0)), fx.to_node([4]f32{0, 0, 0, 0}), fx.to_node(f32(0))
		}
		if key == nil {
			key, shade_t, coverage, kind, special, depth = k_key, k_t, cover, k_kind, k_special, k_depth
			seg_a, seg_b, before, after, free = a, b, k_before, k_after, k_free
			continue
		}
		closer := fx.step(k_key, key)
		key = fx.min(key, k_key)
		shade_t = fx.mix(shade_t, k_t, closer)
		kind = fx.mix(kind, k_kind, closer)
		special = fx.mix(special, k_special, closer)
		depth = fx.mix(depth, k_depth, closer)
		seg_a = fx.mix(seg_a, a, closer)
		seg_b = fx.mix(seg_b, b, closer)
		before = fx.mix(before, k_before, closer)
		after = fx.mix(after, k_after, closer)
		free = fx.mix(free, k_free, closer)
		coverage = fx.max(coverage, cover)
	}
	pos := fx.add(ray.origin, fx.mul(ray.dir, shade_t))
	// The outside's smooth normal, as letter_hit's
	ba := fx.sub(seg_b, seg_a)
	along := fx.div(fx.dot(fx.sub(pos, seg_a), ba), fx.dot(ba, ba))
	clamped := fx.saturate(along)
	out := fx.sub(pos, fx.add(seg_a, fx.mul(ba, clamped)))
	tangent := normalize3(fx.mix(normalize3(fx.sub(seg_b, before)), normalize3(fx.sub(after, seg_a)), clamped))
	on_cap := fx.add(fx.mul(fx.step(along, 0), component(free, "x")), fx.mul(fx.step(1, along), component(free, "y")))
	smooth := normalize3(fx.sub(out, fx.mul(tangent, fx.mul(fx.dot(out, tangent), fx.sub(1, on_cap)))))
	outside := fx.step(kind, 0.5)
	rim := fx.mul(fx.step(0.5, kind), fx.step(kind, 1.5))
	inside := fx.step(1.5, kind)

	// The rust: coordinates across the letter, the tube's front and back apart
	q := fx.sub(pos, fx.param("pivot", [4]f32{0, 0, 0, 0}))
	uv := fx.vec2(fx.add(component(q, "x"), fx.mul(component(q, "z"), 0.6)), fx.sub(component(q, "y"), fx.mul(component(q, "z"), 0.4)))
	patches := fx.fbm(fx.add(fx.mul(uv, 3.2), 1.7), 3)
	grain := fx.noise(fx.mul(uv, 21))
	crust := fx.smoothstep(0.55, 0.72, fx.add(patches, fx.mul(fx.sub(grain, 0.5), 0.3)))
	bare := fx.sub(1, fx.smoothstep(0.24, 0.36, patches))
	streaks := fx.noise(fx.vec2(fx.mul(component(uv, "x"), 17), fx.add(fx.mul(component(uv, "y"), 1.2), 4.1))) // rust running down
	albedo := fx.mix(linear(PIPE_RUST), linear(PIPE_RUST_DEEP), fx.mul(streaks, 0.75))
	albedo = fx.mix(albedo, linear(PIPE_METAL), fx.mul(bare, 0.8))
	albedo = fx.mix(albedo, fx.mul(linear(PIPE_CRUST), fx.add(0.55, fx.mul(grain, 0.7))), crust)
	pits := fx.mul(fx.smoothstep(0.7, 0.8, fx.noise(fx.add(fx.mul(uv, 13), 9.3))), crust)
	albedo = fx.mul(albedo, fx.sub(1, fx.mul(pits, 0.7)))
	// Lumpy where crusted: the normal bent by a bumpy height's slope
	bump :: proc(uv: ^fx.Node) -> ^fx.Node {return fx.add(fx.noise(fx.mul(uv, 7.3)), fx.mul(fx.noise(fx.mul(uv, 23)), 0.35))}
	h := bump(uv)
	slope := fx.vec2(fx.sub(bump(fx.add(uv, [2]f32{0.01, 0})), h), fx.sub(bump(fx.add(uv, [2]f32{0, 0.01})), h))
	tilt := fx.add(fx.mul([4]f32{1, 0, 0.5, 0}, component(slope, "x")), fx.mul([4]f32{0, 1, -0.4, 0}, component(slope, "y")))
	bumpy := normalize3(fx.sub(smooth, fx.mul(tilt, fx.mul(fx.add(0.3, crust), PIPE_BUMP))))
	// The cut rim: grey metal, rusted at its edges; the inside: rust, darker deeper in
	albedo = fx.mix(albedo, fx.mix(linear(PIPE_METAL), linear(PIPE_RUST), fx.mul(grain, 0.6)), rim)
	albedo = fx.mix(albedo, fx.mul(linear(PIPE_RUST_DEEP), fx.exp(fx.div(depth, -0.3))), inside)
	normal := fx.add(fx.mul(bumpy, outside), fx.mul(special, fx.sub(1, outside)))
	surface := Surface {
		pos       = pos,
		normal    = normal,
		view      = fx.neg(ray.dir),
		albedo    = albedo,
		specular  = fx.add(0.06, fx.mul(fx.add(bare, rim), 0.25)),
		shininess = 18,
	}
	light := shade(surface, [4]f32{1, 1, 1, 1}, fx.param("mask", f32(-1)), nil)
	return finish(fx.gate(coverage, with_water(light, ray, shade_t)), coverage)
}

// ---------------------------------------------------------------------------------------
// Glowing dots, one instanced quad each, over the scene: the spores drifting in the water
// (added), the corals' tips' soft glow (premultiplied, as AlgoGame draws it: overlapping
// glows brighten towards their color, never past it). A record (DOT_RECORD): quad | sRGB
// color, brightness.

dots_look :: proc(name: string, max_count: int, falloff: fx.GlowFalloff, premultiplied := false) -> ^fx.Node {
	records := fx.instances(name, DOT_RECORD, max_count)
	color := fx.instance4(records, 4)
	r := fx.div(fx.length(fx.coord()), fx.instance(records, 2))
	strength := fx.mul(fx.falloff(r, falloff), component(color, "w"))
	if premultiplied {
		return fx.mul(fx.add(xyz(color), W1), strength)
	}
	return fx.mask(fx.add(xyz(color), W1), strength)
}

// ---------------------------------------------------------------------------------------
// A jellyfish: AlgoGame's jelly_look, as light (premultiplied, zero alpha), in its own frame
// (bell half-width `w`, meters; `unit` screen pixels a meter; the entity turns it). The bell
// is filled between its dome (flat to pointed) and its scalloped rim, and the oral arms are
// waving ribbons, both worked out per pixel; the strands (bell outline, canals, ribbon
// edges, filaments), the wide faint outline glow and the bright rim are capsules (in the
// entity's own pixels, binned). Gradients run down the jellyfish's height.

// A gradient with four stops (`at`, ascending) of the values `alpha`, constant outside
ramp4 :: proc(y, at, alpha: fx.Expr) -> ^fx.Node {
	s := [4]string{"x", "y", "z", "w"}
	acc := fx.swizzle(alpha, "x")
	for i in 1 ..< 4 {
		a0, a1 := fx.swizzle(at, s[i - 1]), fx.swizzle(at, s[i])
		k := fx.saturate(fx.div(fx.sub(y, a0), fx.max(fx.sub(a1, a0), 1e-6)))
		acc = fx.mix(acc, fx.swizzle(alpha, s[i]), k)
	}
	return acc
}

jelly_look :: proc() -> ^fx.Node {
	unit := fx.param("unit", f32(36))
	origin := fx.param("origin", [2]f32{0, 0}) // the jellyfish's (0, 0) in the entity's own pixels
	lp := fx.div(fx.sub(fx.coord(), origin), unit) // meters around the jellyfish
	x, y := fx.swizzle(lp, "x"), fx.swizzle(lp, "y")
	bw, bh := fx.param("bw", f32(1)), fx.param("bh", f32(0.4))
	w := fx.param("w", f32(1))
	time := fx.param("t", f32(0))
	phase := fx.param("phase", f32(0))
	// The bell: below the dome, above the rim's scallops, within its width
	xr := fx.div(x, bw)
	dome := fx.neg(fx.mul(fx.pow(fx.sqrt(fx.sub(1, fx.mul(xr, xr))), fx.param("peak", f32(1))), bh))
	u := fx.div(fx.add(xr, 1), 2)
	rim := fx.mul(fx.abs(fx.sin(fx.mul(u, fx.mul(fx.param("lobes", f32(8)), math.PI)))), fx.mul(bw, fx.param("lobe_depth", f32(0.04))))
	body := fx.max(fx.max(fx.sub(dome, y), fx.sub(y, rim)), fx.sub(fx.abs(x), bw))
	// The oral arms: ribbons whose middle waves and whose width breathes down their length
	for i in 0 ..< MAX_JELLY_ARMS {
		arm := fx.param(ARM_PARAMS[i], [4]f32{0, 0, 0, 0}) // x0, length, width, in use
		length := fx.max(fx.swizzle(arm, "y"), 1e-4)
		v := fx.saturate(fx.div(y, length))
		sway := fx.sin(fx.add(fx.add(fx.mul(time, 0.7), phase), fx.add(f32(i) * 2.1, fx.mul(v, 3.2))))
		mid := fx.add(fx.swizzle(arm, "x"), fx.mul(sway, fx.mul(fx.mul(w, 0.25), v)))
		breathe := fx.add(0.7, fx.mul(fx.sin(fx.add(fx.add(fx.mul(v, 7), f32(i) * 1.7), fx.mul(time, 0.9))), 0.3))
		half := fx.mul(fx.mul(fx.swizzle(arm, "z"), fx.sub(1, fx.mul(v, 0.55))), breathe)
		ribbon := fx.max(fx.sub(fx.abs(fx.sub(x, mid)), half), fx.max(fx.neg(y), fx.sub(y, length)))
		ribbon = fx.add(ribbon, fx.mul(fx.sub(1, fx.swizzle(arm, "w")), 1e6)) // unused arms: nowhere
		body = fx.min(body, ribbon)
	}
	body_alpha := ramp4(y, fx.param("body_at", [4]f32{0, 0, 0, 0}), fx.param("body_alpha", [4]f32{0, 0, 0, 0}))
	light := fx.mul(fx.param("body_color", [4]f32{0, 0, 0, 0}), fx.mul(fx.fill(fx.mul(body, unit)), body_alpha))

	capsules := fx.data_array("capsules", MAX_JELLY_CAPSULES * fx.CAPSULE_STRIDE)
	bins := fx.data_array("bins", MAX_JELLY_BINS)
	p := fx.coord() // the capsules are in the entity's own pixels
	strands, outline := fx.param("n_strands", f32(0)), fx.param("n_outline", f32(0))
	// Lines thinner than a pixel of the small image are drawn one pixel wide and fainter
	line :: proc(d: ^fx.Node, thin: ^fx.Node) -> ^fx.Node {return fx.mul(fx.fill(d), thin)}
	strand_cover := line(fx.sd_capsules(p, capsules, 0, strands, bins), fx.param("strand_thin", f32(1)))
	strand_alpha := ramp4(y, fx.param("strand_at", [4]f32{0, 0, 0, 0}), fx.param("strand_alpha", [4]f32{0, 0, 0, 0}))
	light = fx.add(light, fx.mul(fx.param("strand_color", [4]f32{0, 0, 0, 0}), fx.mul(strand_cover, strand_alpha)))
	outline_cover := line(fx.sd_capsules(p, capsules, strands, outline, bins), fx.param("outline_thin", f32(1)))
	light = fx.add(light, fx.mul(fx.param("outline_color", [4]f32{0, 0, 0, 0}), outline_cover)) // alpha folded into the color
	rim_cover := line(fx.sd_capsules(p, capsules, fx.add(strands, outline), -1, bins), fx.param("rim_thin", f32(1)))
	light = fx.add(light, fx.mul(fx.param("rim_color", [4]f32{0, 0, 0, 0}), rim_cover))
	return light
}
