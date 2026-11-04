package main

// Corals and sea fans on a wall, ported from index-pixi.html (fractalsInRange,
// seaFansInRange and their helpers) with the same hashing, so they stand and sway exactly
// as in the original. Shapes are worked out every frame for the part of the wall in view.

import "core:math"

// "fractal": recursive branching corals; each level sways by slow noise
FRACTAL_SPACING :: 2.6
FRACTAL_DENSITY :: 0.8
FRACTAL_DEPTH :: 5 // branching levels
FRACTAL_TRUNK_MEAN :: 1.0
FRACTAL_TRUNK_SPREAD :: 0.2
FRACTAL_TRUNK_DRAWN :: 0.75 // the trunk is drawn at this share of its length
FRACTAL_LENGTH_RATIO :: 0.72
FRACTAL_SPREAD :: 0.55
FRACTAL_TRIPLE_CHANCE :: 0.1
FRACTAL_SWAY :: 0.18
FRACTAL_WIDTH :: 0.28
FRACTAL_PERIOD :: 4.0
PLANT_BAND :: 2.2 // plants stand at random depths within this band below the rock's edge
PLANT_EDGE_DEPTH :: 0.25

// Sea fans: flat fans cross-linked into a net, in the gaps between corals
SEA_FAN_SHARE :: 1.0
SEA_FAN_CORAL_SHARE :: 0.04
SEA_FAN_CLEARANCE :: 1.0
SEA_FAN_MIN_FIT :: 0.8
SEA_FAN_SIZE :: 0.65
SEA_FAN_SIZE_SPREAD :: 0.15
SEA_FAN_TRUNK :: 0.12
SEA_FAN_HEIGHT :: 0.75
SEA_FAN_SINK :: 0.5
SEA_FAN_WIDTH :: 0.14
SEA_FAN_SWAY :: 0.08
SEA_FAN_GLOW_WIDTH :: 0.22
SEA_FAN_GLOW_STRENGTH :: 1.0
SEA_FAN_PULSE_PERIOD :: 3.5

CORAL_GLOW_RADIUS :: 0.4
CORAL_GLOW_STRENGTH :: 0.18
GROWTH_FRONT_SHARE :: 0.5 // on a wall with goo: share of growths drawn in front of it

// How far a coral reaches sideways from its root, relative to its trunk length
CORAL_REACH :: 1.47

SeaFanShape :: struct {
	depth:      int,
	spread:     f64,
	ratio:      f64,
	scale:      f64,
	link_level: int,
	link_reach: f64,
	lace:       bool,
	curl:       f64,
	reach:      f64,
}

SEA_FAN_SHAPES := [4]SeaFanShape {
	{depth = 6, spread = 0.42, ratio = 0.82, scale = 1, link_level = 4, link_reach = 1.22, lace = false, curl = 0, reach = 3.4}, // classic
	{depth = 7, spread = 0.36, ratio = 0.83, scale = 0.86, link_level = 3, link_reach = 1.2, lace = true, curl = 0, reach = 3.8}, // lace
	{depth = 6, spread = 0.4, ratio = 0.83, scale = 0.97, link_level = 4, link_reach = 1.25, lace = false, curl = 0.075, reach = 3.55}, // swept
	{depth = 6, spread = 0.55, ratio = 0.86, scale = 0.97, link_level = 3, link_reach = 1.45, lace = true, curl = 0, reach = 4.0}, // round
}

// 32-bit wrapping multiply as a signed value, like JavaScript's Math.imul(a, b) | 0
imul :: proc(a, b: i64) -> i64 {
	return i64(i32(u32(a) * u32(b)))
}

// JavaScript's `a ^ b` on integers
xor32 :: proc(a, b: i64) -> i64 {
	return i64(i32(u32(a) ~ u32(b)))
}

Root :: struct {
	id: i64,
	x:  f64,
}

// Seeded root positions along a wall between x0 and x1: one slot per `spacing`, jittered
// inside its slot, kept with probability `density`
roots_in_range :: proc(seed: i64, x0, x1, spacing, density: f64, out: ^[dynamic]Root) {
	for k := i64(math.floor(x0 / spacing)); k <= i64(math.ceil(x1 / spacing)); k += 1 {
		if hash(seed, k) >= density {
			continue
		}
		append(out, Root{k, (f64(k) + 0.2 + hash(seed + 1, k) * 0.6) * spacing})
	}
}

// Growth direction out of a wall at x: halfway between the wall's normal and straight into
// the tunnel. side = +1 grows down from the ceiling, -1 up from the floor.
growth_angle :: proc(seed: i64, x, side: f64) -> f64 {
	edge :: proc(seed: i64, v, side: f64) -> f64 {
		c := cave_at(seed, v)
		return c.top if side > 0 else c.bottom
	}
	slope := (edge(seed, x + 0.1, side) - edge(seed, x - 0.1, side)) / 0.2
	nx, ny := -slope * side, side
	l := math.sqrt(nx * nx + ny * ny)
	return math.atan2(ny / l + side, nx / l)
}

// Bell-curve random number (mean 0, deviation 1) from four uniform hashes
bell_curve :: proc(seed, i: i64) -> f64 {
	sum := hash(seed, i) + hash(seed + 1, i) + hash(seed + 2, i) + hash(seed + 3, i)
	return (sum - 2) / math.sqrt(f64(4.0) / 12)
}

coral_trunk :: proc(deco, id: i64) -> f64 {
	return math.max(0.05, FRACTAL_TRUNK_MEAN + bell_curve(deco + 3, id) * FRACTAL_TRUNK_SPREAD)
}

// Depth below the rock's edge (fixed per growth) and its drawing group: 0 at the edge
// (behind the rock), 1 and 2 the upper and lower half of the rest of the band (in front)
growth_depth :: proc(deco, id: i64, band: f64) -> (depth: f64, tier: int) {
	depth = hash(deco + 61, id) * band
	tier = 0 if depth < PLANT_EDGE_DEPTH else 1 if depth < (PLANT_EDGE_DEPTH + band) / 2 else 2
	return
}

// Whether a growth is drawn in front of the goo on its wall, fixed per growth
growth_in_front :: proc(id: i64) -> bool {
	return hash(i64(i32(id)), 98) < GROWTH_FRONT_SHARE
}

SeaFanLook :: struct {
	shape:  ^SeaFanShape,
	size:   f64,
	first:  f64, // length of the first branches
	reach:  f64,
	behind: bool, // behind the corals around it
}

sea_fan_look :: proc(deco, id: i64) -> SeaFanLook {
	shape := &SEA_FAN_SHAPES[int(hash(deco + 51, id) * len(SEA_FAN_SHAPES))]
	size := math.max(0.3, 1 + bell_curve(deco + 52, id) * SEA_FAN_SIZE_SPREAD)
	first := SEA_FAN_SIZE * shape.scale * size
	return {shape, size, first, shape.reach * first, hash(deco + 57, id) < 0.5}
}

PlantSpot :: struct {
	id:  i64,
	x:   f64,
	fan: Maybe(SeaFanLook), // nil: a coral
}

// Plants on a coral wall: the corals at their spots, plus a sea fan wherever the gap
// between two neighboring corals is wide enough to hold one
plant_spots :: proc(seed: i64, side, x0, x1: f64, out: ^[dynamic]PlantSpot) {
	deco := seed + (606 if side > 0 else 707)
	margin := 6 * FRACTAL_SPACING
	roots := make([dynamic]Root, context.temp_allocator)
	roots_in_range(deco, x0 - margin, x1 + margin, FRACTAL_SPACING, FRACTAL_DENSITY, &roots)
	Coral :: struct {
		id, root_id: i64,
		x, reach:    f64,
		fan:         Maybe(SeaFanLook),
	}
	corals := make([]Coral, len(roots), context.temp_allocator)
	for root, i in roots {
		id := imul(root.id, 0x9e3779b1)
		fan: Maybe(SeaFanLook)
		if hash(deco + 62, root.id) < SEA_FAN_CORAL_SHARE {
			fan = sea_fan_look(deco, id)
		}
		corals[i] = {id, root.id, root.x, CORAL_REACH * coral_trunk(deco, id) * SEA_FAN_CLEARANCE, fan}
	}
	for left, i in corals {
		if left.x >= x0 && left.x <= x1 {
			append(out, PlantSpot{left.id, left.x, left.fan})
		}
		if i + 1 >= len(corals) {
			break
		}
		right := corals[i + 1]
		id := imul(left.root_id * 2 + 1, 0x9e3779b1) // one possible fan per gap
		if hash(deco + 50, id) >= SEA_FAN_SHARE {
			continue
		}
		from, to := left.x + left.reach, right.x - right.reach
		look := sea_fan_look(deco, id)
		room := (to - from) / 2 / (look.reach * SEA_FAN_CLEARANCE)
		if room < SEA_FAN_MIN_FIT {
			continue
		}
		if room < 1 {
			look.size *= room
			look.first *= room
			look.reach *= room
		}
		x := (from + to) / 2
		if x >= x0 && x <= x1 {
			append(out, PlantSpot{id, x, look})
		}
	}
}

Segment :: struct {
	x1, y1, x2, y2: f64,
	level:          int,
	d:              f64, // sea fans: distance from the root along the branches, at the end
	parent:         int, // corals: index of the branch it grows from; -1 for the trunk
}

Coral :: struct {
	id:       i64,
	tier:     int,
	size:     f64, // trunk length relative to the average
	depth:    f64, // how far below the rock's edge it stands
	segments: [dynamic]Segment,
}

// Branching corals on one wall
corals_in_range :: proc(seed: i64, side, x0, x1, t: f64, spots: []PlantSpot, out: ^[dynamic]Coral) {
	time := t / FRACTAL_PERIOD
	deco := seed + (606 if side > 0 else 707)
	branch :: proc(coral: ^Coral, deco, id: i64, x, y, angle, length: f64, level: int, time: f64, parent: int) {
		sway := (value_noise2(xor32(deco, id), 0, time) * 2 - 1) * FRACTAL_SWAY * (0.3 + f64(level) / FRACTAL_DEPTH)
		angle := angle + sway
		// The trunk is drawn shorter than its length; the crown keeps its size and sits lower
		drawn := length * FRACTAL_TRUNK_DRAWN if level == 0 else length
		x2, y2 := x + math.cos(angle) * drawn, y + math.sin(angle) * drawn
		self := len(coral.segments)
		append(&coral.segments, Segment{x, y, x2, y2, level, 0, parent})
		if level + 1 >= FRACTAL_DEPTH {
			return
		}
		children := 3 if hash(deco, id) < FRACTAL_TRIPLE_CHANCE else 2
		spread := FRACTAL_SPREAD * (0.7 + 0.6 * hash(deco + 1, id))
		for k in 0 ..< children {
			child_id := i64(i32(u32(id) * 4 + u32(k + 1)))
			child_angle := angle + (f64(k) - f64(children - 1) / 2) * spread
			child_length := length * FRACTAL_LENGTH_RATIO * (0.85 + 0.3 * hash(deco + 2, child_id))
			branch(coral, deco, child_id, x2, y2, child_angle, child_length, level + 1, time, self)
		}
	}
	for spot in spots {
		if spot.fan != nil {
			continue
		}
		trunk := coral_trunk(deco, spot.id)
		depth, tier := growth_depth(deco, spot.id, PLANT_BAND)
		coral := Coral {
			id       = spot.id,
			tier     = tier,
			size     = trunk / FRACTAL_TRUNK_MEAN,
			depth    = depth,
			segments = make([dynamic]Segment, context.temp_allocator),
		}
		cave := cave_at(seed, spot.x)
		edge_y := cave.top if side > 0 else cave.bottom
		root_y := edge_y - side * depth // deeper: further into the rock
		angle := growth_angle(seed, spot.x, side)
		branch(&coral, deco, spot.id, spot.x - math.cos(angle) * 0.2, root_y - math.sin(angle) * 0.2, angle, trunk, 0, time, -1)
		append(out, coral)
	}
}

SeaFan :: struct {
	id:       i64,
	size:     f64,
	behind:   bool,
	tier:     int,
	depth:    int, // branching levels (the shape's)
	segments: [dynamic]Segment,
	links:    [dynamic]Segment, // the net between neighboring branch ends
	max_d:    f64,
	pulse:    f64, // where the wave of light is: 0 at the root, 1 at the tips, above 1 a pause
	root_depth: f64, // how far below the rock's edge it stands
	crown_x, crown_y: f64, // the middle of its outermost tips (where it lights the wall from)
	tips:     int,
}

// Sea fans on one wall
sea_fans_in_range :: proc(seed: i64, side, x0, x1, t: f64, spots: []PlantSpot, out: ^[dynamic]SeaFan) {
	time := t / FRACTAL_PERIOD
	deco := seed + (606 if side > 0 else 707)
	End :: struct {
		x, y, d: f64,
	}
	Branching :: struct {
		fan:   ^SeaFan,
		shape: ^SeaFanShape,
		ends:  [dynamic]End,
		deco:  i64,
		first: f64,
		curl:  f64,
		time:  f64,
	}
	// Sway and the current's bend tilt each branch, but its children still fan out around
	// its unbent direction, so the fan stays flat and evenly spread
	branch :: proc(b: ^Branching, bid: i64, x, y, angle, length: f64, level: int, d: f64) {
		shape := b.shape
		sway := (value_noise2(xor32(b.deco, bid), 0, b.time) * 2 - 1) * SEA_FAN_SWAY * (0.3 + f64(level) / f64(shape.depth))
		a := angle + sway + b.curl * f64(level)
		x2, y2 := x + math.cos(a) * length, y + math.sin(a) * length
		append(&b.fan.segments, Segment{x, y, x2, y2, level, d + length, -1})
		b.fan.max_d = math.max(b.fan.max_d, d + length)
		if level >= shape.link_level {
			append(&b.ends, End{x2, y2, d + length})
		}
		if level >= shape.depth {
			b.fan.crown_x += x2
			b.fan.crown_y += y2
			b.fan.tips += 1
			return
		}
		spread := shape.spread * (0.75 + 0.5 * hash(b.deco + 54, bid))
		for k in 0 ..< 2 {
			child_id := i64(i32(u32(bid) * 4 + u32(k + 1)))
			child_length := b.first if level == 0 else length * shape.ratio * (0.9 + 0.2 * hash(b.deco + 55, child_id))
			branch(b, child_id, x2, y2, angle + (spread if k == 1 else -spread), child_length, level + 1, d + length)
		}
	}
	for spot in spots {
		look := spot.fan.? or_continue
		depth, tier := growth_depth(deco, spot.id, PLANT_BAND)
		fan := SeaFan {
			id       = spot.id,
			size     = look.size,
			behind   = look.behind,
			tier     = tier,
			depth    = look.shape.depth,
			segments = make([dynamic]Segment, context.temp_allocator),
			links    = make([dynamic]Segment, context.temp_allocator),
			pulse    = math.mod(t / SEA_FAN_PULSE_PERIOD + hash(deco + 53, spot.id), 1) * 1.5,
			root_depth = depth,
		}
		b := Branching{&fan, look.shape, make([dynamic]End, context.temp_allocator), deco, look.first, look.shape.curl * side, time}
		cave := cave_at(seed, spot.x)
		edge_y := cave.top if side > 0 else cave.bottom
		root_y := edge_y - side * depth
		angle := growth_angle(seed, spot.x, side)
		branch(&b, spot.id, spot.x - math.cos(angle) * 0.2, root_y - math.sin(angle) * 0.2, angle, look.first * SEA_FAN_TRUNK + 0.2, 0, 0)
		// Neighboring branch ends (in branching order) are linked when close enough
		for a, i in b.ends {
			for k in ([2]int{1, 2}) {
				if k == 2 && !look.shape.lace {
					break
				}
				if i + k >= len(b.ends) {
					continue
				}
				e := b.ends[i + k]
				if math.hypot(a.x - e.x, a.y - e.y) < look.shape.link_reach * look.first {
					append(&fan.links, Segment{a.x, a.y, e.x, e.y, 0, (a.d + e.d) / 2, -1})
				}
			}
		}
		fan.crown_x /= f64(fan.tips)
		fan.crown_y /= f64(fan.tips)
		// Squash the fan toward the wall (along its growth direction only), then sink it in
		ux, uy := math.cos(angle), math.sin(angle)
		squash := 1 - SEA_FAN_HEIGHT
		flatten :: proc(x, y, rx, ry, ux, uy, squash: f64) -> (f64, f64) {
			along := (x - rx) * ux + (y - ry) * uy
			shift := along * squash + SEA_FAN_SINK
			return x - ux * shift, y - uy * shift
		}
		for &s in fan.segments {
			s.x1, s.y1 = flatten(s.x1, s.y1, spot.x, root_y, ux, uy, squash)
			s.x2, s.y2 = flatten(s.x2, s.y2, spot.x, root_y, ux, uy, squash)
		}
		for &s in fan.links {
			s.x1, s.y1 = flatten(s.x1, s.y1, spot.x, root_y, ux, uy, squash)
			s.x2, s.y2 = flatten(s.x2, s.y2, spot.x, root_y, ux, uy, squash)
		}
		fan.crown_x, fan.crown_y = flatten(fan.crown_x, fan.crown_y, spot.x, root_y, ux, uy, squash)
		append(out, fan)
	}
}
