package main

// The cave's atmosphere, ported from index-pixi.html: floating spores, the luminous
// jellyfish far behind the cave, and the light that corals, sea fans and tentacles cast on
// the rock (wall light and sand glints). Everything is worked out from the seed and the
// time, with the original's hashing. The fog needs no CPU work: its shader computes the
// same noise (vfx.int_fbm).

import "core:math"

FOG_SCALE :: 7.0 // world units per noise cell
FOG_WARP :: 1.2
FOG_PERIOD :: 8.0
FOG_INTENSITY :: 0.6
FOG_PARALLAX :: 0.5

// Spores
SporeLayer :: struct {
	parallax: f64,
	count:    int,
	size:     f64,
	alpha:    f64,
	drift:    f64,
	front:    bool, // drawn over the growths, clipped to the open tunnel
}
SPORE_LAYERS := [4]SporeLayer {
	{0.25, 70, 0.07, 0.35, 0.15, false},
	{0.45, 45, 0.10, 0.5, 0.25, false},
	{0.7, 28, 0.14, 0.7, 0.4, false},
	{1.4, 6, 0.45, 0.18, 0.8, true},
}
SPORE_TILE :: 30.0 // spores repeat every this many world units horizontally
SPORE_WOBBLE :: 0.6
SPORE_PERIOD :: 5.0

// Spores in view as lights (screen-fixed world units): x, y, radius, brightness, and
// whether it is one of the warm ones (one in five)
Spore :: struct {
	x, y, radius, alpha: f64,
	warm:                bool,
}

spores_in_view :: proc(seed: i64, distance, time, width_units: f64, front: bool, out: ^[dynamic]Spore) {
	span, t := VIEW_HEIGHT + 2, time / SPORE_PERIOD
	for layer, li in SPORE_LAYERS {
		if layer.front != front {
			continue
		}
		layer_seed := seed + 2000 + i64(li) * 97
		camera_x := distance * layer.parallax
		for i in 0 ..< layer.count {
			own := layer_seed + imul(i64(i) + 1, 0x9e3779b1)
			vx := (hash(own, 1) * 2 - 1) * layer.drift
			vy := -(0.2 + 0.8 * hash(own, 2)) * layer.drift // spores slowly rise
			sway_x := (value_noise2(own, 0, t) * 2 - 1) * SPORE_WOBBLE
			sway_y := (value_noise2(own + 1, 0, t) * 2 - 1) * SPORE_WOBBLE
			x := hash(own, 3) * SPORE_TILE + vx * time + sway_x - camera_x
			y := hash(own, 4) * span + vy * time + sway_y
			x = math.mod(math.mod(x, SPORE_TILE) + SPORE_TILE, SPORE_TILE)
			y = math.mod(math.mod(y + 1, span) + span, span) - 1 // leave at the top, return at the bottom
			radius := layer.size * (0.7 + 0.6 * hash(own, 5))
			twinkle := 0.6 + 0.4 * value_noise2(own + 2, 0, time * 0.8)
			warm := hash(own, 6) < 0.2
			for px := x - SPORE_TILE; px - radius < width_units; px += SPORE_TILE {
				if px + radius > 0 {
					append(out, Spore{px, y, radius, layer.alpha * twinkle, warm})
				}
			}
		}
	}
}

// ---------------------------------------------------------------------------------------
// Jellyfish: large, luminous, out-of-focus jellyfish in three depth layers far behind the cave

JellyLayer :: struct {
	parallax, drift, size_min, size_max: f64,
	blur:                                int, // drawn at this many times lower resolution
	spacing, chance, alpha:              f64,
}
JELLY_LAYERS := [3]JellyLayer {
	{0.12, 0.5, 1.8, 2.2, 6, 22, 0.8, 0.35},
	{0.2, 0.8, 2.5, 3.5, 4, 32, 0.73, 0.35},
	{0.3, 1.2, 4.0, 4.5, 2, 46, 0.665, 0.35},
}

JellyType :: struct {
	aspect, peak, lobes, arms, arm_length, arm_width, filaments, filament_length: [2]f64,
}
JELLY_TYPES := [4]JellyType {
	{{0.28, 0.4}, {0.45, 0.7}, {10, 16}, {4, 4}, {0.8, 1.3}, {0.1, 0.14}, {10, 16}, {0.4, 0.9}}, // moon jelly
	{{0.6, 0.85}, {0.8, 1.1}, {6, 9}, {2, 3}, {1.2, 1.8}, {0.12, 0.18}, {4, 7}, {2.4, 3.6}}, // bell jelly
	{{0.85, 1.1}, {1.3, 1.8}, {5, 8}, {2, 2}, {0.9, 1.4}, {0.1, 0.15}, {3, 5}, {2.8, 4.2}}, // helmet
	{{0.45, 0.6}, {0.7, 0.95}, {8, 12}, {4, 5}, {2.0, 3.0}, {0.14, 0.2}, {6, 9}, {3.0, 4.5}}, // sea nettle
}

JellyColors :: struct {
	weight:          f64,
	hue, rim_shift:  [2]f64,
}
JELLY_COLORS := [3]JellyColors {
	{0.48, {215, 240}, {-12, 8}}, // dark blue
	{0.44, {245, 272}, {10, 30}}, // violet
	{0.08, {310, 330}, {-25, -10}}, // magenta
}

JellyFeatures :: struct {
	hue, saturation, rim_hue, body, gain:     f64,
	aspect, peak, lobe_depth:                 f64,
	lobes, arms, filaments, canals:           int,
	arm_length, arm_width, filament_length:   f64,
	tilt, pulse_speed, phase:                 f64,
	variation:                                i64,
}

// A CSS hsl() color's channel n (0 red, 8 green, 4 blue), 0..1
hsl_channel :: proc(h, s, l: f64, n: f64) -> f64 {
	a := s * math.min(l, 1 - l)
	k := math.mod(n + h / 30, 12)
	return l - a * math.max(-1, math.min(k - 3, 9 - k, 1))
}

hsl :: proc(h, s, l: f64) -> [3]f32 {
	return {f32(hsl_channel(h, s, l, 0)), f32(hsl_channel(h, s, l, 8)), f32(hsl_channel(h, s, l, 4))}
}

// Each jellyfish's light is scaled by its colors' brightness (partly: the 0.6 power), so all
// color families look about equally bright
jelly_brightness_gain :: proc(hue, saturation, rim_hue: f64) -> f64 {
	luma :: proc(h, s, l: f64) -> f64 {
		return 0.2126 * hsl_channel(h, s, l, 0) + 0.7152 * hsl_channel(h, s, l, 8) + 0.0722 * hsl_channel(h, s, l, 4)
	}
	brightness := 0.6 * luma(hue, saturation / 100, 0.5) + 0.4 * luma(rim_hue, 1, 0.73)
	return math.min(1.6, math.max(0.6, math.pow(0.45 / brightness, 0.6)))
}

js_round :: proc(x: f64) -> int {
	return int(math.floor(x + 0.5))
}

jelly_features :: proc(seed: i64, layer: int, slot: i64) -> JellyFeatures {
	h :: proc(seed: i64, layer: int, slot: i64, k: int) -> f64 {return hash(seed + 7300 + i64(layer) * 131 + i64(k) * 17, slot)}
	pick :: proc(r: [2]f64, v: f64) -> f64 {return r[0] + (r[1] - r[0]) * v}
	type := JELLY_TYPES[int(h(seed, layer, slot, 0) * len(JELLY_TYPES))]
	roll := h(seed, layer, slot, 30)
	colors := JELLY_COLORS[len(JELLY_COLORS) - 1]
	for family in JELLY_COLORS {
		if roll < family.weight {
			colors = family
			break
		}
		roll -= family.weight
	}
	f: JellyFeatures
	f.hue = pick(colors.hue, h(seed, layer, slot, 1))
	f.saturation = 75 + h(seed, layer, slot, 2) * 25
	f.rim_hue = f.hue + pick(colors.rim_shift, h(seed, layer, slot, 31))
	f.body = 0.3 + h(seed, layer, slot, 3) * 0.12
	f.gain = jelly_brightness_gain(f.hue, f.saturation, f.rim_hue)
	f.aspect = pick(type.aspect, h(seed, layer, slot, 4))
	f.peak = pick(type.peak, h(seed, layer, slot, 5))
	f.lobes = js_round(pick(type.lobes, h(seed, layer, slot, 6)))
	f.lobe_depth = 0.02 + h(seed, layer, slot, 7) * 0.04
	f.arms = js_round(pick(type.arms, h(seed, layer, slot, 8)))
	f.arm_length = pick(type.arm_length, h(seed, layer, slot, 9))
	f.arm_width = pick(type.arm_width, h(seed, layer, slot, 10))
	f.filaments = js_round(pick(type.filaments, h(seed, layer, slot, 11)))
	f.filament_length = pick(type.filament_length, h(seed, layer, slot, 12))
	f.canals = 6 + int(math.floor(h(seed, layer, slot, 16) * 6))
	f.tilt = (h(seed, layer, slot, 13) - 0.5) * 0.6
	f.pulse_speed = 0.9 + h(seed, layer, slot, 14) * 0.9
	f.phase = h(seed, layer, slot, 15) * 6.28
	f.variation = seed + 7300 + i64(layer) * 131 + slot * 7
	return f
}

MAX_JELLY_ARMS :: 5
JELLY_RIM_POINTS :: 25

JellyArm :: struct {
	x0, length, width: f64,
}

// One jellyfish's shape now, around (0, 0) with bell half-width w (world units)
JellyShape :: struct {
	bw, bh:    f64,
	dome, rim: [JELLY_RIM_POINTS][2]f64,
	arms:      [MAX_JELLY_ARMS]JellyArm, // the ribbons: their edges are worked out in the look
}

jelly_shape :: proc(f: ^JellyFeatures, w, time: f64) -> JellyShape {
	s: JellyShape
	pulse := math.sin(time * f.pulse_speed + f.phase)
	s.bw, s.bh = w * (1 + pulse * 0.06), w * f.aspect * (1 - pulse * 0.08)
	for k in 0 ..< JELLY_RIM_POINTS {
		u := f64(k) / 24
		a := math.PI - u * math.PI
		s.rim[k] = {(u * 2 - 1) * s.bw, math.abs(math.sin(u * f64(f.lobes) * math.PI)) * s.bw * f.lobe_depth}
		s.dome[k] = {math.cos(a) * s.bw, -math.pow(math.sin(a), f.peak) * s.bh}
	}
	for i in 0 ..< math.min(f.arms, MAX_JELLY_ARMS) {
		s.arms[i] = {
			x0     = ((f64(i) + 0.5) / f64(f.arms) * 2 - 1) * s.bw * 0.35,
			length = w * f.arm_length * (0.75 + 0.5 * hash(f.variation, i64(i))),
			width  = s.bw * f.arm_width * (0.8 + 0.4 * hash(f.variation + 1, i64(i))),
		}
	}
	return s
}

// A point of an oral arm's edge (side -1 left, 1 right) at u in 0..1 down its length
jelly_arm_edge :: proc(f: ^JellyFeatures, arm: JellyArm, i: int, w, time, u, side: f64) -> [2]f64 {
	x := arm.x0 + math.sin(time * 0.7 + f.phase + f64(i) * 2.1 + u * 3.2) * w * 0.25 * u
	half := arm.width * (1 - u * 0.55) * (0.7 + 0.3 * math.sin(u * 7 + f64(i) * 1.7 + time * 0.9))
	return {x + side * half, u * arm.length}
}

// A filament's point k of 0..12
jelly_filament_point :: proc(f: ^JellyFeatures, s: ^JellyShape, i: int, w, time: f64, k: int) -> [2]f64 {
	x0 := ((f64(i) + 0.5) / f64(f.filaments) * 2 - 1) * s.bw * 0.95
	if k == 0 {
		return {x0, s.rim[js_round((f64(i) + 0.5) / f64(f.filaments) * 24)].y}
	}
	length := w * f.filament_length * (0.6 + 0.8 * hash(f.variation + 2, i64(i)))
	u := f64(k) / 12
	return {x0 + math.sin(time * 1.2 + f.phase + f64(i) * 1.7 + u * 6) * w * 0.1 * u, u * length}
}

Jelly :: struct {
	features:   JellyFeatures,
	size, x, y: f64, // bell half-width; position in screen-fixed world units
}

jellies_in_view :: proc(seed: i64, li: int, distance, time, width_units: f64, out: ^[dynamic]Jelly) {
	layer := JELLY_LAYERS[li]
	camera := distance * layer.parallax + time * layer.drift // drift: swimming against the ship
	reach := layer.size_max * 4 // tentacles hang far below the bell
	k0, k1 := i64(math.floor((camera - reach) / layer.spacing)), i64(math.ceil((camera + width_units + reach) / layer.spacing))
	for k := k0; k <= k1; k += 1 {
		if hash(seed + 7100 + i64(li), k) >= layer.chance {
			continue
		}
		f := jelly_features(seed, li, k)
		size := layer.size_min + hash(seed + 7200 + i64(li), k) * (layer.size_max - layer.size_min)
		x := (f64(k) + 0.2 + 0.6 * hash(seed + 7250 + i64(li), k)) * layer.spacing - camera + math.sin(time * 0.05 + f.phase) * size
		y := -size * 0.3 + hash(seed + 7270 + i64(li), k) * (VIEW_HEIGHT - size * 0.4) + math.sin(time * 0.12 + f.phase) * size * 0.25
		if x < -reach || x > width_units + reach {
			continue
		}
		append(out, Jelly{f, size, x, y})
	}
}

// ---------------------------------------------------------------------------------------
// Light that growths cast on the rock

WALL_LIGHT_STRENGTH :: 0.2
WALL_LIGHT_GLOW_RADIUS :: 1.5
WALL_LIGHT_CORAL :: 1.0
WALL_LIGHT_CORAL_REACH :: 5.0
WALL_LIGHT_CORAL_SPREAD :: 1.2
WALL_LIGHT_TENTACLE :: 0.6
WALL_LIGHT_TENTACLE_REACH :: 2.5
WALL_LIGHT_TENTACLE_SPREAD :: 0.8

GLINT_CELL :: 0.3
GLINT_CHANCE :: 0.5
GLINT_RADIUS :: 2.6
GLINT_DEPTH :: 1.8
GLINT_STRENGTH :: 1.8
GLINT_REACH :: 5.0

LightKind :: enum {
	Coral, // also the sea fans' color group index: see LIGHT_COLORS
	Fan,
	Tentacle,
}

Light :: struct {
	kind:                    LightKind,
	side, depth, x, y:       f64,
	strength, reach, spread: f64,
}

// One light per coral and sea fan at the middle of its outermost tips, and three along
// each tentacle (at a quarter, half and three quarters of its length)
light_sources :: proc(corals: []Coral, fans: []SeaFan, tentacles: []Tentacle, out: ^[dynamic]Light) {
	for fan in fans {
		append(out, Light{.Fan, -1, fan.root_depth, fan.crown_x, fan.crown_y, WALL_LIGHT_CORAL, WALL_LIGHT_CORAL_REACH, WALL_LIGHT_CORAL_SPREAD})
	}
	for coral in corals {
		x, y, n := 0.0, 0.0, 0
		for sg in coral.segments {
			if sg.level == FRACTAL_DEPTH - 1 {
				x += sg.x2
				y += sg.y2
				n += 1
			}
		}
		if n > 0 {
			append(out, Light{.Coral, -1, coral.depth, x / f64(n), y / f64(n), WALL_LIGHT_CORAL, WALL_LIGHT_CORAL_REACH, WALL_LIGHT_CORAL_SPREAD})
		}
	}
	for t in tentacles {
		for share in ([3]f64{0.25, 0.5, 0.75}) {
			p := t.points[js_round(share * TENTACLE_SEGMENTS)]
			append(out, Light{.Tentacle, 1, t.depth, p.x, p.y, WALL_LIGHT_TENTACLE, WALL_LIGHT_TENTACLE_REACH, WALL_LIGHT_TENTACLE_SPREAD})
		}
	}
}

// A glow of the wall light: where (screen-fixed world units), how bright, in which color
WallGlow :: struct {
	x, y, alpha: f64,
	kind:        LightKind,
	wall:        int, // 0 ceiling, 1 floor
}

// The wall light, as drawWallLight works it out: along each wall's edge points (every other
// one), each light lights the edge where it is closest to the wall, over its spread along
// the wall and fading with its distance; a spot gets the glow of the light it receives most
// from. Plants standing lower light the rock around their own base instead.
// edges: per wall (ceiling, floor), the edge points' x (screen-fixed) and y.
wall_glows :: proc(edges: [2][][2]f64, lights: []Light, distance: f64, out: ^[dynamic]WallGlow) {
	for edge, e in edges {
		side := 1.0 if e == 0 else -1.0
		for light in lights {
			if light.depth < PLANT_EDGE_DEPTH || light.side != side {
				continue
			}
			for i := 0; i < len(edge); i += 2 {
				along := edge[i].x - (light.x - distance)
				if math.abs(along) > light.spread {
					continue
				}
				x, y := edge[i].x, edge[i].y - side * light.depth
				away := math.abs(light.y - y)
				if away > light.reach {
					continue
				}
				fade := 1 - (along / light.spread) * (along / light.spread)
				alpha := math.min(1, light.strength * fade * fade * (1 - away / light.reach) * WALL_LIGHT_STRENGTH)
				if alpha >= 0.02 {
					append(out, WallGlow{x, y, alpha, light.kind, e})
				}
			}
		}
		for i := 0; i < len(edge); i += 2 {
			x, y := edge[i].x, edge[i].y
			amount: [LightKind]f64
			best, best_kind := 0.0, LightKind.Coral
			for light in lights {
				if light.depth >= PLANT_EDGE_DEPTH {
					continue
				}
				along := x - (light.x - distance)
				if math.abs(along) > light.spread {
					continue
				}
				away := math.abs(light.y - y)
				if away > light.reach {
					continue
				}
				fade := 1 - (along / light.spread) * (along / light.spread)
				// Fans and corals glow in different colors, so they are counted apart
				amount[light.kind] += light.strength * fade * fade * (1 - away / light.reach)
				if amount[light.kind] > best {
					best, best_kind = amount[light.kind], light.kind
				}
			}
			alpha := math.min(1, best * WALL_LIGHT_STRENGTH)
			if alpha >= 0.02 {
				append(out, WallGlow{x, y, alpha, best_kind, e})
			}
		}
	}
}

// The spot a light gathers its sand glints around: on the nearer wall's surface beneath it
// (within GLINT_REACH), or at the base of a plant standing lower. Strength as its wall light.
GlintSpot :: struct {
	x, y, strength: f64, // x in world units
	wall:           int, // 0 ceiling, 1 floor
	kind:           LightKind,
}

glint_spots :: proc(edges: [2][][2]f64, lights: []Light, distance: f64, out: ^[dynamic]GlintSpot) {
	tentacle_light := 0
	for light in lights {
		if light.kind == .Tentacle {
			tentacle_light += 1
			if (tentacle_light - 1) % 3 != 0 {
				continue // a tentacle's three lights count once
			}
		}
		// The wall whose surface is nearer to the light, if within reach
		best_wall, best_i, best_away := -1, 0, GLINT_REACH
		for edge, e in edges {
			step := edge[1].x - edge[0].x
			i := js_round((light.x - distance - edge[0].x) / step)
			if i < 0 || i >= len(edge) {
				continue
			}
			away := math.abs(edge[i].y - light.y)
			if away < best_away {
				best_wall, best_i, best_away = e, i, away
			}
		}
		if best_wall < 0 {
			continue
		}
		into := -1.0 if best_wall == 0 else 1.0
		ly := edges[best_wall][best_i].y + into * (light.depth if light.depth >= PLANT_EDGE_DEPTH else 0)
		away := math.min(GLINT_REACH, math.abs(light.y - ly))
		append(out, GlintSpot{light.x, ly, GLINT_STRENGTH * light.strength * (1 - away / GLINT_REACH), best_wall, light.kind})
	}
}
