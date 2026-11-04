package main

// Scene 2 (Stage.Deep): the flooded room become a cave of AlgoGame's sea. The walls the
// camera didn't see as the flood ended have given way: the near wall, most of the left one;
// the right wall and the ceiling broke off along them. Past them the seabed runs off into
// AlgoGame's background: its dark water and fog, its spores, its jellyfish (jelly.odin). The
// walls left are rock, the floor silted over, the hatch open in its middle and its lid where
// it landed; the "ZSE" letters stand on the floor below where they floated in scene 1, made
// of rusty, encrusted pipes open at their ends; AlgoGame's teal corals and orange sea fans grow
// in 3D on the floor, their glow the only light; spores drift in the water. All of it a
// function of the seconds into the scene (room.deep_time) and the clock (the plants sway, the
// spores drift, the jellyfish pulse).
//
//   0 .. DEEP_REVEAL   the lens clears: the bubbles' stream stops, the last ones rush up and
//                      away and the murk thins out (set_lens), the camera still where the
//                      flood left it, looking up
//   PAN_START ..       the camera flies round the room, a full circle at scene 1's speed and
//                      again, looping (deep_camera); halfway round it is down low, looking up
//                      as at the jet; after the first circle "Press Space to exit"
//
// The looks are in deep_looks.odin.

import eng "../../engine"
import fx "../../engine/vfx"
import "core:math"
import "core:math/linalg"
import "core:slice"

DEEP_REVEAL :: 2
REVEAL_LIFT :: 3.5 // extra seconds of rising the last bubbles get by the end of it
PAN_START :: 2.5
AUTO_CONTINUE :: 1.5 // autoplay: seconds of the bubble screen before scene 2
DEEP_EXPOSURE :: 1 + EYE_ADAPT // as the flood left the eye

// The water: light dies in it at SEA_FOG per meter (across the room it hardly shows), into
// AlgoGame's dark water (SEA_FAR). The seabed fades out from BED_NEAR to BED_FAR meters off.
SEA_FOG :: 0.04
BED_NEAR :: 9
BED_FAR :: 16
OPEN_REACH :: 2.2 // meters from an opening over which its light on the cave fades
OPEN_LIGHT :: [4]f32{0.02, 0.04, 0.07, 0}
CAVE_MURK :: [4]f32{0.0022, 0.0055, 0.010, 0} // the water's own light in the cave (linear)

// AlgoGame's background (sea_backdrop_look): its fog's noise cells FOG_ANGLE radians across
// (as big on screen as AlgoGame's), changing over FOG_PERIOD seconds, warped by FOG_WARP, as
// thick as FOG_INTENSITY; drawn BACKDROP_DIVISOR times smaller, as AlgoGame's
FOG_ANGLE :: 0.34
FOG_PERIOD :: 8
FOG_WARP :: 1.2
FOG_INTENSITY :: 0.6
BACKDROP_SEED :: 12345
BACKDROP_SEAM :: 1 // noise cells over which the fog fades into itself round the horizon
BACKDROP_DIVISOR :: 8

// The cave: where the left wall broke off (left_break: from this z on, more by height)
LEFT_BREAK :: 4.4

// The camera: from where the flood left it (low, looking up at the jet), round the room to
// the left, a full circle every DEEP_CIRCLE seconds (scene 1's mean speed, ORBIT_SWEEP
// degrees in SCENE1_LEG seconds), speeding up from rest over SETTLE seconds as it settles
// into scene 1's height, aim and field of view; on the way it goes down, and halfway round
// it is as low and looks up as steeply as at the jet (ARC_END_HEIGHT, JET_TILT, ARC_END_FOV),
// then comes back up. Its path: round PATH_CENTER, PATH_RADII across and along the room,
// squared off (a superellipse of power PATH_SQUARE: 2 an ellipse, more towards a rectangle),
// passing in front of the letters (looking away from them), so that they stay a backdrop.
DEEP_CIRCLE :: 360 * SCENE1_LEG / ORBIT_SWEEP
SETTLE :: 5
PATH_CENTER :: [2]f32{0, 4.8}
PATH_RADII :: [2]f32{4.2, 2.6}
PATH_SQUARE :: 4
JET_TILT :: 14 // degrees up, as the flood's camera looks at the jet (ARC_LOOK)

// The plants are AlgoGame's, in its proportions: a plant's unit is a coral's trunk length
// (its size), a fan's first branch's length over SEA_FAN_SIZE (0.65 there).
//
// Corals: CORAL_DEPTH levels of branches, each CORAL_RATIO as long as the one it grows from,
// forking in two (now and then three) by CORAL_SPREAD in a plane of their own round it,
// swaying (CORAL_SWAY radians, more higher up, over CORAL_PERIOD seconds); CORAL_WIDTH of the
// unit across at the trunk, thinning towards the tips (CORAL_TIP_WIDTH more); each outermost
// tip glows CORAL_GLOW_RADIUS of the unit round it at CORAL_GLOW_STRENGTH
CORAL_DEPTH :: 5
CORAL_RATIO :: 0.72
CORAL_SPREAD :: 0.55
CORAL_TRIPLE :: 0.1
CORAL_TWIST :: 0.9 // radians
CORAL_TRUNK_DRAWN :: 0.75
CORAL_SWAY :: 0.18
CORAL_PERIOD :: 4
CORAL_WIDTH :: 0.28
CORAL_TIP_WIDTH :: 0.03
CORAL_GLOW_RADIUS :: 0.4
CORAL_GLOW_STRENGTH :: 0.18
CORAL_RECORD :: 16 // quad | a.xyz, ra | b.xyz, rb | level, 0, 0, 0 (coral_look)
MAX_BRANCHES :: 128

// Sea fans: AlgoGame's SEA_FAN_SHAPES, branching in two by `spread` each level (a dome), a
// short trunk (FAN_TRUNK of the first branch), the ends from `link_level` on linked into lace
// (FAN_LACE as strong as a branch); squashed to FAN_SQUASH of its height, bent round into a
// cup (an upright cylinder FAN_CUP first branches in radius, fan_cup) and sunk FAN_SINK first
// branches into the floor; FAN_WIDTH of the unit across at the root, thinning to
// FAN_TIP_WIDTH, the lace that thin; swaying FAN_SWAY radians; a wave of light up it every
// FAN_PULSE_PERIOD seconds; its glow FAN_GLOW_WIDTH first branches wide at most
FanShape :: struct {
	depth, link_level:                int,
	spread, ratio, scale, link_reach: f32,
	lace:                             bool,
	curl:                             f32,
}
FAN_SHAPES := [4]FanShape {
	{depth = 6, link_level = 4, spread = 0.42, ratio = 0.82, scale = 1, link_reach = 1.22, lace = false, curl = 0}, // classic
	{depth = 7, link_level = 3, spread = 0.36, ratio = 0.83, scale = 0.86, link_reach = 1.2, lace = true, curl = 0}, // lace
	{depth = 6, link_level = 4, spread = 0.4, ratio = 0.83, scale = 0.97, link_reach = 1.25, lace = false, curl = 0.075}, // swept
	{depth = 6, link_level = 3, spread = 0.55, ratio = 0.86, scale = 0.97, link_reach = 1.45, lace = true, curl = 0}, // round
}
FAN_TRUNK :: 0.43
FAN_LACE :: 0.5
FAN_SQUASH :: 0.75
FAN_SINK :: 0.77
FAN_WIDTH :: 0.14
FAN_TIP_WIDTH :: 0.025
FAN_SWAY :: 0.08
FAN_PERIOD :: 4
FAN_PULSE_PERIOD :: 3.5
FAN_GLOW_WIDTH :: 0.17 // half of AlgoGame's 0.22 units, in first branches
FAN_CUP :: 0.9
FAN_GLOW_STRENGTH :: 1
MAX_FAN_CAPSULES :: 1024
MAX_FAN_BINS :: 16384
FAN_BIN_CELL :: 6 // centimeters

// The pipe letters (pipe_letter_look): LOGO_TUBE across outside, PIPE_WALL of that thick, sunk
// PIPE_SINK into the floor; their crusts bend the normal by PIPE_BUMP
PIPE_WALL :: 0.16
PIPE_SINK :: 0.03
PIPE_BUMP :: 2.5

// The plants' light on the rock round them (plant_glow), as AlgoGame's wall light: a pool
// POOL_RADIUS units round its foot at POOL_STRENGTH; sand grains GLINT_CELL apart (meters)
// sparkling in it, GLINT_FROM_POOL times as bright (AlgoGame's glint spots, about as wide)
POOL_RADIUS :: 2.5
POOL_STRENGTH :: 0.25
GLINT_CELL :: 0.04
GLINT_FROM_POOL :: 4.4

// The plants' lights on the hatch, its lid and the rubble: each lit one a point light at its
// crown (the cave and the plants themselves take none)
CORAL_LIGHT :: 1.2
FAN_LIGHT :: 1.0
PLANT_LIGHT_RANGE :: 3.5

// Glowing dots (dots_look): the spores, SPORE_SIZE across (at least a pixel and a half),
// drifting: MAX_SPORES in the cave, MAX_SEA_SPORES out in the sea round it (drawn before the
// cave, which hides those behind its walls); the corals' tips' glow
DOT_RECORD :: 8 // quad | sRGB color, brightness
MAX_SPORES :: 140
MAX_SEA_SPORES :: 320
SPORE_SIZE :: 0.02
SPORE_NEAREST :: 1.2
MAX_TIP_GLOWS :: 512


PlantKind :: enum {
	Coral,
	Fan,
}

// A plant on the floor at `at` (x, z): a coral (size: its trunk's length) or a sea fan (size:
// its first branch's), lit or not (its glow lighting the objects near), drawn by its own
// entity, whose sort key (its distance this frame) also divides the objects' buckets. The
// corals come first.
Plant :: struct {
	kind:   PlantKind,
	at:     [2]f32,
	size:   f32,
	lit:    bool,
	entity: int,
	key:    f32,
}

plants := [?]Plant {
	{.Coral, {-1.3, 5.9}, 0.42, true, 0, 0},
	{.Coral, {1.9, 4.2}, 0.45, true, 0, 0},
	{.Coral, {1.2, 0.6}, 0.4, false, 0, 0},
	{.Coral, {3.2, 9.0}, 0.65, true, 0, 0}, // behind the letters
	{.Coral, {-1.9, 3.8}, 0.45, true, 0, 0},
	{.Coral, {3.6, 0.8}, 0.55, true, 0, 0},
	{.Coral, {-6.6, 2.4}, 0.75, false, 0, 0}, // out on the seabed
	{.Coral, {-2.4, -2.6}, 0.7, false, 0, 0},
	{.Coral, {-8.8, -1.2}, 0.8, false, 0, 0},
	{.Fan, {-2.6, 5.0}, 0.38, true, 0, 0},
	{.Fan, {-0.9, 9.3}, 0.42, true, 0, 0}, // behind the letters
	{.Fan, {2.5, 5.4}, 0.4, true, 0, 0},
	{.Fan, {-3.0, 9.0}, 0.4, true, 0, 0},
	{.Fan, {-7.6, 0.2}, 0.46, false, 0, 0},
	{.Fan, {0.8, -3.5}, 0.44, false, 0, 0},
}

// A plant's unit (meters)
plant_unit :: proc(p: Plant) -> f32 {return p.size if p.kind == .Coral else p.size / 0.65}

// Rocks fallen where the room broke open: (x, z, size)
RUBBLE := [?][3]f32 {
	{-4.6, 5.2, 0.45},
	{-4.3, 4.1, 0.3},
	{-3.6, 0.6, 0.35},
	{-1.2, 0.3, 0.28},
	{2.6, 0.4, 0.38},
	{4.6, 1.1, 0.42},
}

in_deep :: proc() -> bool {return room.stage == .Deep}

// Whether an object is in the scene now: the random ones, the logo's and the lamp's before
// the deep, the rubble in it, the hatch always
shown :: proc(o: Object) -> bool {
	return o.presence != (.Before if in_deep() else .Deep)
}

exp_fog :: proc(dist: f32) -> f32 {return math.exp(-dist * SEA_FOG)}

// The rubble: blobs of rock (props, only in the deep), sunk into the floor
place_rubble :: proc() {
	for r in RUBBLE {
		scale := r[2]
		add_prop(.Blob, {scale, r[0] * 7 + r[1] * 3, 0, 0}, 1.7 * scale, {r[0], scale * 0.55, r[1]}, linear3(ROCK))
		o := &room.objects[len(room.objects) - 1]
		o.col_b = linear3(ROCK_DARK)
		o.presence = .Deep
	}
}

// The scene's entities: AlgoGame's background (its fog, its jellyfish, the spores out in the
// sea) behind the cave, a coral or fan per plant, the pipe letters, the
// corals' tips' glow, the spores in the cave (hidden until the deep)
add_deep_entities :: proc() {
	room.backdrop = eng.add_entity(sea_backdrop_look(), {}, {1, 1}, {z_index = LAYER_SEA})
	add_jellies()
	room.sea_spores = eng.add_entity(dots_look("spores", MAX_SEA_SPORES, .Dot), {}, {1, 1}, {z_index = LAYER_SEA_SPORES, blend = .Additive})
	room.cave = eng.add_entity(cave_look(), {}, {1, 1}, {z_index = LAYER_ROOM, blend = .Premultiplied})
	for &p in plants {
		if p.kind == .Coral {
			p.entity = eng.add_entity(coral_look(), {}, {1, 1}, {z_index = LAYER_OBJECTS})
		} else {
			p.entity = eng.add_entity(fan_look(), {}, {1, 1}, {z_index = LAYER_OBJECTS, blend = .Premultiplied})
		}
	}
	for letter, i in room.logo.letters {
		capsules := room.logo.capsules[letter.capsules[0]:][:letter.capsules[1]]
		room.pipe_letters[i] = eng.add_entity(pipe_letter_look(capsules), {}, {1, 1}, {z_index = LAYER_OBJECTS})
	}
	room.tip_glows = eng.add_entity(dots_look("tips", MAX_TIP_GLOWS, .Soft, premultiplied = true), {}, {1, 1}, {z_index = LAYER_GLOWS, blend = .Premultiplied})
	room.spores = eng.add_entity(dots_look("spores", MAX_SPORES, .Dot), {}, {1, 1}, {z_index = LAYER_GLOWS, blend = .Additive})
	hide_deep()
}

hide_deep :: proc() {
	for id in ([?]int{room.backdrop, room.sea_spores, room.cave, room.tip_glows, room.spores}) {
		eng.get_entity(id).visible = false
	}
	for ids in ([?][]int{room.jellies[:], room.pipe_letters[:]}) {
		for id in ids {
			eng.get_entity(id).visible = false
		}
	}
	for p in plants {
		eng.get_entity(p.entity).visible = false
	}
}

// How far round its circle the camera is `d` seconds into scene 2 (degrees, from where the
// flood left it): speeding up evenly from rest over SETTLE seconds, then steady
deep_turn :: proc(d: f32) -> f32 {
	pan := max(d - PAN_START, 0)
	speed := f32(360) / DEEP_CIRCLE
	if pan < SETTLE {
		return speed * pan * pan / (2 * SETTLE)
	}
	return speed * (pan - SETTLE / 2)
}

// When the camera's first circle is done ("Press Space to exit" from then on)
deep_first_circle :: proc() -> f32 {return PAN_START + SETTLE / 2 + DEEP_CIRCLE}

// The point of the camera's path at `angle` degrees round (0 at the near side, the middle of
// the near wall, then to the right)
path_point :: proc(angle: f32) -> Vec3 {
	a := angle * math.RAD_PER_DEG
	s, c := math.sin(a), math.cos(a)
	r := math.pow(math.pow(abs(s) / PATH_RADII.x, PATH_SQUARE) + math.pow(abs(c) / PATH_RADII.y, PATH_SQUARE), -1.0 / PATH_SQUARE)
	return {PATH_CENTER.x + r * s, 0, PATH_CENTER.y - r * c}
}

// The camera `d` seconds into scene 2: from where the flood left it round the room, down low
// halfway round, looking at the room's middle (scene 1's aim) or, down low, up as at the jet
deep_camera :: proc(d: f32) -> Camera {
	turn := deep_turn(d)
	settle := math.smoothstep(f32(0), SETTLE, max(d - PAN_START, 0))
	low := (1 - math.cos(turn * math.RAD_PER_DEG)) / 2 // 1 halfway round
	pos := path_point(-f32(ARC_DEGREES) - turn) // to the left
	pos.y = math.lerp(f32(CAMERA_HEIGHT), ARC_END_HEIGHT, low)
	middle := Vec3{PATH_CENTER.x, 0, PATH_CENTER.y}
	across := linalg.length((middle - pos).xz)
	up := Vec3{middle.x, pos.y + across * math.tan(f32(JET_TILT) * math.RAD_PER_DEG), middle.z}
	aim := math.lerp(CAMERA_LOOK_AT, up, low)
	fov := math.lerp(f32(CAMERA_FOV), ARC_END_FOV, low)
	// From the flood's last view into the circle
	start := arc_position(1)
	pos = math.lerp(start, pos, settle)
	return camera_looking(pos, math.lerp(ARC_LOOK, aim, settle), math.lerp(f32(ARC_END_FOV), fov, settle))
}

// A coral's branches `t` seconds into the clock: AlgoGame's branching, each fork in a plane of
// its own round the branch it grows from; the outermost tips, for their glow
Cone :: struct {
	a, b:   Vec3,
	ra, rb: f32,
	level:  int,
}

// A coral's branch's radius at the start of a level (AlgoGame's widths), `unit` its trunk
coral_radius :: proc(unit: f32, level: int) -> f32 {
	return unit * (CORAL_WIDTH * math.pow(max(1 - f32(level) / CORAL_DEPTH, 0), 1.2) + CORAL_TIP_WIDTH) / 2
}

grow_coral :: proc(p: Plant, seed: int, t: f32, out: ^[dynamic]Cone) {
	branch :: proc(out: ^[dynamic]Cone, unit: f32, seed, id: int, a, dir, side: Vec3, length: f32, level: int, t: f32) {
		// Sway: tipped about a level axis across it, more higher up
		across := linalg.cross(dir, Vec3{0, 1, 0})
		if linalg.length(across) < 1e-3 {
			across = {1, 0, 0}
		}
		sway := (noise1(t / CORAL_PERIOD + f32(id % 97) * 0.37, seed + id) * 2 - 1) * CORAL_SWAY * (0.3 + f32(level) / CORAL_DEPTH)
		d := linalg.matrix3_rotate_f32(sway, linalg.normalize(across)) * dir
		drawn := length * (CORAL_TRUNK_DRAWN if level == 0 else 1) // the crown sits lower
		b := a + d * drawn
		append(out, Cone{a, b, coral_radius(unit, level), coral_radius(unit, level + 1), level})
		if level + 1 >= CORAL_DEPTH || len(out) >= MAX_BRANCHES - 3 {
			return
		}
		// The fork: two (or three) children spread across a plane through the branch, the plane
		// of the fork before it turned by up to CORAL_TWIST, so that the crown spreads wide as
		// AlgoGame's does, yet round
		children := 3 if rnd(seed, id, 1) < CORAL_TRIPLE else 2
		spread := CORAL_SPREAD * (0.7 + 0.6 * rnd(seed, id, 2))
		flat := linalg.normalize0(side - d * linalg.dot(side, d))
		if linalg.length(flat) < 0.5 {
			flat = linalg.normalize(linalg.cross(d, Vec3{0, 0, 1} if abs(d.z) < 0.9 else Vec3{1, 0, 0}))
		}
		side := linalg.matrix3_rotate_f32((rnd(seed, id, 3) * 2 - 1) * CORAL_TWIST, d) * flat
		for k in 0 ..< children {
			child := id * 4 + k + 1
			angle := (f32(k) - f32(children - 1) / 2) * spread
			cd := d * math.cos(angle) + side * math.sin(angle)
			child_length := length * CORAL_RATIO * (0.85 + 0.3 * rnd(seed, child, 4))
			branch(out, unit, seed, child, b, cd, side, child_length, level + 1, t)
		}
	}
	tilt := Vec3{(rnd(seed, 0, 5) - 0.5) * 0.4, 1, (rnd(seed, 0, 6) - 0.5) * 0.4}
	root := Vec3{p.at.x, -0.05, p.at.y}
	// Its crown spreads across the view from where the camera mostly is, as AlgoGame's face it
	_, facing := fan_frame(p, seed)
	branch(out, p.size, seed, 1, root, linalg.normalize(tilt), linalg.cross(Vec3{0, 1, 0}, facing), p.size, 0, t)
}

// A sea fan's capsules (fx.CAPSULE_STRIDE values each, centimeters across its plane from its
// root, which is sunk into the floor, up) `t` seconds into the clock, as AlgoGame grows it:
// the branches, then the lace; returns how many in all, how many branches, its first
// branch's length (centimeters) and how high it reaches above its root (meters)
grow_fan :: proc(p: Plant, seed: int, t: f32, out: []f32) -> (n, branches: int, first, height: f32) {
	shape := fan_shape(seed)
	unit := plant_unit(p) * 100
	first = p.size * shape.scale * 100
	End :: struct {
		at: [2]f32,
	}
	Growing :: struct {
		shape:       FanShape,
		seed:        int,
		first, unit: f32,
		t:           f32,
		out:         []f32,
		n:           int,
		ends:        [dynamic]End,
	}
	g := Growing{shape, seed, first, unit, t, out, 0, make([dynamic]End, context.temp_allocator)}
	add :: proc(g: ^Growing, a, b: [2]f32, ra, rb: f32) {
		if (g.n + 1) * fx.CAPSULE_STRIDE > len(g.out) {
			return
		}
		squash :: proc(p: [2]f32) -> [2]f32 {return {p.x, p.y * FAN_SQUASH}}
		a, b := squash(a), squash(b)
		c := [fx.CAPSULE_STRIDE]f32{a.x, a.y, b.x, b.y, ra, rb, 0, 0}
		copy(g.out[g.n * fx.CAPSULE_STRIDE:], c[:])
		g.n += 1
	}
	// AlgoGame's widths: from FAN_WIDTH units across at the root, evenly down to FAN_TIP_WIDTH
	radius :: proc(g: ^Growing, level: int) -> f32 {
		w := FAN_WIDTH - f32(level) * (FAN_WIDTH - FAN_TIP_WIDTH) / f32(g.shape.depth)
		return max(w, FAN_TIP_WIDTH) * g.unit / 2
	}
	branch :: proc(g: ^Growing, id: int, at: [2]f32, angle, length: f32, level: int) {
		sway := (noise1(g.t / FAN_PERIOD + f32(id % 89) * 0.29, g.seed + id) * 2 - 1) * FAN_SWAY * (0.3 + f32(level) / f32(g.shape.depth))
		a := angle + sway + g.shape.curl * f32(level)
		to := at + length * [2]f32{math.cos(a), math.sin(a)}
		add(g, at, to, radius(g, level), radius(g, level))
		if level >= g.shape.link_level {
			append(&g.ends, End{to})
		}
		if level >= g.shape.depth {
			return
		}
		spread := g.shape.spread * (0.75 + 0.5 * rnd(g.seed, id, 54))
		for k in 0 ..< 2 {
			child := id * 4 + k + 1
			child_length := g.first if level == 0 else length * g.shape.ratio * (0.9 + 0.2 * rnd(g.seed, child, 55))
			branch(g, child, to, angle + (spread if k == 1 else -spread), child_length, level + 1)
		}
	}
	branch(&g, 1, {0, 0}, math.PI / 2, first * FAN_TRUNK, 0)
	branches = g.n
	// Neighboring ends (in the order they grew) linked into lace where close enough
	lace := FAN_TIP_WIDTH * unit / 2
	for e, i in g.ends {
		for k in ([2]int{1, 2}) {
			if k == 2 && !shape.lace {
				break
			}
			if i + k < len(g.ends) && linalg.distance(e.at, g.ends[i + k].at) < shape.link_reach * first {
				add(&g, e.at, g.ends[i + k].at, lace, lace)
			}
		}
	}
	top: f32 = 0
	for k in 0 ..< g.n {
		top = max(top, out[k * fx.CAPSULE_STRIDE + 1], out[k * fx.CAPSULE_STRIDE + 3])
	}
	return g.n, branches, first, top / 100
}

// A fan's cup: the radius of the cylinder it is bent round (meters), FAN_CUP first branches
// but at least wide enough that its sides (`half`: the widest it reaches across, meters) come
// no further round than a quarter turn from its middle
fan_cup :: proc(first, half: f32) -> f32 {return max(first * FAN_CUP, half / (math.PI / 2) * 1.02)}

// Where a point of a fan grown flat (`p`: meters across and up from its root) is in its cup
// of radius `cup`, whose middle is the root and whose sides come forward round `opens`
fan_cup_point :: proc(root, along, opens: Vec3, cup: f32, p: [2]f32) -> Vec3 {
	a := p.x / cup
	return root + opens * (cup * (1 - math.cos(a))) + along * (cup * math.sin(a)) + Vec3{0, p.y, 0}
}

// How deep a fan's root is sunk into the floor (meters)
fan_sink :: proc(p: Plant, seed: int) -> f32 {return FAN_SINK * p.size * fan_shape(seed).scale}

// Which of FAN_SHAPES a fan has
fan_shape :: proc(seed: int) -> FanShape {return FAN_SHAPES[min(int(rnd(seed, 0, 51) * f32(len(FAN_SHAPES))), len(FAN_SHAPES) - 1)]}

// A fan's plane: its normal faces FAN_FACING (the middle of the camera's path round the room),
// turned a little
FAN_FACING :: PATH_CENTER

fan_frame :: proc(p: Plant, seed: int) -> (along, normal: Vec3) {
	to_middle := linalg.normalize(Vec3{FAN_FACING.x - p.at.x, 0, FAN_FACING.y - p.at.y})
	turn := (rnd(seed, 0, 52) - 0.5) * 50 * math.RAD_PER_DEG
	normal = linalg.matrix3_rotate_f32(turn, Vec3{0, 1, 0}) * to_middle
	along = linalg.cross(Vec3{0, 1, 0}, normal)
	return
}

// Where a fan's wave of light is: 0 at the root, 1 at the tips, above 1 a pause
fan_wave :: proc(seed: int, t: f32) -> f32 {
	return math.mod(t / FAN_PULSE_PERIOD + rnd(seed, 0, 53), 1) * 1.5
}

// Every frame of scene 2
update_deep :: proc(t: f32) {
	d := room.deep_time
	room.camera = deep_camera(d)
	room.views[0].camera = room.camera
	room.water = {}
	room.jet_key = 1e6
	update_objects(t) // the lid where it landed, the rest hidden (shown)
	n := len(room.objects)
	for k in 0 ..< len(room.logo.proxies) {
		copy(room.occluders[(n + k) * fx.CAPSULE3_STRIDE:], far_away[:])
	}
	room.occluder_n = n + len(room.logo.proxies)
	update_logo(t, still = true)
	update_plants(t)
	update_buckets(&room.views[0])
	update_pipe_letters()
	update_jellies(t)
	cam := room.camera
	screen := eng.screen_size()
	for id in ([2]int{room.cave, room.backdrop}) {
		e := eng.get_entity(id)
		e.pos, e.size, e.visible = screen / 2, screen, true
		if id == room.cave {
			set_shared(id, cam)
		} else {
			set_camera(id, cam) // the backdrop only needs its directions
		}
		eng.set_param(id, "deep", [4]f32{d, t, 0, 0})
	}
	// The plants' light on the rock: a pool round each one's foot
	pools: [len(plants) * fx.GLOW_STRIDE]f32
	corals := 0
	for p, i in plants {
		u := plant_unit(p)
		pool := [fx.GLOW_STRIDE]f32{p.at.x, p.at.y, POOL_RADIUS * u, POOL_STRENGTH}
		copy(pools[i * fx.GLOW_STRIDE:], pool[:])
		corals += 1 if p.kind == .Coral else 0
	}
	eng.set_param_array(room.cave, "pools", pools[:])
	eng.set_param(room.cave, "pool_split", f32(corals))
	eng.set_param(room.cave, "pool_count", f32(len(plants)))
	update_spores(t)
	// The lens clears
	u := math.saturate(d / DEEP_REVEAL)
	s := room.flood_time - BURST
	set_lens(2, s + d + REVEAL_LIFT * u * u, s, math.smoothstep(f32(0), 1, u), d < DEEP_REVEAL + 0.2)
	// What belongs to the room before
	for id in ([?]int{room.room, room.shadow_buffer, room.air_buffer, room.jet, room.drops[0], room.drops[1]}) {
		if id >= 0 {
			eng.get_entity(id).visible = false
		}
	}
	for &view in room.views {
		if !view.on {
			continue
		}
		for ids in ([?][]int{view.letters[:], view.glows[:], view.cables[:]}) { // the letters: the pipe ones instead
			for id in ids {
				eng.get_entity(id).visible = false
			}
		}
		if view.mirror {
			for id in view.buckets {
				eng.get_entity(id).visible = false
			}
		}
	}
}

// A lit plant's light this frame: at a coral's crown, flickering a little, or in front of a
// fan, brighter as its wave of light goes up it
plant_light :: proc(p: Plant, seed: int, t: f32) -> (at: Vec3, strength: f32) {
	switch p.kind {
	case .Coral:
		return {p.at.x, p.size * 2, p.at.y}, CORAL_LIGHT * (0.85 + 0.3 * noise1(t * 0.4, seed))
	case .Fan:
		_, normal := fan_frame(p, seed)
		wave := fan_wave(seed, t)
		return Vec3{p.at.x, p.size * 1.2, p.at.y} + normal * 0.3, FAN_LIGHT * (0.7 + 0.6 * math.exp(-math.pow((wave - 0.5) / 0.35, 2)))
	}
	return
}

// The plants: their lights into the light list (for the objects near them; every look reads
// the list, so it comes first), which of them reach each object, their shapes this frame into
// their entities, the corals' tips' glows
update_plants :: proc(t: f32) {
	cam := room.camera
	count := 0
	for p, i in plants {
		if !p.lit {
			continue
		}
		at, strength := plant_light(p, 1000 + i * 7919, t)
		color := linear(CORAL_GLOW if p.kind == .Coral else SEA_FAN_GLOW)
		values := [fx.LIGHT_STRIDE]f32{at.x, at.y, at.z, PLANT_LIGHT_RANGE, color.r, color.g, color.b, strength}
		copy(room.light_values[count * fx.LIGHT_STRIDE:], values[:])
		count += 1
	}
	room.deep_lights = count
	for &o in room.objects {
		o.mask = 0
		if !shown(o) {
			continue
		}
		for k in 0 ..< count {
			l := room.light_values[k * fx.LIGHT_STRIDE:]
			if linalg.distance(Vec3{l[0], l[1], l[2]}, o.pos) < PLANT_LIGHT_RANGE + o.bound {
				o.mask |= 1 << u32(k)
			}
		}
	}
	tips := make([dynamic]f32, context.temp_allocator)
	glow := display(CORAL_GLOW)
	for &p, i in plants {
		seed := 1000 + i * 7919
		id := p.entity
		e := eng.get_entity(id)
		set_shared(id, cam)
		switch p.kind {
		case .Coral:
			cones := make([dynamic]Cone, context.temp_allocator)
			grow_coral(p, seed, t, &cones)
			lo := Vec3{math.F32_MAX, math.F32_MAX, math.F32_MAX}
			hi := -lo
			for c in cones {
				lo = linalg.min(lo, linalg.min(c.a, c.b) - c.ra)
				hi = linalg.max(hi, linalg.max(c.a, c.b) + c.ra)
				if c.level == CORAL_DEPTH - 1 && len(tips) < MAX_TIP_GLOWS * DOT_RECORD {
					at, depth := project(cam, c.b)
					if depth > 0.3 {
						r := CORAL_GLOW_RADIUS * p.size * cam.focal / depth
						append(&tips, at.x, at.y, r, r, glow.r, glow.g, glow.b, CORAL_GLOW_STRENGTH * exp_fog(depth))
					}
				}
			}
			records := cone_records(cones[:], cam)
			eng.set_instances(id, "branches", records)
			e.visible = len(records) > 0
			e.pos, e.size = {}, {1, 1}
			p.key = linalg.distance((lo + hi) / 2, cam.pos)
			eng.set_sort_key(id, p.key)
		case .Fan:
			values := make([]f32, MAX_FAN_CAPSULES * fx.CAPSULE_STRIDE, context.temp_allocator)
			n, branches, first, height := grow_fan(p, seed, t, values)
			along, opens := fan_frame(p, seed)
			root := Vec3{p.at.x, -fan_sink(p, seed), p.at.y}
			reach := first * FAN_GLOW_WIDTH // its glow round it (centimeters)
			lo, hi := [2]f32{math.F32_MAX, math.F32_MAX}, [2]f32{-math.F32_MAX, -math.F32_MAX}
			for k in 0 ..< n {
				c := values[k * fx.CAPSULE_STRIDE:]
				r := c[4] + reach
				lo = linalg.min(lo, linalg.min([2]f32{c[0], c[1]}, [2]f32{c[2], c[3]}) - r)
				hi = linalg.max(hi, linalg.max([2]f32{c[0], c[1]}, [2]f32{c[2], c[3]}) + r)
			}
			lo, hi = lo / 100, hi / 100
			cup := fan_cup(first / 100, max(-lo.x, hi.x))
			// Its quad: round the cup's points along its edges, across and up
			box: [2 * 9]Vec3
			for k in 0 ..< 9 {
				u := math.lerp(lo.x, hi.x, f32(k) / 8)
				box[2 * k] = fan_cup_point(root, along, opens, cup, {u, lo.y})
				box[2 * k + 1] = fan_cup_point(root, along, opens, cup, {u, hi.y})
			}
			center, size, ok := screen_quad(cam, box[:])
			e.visible = ok
			e.pos, e.size = center, size
			bins := make([]f32, MAX_FAN_BINS, context.temp_allocator)
			used := eng.bin_shapes(bins, values[:n * fx.CAPSULE_STRIDE], .Capsules, reach + 2, FAN_BIN_CELL)
			eng.set_param_array(id, "fan", values[:n * fx.CAPSULE_STRIDE])
			eng.set_param_array(id, "fan_bins", bins[:used])
			eng.set_param(id, "fan_o", [4]f32{root.x, root.y, root.z, 0})
			eng.set_param(id, "fan_u", [4]f32{along.x, along.y, along.z, 0})
			eng.set_param(id, "fan_n", [4]f32{opens.x, opens.y, opens.z, 0})
			eng.set_param(id, "fan_cup", cup)
			eng.set_param(id, "fan_shape", [4]f32{height, fan_wave(seed, t), f32(branches), first})
			p.key = linalg.distance(fan_cup_point(root, along, opens, cup, {0, height / 2}), cam.pos)
			eng.set_sort_key(id, p.key)
		}
	}
	eng.set_instances(room.tip_glows, "tips", tips[:])
	eng.get_entity(room.tip_glows).visible = len(tips) > 0
}

// The spores: where each drifts this frame (from where it started, rising slowly and
// wrapping round), as bright as the water between lets it be. Those in the cave (the room's
// box) are drawn over everything; those out in the sea, far round it, before the cave, whose
// walls hide those behind them.
update_spores :: proc(t: f32) {
	cam := room.camera
	Drift :: struct {
		lo, hi: Vec3, // the space they drift in
		count:  int,
		seed:   int,
		inside: bool,
	}
	for drift in ([2]Drift{{{-ROOM_HALF_WIDTH, 0, 0}, {ROOM_HALF_WIDTH, ROOM_HEIGHT, ROOM_DEPTH}, MAX_SPORES, 0, true}, {{-30, 0, -28}, {24, 12, 14}, MAX_SEA_SPORES, 5000, false}}) {
		records := make([dynamic]f32, context.temp_allocator)
		size := drift.hi - drift.lo
		for i in drift.seed ..< drift.seed + drift.count {
			base: Vec3
			for try in 0 ..< 8 {
				base = drift.lo + size * Vec3{rnd(i, try, 901), rnd(i, try, 902), rnd(i, try, 903)}
				in_room := abs(base.x) < ROOM_HALF_WIDTH && base.z > 0 && base.z < ROOM_DEPTH
				if in_room == drift.inside {
					break
				}
			}
			rate := 0.04 + 0.05 * rnd(i, 0, 904)
			phase := rnd(i, 0, 905) * math.TAU
			p := Vec3 {
				base.x + 0.35 * math.sin(t * 0.11 + phase),
				drift.lo.y + 0.2 + math.mod(base.y - drift.lo.y + t * rate, size.y - 0.4),
				base.z + 0.35 * math.cos(t * 0.09 + phase * 1.3),
			}
			at, depth := project(cam, p)
			if depth < SPORE_NEAREST {
				continue // nearer, it would be a big blur on the lens
			}
			radius := max(SPORE_SIZE * cam.focal / depth, 1.5) * 2.5
			warm := rnd(i, 0, 906) < 0.2
			c := SPORE_WARM if warm else SPORE
			twinkle := 0.6 + 0.4 * noise1(t * 0.7, i + 300)
			bright := twinkle * exp_fog(depth) * 0.8
			append(&records, at.x, at.y, radius, radius, f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, bright)
		}
		id := room.spores if drift.inside else room.sea_spores
		eng.set_instances(id, "spores", records[:])
		eng.get_entity(id).visible = len(records) > 0
	}
}

// The pipe letters, standing on the floor where scene 1's floated (update_logo, still), lit
// by the plants' lights that reach them
update_pipe_letters :: proc() {
	cam := room.camera
	for &letter, i in room.logo.letters {
		id := room.pipe_letters[i]
		center, size, ok := screen_quad(cam, letter.box[:])
		e := eng.get_entity(id)
		e.visible = ok
		e.pos, e.size = center, size
		eng.set_sort_key(id, linalg.distance(letter.center, cam.pos))
		set_shared(id, cam)
		capsules := room.logo.capsules[letter.capsules[0]:][:letter.capsules[1]]
		for c, k in capsules {
			eng.set_param(id, logo_a_names[k], [4]f32{c.a.x, c.a.y, c.a.z, 0})
			eng.set_param(id, logo_b_names[k], [4]f32{c.b.x, c.b.y, c.b.z, 0})
		}
		m := letter.center
		eng.set_param(id, "pivot", [4]f32{m.x, m.y, m.z, 0})
		mask: u32
		for k in 0 ..< room.deep_lights {
			l := room.light_values[k * fx.LIGHT_STRIDE:]
			if linalg.distance(Vec3{l[0], l[1], l[2]}, letter.center) < PLANT_LIGHT_RANGE + letter.bound + 1 {
				mask |= 1 << u32(k)
			}
		}
		eng.set_param(id, "mask", f32(mask))
	}
}

// Round cones as instanced records (CORAL_RECORD), ordered far to near, those off screen left
// out
cone_records :: proc(cones: []Cone, cam: Camera) -> []f32 {
	Far :: struct {
		distance: f32,
		cone:     Cone,
	}
	order := make([]Far, len(cones), context.temp_allocator)
	for c, k in cones {
		order[k] = {linalg.distance((c.a + c.b) / 2, cam.pos), c}
	}
	slice.sort_by(order, proc(a, b: Far) -> bool {return a.distance > b.distance})
	records := make([]f32, len(order) * CORAL_RECORD, context.temp_allocator)
	used := 0
	for f in order {
		c := f.cone
		corners := sphere_corners((c.a + c.b) / 2, linalg.distance(c.a, c.b) / 2 + max(c.ra, c.rb))
		center, size, ok := screen_quad(cam, corners[:])
		if !ok {
			continue
		}
		rec := records[used * CORAL_RECORD:][:CORAL_RECORD]
		rec[0], rec[1], rec[2], rec[3] = center.x, center.y, size.x / 2, size.y / 2
		rec[4], rec[5], rec[6], rec[7] = c.a.x, c.a.y, c.a.z, c.ra
		rec[8], rec[9], rec[10], rec[11] = c.b.x, c.b.y, c.b.z, c.rb
		rec[12] = f32(c.level)
		used += 1
	}
	return records[:used * CORAL_RECORD]
}
