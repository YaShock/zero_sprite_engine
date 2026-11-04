package main

// Scene 2's jellyfish: AlgoGame's luminous jellyfish (its atmosphere.odin and scenery.odin,
// ported), floating far out in the sea round the cave, seen through where the room broke
// open. Each is AlgoGame's flat jellyfish turned to face the camera at its place in the
// water, as big on screen as its distance makes it, in one of AlgoGame's three depth layers,
// drawn small and stretched (blurred) as AlgoGame's: the farther, the blurrier. Its shape
// (one of AlgoGame's four kinds) and colors (one of its three families) are chosen here, the
// rest drawn from its seed as AlgoGame draws them; it pulses, waves its arms and sways.

import eng "../../engine"
import fx "../../engine/vfx"
import "core:math"

JellyLayer :: struct {
	blur:  int, // drawn at this many times lower resolution
	alpha: f32,
}
JELLY_LAYERS := [3]JellyLayer{{6, 0.35}, {4, 0.35}, {2, 0.35}} // far to near

JellyType :: struct {
	aspect, peak, lobes, arms, arm_length, arm_width, filaments, filament_length: [2]f32,
}
JELLY_TYPES := [4]JellyType {
	{{0.28, 0.4}, {0.45, 0.7}, {10, 16}, {4, 4}, {0.8, 1.3}, {0.1, 0.14}, {10, 16}, {0.4, 0.9}}, // moon jelly
	{{0.6, 0.85}, {0.8, 1.1}, {6, 9}, {2, 3}, {1.2, 1.8}, {0.12, 0.18}, {4, 7}, {2.4, 3.6}}, // bell jelly
	{{0.85, 1.1}, {1.3, 1.8}, {5, 8}, {2, 2}, {0.9, 1.4}, {0.1, 0.15}, {3, 5}, {2.8, 4.2}}, // helmet
	{{0.45, 0.6}, {0.7, 0.95}, {8, 12}, {4, 5}, {2.0, 3.0}, {0.14, 0.2}, {6, 9}, {3.0, 4.5}}, // sea nettle
}

// Hues (degrees) and how far the rim's hue is shifted from the bell's
JellyColors :: struct {
	hue, rim_shift: [2]f32,
}
JELLY_COLORS := [3]JellyColors {
	{{215, 240}, {-12, 8}}, // dark blue
	{{245, 272}, {10, 30}}, // violet
	{{310, 330}, {-25, -10}}, // magenta
}

// The jellyfish: where (meters), its bell's half-width (meters), its kind, its colors, its
// depth layer (0 far .. 2 near)
JellyPlace :: struct {
	at:           Vec3,
	size:         f32,
	kind, colors: int,
	layer:        int,
}
JELLIES := [?]JellyPlace {
	{{14, 8, -20}, 3.4, 0, 0, 0}, // moon jelly, dark blue
	{{3, 9.5, -23}, 3.2, 2, 1, 0}, // helmet, violet
	{{-4, 7, -20}, 3.3, 1, 0, 0}, // bell jelly, dark blue
	{{9, 5.5, -12}, 3.6, 3, 2, 1}, // sea nettle, magenta
	{{-1, 6.5, -15}, 3.4, 1, 1, 1}, // bell jelly, violet
	{{5.5, 4, -6}, 3.3, 0, 1, 2}, // moon jelly, violet
	{{-17, 6, 1}, 3.4, 3, 0, 1}, // sea nettle, dark blue: out past the left wall
}

JellyFeatures :: struct {
	hue, saturation, rim_hue, body, gain:   f32,
	aspect, peak, lobe_depth:               f32,
	lobes, arms, filaments, canals:         int,
	arm_length, arm_width, filament_length: f32,
	tilt, pulse_speed, phase:               f32,
	variation:                              int,
}

// A CSS hsl() color's channel n (0 red, 8 green, 4 blue), 0..1
hsl_channel :: proc(h, s, l: f32, n: f32) -> f32 {
	a := s * min(l, 1 - l)
	k := math.mod(n + h / 30, 12)
	return l - a * max(-1, min(k - 3, 9 - k, 1))
}

hsl :: proc(h, s, l: f32) -> [3]f32 {
	return {hsl_channel(h, s, l, 0), hsl_channel(h, s, l, 8), hsl_channel(h, s, l, 4)}
}

// Each jellyfish's light is scaled by its colors' brightness (partly: the 0.6 power), so all
// color families look about equally bright
jelly_brightness_gain :: proc(hue, saturation, rim_hue: f32) -> f32 {
	luma :: proc(h, s, l: f32) -> f32 {
		return 0.2126 * hsl_channel(h, s, l, 0) + 0.7152 * hsl_channel(h, s, l, 8) + 0.0722 * hsl_channel(h, s, l, 4)
	}
	brightness := 0.6 * luma(hue, saturation / 100, 0.5) + 0.4 * luma(rim_hue, 1, 0.73)
	return min(1.6, max(0.6, math.pow(0.45 / brightness, 0.6)))
}

js_round :: proc(x: f32) -> int {return int(math.floor(x + 0.5))}

jelly_features :: proc(place: JellyPlace, slot: int) -> JellyFeatures {
	h :: proc(slot, k: int) -> f32 {return rnd(slot, k, 7300)}
	pick :: proc(r: [2]f32, v: f32) -> f32 {return r[0] + (r[1] - r[0]) * v}
	type := JELLY_TYPES[place.kind]
	colors := JELLY_COLORS[place.colors]
	f: JellyFeatures
	f.hue = pick(colors.hue, h(slot, 1))
	f.saturation = 75 + h(slot, 2) * 25
	f.rim_hue = f.hue + pick(colors.rim_shift, h(slot, 31))
	f.body = 0.3 + h(slot, 3) * 0.12
	f.gain = jelly_brightness_gain(f.hue, f.saturation, f.rim_hue)
	f.aspect = pick(type.aspect, h(slot, 4))
	f.peak = pick(type.peak, h(slot, 5))
	f.lobes = js_round(pick(type.lobes, h(slot, 6)))
	f.lobe_depth = 0.02 + h(slot, 7) * 0.04
	f.arms = js_round(pick(type.arms, h(slot, 8)))
	f.arm_length = pick(type.arm_length, h(slot, 9))
	f.arm_width = pick(type.arm_width, h(slot, 10))
	f.filaments = js_round(pick(type.filaments, h(slot, 11)))
	f.filament_length = pick(type.filament_length, h(slot, 12))
	f.canals = 6 + int(math.floor(h(slot, 16) * 6))
	f.tilt = (h(slot, 13) - 0.5) * 0.6
	f.pulse_speed = 0.9 + h(slot, 14) * 0.9
	f.phase = h(slot, 15) * 6.28
	f.variation = 7300 + slot * 7
	return f
}

MAX_JELLY_ARMS :: 5
JELLY_RIM_POINTS :: 25
MAX_JELLY_CAPSULES :: 600 // strands, outline and rim
MAX_JELLY_BINS :: 16384
JELLY_BIN_CELL :: 16 // screen pixels at blur 2, as AlgoGame

JellyArm :: struct {
	x0, length, width: f32,
}

// One jellyfish's shape now, around (0, 0) with bell half-width w
JellyShape :: struct {
	bw, bh:    f32,
	dome, rim: [JELLY_RIM_POINTS][2]f32,
	arms:      [MAX_JELLY_ARMS]JellyArm, // the ribbons: their edges are worked out in the look
}

jelly_shape :: proc(f: ^JellyFeatures, w, time: f32) -> JellyShape {
	s: JellyShape
	pulse := math.sin(time * f.pulse_speed + f.phase)
	s.bw, s.bh = w * (1 + pulse * 0.06), w * f.aspect * (1 - pulse * 0.08)
	for k in 0 ..< JELLY_RIM_POINTS {
		u := f32(k) / 24
		a := math.PI - u * math.PI
		s.rim[k] = {(u * 2 - 1) * s.bw, abs(math.sin(u * f32(f.lobes) * math.PI)) * s.bw * f.lobe_depth}
		s.dome[k] = {math.cos(a) * s.bw, -math.pow(math.sin(a), f.peak) * s.bh}
	}
	for i in 0 ..< min(f.arms, MAX_JELLY_ARMS) {
		s.arms[i] = {
			x0     = ((f32(i) + 0.5) / f32(f.arms) * 2 - 1) * s.bw * 0.35,
			length = w * f.arm_length * (0.75 + 0.5 * rnd(f.variation, i, 1)),
			width  = s.bw * f.arm_width * (0.8 + 0.4 * rnd(f.variation + 1, i, 1)),
		}
	}
	return s
}

// A point of an oral arm's edge (side -1 left, 1 right) at u in 0..1 down its length
jelly_arm_edge :: proc(f: ^JellyFeatures, arm: JellyArm, i: int, w, time, u, side: f32) -> [2]f32 {
	x := arm.x0 + math.sin(time * 0.7 + f.phase + f32(i) * 2.1 + u * 3.2) * w * 0.25 * u
	half := arm.width * (1 - u * 0.55) * (0.7 + 0.3 * math.sin(u * 7 + f32(i) * 1.7 + time * 0.9))
	return {x + side * half, u * arm.length}
}

// A filament's point k of 0..12
jelly_filament_point :: proc(f: ^JellyFeatures, s: ^JellyShape, i: int, w, time: f32, k: int) -> [2]f32 {
	x0 := ((f32(i) + 0.5) / f32(f.filaments) * 2 - 1) * s.bw * 0.95
	if k == 0 {
		return {x0, s.rim[js_round((f32(i) + 0.5) / f32(f.filaments) * 24)].y}
	}
	length := w * f.filament_length * (0.6 + 0.8 * rnd(f.variation + 2, i, 1))
	u := f32(k) / 12
	return {x0 + math.sin(time * 1.2 + f.phase + f32(i) * 1.7 + u * 6) * w * 0.1 * u, u * length}
}

ARM_PARAMS := [MAX_JELLY_ARMS]string{"arm0", "arm1", "arm2", "arm3", "arm4"}

// The jellyfish's entities, one per jellyfish in its layer's out-of-focus image
add_jellies :: proc() {
	for &id, i in room.jellies {
		id = eng.add_entity(jelly_look(), {}, {1, 1}, {z_index = LAYER_JELLY + JELLIES[i].layer, blend = .Premultiplied})
	}
}

// Every frame: each jellyfish where it sways to, facing the camera, as big as its distance
// makes it (`s`: screen pixels per meter there), its strands as capsules in the entity's own
// pixels, as AlgoGame's sync_jelly
update_jellies :: proc(t: f32) {
	cam := room.camera
	@(static) values: [MAX_JELLY_CAPSULES * fx.CAPSULE_STRIDE]f32
	@(static) bins: [MAX_JELLY_BINS]f32
	for place, slot in JELLIES {
		id := room.jellies[slot]
		e := eng.get_entity(id)
		f := jelly_features(place, slot)
		w := place.size
		// AlgoGame's sway, in the plane facing the camera
		at := place.at + cam.right * (math.sin(t * 0.05 + f.phase) * w) + Vec3{0, math.sin(t * 0.12 + f.phase) * w * 0.25, 0}
		center_px, depth := project(cam, at)
		if depth < 2 {
			e.visible = false
			continue
		}
		s := cam.focal / depth
		blur := f32(JELLY_LAYERS[place.layer].blur)
		shape := jelly_shape(&f, w, t)
		k := 0
		lo, hi := [2]f32{-shape.bw, -shape.bh}, [2]f32{shape.bw, shape.bw * f.lobe_depth}
		// A line through `points` (meters around the jellyfish), drawn at least one pixel of
		// the small image wide
		line :: proc(out: []f32, k: ^int, points: [][2]f32, width, s, blur: f32, lo, hi: ^[2]f32) {
			radius := max(width * s / 2, 0.5 * blur) // screen pixels
			for i in 0 ..< len(points) - 1 {
				if k^ >= len(out) {
					return
				}
				a, b := points[i], points[i + 1]
				c := k^
				out[c], out[c + 1], out[c + 2], out[c + 3] = a.x * s, a.y * s, b.x * s, b.y * s
				out[c + 4], out[c + 5] = radius, radius
				k^ += fx.CAPSULE_STRIDE
				for p in ([2][2]f32{a, b}) {
					lo^ = {min(lo.x, p.x), min(lo.y, p.y)}
					hi^ = {max(hi.x, p.x), max(hi.y, p.y)}
				}
			}
		}
		// How faint a line is for being thinner than a pixel of the small image
		thin :: proc(width, s, blur: f32) -> f32 {return min(1, width * s / blur)}

		// Strands: the bell's outline, the canals, the ribbons' edges and the filaments
		strand_width := w * 0.022
		line(values[:], &k, shape.dome[:], strand_width, s, blur, &lo, &hi)
		for i in 0 ..< f.canals {
			m := shape.rim[js_round((f32(i) + 0.5) / f32(f.canals) * 24)]
			p0, c, p1 := [2]f32{m.x * 0.15, -shape.bh * 0.55}, [2]f32{m.x * 0.6, -shape.bh * 0.45}, m
			pts: [13][2]f32
			for q in 0 ..= 12 {
				u := f32(q) / 12
				v := 1 - u
				pts[q] = v * v * p0 + 2 * v * u * c + u * u * p1
			}
			line(values[:], &k, pts[:], strand_width, s, blur, &lo, &hi)
		}
		arms := min(f.arms, MAX_JELLY_ARMS)
		for i in 0 ..< arms {
			for side in ([2]f32{-1, 1}) {
				pts: [15][2]f32
				for q in 0 ..= 14 {
					pts[q] = jelly_arm_edge(&f, shape.arms[i], i, w, t, f32(q) / 14, side)
				}
				line(values[:], &k, pts[:], strand_width, s, blur, &lo, &hi)
			}
		}
		for i in 0 ..< f.filaments {
			pts: [13][2]f32
			for q in 0 ..= 12 {
				pts[q] = jelly_filament_point(&f, &shape, i, w, t, q)
			}
			line(values[:], &k, pts[:], strand_width, s, blur, &lo, &hi)
		}
		strands := k / fx.CAPSULE_STRIDE
		// The wide faint outline glow along the dome and the rim, then the bright rim
		line(values[:], &k, shape.dome[:], w * 0.16, s, blur, &lo, &hi)
		line(values[:], &k, shape.rim[:], w * 0.16, s, blur, &lo, &hi)
		outline := k / fx.CAPSULE_STRIDE - strands
		line(values[:], &k, shape.rim[:], w * 0.06, s, blur, &lo, &hi)

		// The entity covers the jellyfish's frame (unturned); its center, from the jellyfish's
		// origin, is where the capsules and the look's coordinates are measured from
		margin := w * 0.1 + 2 * blur / s
		lo -= margin
		hi += margin
		center := (lo + hi) / 2 * s
		for c := 0; c < k; c += fx.CAPSULE_STRIDE {
			values[c] -= center.x
			values[c + 1] -= center.y
			values[c + 2] -= center.x
			values[c + 3] -= center.y
		}
		eng.set_param_array(id, "capsules", values[:k])
		used := eng.bin_shapes(bins[:], values[:k], .Capsules, blur + 1, JELLY_BIN_CELL * blur / 2)
		eng.set_param_array(id, "bins", bins[:used])
		eng.set_param(id, "n_strands", f32(strands))
		eng.set_param(id, "n_outline", f32(outline))

		// Shape and paints
		a :: proc(f: ^JellyFeatures, alpha: f32) -> f32 {return min(1, alpha * f.gain)}
		edge_hue := (f.hue + f.rim_hue) / 2
		sat := f.saturation / 100
		color :: proc(rgb: [3]f32, alpha: f32 = 1) -> [4]f32 {return {rgb.r * alpha, rgb.g * alpha, rgb.b * alpha, 0}}
		eng.set_param(id, "unit", s)
		eng.set_param(id, "origin", eng.Vector2{-center.x, -center.y})
		eng.set_param(id, "bw", shape.bw)
		eng.set_param(id, "bh", shape.bh)
		eng.set_param(id, "w", w)
		eng.set_param(id, "t", t)
		eng.set_param(id, "phase", f.phase)
		eng.set_param(id, "peak", f.peak)
		eng.set_param(id, "lobes", f32(f.lobes))
		eng.set_param(id, "lobe_depth", f.lobe_depth)
		for i in 0 ..< MAX_JELLY_ARMS {
			arm := shape.arms[i]
			eng.set_param(id, ARM_PARAMS[i], [4]f32{arm.x0, arm.length, arm.width, 1 if i < arms else 0})
		}
		eng.set_param(id, "body_color", color(hsl(f.hue, sat, 0.5)))
		eng.set_param(id, "body_at", [4]f32{-shape.bh, 0, w * 0.3, w * 1.5})
		eng.set_param(id, "body_alpha", [4]f32{a(&f, f.body * 0.45), a(&f, f.body * 1.35), a(&f, f.body * 0.9), a(&f, f.body * 0.7)})
		eng.set_param(id, "strand_color", color(hsl(edge_hue, sat, 0.63)))
		eng.set_param(id, "strand_at", [4]f32{-shape.bh, -shape.bh * 0.8, -w * 0.04, w * 0.15})
		eng.set_param(id, "strand_alpha", [4]f32{a(&f, 0.5), a(&f, 0.3), a(&f, 0.3), a(&f, 0.62)})
		eng.set_param(id, "strand_thin", thin(strand_width, s, blur))
		eng.set_param(id, "outline_color", color(hsl(edge_hue, sat, 0.63), a(&f, 0.14)))
		eng.set_param(id, "outline_thin", thin(w * 0.16, s, blur))
		eng.set_param(id, "rim_color", color(hsl(f.rim_hue, 1, 0.73), a(&f, 0.95)))
		eng.set_param(id, "rim_thin", thin(w * 0.06, s, blur))

		// Placed so that turning the entity around its center turns the jellyfish around its origin
		c, n := math.cos(f.tilt), math.sin(f.tilt)
		e.visible = true
		e.size = (hi - lo) * s
		e.pos = {center_px.x + center.x * c - center.y * n, center_px.y + center.x * n + center.y * c}
		e.rotation = f.tilt * math.DEG_PER_RAD
	}
}
