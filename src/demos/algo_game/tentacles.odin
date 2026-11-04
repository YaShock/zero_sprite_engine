package main

// Tentacles hanging from the ceiling, ported from index-pixi.html (tentaclesInRange): tapered
// chains whose joints bend by slow noise. Their physics is switched off in the original
// (tentaclePhysics: false), so they only sway on their own.

import "core:math"

TENTACLE_SPACING :: 2.2
TENTACLE_DENSITY :: 0.75
TENTACLE_LENGTH_MIN :: 2.6
TENTACLE_LENGTH_MAX :: 4.8
TENTACLE_BAND :: 2.2 // they hang from random depths within this band beyond the rock's edge
TENTACLE_SEGMENTS :: 16
TENTACLE_ROOT_WIDTH :: 0.65
TENTACLE_CURL :: 0.28 // max bend per joint in radians
TENTACLE_WAVE_SCALE :: 0.25
TENTACLE_PERIOD :: 3.0
TENTACLE_GLOW_WIDTH :: 0.3
TENTACLE_GLOW_STRENGTH :: 0.18

TentaclePoint :: struct {
	x, y, angle, width: f64,
}

Tentacle :: struct {
	key:    i64, // its own noise seed; identifies it
	tier:   int,
	depth:  f64, // how far beyond the rock's edge it hangs
	points: [TENTACLE_SEGMENTS + 1]TentaclePoint,
}

tentacles_in_range :: proc(seed: i64, side, x0, x1, t: f64, out: ^[dynamic]Tentacle) {
	n :: TENTACLE_SEGMENTS
	time := t / TENTACLE_PERIOD
	deco := seed + (404 if side > 0 else 505) // separate from the cave's seed
	roots := make([dynamic]Root, context.temp_allocator)
	roots_in_range(deco, x0, x1, TENTACLE_SPACING, TENTACLE_DENSITY, &roots)
	for root in roots {
		own := deco + imul(root.id, 0x9e3779b1) // this tentacle's own noise
		length := TENTACLE_LENGTH_MIN + hash(own, 1) * (TENTACLE_LENGTH_MAX - TENTACLE_LENGTH_MIN)
		seg := length / n
		// Each hangs from a random depth beyond the rock's edge: the deeper ones in front of it
		depth, tier := growth_depth(deco, root.id, TENTACLE_BAND)
		cave := cave_at(seed, root.x)
		edge_y := cave.top if side > 0 else cave.bottom
		root_y := edge_y - side * depth
		angle := growth_angle(seed, root.x, side)
		// Start slightly inside the rock so the root is hidden by the wall
		x, y := root.x - math.cos(angle) * 0.3, root_y - math.sin(angle) * 0.3
		tentacle := Tentacle {
			key  = own,
			tier = tier,
			depth = depth,
		}
		for i in 0 ..= n {
			width := TENTACLE_ROOT_WIDTH * math.pow(1 - f64(i) / n, 0.8) + 0.03
			tentacle.points[i] = {x, y, angle, width}
			angle += (value_noise2(own, f64(i) * TENTACLE_WAVE_SCALE, time) * 2 - 1) * TENTACLE_CURL
			x += math.cos(angle) * seg
			y += math.sin(angle) * seg
		}
		append(out, tentacle)
	}
}
