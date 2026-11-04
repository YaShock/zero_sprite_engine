package main

import fx "../../engine/vfx"
import "core:fmt"
import rl "vendor:raylib"

// 3D in a 2D engine: every look casts the camera ray through its pixel and finds what it
// hits (a closed-form intersection, or sphere tracing for the objects). 3D vectors are vec4s
// whose w is 0 (dot, length and the arithmetic then work as in 3D); positions are in
// meters, x right, y up, z into the room. The lights and occluders are lists the looks loop
// over (fx.point_lights, fx.capsule_shadows, ...), filled by game code every frame.

XYZ :: [4]f32{1, 1, 1, 0}
W1 :: [4]f32{0, 0, 0, 1}

// Drops the w of a vec4 holding a position plus something else (radius, kind, ...).
xyz :: proc(v: fx.Expr) -> ^fx.Node {return fx.mul(v, XYZ)}

normalize3 :: proc(v: fx.Expr) -> ^fx.Node {return fx.div(v, fx.length(v))}

component :: proc(v: fx.Expr, c: string) -> ^fx.Node {return fx.swizzle(v, c)}

// sRGB color as linear light (squared: close enough, and cheap), as a vec4 (w 0) or a Vec3
linear :: proc(c: rl.Color) -> [4]f32 {
	v := [4]f32{f32(c.r), f32(c.g), f32(c.b), 0} / 255
	return v * v
}

linear3 :: proc(c: rl.Color) -> Vec3 {
	v := linear(c)
	return v.xyz
}

// Which effects the looks include (ROOM_SHADOWS, ROOM_AO, ROOM_HAZE; keys 1-3), and whether
// the floor reflects (ROOM_REFLECTIONS, key 4: a second view, see View) and bright parts
// bloom (ROOM_BLOOM, key 5: LAYER_BLOOM)
Effects :: struct {
	shadows, occlusion, haze, reflections, bloom: bool,
}

// The camera ray through this pixel. Game code sets the camera every frame (set_camera):
// the ray direction is cam_a + cam_r·x + cam_d·y for screen position (x, y), and cam_pix
// is the angle of one pixel, so pixel-wide anti-aliasing at distance t is t·cam_pix.
Ray :: struct {
	origin, dir: ^fx.Node,
}

camera_ray :: proc() -> Ray {
	w := fx.world()
	d := fx.sum(
		fx.param("cam_a", [4]f32{0, 0, 1, 0}),
		fx.mul(fx.param("cam_r", [4]f32{1, 0, 0, 0}), component(w, "x")),
		fx.mul(fx.param("cam_d", [4]f32{0, -1, 0, 0}), component(w, "y")),
	)
	return {fx.param("cam_pos", [4]f32{0, 2, 0, 0}), normalize3(d)}
}

camera_pixel :: proc() -> ^fx.Node {return fx.param("cam_pix", f32(0.001))}

// The lists every look reads, filled every frame (update_shared): the lights
// (fx.LIGHT_STRIDE values each, light_count of them in use) and, for the room, every
// object's and the logo's occluding capsule (fx.CAPSULE3_STRIDE values each) with a bin
// grid of their reach on screen for the occlusion.
lights_list :: proc() -> ^fx.Node {return fx.param_array("lights", MAX_LIGHTS * fx.LIGHT_STRIDE)}
light_count :: proc() -> ^fx.Node {return fx.param("light_count", f32(0))}
occluders_list :: proc() -> ^fx.Node {return fx.data_array("occluders", MAX_OCCLUDERS * fx.CAPSULE3_STRIDE)}
occluder_count :: proc() -> ^fx.Node {return fx.param("occluder_count", f32(0))}

// Param names of the logo's capsules: ca<k>/cb<k> = the ends of capsule k of a letter
logo_a_names, logo_b_names: [MAX_LOGO_CAPSULES]string
cable_a_names, cable_b_names: [MAX_CABLES]string // wa<k>/wb<k>: the ends of cable k (cables_look)

init_param_names :: proc() {
	for i in 0 ..< MAX_LOGO_CAPSULES {
		logo_a_names[i] = fmt.aprintf("ca%d", i)
		logo_b_names[i] = fmt.aprintf("cb%d", i)
	}
	for i in 0 ..< MAX_CABLES {
		cable_a_names[i] = fmt.aprintf("wa%d", i)
		cable_b_names[i] = fmt.aprintf("wb%d", i)
	}
}

// ---------------------------------------------------------------------------------------
// Lighting

// A lit point of a surface. albedo is linear color (w 0).
Surface :: struct {
	pos, normal, view, albedo: ^fx.Node,
	specular, shininess:       fx.Expr,
}

// The light reaching a surface point: hemisphere ambient plus the point lights (Lambert,
// Blinn-Phong, inverse-square falloff windowed to each light's range), lights 0..3 scaled by
// `shadow`, only the lights in `mask` (-1: all). occlusion (nil = 1) darkens the ambient fully
// and the direct light by OCCLUSION_DIRECT, as nearby surfaces also block light that would
// have bounced in. The ambient light is params (ambient_sky, ambient_ground: the room's, or
// the sea's in the deep). Linear color, w 0.
shade :: proc(s: Surface, shadow, mask: fx.Expr, occlusion: ^fx.Node) -> ^fx.Node {
	up := fx.add(fx.mul(component(s.normal, "y"), 0.5), 0.5)
	ambient := fx.mul(s.albedo, fx.mix(fx.param("ambient_ground", AMBIENT_GROUND), fx.param("ambient_sky", AMBIENT_SKY), up))
	material := fx.rgba(s.specular, s.shininess, 0, 0)
	direct := fx.point_lights(s.pos, s.normal, s.view, s.albedo, material, lights_list(), light_count(), shadow, mask)
	if occlusion != nil {
		ambient = fx.mul(ambient, occlusion)
		direct = fx.mul(direct, fx.add(1 - OCCLUSION_DIRECT, fx.mul(occlusion, OCCLUSION_DIRECT)))
	}
	return fx.add(ambient, direct)
}

// The air between the camera and a surface `far` along the ray: it scatters the lights'
// glow towards the camera (closed form per light, fx.haze_lights) and dims what lies behind
// it; it also has a faint glow of its own.
with_haze :: proc(light: ^fx.Node, ray: Ray, far: ^fx.Node) -> ^fx.Node {
	return fx.add(fx.mul(light, haze_through(far)), haze_scattered(ray, far))
}

// What of the light from `far` away gets through the air
haze_through :: proc(far: ^fx.Node) -> ^fx.Node {return fx.exp(fx.mul(far, -HAZE_EXTINCTION))}

// The light the air scatters towards the camera along the ray up to `far` (w 0)
haze_scattered :: proc(ray: Ray, far: ^fx.Node) -> ^fx.Node {
	return fx.add(
		fx.mul(HAZE_GLOW, fx.sub(1, haze_through(far))),
		fx.mul(fx.haze_lights(ray.origin, ray.dir, far, lights_list(), light_count(), HAZE_CORE), HAZE_DENSITY),
	)
}

// Linear light to the screen: exposure, a soft shoulder instead of clipping at 1 (many
// lights add up), and back to sRGB.
finish :: proc(light: ^fx.Node, alpha: fx.Expr, loc := #caller_location) -> ^fx.Node {
	mapped := fx.sub(1, fx.exp(fx.neg(fx.mul(light, fx.param("exposure", f32(1))))))
	return fx.add(fx.pow(mapped, 1 / 2.2), fx.mul(W1, alpha), loc) // named after the look calling it, for the profiler
}

// The same for a surface seen in the floor (a ray of the mirrored camera, which crosses the
// floor before it gets there), for the reflection's layer: premultiplied by its coverage
// times how much the floor reflects there
reflected :: proc(light: ^fx.Node, coverage: fx.Expr, ray: Ray, loc := #caller_location) -> ^fx.Node {
	mapped := fx.pow(fx.sub(1, fx.exp(fx.neg(fx.mul(light, fx.param("exposure", f32(1)))))), 1 / 2.2)
	k := fx.mul(reflectivity(ray), coverage)
	return fx.add(fx.mul(mapped, k), fx.mul(W1, k), loc)
}

// Of the floor at uv (meters), the share that is grout (anti-aliased over `aa` meters)
floor_grout :: proc(uv, aa: fx.Expr) -> ^fx.Node {
	d := fx.sd_box(fx.tile(uv, [2]f32{TILE_SIZE, TILE_SIZE}), [2]f32{TILE_SIZE / 2 - GROUT_WIDTH, TILE_SIZE / 2 - GROUT_WIDTH})
	return fx.smoothstep(fx.neg(aa), aa, d)
}

// How much the floor reflects where a ray of the mirrored camera comes up through it:
// Schlick's approximation from REFLECT_FACING straight on to REFLECT_GRAZING, a fifth of
// that in the grout (floor_reflect in light_room.odin is the same without the grout), and
// nothing where the flood covers the floor
reflectivity :: proc(ray: Ray) -> ^fx.Node {
	rise := fx.max(component(ray.dir, "y"), 1e-3)
	t := fx.div(fx.neg(component(ray.origin, "y")), rise)
	at := fx.add(ray.origin, fx.mul(ray.dir, t))
	uv := fx.swizzle(at, "xz")
	k := fx.mix(REFLECT_FACING, REFLECT_GRAZING, fx.pow(fx.sub(1, fx.saturate(rise)), 5))
	rr, _ := from_hatch(at)
	dry := fx.sub(1, flooded(water_param(), rr))
	return fx.mul(fx.mul(k, dry), fx.sub(1, fx.mul(floor_grout(uv, fx.mul(t, camera_pixel())), 0.8)))
}

// The floor's contact shading of a surface point: undersides near the floor see mostly floor
floor_contact :: proc(pos, normal: ^fx.Node) -> ^fx.Node {
	near := fx.mul(fx.sub(1, fx.smoothstep(0, FLOOR_CONTACT, component(pos, "y"))), fx.saturate(fx.neg(component(normal, "y"))))
	return fx.sub(1, fx.mul(near, 0.85))
}

// ---------------------------------------------------------------------------------------
// The room: a box seen from inside, so every ray leaves it through one of its faces. The
// face is the one whose plane the ray reaches first.

RoomHit :: struct {
	pos, normal: ^fx.Node,
	exit:        ^fx.Node, // distance along the ray
	face, ahead: ^fx.Node, // per axis: the face's axis (1), the ray going towards +axis (1)
}

room_hit :: proc(ray: Ray) -> RoomHit {
	lo := [4]f32{-ROOM_HALF_WIDTH, 0, 0, 0}
	hi := [4]f32{ROOM_HALF_WIDTH, ROOM_HEIGHT, ROOM_DEPTH, 0}
	// w 1 so that w divides 0 by 1 instead of by 0
	dir := fx.add(ray.dir, W1)
	ahead := fx.step(0, dir)
	t := fx.div(fx.sub(fx.mix(lo, hi, ahead), ray.origin), dir)
	exit := fx.min(fx.min(component(t, "x"), component(t, "y")), component(t, "z"))
	// The axis (or axes, on an edge) whose plane is reached first; the normal faces back (on
	// an edge, between the two faces: unnormalized, it would make the specular highlight
	// blow up to a white pixel)
	face := fx.step(t, fx.mul(fx.add(exit, 1e-4), [4]f32{1, 1, 1, 1}))
	normal := normalize3(fx.mul(fx.mul(face, fx.sub(1, fx.mul(ahead, 2))), XYZ))
	return {fx.add(ray.origin, fx.mul(ray.dir, exit)), normal, exit, face, ahead}
}

// Where two faces of the room meet, each hides part of the other's sky: every face at a
// right angle to the surface darkens it near their edge.
corner_occlusion :: proc(hit: RoomHit) -> ^fx.Node {
	p := hit.pos
	x, y := component(p, "x"), component(p, "y")
	gaps := fx.rgba(fx.sub(ROOM_HALF_WIDTH, x), fx.add(x, ROOM_HALF_WIDTH), y, fx.sub(ROOM_HEIGHT, y))
	n := fx.abs(hit.normal)
	across := fx.sub(1, fx.rgba(component(n, "x"), component(n, "x"), component(n, "y"), component(n, "y")))
	near := fx.add(
		fx.dot(fx.exp(fx.div(gaps, -CORNER_REACH)), across),
		fx.mul(fx.exp(fx.div(fx.sub(ROOM_DEPTH, component(p, "z")), -CORNER_REACH)), fx.sub(1, component(n, "z"))),
	)
	return fx.saturate(fx.sub(1, fx.mul(near, CORNER_STRENGTH)))
}

room_look :: proc(effects: Effects) -> ^fx.Node {
	ray := camera_ray()
	hit := room_hit(ray)
	pos, face, ahead := hit.pos, hit.face, hit.ahead
	floor := fx.mul(component(face, "y"), fx.sub(1, component(ahead, "y")))
	ceiling := fx.mul(component(face, "y"), component(ahead, "y"))
	// Surface coordinates in meters: floor and ceiling x/z, side walls z/y, back wall x/y
	uv := fx.sum(
		fx.mul(fx.swizzle(pos, "zy"), component(face, "x")),
		fx.mul(fx.swizzle(pos, "xz"), component(face, "y")),
		fx.mul(fx.swizzle(pos, "xy"), component(face, "z")),
	)
	aa := fx.mul(hit.exit, camera_pixel()) // a pixel, in meters, where the ray lands
	grime := fx.fbm(fx.mul(uv, 0.9), 4)

	// Floor: two tones of tiles with grout between them
	tile := [2]f32{TILE_SIZE, TILE_SIZE}
	tone := fx.mix(linear(FLOOR_TILE_A), linear(FLOOR_TILE_B), fx.mul(fx.hash(fx.cell_id(uv, tile)), 0.8))
	tiles := fx.mix(tone, linear(GROUT), floor_grout(uv, aa))
	floor_color := fx.mul(tiles, fx.add(0.7, fx.mul(grime, 0.5)))

	// Walls: plaster with a dark trim along the floor
	trim := fx.sub(1, fx.smoothstep(fx.sub(TRIM_HEIGHT, aa), fx.add(TRIM_HEIGHT, aa), component(pos, "y")))
	plaster := fx.mul(linear(WALL), fx.add(0.82, fx.mul(grime, 0.3)))
	wall_color := fx.mix(plaster, linear(TRIM), trim)
	ceiling_color := fx.mul(linear(CEILING), fx.add(0.9, fx.mul(grime, 0.15)))

	// The jet's water on the ceiling and running down the walls: a dark, shiny film
	water := water_param()
	film := fx.gate(component(water, "w"), wet_film(pos, uv, ceiling, fx.sub(1, component(face, "y")), water))
	surface := Surface {
		pos       = pos,
		normal    = hit.normal,
		view      = fx.neg(ray.dir),
		albedo    = fx.mix(fx.mix(fx.mix(wall_color, floor_color, floor), ceiling_color, ceiling), linear(WET_FILM), fx.mul(film, 0.85)),
		specular  = fx.sum(0.04, fx.mul(floor, 0.3), fx.mul(film, 0.5)),
		shininess = fx.mix(fx.add(10, fx.mul(floor, 50)), 60, film),
	}
	// What of the first four lights gets past the objects, worked out at half resolution by
	// shadow_buffer_look, a light per channel
	shadow: fx.Expr = [4]f32{1, 1, 1, 1}
	if effects.shadows {
		shadow = fx.layer_sample(LAYER_SHADOW_BUFFER, fx.world())
	}
	// The objects' occlusion and the haze change slowly over the room: worked out at a
	// quarter of the resolution by air_buffer_look
	air: ^fx.Node
	if effects.occlusion || effects.haze {
		air = fx.layer_sample(LAYER_AIR_BUFFER, fx.world())
	}
	occlusion: ^fx.Node
	if effects.occlusion {
		occlusion = fx.mul(corner_occlusion(hit), component(air, "w"))
	}
	light := shade(surface, shadow, f32(-1), occlusion)
	if effects.haze {
		light = fx.add(fx.mul(light, haze_through(hit.exit)), xyz(air))
	}
	return finish(room_water(light, ray, hit.exit), 1)
}

// The room's slowly changing parts, for the room look to read: the light the air scatters
// towards the camera (rgb) and what of the sky the objects leave each point (w), drawn into
// the low-resolution buffer layer as they are (premultiplied blending). A pixel tests only
// the occluders whose reach covers it (update_occluders).
air_buffer_look :: proc(effects: Effects) -> ^fx.Node {
	ray := camera_ray()
	hit := room_hit(ray)
	scattered: fx.Expr = [4]f32{}
	if effects.haze {
		scattered = haze_scattered(ray, hit.exit)
	}
	sky: fx.Expr = f32(1)
	if effects.occlusion {
		bins := fx.data_array("occlusion_bins", MAX_BINS)
		sky = fx.capsule_occlusion(hit.pos, hit.normal, occluders_list(), 0, occluder_count(), bins)
	}
	return fx.add(scattered, fx.mul(W1, sky))
}

// What reaches each point of the room from the first four lights past all occluders, one
// light per channel, drawn into the half-resolution buffer layer the room look reads
// (premultiplied blending writes the values as they are). A pixel tests only the occluders
// whose shadow can reach it (update_shadow_bins).
shadow_buffer_look :: proc() -> ^fx.Node {
	hit := room_hit(camera_ray())
	pos := fx.add(hit.pos, fx.mul(hit.normal, 0.002))
	bins := fx.data_array("shadow_bins", MAX_BINS)
	return fx.capsule_shadows(pos, lights_list(), occluders_list(), 0, occluder_count(), LIGHT_SIZE, bins)
}

// ---------------------------------------------------------------------------------------
// Objects: every object of a drawing bucket in one instanced draw, one quad each. A record
// (OBJECT_RECORD values): its quad on screen | center (xyz) and bounding radius | rows of the
// rotation from room to object space, their w the solid's kind, the pattern and the mask of
// lights in reach | the solid's size | color A (rgb) and pattern scale | color B (rgb) and
// seed | specular, shininess. The solid is sphere traced in its own space (fx.march_solid);
// each object is shaded by its NEIGHBORS nearest occluders, listed per record in the
// `neighbors` data array. With `mirror` it draws the object as the floor reflects it, for the
// reflection's layer (the view of the mirrored camera, see `reflected`).

Pattern :: enum {
	Marble,
	Checker,
	Bands,
	Rust, // patches of rust on steel (col_a), the props'
	Plain, // col_a only
}

object_look :: proc(effects: Effects, mirror := false) -> ^fx.Node {
	records := fx.instances("objects", OBJECT_RECORD, MAX_OBJECTS)
	ray := camera_ray()
	pix := camera_pixel()
	c := fx.instance4(records, 4)
	r0, r1, r2 := fx.instance4(records, 8), fx.instance4(records, 12), fx.instance4(records, 16)
	size := fx.instance4(records, 20)
	color_a, color_b := fx.instance4(records, 24), fx.instance4(records, 28)
	mat := fx.instance4(records, 32)
	kind := component(r0, "w")

	// The ray in the object's space (r0..r2 rows of the rotation; their w is data)
	to_object :: proc(r0, r1, r2: ^fx.Node, v: fx.Expr) -> ^fx.Node {
		return fx.rgba(fx.dot(xyz(r0), v), fx.dot(xyz(r1), v), fx.dot(xyz(r2), v), 0)
	}
	from_center := fx.sub(ray.origin, xyz(c))
	local_origin := to_object(r0, r1, r2, from_center)
	local_dir := to_object(r0, r1, r2, ray.dir)
	// The bound grown by two pixels at its distance, for the anti-aliased outline
	bound := fx.add(component(c, "w"), fx.mul(fx.mul(fx.length(from_center), pix), 2))
	march := fx.march_solid(kind, local_origin, local_dir, size, bound, pix, MARCH_STEPS)
	t := component(march, "x")

	local := fx.add(local_origin, fx.mul(local_dir, t))
	n := fx.solid_normal(kind, local, size)
	normal := fx.sum(fx.mul(xyz(r0), component(n, "x")), fx.mul(xyz(r1), component(n, "y")), fx.mul(xyz(r2), component(n, "z")))
	pos := fx.add(ray.origin, fx.mul(ray.dir, t))
	// Nothing below the floor (a prop sunk into it: the floor covers that part)
	coverage := fx.mul(component(march, "y"), fx.smoothstep(fx.neg(fx.mul(t, pix)), fx.mul(t, pix), component(pos, "y")))

	// Patterns in the object's space, scaled to its size, each worked out only where it is
	// used (the same for a whole object, so whole groups of pixels skip the others)
	q := fx.div(local, component(c, "w"))
	qx, qy, qz := component(q, "x"), component(q, "y"), component(q, "z")
	scale, seed := component(color_a, "w"), component(color_b, "w")
	pattern := component(r1, "w")
	is_checker := fx.mul(fx.step(0.5, pattern), fx.sub(1, fx.step(1.5, pattern)))
	is_bands := fx.mul(fx.step(1.5, pattern), fx.sub(1, fx.step(2.5, pattern)))
	is_rust := fx.mul(fx.step(2.5, pattern), fx.sub(1, fx.step(3.5, pattern)))
	is_marble := fx.sub(1, fx.step(0.5, pattern))
	flow := fx.add(fx.mul(fx.add(fx.swizzle(q, "xy"), fx.mul(fx.swizzle(q, "zz"), [2]f32{0.9, -0.6})), scale), seed)
	marble := fx.smoothstep(-0.6, 0.9, fx.sin(fx.add(fx.mul(qy, fx.mul(scale, 2)), fx.mul(fx.fbm(flow, 4), 7))))
	k := fx.mul(scale, 3.14159)
	checker := fx.smoothstep(-0.08, 0.08, fx.mul(fx.mul(fx.sin(fx.mul(qx, k)), fx.sin(fx.mul(qy, k))), fx.sin(fx.mul(qz, k))))
	wave := fx.add(fx.mul(qy, fx.mul(scale, 4)), fx.mul(fx.sin(fx.add(fx.mul(qx, 3), seed)), 1.2))
	bands := fx.smoothstep(-0.15, 0.15, fx.sin(wave))
	// Rust: patches (scale per meter is RUST_SCALE on every prop) with grain at their edges
	smear := fx.add(fx.mul(fx.add(fx.swizzle(q, "xz"), fx.mul(fx.swizzle(q, "yy"), [2]f32{0.7, -0.4})), scale), seed)
	grain := fx.sub(fx.fbm(fx.mul(smear, 5.3), 2), 0.5)
	rust := fx.saturate(fx.add(fx.smoothstep(0.4, 0.62, fx.fbm(smear, 4)), fx.mul(grain, 0.6)))
	mix_t := fx.sum(
		fx.gate(is_marble, marble),
		fx.gate(is_checker, fx.mul(checker, is_checker)),
		fx.gate(is_bands, fx.mul(bands, is_bands)),
		fx.gate(is_rust, fx.mul(rust, is_rust)),
	)

	surface := Surface {
		pos       = pos,
		normal    = normal,
		view      = fx.neg(ray.dir),
		albedo    = fx.mix(xyz(color_a), xyz(color_b), mix_t),
		specular  = component(mat, "x"),
		shininess = component(mat, "y"),
	}
	neighbors := fx.data_array("neighbors", MAX_OBJECTS * NEIGHBORS * fx.CAPSULE3_STRIDE)
	first := fx.mul(fx.instance_index(), NEIGHBORS)
	shadow: fx.Expr = [4]f32{1, 1, 1, 1}
	if effects.shadows {
		shadow = fx.capsule_shadows(pos, lights_list(), neighbors, first, NEIGHBORS, LIGHT_SIZE)
	}
	occlusion: ^fx.Node
	if effects.occlusion {
		occlusion = fx.mul(fx.capsule_occlusion(pos, normal, neighbors, first, NEIGHBORS), floor_contact(pos, normal))
	}
	light := shade(surface, shadow, component(r2, "w"), occlusion)
	light = fx.add(light, fx.mul(surface.albedo, component(mat, "z"))) // its own glow
	// All of it only where the object covers the pixel
	if mirror {
		if effects.haze {
			light = fx.mul(light, haze_through(t)) // the air's own light is the room's
		}
		return reflected(fx.gate(coverage, light), coverage, ray)
	}
	if effects.haze {
		light = with_haze(light, ray, t)
	}
	return finish(fx.gate(coverage, with_water(light, ray, t)), coverage)
}

// ---------------------------------------------------------------------------------------
// The logo: letters made of capsules (tubes with round ends) of radius LOGO_TUBE, so every
// edge and corner is round and a ray finds them in closed form. Joined end to end with the
// same radius, capsules make one smooth tube. Params: ca<k>/cb<k> = the ends of capsule k
// (w 0); `neighbors` = the NEIGHBORS nearest objects' occluding capsules.

// Where a ray (unit dir) comes closest to the segment a-b: how far along the ray (0 if the
// closest point is behind its origin) and how far apart they are there
segment_approach :: proc(origin, dir, a, b: ^fx.Node) -> (t, gap: ^fx.Node) {
	ba := fx.sub(b, a)
	oa := fx.sub(origin, a)
	baba := fx.dot(ba, ba)
	bard := fx.dot(ba, dir)
	rdoa := fx.dot(dir, oa)
	s := fx.saturate(fx.div(fx.sub(fx.dot(ba, oa), fx.mul(bard, rdoa)), fx.max(fx.sub(baba, fx.mul(bard, bard)), 1e-6)))
	t = fx.max(fx.sub(fx.mul(bard, s), rdoa), 0)
	gap = fx.length(fx.sub(fx.add(oa, fx.mul(dir, t)), fx.mul(ba, s)))
	return
}

// Where a ray enters the capsule a-b of radius r (iquilezles.org/articles/intersectors): the
// infinite cylinder around the segment, and if it lands beyond either end, that end's
// sphere. hit is 1 if it does at all.
capsule_hit :: proc(ray: Ray, a, b: ^fx.Node, r: fx.Expr) -> (t, hit: ^fx.Node) {
	ba := fx.sub(b, a)
	oa := fx.sub(ray.origin, a)
	baba := fx.dot(ba, ba)
	bard := fx.dot(ba, ray.dir)
	baoa := fx.dot(ba, oa)
	qa := fx.max(fx.sub(baba, fx.mul(bard, bard)), 1e-6)
	qb := fx.sub(fx.mul(baba, fx.dot(ray.dir, oa)), fx.mul(baoa, bard))
	qc := fx.sub(fx.mul(baba, fx.sub(fx.dot(oa, oa), fx.mul(r, r))), fx.mul(baoa, baoa))
	h := fx.sub(fx.mul(qb, qb), fx.mul(qa, qc))
	body_t := fx.div(fx.sub(fx.neg(qb), fx.sqrt(h)), qa)
	along := fx.add(baoa, fx.mul(body_t, bard))
	on_body := fx.mul(fx.step(0, along), fx.step(along, baba))
	end := fx.sub(ray.origin, fx.mix(b, a, fx.step(along, 0)))
	eb := fx.dot(ray.dir, end)
	he := fx.sub(fx.mul(eb, eb), fx.sub(fx.dot(end, end), fx.mul(r, r)))
	t = fx.mix(fx.sub(fx.neg(eb), fx.sqrt(he)), body_t, on_body)
	hit = fx.mul(fx.step(0, h), fx.max(on_body, fx.step(0, he)))
	return
}

// What a shiny surface sees of the room along dir, softened into a gradient: the floor's
// tones below, the walls around (brightest at the horizon), the ceiling above, under an
// even ENV_LIGHT. Exact faces with hard edges between them would break up into blotches
// on crinkled foil; the lights themselves show as specular highlights.
room_env :: proc(dir: ^fx.Node) -> ^fx.Node {
	up := component(dir, "y")
	floor := fx.mix(linear(FLOOR_TILE_A), linear(FLOOR_TILE_B), 0.5)
	env := fx.mix(floor, linear(WALL), fx.smoothstep(-0.45, 0.05, up))
	env = fx.mix(env, linear(CEILING), fx.smoothstep(0.2, 0.8, up))
	horizon := fx.exp(fx.neg(fx.mul(fx.mul(up, up), 40)))
	return fx.mul(env, fx.mul(fx.add(1, fx.mul(horizon, 0.5)), ENV_LIGHT))
}

// A letter as a balloon of silver foil. The ray takes the nearest of the letter's capsules;
// where it enters none (edge pixels), the one it passes closest to, shaded at that closest
// point, coverage from the closest pass. The capsules' shading is smoothed across the
// joints of a line: at each end the surface is shaded as if the tube ran along the average
// direction of the two capsules meeting there (blended along the capsule), so a curve made
// of straight pieces shades as a curve. The free ends of a line keep their round caps. The
// foil mirrors the room (room_env), has small crinkles and a seam round its edge, where its
// front and back sheets meet (across `facing`). Params: ca<k>/cb<k> = the ends of capsule
// k (w 0), facing, pivot (the letter's middle, for the crinkles), `neighbors` = the
// NEIGHBORS nearest objects' occluding capsules. Its cables are cables_look's.
logo_look :: proc(capsules: []Capsule, effects: Effects, mirror := false) -> ^fx.Node {
	ray := camera_ray()
	pos, smooth, shade_t, coverage := letter_hit(capsules, ray)
	// Crinkles: a few crossed, wavering ripples in the letter's own frame
	q := fx.sub(pos, fx.param("pivot", [4]f32{0, 0, 0, 0}))
	ripple :: proc(q: ^fx.Node, k, warp: [4]f32, amount: f32) -> ^fx.Node {
		return fx.sin(fx.add(fx.dot(q, k), fx.mul(fx.sin(fx.dot(q, warp)), amount)))
	}
	coarse := fx.rgba(
		ripple(q, {31, 17, 23, 0}, {11, -19, 7, 0}, 1.7),
		ripple(q, {-13, 29, 19, 0}, {17, 5, -23, 0}, 1.3),
		ripple(q, {19, -23, 31, 0}, {-7, 13, 11, 0}, 1.9),
		0,
	)
	fine := fx.rgba(
		ripple(q, {-67, 53, 41, 0}, {29, 37, -17, 0}, 2.1),
		ripple(q, {47, 61, -59, 0}, {-31, 23, 19, 0}, 1.6),
		ripple(q, {71, -43, 37, 0}, {13, -41, 27, 0}, 2.4),
		0,
	)
	// The seam: where the surface turns side-on to the letter's facing, the front and back
	// sheets welded together, a dark groove with a bright ridge along it; the foil bunches up
	// in crinkles towards it
	facing := fx.param("facing", [4]f32{0, 0, -1, 0})
	side := fx.abs(fx.dot(smooth, facing))
	seam := fx.sub(1, fx.smoothstep(0, 0.07, side))
	ridge := fx.mul(fx.smoothstep(0.05, 0.1, side), fx.sub(1, fx.smoothstep(0.1, 0.17, side)))
	bunch := fx.add(0.3, fx.mul(fx.sub(1, fx.smoothstep(0, 0.4, side)), 1.9))
	crinkle := fx.mul(fx.add(coarse, fx.mul(fine, 0.5)), fx.mul(bunch, FOIL_CRINKLE))
	normal := normalize3(fx.add(smooth, crinkle))
	silver := linear(FOIL)
	surface := Surface {
		pos       = pos,
		normal    = normal,
		view      = fx.neg(ray.dir),
		albedo    = fx.to_node(silver * FOIL_DIFFUSE),
		specular  = FOIL_SPECULAR,
		shininess = FOIL_SHININESS,
	}
	neighbors := fx.param_array("neighbors", NEIGHBORS * fx.CAPSULE3_STRIDE)
	shadow: fx.Expr = [4]f32{1, 1, 1, 1}
	if effects.shadows {
		shadow = fx.capsule_shadows(pos, lights_list(), neighbors, 0, NEIGHBORS, LIGHT_SIZE)
	}
	occlusion: ^fx.Node
	if effects.occlusion {
		occlusion = fx.mul(fx.capsule_occlusion(pos, normal, neighbors, 0, NEIGHBORS), floor_contact(pos, normal))
	}
	light := shade(surface, shadow, f32(-1), occlusion)
	// The foil mirrors the room
	d := ray.dir
	bounce := fx.sub(d, fx.mul(normal, fx.mul(fx.dot(d, normal), 2)))
	light = fx.add(light, fx.mul(room_env(bounce), silver * FOIL_MIRROR))
	light = fx.mul(light, fx.add(fx.sub(1, fx.mul(seam, 0.6)), fx.mul(ridge, 0.35)))
	return finish_object(light, coverage, ray, shade_t, effects, mirror)
}

// Where the ray meets a letter (its capsules: params ca<k>/cb<k>): the point to shade (the
// nearest tube's hit, or on a miss its closest pass), the tube's smooth normal there (taken
// across the direction blended between its joints, so that a curve of straight pieces
// shades smoothly), how far along the ray, and the pixel's coverage
letter_hit :: proc(capsules: []Capsule, ray: Ray) -> (pos, smooth, shade_t, coverage: ^fx.Node) {
	ends := make([][2]^fx.Node, len(capsules), context.temp_allocator)
	for k in 0 ..< len(capsules) {
		ends[k] = {fx.param(logo_a_names[k], [4]f32{0, 0, 0, 0}), fx.param(logo_b_names[k], [4]f32{0, 1, 0, 0})}
	}
	// Besides its ends, the chosen one brings the far ends of its neighbors on the line (its
	// own where it has none), for the directions across its joints
	key: ^fx.Node
	seg_a, seg_b, before, after, free: ^fx.Node
	for c, k in capsules {
		a, b := ends[k][0], ends[k][1]
		k_before := ends[c.prev][0] if c.prev >= 0 else a
		k_after := ends[c.next][1] if c.next >= 0 else b
		k_free := fx.to_node([2]f32{1 if c.prev < 0 else 0, 1 if c.next < 0 else 0})
		k_key, k_t, cover := tube_approach(ray, a, b, LOGO_TUBE)
		if key == nil {
			key, shade_t, coverage = k_key, k_t, cover
			seg_a, seg_b, before, after, free = a, b, k_before, k_after, k_free
			continue
		}
		closer := fx.step(k_key, key)
		key = fx.min(key, k_key)
		shade_t = fx.mix(shade_t, k_t, closer)
		seg_a = fx.mix(seg_a, a, closer)
		seg_b = fx.mix(seg_b, b, closer)
		before = fx.mix(before, k_before, closer)
		after = fx.mix(after, k_after, closer)
		free = fx.mix(free, k_free, closer)
		coverage = fx.max(coverage, cover)
	}
	pos = fx.add(ray.origin, fx.mul(ray.dir, shade_t))
	ba := fx.sub(seg_b, seg_a)
	along := fx.div(fx.dot(fx.sub(pos, seg_a), ba), fx.dot(ba, ba))
	clamped := fx.saturate(along)
	out := fx.sub(pos, fx.add(seg_a, fx.mul(ba, clamped))) // from the center line
	// Taken across the direction blended between the joints' (each across its two
	// capsules), except on a free end's cap
	tangent := normalize3(fx.mix(normalize3(fx.sub(seg_b, before)), normalize3(fx.sub(after, seg_a)), clamped))
	on_cap := fx.add(fx.mul(fx.step(along, 0), component(free, "x")), fx.mul(fx.step(1, along), component(free, "y")))
	smooth = normalize3(fx.sub(out, fx.mul(tangent, fx.mul(fx.dot(out, tangent), fx.sub(1, on_cap)))))
	return
}

// Thin cables (CABLE_RADIUS) holding the letters down, `count` of them in one entity (the
// letters' front cables, drawn after the letters, or their back cables, drawn before), so
// that a letter's quad needn't reach down to the floor. Shaded plainly, without shadows or
// occlusion: too thin to show them. Params: wa<k>/wb<k> = the ends of cable k.
cables_look :: proc(count: int, effects: Effects, mirror := false) -> ^fx.Node {
	ray := camera_ray()
	key, shade_t, coverage, seg_a, seg_b: ^fx.Node
	for k in 0 ..< count {
		a, b := fx.param(cable_a_names[k], [4]f32{0, 1, 0, 0}), fx.param(cable_b_names[k], [4]f32{0, 0, 0, 0})
		k_key, k_t, cover := tube_approach(ray, a, b, CABLE_RADIUS)
		if key == nil {
			key, shade_t, coverage, seg_a, seg_b = k_key, k_t, cover, a, b
			continue
		}
		closer := fx.step(k_key, key)
		key = fx.min(key, k_key)
		shade_t = fx.mix(shade_t, k_t, closer)
		seg_a = fx.mix(seg_a, a, closer)
		seg_b = fx.mix(seg_b, b, closer)
		coverage = fx.max(coverage, cover)
	}
	pos := fx.add(ray.origin, fx.mul(ray.dir, shade_t))
	ba := fx.sub(seg_b, seg_a)
	out := fx.sub(pos, fx.add(seg_a, fx.mul(ba, fx.saturate(fx.div(fx.dot(fx.sub(pos, seg_a), ba), fx.dot(ba, ba))))))
	surface := Surface {
		pos       = pos,
		normal    = normalize3(out),
		view      = fx.neg(ray.dir),
		albedo    = fx.to_node(linear(CABLE)),
		specular  = 0.15,
		shininess = 12,
	}
	light := shade(surface, [4]f32{1, 1, 1, 1}, f32(-1), nil)
	return finish_object(light, coverage, ray, shade_t, effects, mirror)
}

// Of a tube a-b of radius r: the key that orders the tubes of a look (the distance to the
// ray's hit, or past 100 by how far it misses: hits come first), where to shade it (the
// hit, or on a miss the closest pass) and the pixel's coverage (from the closest pass)
tube_approach :: proc(ray: Ray, a, b: ^fx.Node, r: fx.Expr) -> (key, t, coverage: ^fx.Node) {
	hit_t, hit := capsule_hit(ray, a, b, r)
	near_t, gap := segment_approach(ray.origin, ray.dir, a, b)
	miss := fx.sub(gap, r)
	coverage = fx.saturate(fx.sub(0.5, fx.div(miss, fx.mul(fx.max(near_t, 0.1), camera_pixel()))))
	return fx.mix(fx.add(miss, 100), hit_t, hit), fx.mix(near_t, hit_t, hit), coverage
}

// The end of a letter's or cable's look: through the air, on the screen or in the
// reflection, only where it covers the pixel
finish_object :: proc(light: ^fx.Node, coverage: ^fx.Node, ray: Ray, t: ^fx.Node, effects: Effects, mirror: bool, loc := #caller_location) -> ^fx.Node {
	light := light
	if mirror {
		if effects.haze {
			light = fx.mul(light, haze_through(t)) // the air's own light is the room's
		}
		return reflected(fx.gate(coverage, light), coverage, ray, loc)
	}
	if effects.haze {
		light = with_haze(light, ray, t)
	}
	return finish(fx.gate(coverage, with_water(light, ray, t)), coverage, loc)
}

// ---------------------------------------------------------------------------------------
// A light's glowing core, drawn additively over everything; vis fades it where something
// stands between it and the camera. Params: glow = sRGB color, vis. With haze the air
// makes the halo, so the drawn one is fainter. In the reflection (mirror) it is light added
// to the layer's premultiplied image, covering nothing, as strong as the floor reflects
// where it shows (param reflect).

light_glow_look :: proc(effects: Effects, mirror := false) -> ^fx.Node {
	r := fx.div(fx.length(fx.coord()), fx.mul(component(fx.size(), "x"), 0.5))
	halo := fx.falloff(r, .Soft)
	core := fx.sub(1, fx.smoothstep(0.08, 0.16, r))
	color := fx.mix(fx.param("glow", [4]f32{1, 1, 1, 1}), [4]f32{1, 1, 1, 1}, core)
	halo_strength: f32 = 0.25 if effects.haze && !mirror else 0.55 // the reflection has no haze around the light
	strength := fx.mul(fx.add(fx.mul(halo, halo_strength), core), fx.param("vis", f32(1)))
	if mirror {
		return fx.mul(color, fx.mul(fx.mul(strength, fx.param("reflect", f32(0.2))), XYZ))
	}
	return fx.mask(color, strength)
}

// Black over the whole screen, as opaque as the param fade (0..1)
fade_look :: proc() -> ^fx.Node {
	return fx.rgba(0, 0, 0, fx.param("fade", f32(1)))
}
