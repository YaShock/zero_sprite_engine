package main

// Looks of the atmosphere: fog, spores, jellyfish and the light growths cast on the rock.
// Light-only looks are premultiplied with zero alpha: they add and cover nothing.

import fx "../../engine/vfx"
import "core:fmt"
import "core:math"
import rl "vendor:raylib"

MAX_SPORES :: 320
MAX_FRONT_SPORES :: 16
MAX_WALL_GLOWS :: 512
MAX_GLINT_SPOTS :: 64
MAX_GLINT_BINS :: 8192
MAX_JELLY_CAPSULES :: 600 // strands, outline and rim
MAX_JELLY_BINS :: 16384

// A light color (alpha 0) for adding up light-only looks
light_color :: proc(c: rl.Color) -> [4]f32 {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, 0}
}

// The fog behind the cave: domain-warped noise (the original's own, with its integer
// hashing), tinted between two hues and thinned to its upper range, over the dark water.
// It scrolls at half the cave's speed; drawn into a small, stretched image as the original.
fog_look :: proc() -> ^fx.Node {
	unit := fx.param("unit", f32(36))
	hi, lo := fx.param("seed_hi", f32(0)), fx.param("seed_lo", f32(0))
	t := fx.param("fog_t", f32(0)) // time in noise cells
	// World position in noise cells: screen-fixed units plus the fog's own scroll
	w := fx.div(fx.add(fx.div(fx.world(), unit), fx.vec2(fx.param("fog_x", f32(0)), 0)), FOG_SCALE)
	x, y := fx.swizzle(w, "x"), fx.swizzle(w, "y")
	wx := fx.sub(fx.mul(fx.int_fbm(fx.vec2(x, fx.add(y, fx.mul(t, 0.5))), hi, lo, 2, 11), 2), 1)
	wy := fx.sub(fx.mul(fx.int_fbm(fx.vec2(fx.add(x, fx.mul(t, 0.3)), y), hi, lo, 2, 12), 2), 1)
	v := fx.int_fbm(fx.vec2(fx.add(fx.add(x, fx.mul(wx, FOG_WARP)), fx.mul(t, 0.2)), fx.add(y, fx.mul(wy, FOG_WARP))), hi, lo, 3, 13)
	d := fx.saturate(fx.div(fx.sub(v, 0.35), 0.5))
	alpha := fx.min(fx.mul(fx.mul(fx.mul(d, d), fx.sub(3, fx.mul(d, 2))), FOG_INTENSITY), 1)
	a, b := FOG_A / 255, FOG_B / 255
	tint := fx.mix([4]f32{a.r, a.g, a.b, 1}, [4]f32{b.r, b.g, b.b, 1}, fx.div(fx.add(wx, 1), 2))
	return fx.mix(BACKGROUND, tint, alpha)
}

// Values per light of light_splats_look: x, y, radius, radius (its quad) | r, g, b of its
// light (color times strength), 0
SPLAT_STRIDE :: 8

// Round lights drawn one quad each (an instanced look), so a pixel pays only for the lights
// that reach it: each fades from its center to its radius by `falloff`, in its own color.
// Premultiplied with zero alpha: it only adds light. Lights are in the entity's frame
// (screen pixels with the entity at 0, 0).
light_splats_look :: proc(name: string, max_count: int, falloff: fx.GlowFalloff) -> ^fx.Node {
	lights := fx.instances(name, SPLAT_STRIDE, max_count)
	r := fx.div(fx.length(fx.coord()), fx.instance(lights, 2))
	return fx.mul(fx.instance4(lights, 4), fx.falloff(r, falloff))
}

// The front spores: soft dots, only inside the open tunnel, between the two walls' edges
front_spores_look :: proc() -> ^fx.Node {
	light := light_splats_look("spores", MAX_FRONT_SPORES, .Dot)
	p := fx.world()
	x, y := fx.swizzle(p, "x"), fx.swizzle(p, "y")
	at := fx.div(fx.sub(x, fx.param("edge_x0", f32(0))), fx.param("edge_step", f32(9)))
	top := fx.curve(fx.param_array("top", EDGE_SAMPLES), at)
	bottom := fx.curve(fx.param_array("bottom", EDGE_SAMPLES), at)
	return fx.mul(light, fx.mul(fx.fill(fx.sub(top, y)), fx.fill(fx.sub(y, bottom))))
}

// A glint's color: its light's color brightened toward white
glint_color :: proc(kind: LightKind) -> [4]f32 {
	c := light_color(LIGHT_COLORS[kind])
	return {c.r + (1 - c.r) * 0.55, c.g + (1 - c.g) * 0.55, c.b + (1 - c.b) * 0.55, 0}
}

// Sand glints on one wall's rock (side 1 ceiling, -1 floor): grains on a fixed grid in the
// rock, half the cells holding one, that sparkle now and then and catch the light of the
// spots near them (each as bright as its light's wall light, fading over GLINT_RADIUS), in
// the brightest light's color brightened toward white, in four brightness steps; only
// inside the rock, down to GLINT_DEPTH below its surface. Each pixel looks at the four
// grain cells nearest to it.
glint_look :: proc(side: f32) -> ^fx.Node {
	p := fx.world() // screen pixels
	unit := fx.param("unit", f32(36))
	scroll := fx.param("scroll", f32(0))
	spots := fx.data_array("spots", MAX_GLINT_SPOTS * fx.GLOW_STRIDE)
	spot_bins := fx.data_array("bins", MAX_GLINT_BINS) // each grain looks only at the spots near it
	edges := fx.param_array("edges", EDGE_SAMPLES)
	edge_x0, edge_step := fx.param("edge_x0", f32(0)), fx.param("edge_step", f32(9))
	cells := fx.div(fx.div(fx.add(p, fx.vec2(scroll, 0)), unit), GLINT_CELL)
	c0 := fx.floor(fx.sub(cells, 0.5))
	sparkle_time := fx.mul(fx.time(), 2.3)
	counts := [LightKind]^fx.Node{.Coral = fx.param("n0", f32(0)), .Fan = fx.param("n1", f32(0)), .Tentacle = fx.param("n2", f32(0))}
	// A grain's square is at most 3 pixels wide, so only pixels right at its center show it:
	// its light, color and depth are taken at the pixel, once for all four cells
	lit: [LightKind]^fx.Node
	first: fx.Expr = f32(0)
	for kind in LightKind {
		lit[kind] = fx.glow_points(p, spots, first, counts[kind], spot_bins, .Quadratic)
		first = fx.add(first, counts[kind])
	}
	brightest := fx.max(lit[.Coral], fx.max(lit[.Fan], lit[.Tentacle]))
	color: fx.Expr = glint_color(.Coral) // of the brightest group
	color = fx.mix(color, glint_color(.Fan), fx.step(fx.max(lit[.Coral], lit[.Tentacle]), lit[.Fan]))
	color = fx.mix(color, glint_color(.Tentacle), fx.step(fx.max(lit[.Coral], lit[.Fan]), lit[.Tentacle]))
	// Inside the rock, not deeper than GLINT_DEPTH
	surface := fx.curve(edges, fx.div(fx.sub(fx.swizzle(p, "x"), edge_x0), edge_step))
	depth := fx.div(fx.mul(fx.sub(surface, fx.swizzle(p, "y")), side), unit) // > 0 inside the rock
	inside := fx.mul(fx.step(0.03, depth), fx.step(depth, GLINT_DEPTH))
	grains: fx.Expr = f32(0)
	covered: fx.Expr = f32(0) // how much of the pixel the present grains cover, light aside
	for offset in ([4][2]f32{{0, 0}, {1, 0}, {0, 1}, {1, 1}}) {
		cell := fx.add(c0, offset)
		present := fx.step(fx.hash(cell), GLINT_CHANCE) // hash <= GLINT_CHANCE
		grain := fx.mul(fx.add(cell, fx.vec2(fx.hash(fx.add(cell, 1.3)), fx.hash(fx.add(cell, 2.7)))), GLINT_CELL) // world units
		at := fx.sub(fx.mul(grain, unit), fx.vec2(scroll, 0)) // its center on screen
		phase := fx.add(0.5, fx.mul(fx.sin(fx.add(sparkle_time, fx.mul(fx.hash(fx.add(cell, 3.1)), 6.28))), 0.5))
		best := fx.mul(brightest, fx.add(0.25, fx.mul(fx.mul(fx.mul(phase, phase), phase), 0.75))) // sparkling
		// Four brightness steps, nothing below the faintest
		steps := fx.mul(fx.step(0.125, best), fx.div(fx.min(fx.floor(fx.add(fx.mul(best, 4), 0.5)), 4), 4))
		// The grain's square (1.5 to 3 pixels), as much of it as covers this pixel
		half := fx.mul(fx.add(1.5, fx.mul(fx.hash(fx.add(cell, 4.4)), 1.5)), 0.5)
		overlap := fx.max(fx.sub(fx.min(fx.add(p, 0.5), fx.add(at, half)), fx.max(fx.sub(p, 0.5), fx.sub(at, half))), 0)
		cover := fx.mul(present, fx.mul(fx.swizzle(overlap, "x"), fx.swizzle(overlap, "y")))
		covered = fx.add(covered, cover)
		grains = fx.add(grains, fx.mul(steps, cover))
	}
	// Outside the rock band nothing is computed; the light (the list walks) only where a grain
	// covers the pixel (a few percent of them), and the grains' brightness only where the light
	// is bright enough to light any (sparkling scales it by 0.25 to 1, and below 0.125 a grain
	// stays dark)
	lit_grains := fx.gate(fx.step(0.125, brightest), fx.mul(color, grains))
	return fx.gate(inside, fx.gate(covered, lit_grains))
}

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

// A luminous jellyfish, as light, in its own frame (bell half-width `w`, world units; the
// entity turns it). The bell is filled between its dome (flat to pointed) and its
// scalloped rim, and the oral arms are waving ribbons, both worked out per pixel; the
// strands (bell outline, canals, ribbon edges, filaments), the wide faint outline glow and
// the bright rim are capsules. Gradients run down the jellyfish's height.
jelly_look :: proc() -> ^fx.Node {
	unit := fx.param("unit", f32(36))
	origin := fx.param("origin", [2]f32{0, 0}) // the jellyfish's (0, 0) in the entity's own pixels
	lp := fx.div(fx.sub(fx.coord(), origin), unit) // world units around the jellyfish
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
		arm := fx.param(fmt.tprintf("arm%d", i), [4]f32{0, 0, 0, 0}) // x0, length, width, in use
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
