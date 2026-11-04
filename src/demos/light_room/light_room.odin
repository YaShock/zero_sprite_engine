package main

// Light Room: algorithmic 3D on the 2D engine. A room seen from inside by a drifting camera,
// randomly placed solids (spheres, rounded boxes and cylinders, ellipsoids, tori, capsules,
// and ray-marched blobs, twisted and carved boxes) with procedural patterns, a "ZSE" logo
// standing on the floor, colored point lights flying among them, all of it reflected in the
// polished floor.
// Every surface is found per pixel by casting the camera ray (looks.odin): the room and the
// logo in closed form, the solids by sphere tracing. The lights and the occluders are lists
// the looks loop over (fx.point_lights, fx.capsule_shadows, fx.capsule_occlusion,
// fx.haze_lights), so their numbers are params, not shader structure. The CPU does the
// camera, each object's quad, the light paths, which lights reach which object, the
// neighbors that shade each object and the drawing order.
//
// Effects: soft shadows from the first four lights (on the room at half resolution into a
// buffer layer, binned on screen by where each occluder's shadow can fall; on each object
// and letter from its NEIGHBORS nearest occluders), ambient occlusion and haze (the room's
// at a quarter of the resolution into a second buffer layer, the occlusion binned on screen).
// Reflections: the objects, letters and glows drawn again from the camera mirrored below
// the floor (a second View) into an out-of-focus layer between the room and the objects,
// each pixel weighted by how much the floor reflects there. Bloom: eng.set_layer_bloom.
//
// Objects are drawn instanced, one draw per bucket: the objects between two letters of the
// logo in depth share a bucket, and the layer is sorted by distance (eng.set_layer_sorted),
// so nearer things cover farther ones without a depth buffer.
//
//   odin run src/demos/light_room                        random room
//   ROOM_SEED=123 ...                                     a given room
//   ROOM_OBJECTS=40 ROOM_LIGHTS=8 ...                     how many objects (1..256) and lights (1..24)
//   ROOM_SHADOWS=off ROOM_AO=off ...                      without some of the effects
//   ROOM_HAZE=on ...                                      with haze in the air (off by default)
//   ROOM_REFLECTIONS=off ROOM_BLOOM=off ...               without reflections in the floor, bloom
//   ROOM_CAMERA=still ...                                 the camera stays put
//   ROOM_FULLSCREEN=off ROOM_SIZE=1600x900 ...            in a window (default 1280x720) instead of
//                                                         a borderless one over the whole screen
//   ROOM_MONITOR=1 or ROOM_MONITOR=HDMI-A-1 ...           the screen to fill, by number or name
//                                                         (on Wayland the first one otherwise)
//   ROOM_VSYNC=off ...                                    frames as fast as possible
//   ROOM_SHOT=4 ZSE_FIXED_DT=0.016667 ...                 save light_room.png at time 4 s and quit
//   ZSE_PROFILE_SECONDS=20 ...                            benchmark (seed 12345), then a report
//   ROOM_PART=flood ...                                   straight into the flood (looping with the two above)
//   ROOM_PART=deep ...                                    straight to the bubble screen, then scene 2 (deep.odin)
//
// Keys: Space starts the sequence, goes on from scene 1 to the flood (flood.odin), once the
// room is under water on to scene 2 (deep.odin), and at its end closes the demo. Up / Down
// lights ±1, Right / Left objects ±8, R new room, 1 - 5 shadows / occlusion / haze /
// reflections / bloom on and off, C stops or restarts the scene's clock, F3 profiler, Escape quits.

import eng "../../engine"
import fx "../../engine/vfx"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

Vec3 :: [3]f32

// The room, in meters: x in ±ROOM_HALF_WIDTH, y from the floor (0) up, z from the open
// front (0) to the back wall.
ROOM_HALF_WIDTH :: 5
ROOM_HEIGHT :: 4
ROOM_DEPTH :: 10
TILE_SIZE :: 0.8
GROUT_WIDTH :: 0.012
TRIM_HEIGHT :: 0.14

CAMERA_FOV :: 52 // vertical, degrees

// Scene 1 (SCENE1_LEG · 2 seconds, then again): the camera flies round the room's center
// (the hatch) at ORBIT_RADIUS, ORBIT_SWEEP degrees to the left in SCENE1_LEG seconds,
// easing in and out and rising by CAMERA_RISE on the way, then back the same way; it looks
// at CAMERA_LOOK_AT all along. ROOM_CAMERA=still or key C stops the scene's clock.
SCENE1_LEG :: 15
ROOM_CENTER :: Vec3{0, 0, 5}
ORBIT_RADIUS :: 4
ORBIT_SWEEP :: 100
CAMERA_HEIGHT :: 1.9
CAMERA_RISE :: 0.7
CAMERA_LOOK_AT :: Vec3{0, 1.1, 5.6}
CAMERA_CLEARANCE :: 1.5 // objects keep this far from the camera's path, lights from the camera

// The sequence (Stage): black until Space, then fading in over FADE_SECONDS as scene 1 plays
// once (SCENE1_LENGTH), then holding its last frame until Space starts the transition (the
// flood, flood.odin), which ends under water until Space fades it out and closes the demo.
// Benchmarks and screenshots start at once and loop scene 1, or the flood (autoplay).
SCENE1_LENGTH :: 2 * SCENE1_LEG
FADE_SECONDS :: 1

// Reflections in the floor: what the mirrored camera sees, drawn at half resolution and
// blurred (soften sigma in its pixels). The floor reflects REFLECT_FACING of the light
// straight on, up to REFLECT_GRAZING at grazing angles (Schlick), the grout less.
REFLECTION_DIVISOR :: 2
REFLECTION_BLUR :: 1.2
REFLECT_FACING :: 0.1
REFLECT_GRAZING :: 0.65

// Bloom: what is brighter on screen than BLOOM_THRESHOLD bleeds a glow
BLOOM_THRESHOLD :: 0.75
BLOOM_STRENGTH :: 0.6

DEFAULT_OBJECTS :: 16
DEFAULT_LIGHTS :: 4
MAX_OBJECTS :: 256
MAX_LIGHTS :: 24 // an object's light mask is a float: 24 bits
OBJECT_GAP :: 0.15 // empty space kept between two objects' bounding spheres
HATCH_CLEARANCE :: 1.5 // objects keep this far (sideways) from the hatch's middle
FLOATING_SHARE :: 0.3 // of the objects, the share that floats, tumbles and bobs
BOB_AMPLITUDE :: 0.12
LIGHT_CLEARANCE :: 0.3 // lights keep this far from objects
LIGHT_PACE :: 0.5 // the lights fly this much slower than their paths' frequencies (make_lights) say
GLOW_RADIUS :: 0.35 // of a light's drawn halo, meters
BENCH_SEED :: 12345
MARCH_STEPS :: 40 // sphere tracing steps per object pixel at most
OBJECT_RECORD :: 36 // values per instance record (object_look)
MAX_BUCKETS :: 12 // instanced object draws per view (update_buckets)

// Shadows: lights 0..3 cast them (one per channel of the shadow buffer), as discs
// LIGHT_SIZE across; each object is shaded by its NEIGHBORS nearest occluders.
LIGHT_SIZE :: 0.3
NEIGHBORS :: 6
SHADOW_BUFFER_DIVISOR :: 2
AIR_BUFFER_DIVISOR :: 4 // the room's occlusion and haze (air_buffer_look)
SHADOW_FAN :: 8 // sides of the pyramid standing in for a shadow cone when binning shadows
far_away := [fx.CAPSULE3_STRIDE]f32{0, -1000, 0, 0, 0, -1000, 0, 0} // an empty occluder slot: far below the floor

// Ambient occlusion
OCCLUSION_DIRECT :: 0.5 // how much of it also darkens the lights' direct light
OCCLUSION_REACH :: 6 // radii beyond which an occluder darkens nothing (as fx.capsule_occlusion)
CORNER_REACH :: 0.35 // meters over which a corner darkens
CORNER_STRENGTH :: 0.35
FLOOR_CONTACT :: 0.3 // height over which an underside darkens towards the floor
MAX_BINS :: 32768 // the room's occlusion lookup grid (see eng.bin_shapes)
BIN_CELL :: 64 // pixels

// Haze: how much light the air scatters per meter, how much it dims what lies behind it,
// and the closest a light's glow is worked out (its core, in meters)
HAZE_DENSITY :: 0.004
HAZE_EXTINCTION :: 0.025
HAZE_CORE :: 0.06

// The logo: "ZSE" in tube letters facing the camera's starting point.
// Every stroke is a capsule of radius LOGO_TUBE, so no edge or corner is sharp.
LOGO_HEIGHT :: 1.5
LOGO_TUBE :: 0.17
LOGO_LETTER_WIDTH :: 1.05
LOGO_GAP :: 0.28 // between letters
LOGO_BEND :: 0.22 // radius of the bends at the letters' corners (wider than the tube: no crease inside)
LOGO_ARC_DEGREES :: 20 // curves are capsules this many degrees of arc long
LOGO_PROXY_ARC_DEGREES :: 90 // the same for the coarser copy that occludes
LOGO_LETTERS :: 3
MAX_LOGO_CAPSULES :: 32 // per letter: up to 24 at 20°, two uniform vec4s each
MAX_LOGO_PROXIES :: 24 // in all: 21 at 90°
MAX_OCCLUDERS :: MAX_OBJECTS + MAX_LOGO_PROXIES

// The logo floats: its letters are balloons LOGO_LIFT above the floor, each bobbing by up to
// LETTER_BOB, leaning by LETTER_LEAN and turning by up to LETTER_SWAY degrees on its CABLES
// cables, which run from its top to weights on the floor CABLE_SPREAD in front of and
// behind it
LOGO_CENTER :: Vec3{0, 0, 7.9} // the floor below its middle
LOGO_LIFT :: 0.45
LETTER_BOB :: 0.1
LETTER_SWAY :: 8
LETTER_LEAN :: 3 // degrees each way, leaning sideways
LETTER_PACE :: 0.45 // radians per second of its bobbing
LETTER_ROOM :: 0.25 // objects keep this much farther from the letters, which move
CABLES :: 3 // per letter: the first FRONT_CABLES in front of it, the rest behind
FRONT_CABLES :: 2
MAX_CABLES :: FRONT_CABLES * LOGO_LETTERS // in one cables_look
CABLE_RADIUS :: 0.006
CABLE_SPREAD :: 0.8

// The rusty hatch in the middle of the floor (ROOM_CENTER), and the lamp hanging from the
// ceiling near the far right corner, on a cord low enough to be seen: a warm fill light
// (light number light_count, after the flying ones, casting no shadow) at its bulb
HATCH_LID :: 0.62 // radius
LAMP_POS :: Vec3{3.6, ROOM_HEIGHT - 0.75, 8.6} // its shade's middle, hanging on a cord
LAMP_COLOR :: Vec3{1, 0.82, 0.62}
LAMP_INTENSITY :: 5
LAMP_RANGE :: 12
BULB_GLOW :: 6 // the bulb's own light (emission)
RUST_SCALE :: 10 // rust patches across a meter, roughly

// The balloons' foil: how much light it scatters (times its color), how much of the room it
// mirrors, how deep its crinkles are; and the even light the mirrored room is seen in
FOIL_DIFFUSE :: 0.06
FOIL_MIRROR :: 1.1
FOIL_CRINKLE :: 0.13
ENV_LIGHT :: 0.4
FOIL_SPECULAR :: 5 // its highlights: strong and sharp
FOIL_SHININESS :: 200

// Drawing layers, back to front
LAYER_SHADOW_BUFFER :: 0 // never shown: read by the room look
LAYER_AIR_BUFFER :: 1 // the same
LAYER_SEA :: 2 // the deep's background (AlgoGame's fog), out of focus
LAYER_JELLY :: 3 // its jellyfish: three out-of-focus layers, far to near
LAYER_SEA_SPORES :: 6 // the spores out in the sea, which the cave's walls hide
LAYER_ROOM :: 7
LAYER_REFLECTION :: 8 // out of focus, sorted: the mirrored view, over the floor
LAYER_OBJECTS :: 9 // objects and letters, sorted by distance
LAYER_GLOWS :: 10
LAYER_BLOOM :: 11 // the screen's bright parts, blurred and added back (eng.set_layer_bloom)
LAYER_LENS :: 12 // the camera's lens going under water (lens_look)
LAYER_FADE :: 13 // black over everything, fading the sequence in and out
LAYER_TEXT :: 14
LAYER_COUNT :: 15

Camera :: struct {
	pos, right, up, fwd: Vec3,
	focal:               f32, // pixels
	center:              [2]f32, // screen
}

Object :: struct {
	kind:         fx.Solid,
	size:         [4]f32, // as fx.march_solid reads it
	bound:        f32, // bounding sphere radius
	rest:         f32, // height of its center when standing on the floor
	pattern:      Pattern,
	scale, seed:  f32,
	col_a, col_b: Vec3, // linear
	specular:     f32,
	shininess:    f32,
	center:       Vec3, // at rest
	floating:     bool, // tumbles around `axis` and bobs; else stands upright, turning around y
	bob_freq:     f32, // radians/s
	bob_phase:    f32,
	axis:         Vec3,
	spin:         f32, // radians/s
	spin_phase:   f32,
	prop:         bool, // a fixed part of the scene (add_prop): it stays as it was placed
	emission:     f32, // light of its own, times its color
	presence:     Presence, // in which scenes it is (shown)
	neighbors:    [NEIGHBORS]int, // occluders (index into Room.occluders) that shade it, -1 for none
	// This frame
	pos:          Vec3,
	rows:         [3]Vec3, // rotation from room to object space
	mask:         u32, // lights in reach
}

// Which scenes an object is in: before the deep (scene 1, the flood), always, only in the deep
Presence :: enum {
	Before,
	Always,
	Deep,
}

Light :: struct {
	color:       [4]f32, // linear rgb, intensity in w
	glow:        rl.Color,
	range:       f32,
	mid, amp:    Vec3, // flight: mid + amp·sin(freq·t + phase) per axis
	freq, phase: Vec3,
	pos:         Vec3, // this frame
	brightness:  f32, // this frame (flickering out in the transition, shimmer)
}

Capsule :: struct {
	a, b:       Vec3, // radius LOGO_TUBE
	prev, next: int, // the capsules before and after it on its line, -1 at the line's ends
}

// A cable holding a letter down: from a point on its top to a weight on the floor
Cable :: struct {
	top, anchor: Vec3, // top as placed (it moves with the letter)
	at:          Vec3, // top this frame
}

// A letter of the logo: drawn by its own entity (per view), so that a pixel tests only its
// capsules and cables
Letter :: struct {
	neighbors: [NEIGHBORS]int, // occluders (objects only) that shade it
	capsules:  [2]int, // first and count in Logo.capsules (their prev / next count from the first)
	proxies:   [2]int, // the same in Logo.proxies
	cables:    [CABLES]Cable,
	pivot:     Vec3, // it turns around the vertical line through this point
	bob_phase: f32,
	center:    Vec3, // of its bounding sphere, this frame
	bound:     f32,
	box:       [8]Vec3, // corners of its bounding box this frame, for its quad
	facing:    Vec3, // the way its front faces, this frame
}

Logo :: struct {
	capsules: [dynamic]Capsule, // drawn, this frame
	proxies:  [dynamic]Capsule, // coarser: occluders, and keeping things clear of it, this frame
	placed:   [2][dynamic]Capsule, // the same as placed (capsules, proxies)
	letters:  [LOGO_LETTERS]Letter,
	center:   Vec3, // of the whole logo
	box:      [8]Vec3, // around the whole logo
}

// Where the sequence is (see SCENE1_LENGTH)
Stage :: enum {
	Waiting, // black, until Space
	Playing,
	Ended, // the last frame held, until Space
	Flooding, // the transition (flood.odin)
	Flooded, // under water, until Space
	Deep, // scene 2 (deep.odin), looping until Space (after its first circle)
	Closing, // fading out, then the demo closes
}

// A way of seeing the objects, the logo and the lights: through the camera, or through its
// mirror image below the floor (the reflection, drawn into LAYER_REFLECTION). Each has its
// own entities. `on` is false for a reflection that is switched off.
View :: struct {
	on:      bool,
	mirror:  bool,
	camera:  Camera, // this frame
	buckets: [MAX_BUCKETS]int, // instanced object draws, between the letters (the jet, the plants) in depth
	letters: [LOGO_LETTERS]int,
	glows:   [MAX_LIGHTS]int,
	cables:  [2]int, // the letters' cables in front of them, behind them
}

Room :: struct {
	seed:          u64,
	object_count:  int,
	light_count:   int,
	effects:       Effects,
	camera:        Camera,
	room:          int,
	shadow_buffer: int, // -1 without shadows
	air_buffer:    int, // -1 without occlusion and haze
	views:         [2]View, // the camera's, its mirror image's (the reflection)
	scene_time:    f32, // seconds into scene 1 (camera_at)
	clock_running: bool, // the scene's clock (key C)
	stage:         Stage,
	stage_time:    f32, // seconds in this stage
	autoplay:      bool, // no waiting for Space, scene 1 looping (benchmarks, screenshots)
	fade:          int, // the black over everything
	hint:          int, // "Press Space to ..."
	objects:       [dynamic]Object,
	lights:        [MAX_LIGHTS]Light, // flying: light_count of them in use
	lit:           int, // of them, how many are on (none once they have gone out in the transition)
	lamp:          Light, // the ceiling lamp's, after the lit ones in the light list
	lamp_first:    int, // the lamp's props in objects (cord, shade, bulb)
	lid_first:     int, // the hatch lid's props in objects (LID_PARTS of them)
	flood_time:    f32, // seconds into the transition (flood.odin)
	water:         [4]f32, // the param every lit look reads (water_looks.odin)
	jet:           int,
	jet_key:       f32, // its distance from the camera, between the drawing buckets
	drops:         [2]int, // the spray behind the jet, in front of it
	lens:          int,
	cave:          int, // scene 2's (deep.odin): the room as a cave, the spores in it and out in the sea
	spores:        int,
	sea_spores:    int,
	backdrop:      int, // AlgoGame's background round it
	jellies:       [len(JELLIES)]int,
	pipe_letters:  [LOGO_LETTERS]int, // the letters there, of pipes
	tip_glows:     int, // the corals' tips' glow
	deep_time:     f32, // seconds into scene 2
	deep_lights:   int, // the plants' lights in the light list then
	logo:          Logo,
	text:          int,
	meter:         Meter, // the frame rate and frame time shown in `text`
	shot_at:       f64,
	// Filled every frame: every object's occluding capsule then the logo's proxies
	// (fx.CAPSULE3_STRIDE values each), the lights (fx.LIGHT_STRIDE each), and the room's
	// occlusion bins over each occluder's reach on screen, and the shadow buffer's bins over
	// where each occluder's shadow can fall (a rectangle as a capsule of radius 0)
	occluders:     [MAX_OCCLUDERS * fx.CAPSULE3_STRIDE]f32,
	occluder_n:    int,
	light_values:  [MAX_LIGHTS * fx.LIGHT_STRIDE]f32,
	reach:         [MAX_OCCLUDERS * fx.GLOW_STRIDE]f32,
	bins:          [MAX_BINS]f32,
	shadow_rects:  [MAX_OCCLUDERS * fx.CAPSULE_STRIDE]f32,
	shadow_bins:   [MAX_BINS]f32,
}

room: Room

// ---------------------------------------------------------------------------------------
// Camera and projection

// How far round its sweep the scene 1 camera is `seconds` in: 0 at the start, 1 at the far
// end, eased at both ends, out and back every 2 · SCENE1_LEG seconds
orbit_at :: proc(seconds: f32) -> f32 {
	s := math.mod(seconds, 2 * SCENE1_LEG) / SCENE1_LEG
	if s > 1 {
		s = 2 - s
	}
	return s * s * (3 - 2 * s)
}

// Where the camera is at `sweep` (0..1) round the room's center
orbit_position :: proc(sweep: f32) -> Vec3 {
	angle := -f32(ORBIT_SWEEP) * math.RAD_PER_DEG * sweep // to the left
	return ROOM_CENTER + Vec3{ORBIT_RADIUS * math.sin(angle), CAMERA_HEIGHT + CAMERA_RISE * math.sin(math.PI * sweep), -ORBIT_RADIUS * math.cos(angle)}
}

// The camera `seconds` into scene 1
camera_at :: proc(seconds: f32) -> Camera {
	return camera_from(orbit_position(orbit_at(seconds)))
}

// A camera at `pos` looking at CAMERA_LOOK_AT
camera_from :: proc(pos: Vec3) -> Camera {return camera_looking(pos, CAMERA_LOOK_AT, CAMERA_FOV)}

// A camera at `pos` looking at `aim`, `fov` degrees high
camera_looking :: proc(pos, aim: Vec3, fov: f32) -> (c: Camera) {
	screen := eng.screen_size()
	c.pos = pos
	c.fwd = linalg.normalize(aim - c.pos)
	c.right = linalg.normalize(linalg.cross(Vec3{0, 1, 0}, c.fwd))
	c.up = linalg.cross(c.fwd, c.right)
	c.focal = screen.y / 2 / math.tan(fov * math.RAD_PER_DEG / 2)
	c.center = {screen.x / 2, screen.y / 2}
	return
}

// The camera's mirror image below the floor: what it sees above the floor is what the
// camera sees reflected in it, at the same place on screen
mirrored :: proc(c: Camera) -> Camera {
	m := c
	m.pos.y, m.right.y, m.up.y, m.fwd.y = -c.pos.y, -c.right.y, -c.up.y, -c.fwd.y
	return m
}

// Screen position of a point and its depth along the view direction
project :: proc(c: Camera, p: Vec3) -> (screen: [2]f32, depth: f32) {
	v := p - c.pos
	depth = linalg.dot(v, c.fwd)
	screen = c.center + c.focal / depth * [2]f32{linalg.dot(v, c.right), -linalg.dot(v, c.up)}
	return
}

// Screen rectangle around a set of points, or false if any of them is behind the camera
project_bounds :: proc(c: Camera, points: []Vec3) -> (center, size: [2]f32, ok: bool) {
	lo := [2]f32{math.F32_MAX, math.F32_MAX}
	hi := -lo
	for p in points {
		s, depth := project(c, p)
		if depth < 0.05 {
			return
		}
		lo = linalg.min(lo, s)
		hi = linalg.max(hi, s)
	}
	return (lo + hi) / 2, hi - lo + 4, true // + 2 pixels each side for anti-aliasing
}

// The quad a look drawing what lies within these points needs: their screen rectangle
// clipped to the screen (+ 2 pixels each side for anti-aliasing), the whole screen if some
// of them lie behind the camera (what they bound reaches round it), ok = false if nothing
// of it is in view
screen_quad :: proc(c: Camera, points: []Vec3) -> (center, size: [2]f32, ok: bool) {
	screen := eng.screen_size()
	lo := [2]f32{math.F32_MAX, math.F32_MAX}
	hi := -lo
	behind, ahead := false, false
	for p in points {
		s, depth := project(c, p)
		if depth < 0.05 {
			behind = true
			continue
		}
		ahead = true
		lo = linalg.min(lo, s)
		hi = linalg.max(hi, s)
	}
	if !ahead {
		return
	}
	if behind {
		lo, hi = {0, 0}, screen
	}
	lo, hi = linalg.max(lo - 2, 0), linalg.min(hi + 2, screen)
	if hi.x <= lo.x || hi.y <= lo.y {
		return
	}
	return (lo + hi) / 2, hi - lo, true
}

// The screen rectangle of a sphere: its bounding cube's (sphere_corners)
project_sphere :: proc(c: Camera, center: Vec3, r: f32) -> (at, size: [2]f32, ok: bool) {
	corners := sphere_corners(center, r)
	return project_bounds(c, corners[:])
}

sphere_corners :: proc(center: Vec3, r: f32) -> (corners: [8]Vec3) {
	for i in 0 ..< 8 {
		corners[i] = center + r * Vec3{-1 if i & 1 == 0 else 1, -1 if i & 2 == 0 else 1, -1 if i & 4 == 0 else 1}
	}
	return
}

// The camera as the looks read it (camera_ray in looks.odin); `pix` is the size of the
// look's pixels in screen pixels (2 in a half-resolution layer), 0 for looks without
// anti-aliased edges (the buffers), which have no cam_pix
set_camera :: proc(id: int, c: Camera, pix: f32 = 1) {
	a := c.fwd * c.focal - c.right * c.center.x + c.up * c.center.y
	if eng.has_param(id, "cam_pos") { // a look that only needs the directions (the deep's backdrop) has none
		eng.set_param(id, "cam_pos", [4]f32{c.pos.x, c.pos.y, c.pos.z, 0})
	}
	eng.set_param(id, "cam_a", [4]f32{a.x, a.y, a.z, 0})
	eng.set_param(id, "cam_r", [4]f32{c.right.x, c.right.y, c.right.z, 0})
	eng.set_param(id, "cam_d", [4]f32{-c.up.x, -c.up.y, -c.up.z, 0})
	if pix > 0 && eng.has_param(id, "cam_pix") {
		eng.set_param(id, "cam_pix", pix / c.focal)
	}
}

// The camera, lights and exposure every lit look reads, the flood (water) or the sea it sees
// things through, the ambient light (the shadow buffer: only the camera and the lights)
set_shared :: proc(id: int, c: Camera, lit := true, pix: f32 = 1) {
	set_camera(id, c, pix if lit else 0)
	if eng.has_param(id, "lights") {
		eng.set_param_array(id, "lights", room.light_values[:])
	}
	if !lit {
		return
	}
	deep := in_deep()
	if eng.has_param(id, "light_count") {
		eng.set_param(id, "light_count", f32(lights_in_use()))
	}
	eng.set_param(id, "exposure", exposure())
	if eng.has_param(id, "water") {
		eng.set_param(id, "water", room.water)
	}
	if eng.has_param(id, "sea") {
		eng.set_param(id, "sea", f32(1) if deep else 0)
	}
	if eng.has_param(id, "ambient_sky") {
		eng.set_param(id, "ambient_sky", SEA_AMBIENT_SKY if deep else AMBIENT_SKY)
		eng.set_param(id, "ambient_ground", SEA_AMBIENT_GROUND if deep else AMBIENT_GROUND)
	}
}

// How many lights of the list are in use: the lit flying ones and the lamp, or in the deep
// the plants'
lights_in_use :: proc() -> int {return room.deep_lights if in_deep() else room.lit + 1}

// ---------------------------------------------------------------------------------------
// Making a room

random_unit :: proc() -> Vec3 {
	for {
		v := Vec3{rand.float32_range(-1, 1), rand.float32_range(-1, 1), rand.float32_range(-1, 1)}
		if l := linalg.length(v); l > 0.1 && l <= 1 {
			return v / l
		}
	}
}

// Fully saturated hue (0..1) as linear rgb, with some saturation taken away
hue_color :: proc(hue, saturation: f32) -> Vec3 {
	k := Vec3{0, 2.0 / 3, 1.0 / 3}
	rgb: Vec3
	for i in 0 ..< 3 {
		x := math.abs(math.mod(hue + k[i], 1) * 6 - 3) - 1
		rgb[i] = math.clamp(x, 0, 1)
	}
	return math.lerp(Vec3{1, 1, 1}, rgb, saturation)
}

// The point of segment a-b nearest to p
nearest_on_segment :: proc(p, a, b: Vec3) -> Vec3 {
	ba := b - a
	return a + ba * math.saturate(linalg.dot(p - a, ba) / max(linalg.dot(ba, ba), 1e-12))
}

// How far from p the nearest stroke of the logo (its proxies) passes, and where
nearest_on_logo :: proc(p: Vec3) -> (dist: f32, at: Vec3) {
	dist = math.F32_MAX
	for c in room.logo.proxies {
		q := nearest_on_segment(p, c.a, c.b)
		if d := linalg.distance(p, q); d < dist {
			dist, at = d, q
		}
	}
	return
}

// Where a ray (unit dir) comes closest to the segment a-b, as segment_approach in looks.odin
ray_segment :: proc(origin, dir, a, b: Vec3) -> (t, gap: f32) {
	ba, oa := b - a, origin - a
	baba, bard, rdoa := linalg.dot(ba, ba), linalg.dot(ba, dir), linalg.dot(dir, oa)
	s := math.saturate((linalg.dot(ba, oa) - bard * rdoa) / max(baba - bard * bard, 1e-6))
	t = max(bard * s - rdoa, 0)
	gap = linalg.length(oa + dir * t - ba * s)
	return
}

// Whether two screen rectangles (center, size) overlap
overlaps :: proc(c0, s0, c1, s1: [2]f32) -> bool {
	gap := linalg.abs(c0 - c1) - (s0 + s1) / 2
	return gap.x < 0 && gap.y < 0
}

Polyline :: [dynamic][2]f32

// Points on an ellipse from one angle to another (degrees, either way round), at most
// `step` degrees apart, both ends included
arc :: proc(line: ^Polyline, center, radii: [2]f32, from, to, step: f32) {
	steps := max(int(math.ceil(abs(to - from) / step)), 1)
	for i in 0 ..= steps {
		a := math.lerp(from, to, f32(i) / f32(steps)) * math.RAD_PER_DEG
		append(line, center + radii * [2]f32{math.cos(a), math.sin(a)})
	}
}

// A polyline whose corners are bent round instead: each corner becomes an arc of radius
// `bend` (less where the segments are short), so a tube along it has no crease inside the
// bend as long as the bend is wider than the tube
round_corners :: proc(points: [][2]f32, bend, step: f32) -> Polyline {
	line := make(Polyline, context.temp_allocator)
	append(&line, points[0])
	for i in 1 ..< len(points) - 1 {
		p := points[i]
		u := linalg.normalize(p - points[i - 1])
		v := linalg.normalize(points[i + 1] - p)
		turn := math.acos(math.clamp(linalg.dot(u, v), -1, 1))
		if turn < 1e-3 {
			append(&line, p)
			continue
		}
		reach := min(bend * math.tan(turn / 2), 0.45 * linalg.length(p - points[i - 1]), 0.45 * linalg.length(points[i + 1] - p))
		radius := reach / math.tan(turn / 2)
		left := u.x * v.y - u.y * v.x > 0 // turning counterclockwise
		inward := [2]f32{-u.y, u.x} if left else [2]f32{u.y, -u.x}
		start := p - u * reach
		center := start + inward * radius
		a0 := math.atan2(start.y - center.y, start.x - center.x) * math.DEG_PER_RAD
		turn_deg := turn * math.DEG_PER_RAD
		arc(&line, center, {radius, radius}, a0, a0 + (turn_deg if left else -turn_deg), step)
	}
	append(&line, points[len(points) - 1])
	return line
}

// The center lines of the letters Z, S, E in the logo's plane (x right, y up, meters from
// its bottom left), curves made of segments at most `step` degrees of arc apart. A tube of
// radius LOGO_TUBE along each line draws the letter.
logo_lines :: proc(step: f32) -> (letters: [LOGO_LETTERS][dynamic]Polyline) {
	for &l in letters {
		l = make([dynamic]Polyline, context.temp_allocator)
	}
	r := f32(LOGO_TUBE)
	w := f32(LOGO_LETTER_WIDTH)
	bend := f32(LOGO_BEND)
	bottom, top, middle := r, LOGO_HEIGHT - r, f32(LOGO_HEIGHT) / 2
	// Z: one line with its two corners bent
	x := f32(0)
	l, rt := x + r, x + w - r
	z := [4][2]f32{{l, top}, {rt, top}, {l, bottom}, {rt, bottom}}
	append(&letters[0], round_corners(z[:], bend, step))
	// S: around the upper ellipse counterclockwise from its right side to the middle, then
	// around the lower one clockwise from the middle to its left side
	x += w + LOGO_GAP
	cx, q := x + w / 2, (top - bottom) / 4
	s := make(Polyline, context.temp_allocator)
	arc(&s, {cx, middle + q}, {w / 2 - r, q}, 30, 270, step)
	pop(&s) // the lower bend starts where the upper one ends
	arc(&s, {cx, middle - q}, {w / 2 - r, q}, 90, -150, step)
	append(&letters[1], s)
	// E: its outline with two corners bent, and the middle bar, which grows out of the
	// upright through two curved flares instead of meeting it at a right angle
	x += w + LOGO_GAP
	l, rt = x + r, x + w - r
	e := [4][2]f32{{rt, top}, {l, top}, {l, bottom}, {rt, bottom}}
	append(&letters[2], round_corners(e[:], bend, step))
	bar := make(Polyline, context.temp_allocator)
	arc(&bar, {l + bend, middle + bend}, {bend, bend}, 180, 270, step)
	append(&bar, [2]f32{rt - 0.1, middle})
	append(&letters[2], bar)
	flare := make(Polyline, context.temp_allocator)
	arc(&flare, {l + bend, middle - bend}, {bend, bend}, 180, 90, step)
	append(&letters[2], flare)
	return
}

// The capsules along a letter's lines, in the room, each knowing its neighbors on its line
// (whose directions smooth its shading across the joints), counted from the letter's
// first capsule. Returns where they are in `out` (first, count).
letter_capsules :: proc(out: ^[dynamic]Capsule, lines: [dynamic]Polyline, origin, right: Vec3, width: f32) -> [2]int {
	to_room :: proc(origin, right: Vec3, width: f32, p: [2]f32) -> Vec3 {
		return origin + right * (p.x - width / 2) + Vec3{0, p.y, 0}
	}
	first := len(out)
	for line in lines {
		for i in 0 ..< len(line) - 1 {
			k := len(out) - first
			append(out, Capsule {
				a    = to_room(origin, right, width, line[i]),
				b    = to_room(origin, right, width, line[i + 1]),
				prev = k - 1 if i > 0 else -1,
				next = k + 1 if i < len(line) - 2 else -1,
			})
		}
	}
	return {first, len(out) - first}
}

// Floats the logo LOGO_LIFT above the floor at LOGO_CENTER, facing the camera's starting
// point, each letter tied down by CABLES cables from its top: two to weights in front of
// it, one behind (the weights are props)
place_logo :: proc() {
	logo := &room.logo
	clear(&logo.placed[0])
	clear(&logo.placed[1])
	width := 3 * f32(LOGO_LETTER_WIDTH) + 2 * LOGO_GAP
	origin := LOGO_CENTER + Vec3{0, LOGO_LIFT, 0}
	right := Vec3{1, 0, 0}
	drawn := logo_lines(LOGO_ARC_DEGREES)
	coarse := logo_lines(LOGO_PROXY_ARC_DEGREES)
	for &letter, i in logo.letters {
		letter.capsules = letter_capsules(&logo.placed[0], drawn[i], origin, right, width)
		letter.proxies = letter_capsules(&logo.placed[1], coarse[i], origin, right, width)
		assert(letter.capsules[1] <= MAX_LOGO_CAPSULES, "raise MAX_LOGO_CAPSULES")
		capsules := logo.placed[0][letter.capsules[0]:][:letter.capsules[1]]
		left := origin.x - width / 2 + f32(i) * (LOGO_LETTER_WIDTH + LOGO_GAP)
		letter.pivot = {left + LOGO_LETTER_WIDTH / 2, origin.y + LOGO_HEIGHT / 2, origin.z}
		letter.bob_phase = f32(i) * 2.1
		// The cables start on the top of the tube, where it is highest across the letter
		for &cable, k in letter.cables {
			share := [CABLES]f32{0.2, 0.8, 0.5}
			side: f32 = -1 if k < FRONT_CABLES else 1 // -z: in front
			x := left + share[k] * LOGO_LETTER_WIDTH
			top := Vec3{x, 0, origin.z}
			for c in capsules {
				for s in 0 ..= 20 {
					p := math.lerp(c.a, c.b, f32(s) / 20)
					if abs(p.x - x) < 0.04 && p.y + LOGO_TUBE > top.y {
						top.y = p.y + LOGO_TUBE
					}
				}
			}
			cable.top = top
			cable.anchor = {x, 0, origin.z + side * CABLE_SPREAD}
			add_prop(.Cylinder, {0.045, 0.02, 0, 0.008}, 0.05, cable.anchor + {0, 0.02, 0}, linear3(STEEL))
		}
	}
	assert(len(logo.placed[1]) <= MAX_LOGO_PROXIES, "raise MAX_LOGO_PROXIES")
	logo.center = origin + Vec3{0, LOGO_HEIGHT / 2, 0}
	for i in 0 ..< 8 {
		x := width / 2 if i & 1 != 0 else -width / 2
		y := f32(LOGO_HEIGHT) if i & 2 != 0 else 0
		z := f32(LOGO_TUBE) if i & 4 != 0 else -LOGO_TUBE
		logo.box[i] = origin + Vec3{x, y, z}
	}
	update_logo(0)
}

// The letters `t` seconds in: each bobs up and down, leans a little sideways and turns on its
// cables around its pivot, slowly, out of step with the others; its capsules, proxies,
// cable tops and bounds follow; `still`: each where it was placed, let down onto the floor and
// sunk PIPE_SINK into it (the pipe letters of the deep)
update_logo :: proc(t: f32, still := false) {
	logo := &room.logo
	resize(&logo.capsules, len(logo.placed[0]))
	resize(&logo.proxies, len(logo.placed[1]))
	// A letter's pose: lifted, leaning in its own plane (cos, sin), turned around y
	Pose :: struct {
		pivot, lift: Vec3,
		lean, turn:  [2]f32,
	}
	move :: proc(p: Vec3, m: Pose) -> Vec3 {
		v := p - m.pivot
		v = {m.lean[0] * v.x - m.lean[1] * v.y, m.lean[1] * v.x + m.lean[0] * v.y, v.z}
		return m.pivot + m.lift + Vec3{m.turn[0] * v.x + m.turn[1] * v.z, v.y, -m.turn[1] * v.x + m.turn[0] * v.z}
	}
	for &letter in logo.letters {
		phase := LETTER_PACE * t + letter.bob_phase
		turn := f32(LETTER_SWAY) * math.RAD_PER_DEG * math.sin(0.63 * phase + 1)
		lean := f32(LETTER_LEAN) * math.RAD_PER_DEG * math.sin(0.81 * phase + 2.3)
		pose := Pose {
			pivot = letter.pivot,
			lift  = {0, LETTER_BOB * math.sin(phase), 0},
			lean  = {math.cos(lean), math.sin(lean)},
			turn  = {math.cos(turn), math.sin(turn)},
		}
		if still {
			lowest := f32(math.F32_MAX)
			for c in logo.placed[0] {
				lowest = min(lowest, c.a.y, c.b.y)
			}
			pose = {pivot = letter.pivot, lift = {0, LOGO_TUBE - PIPE_SINK - lowest, 0}, lean = {1, 0}, turn = {1, 0}}
		}
		letter.facing = {-pose.turn[1], 0, -pose.turn[0]} // (0, 0, -1) turned: towards the camera's starting point
		for group in 0 ..< 2 {
			span := letter.capsules if group == 0 else letter.proxies
			to := logo.capsules[:] if group == 0 else logo.proxies[:]
			for k in span[0] ..< span[0] + span[1] {
				from := logo.placed[group][k]
				to[k] = {move(from.a, pose), move(from.b, pose), from.prev, from.next}
			}
		}
		// Bounds around its capsules
		lo := Vec3{math.F32_MAX, math.F32_MAX, math.F32_MAX}
		hi := -lo
		for k in letter.capsules[0] ..< letter.capsules[0] + letter.capsules[1] {
			cap := logo.capsules[k]
			lo = linalg.min(lo, linalg.min(cap.a, cap.b) - LOGO_TUBE)
			hi = linalg.max(hi, linalg.max(cap.a, cap.b) + LOGO_TUBE)
		}
		letter.center = (lo + hi) / 2
		letter.bound = linalg.length(hi - lo) / 2
		for &cable in letter.cables {
			cable.at = move(cable.top, pose)
		}
		for k in 0 ..< 8 {
			letter.box[k] = {lo.x if k & 1 == 0 else hi.x, lo.y if k & 2 == 0 else hi.y, lo.z if k & 4 == 0 else hi.z}
		}
	}
}

// A fixed part of the scene (the hatch, the lamp, the cables' weights): an object that
// neither moves nor turns, `angle` degrees around `axis` from upright, rusty steel unless
// told otherwise
add_prop :: proc(kind: fx.Solid, size: [4]f32, bound: f32, center: Vec3, color: Vec3, pattern := Pattern.Rust, axis := Vec3{0, 1, 0}, angle: f32 = 0, emission: f32 = 0) {
	append(&room.objects, Object {
		kind = kind,
		size = size,
		bound = bound,
		center = center,
		pos = center,
		prop = true,
		pattern = pattern,
		col_a = color,
		col_b = linear3(RUST),
		scale = RUST_SCALE * bound, // rust patches the same size on every prop
		seed = rand.float32_range(0, 50),
		specular = 0.15,
		shininess = 12,
		axis = axis,
		spin_phase = angle * math.RAD_PER_DEG,
		emission = emission,
	})
}

// The hatch in the middle of the floor: a rim half sunk in the floor, the lid, a handwheel
// on a hub with two spokes across it, rivets round the lid's edge
place_hatch :: proc() {
	c := ROOM_CENTER
	add_prop(.Torus, {HATCH_LID + 0.08, 0.055, 0, 0}, HATCH_LID + 0.14, c, linear3(STEEL))
	room.lid_first = len(room.objects) // the rest is the lid, which flies off (place_lid)
	add_prop(.Cylinder, {HATCH_LID, 0.035, 0, 0.012}, HATCH_LID + 0.01, c + {0, 0.035, 0}, linear3(STEEL))
	add_prop(.Cylinder, {0.07, 0.05, 0, 0.012}, 0.09, c + {0, 0.12, 0}, linear3(STEEL))
	add_prop(.Torus, {0.3, 0.022, 0, 0}, 0.33, c + {0, 0.17, 0}, linear3(STEEL))
	add_prop(.Capsule, {0.016, 0.29, 0, 0}, 0.31, c + {0, 0.17, 0}, linear3(STEEL), axis = {1, 0, 0}, angle = 90)
	add_prop(.Capsule, {0.016, 0.29, 0, 0}, 0.31, c + {0, 0.17, 0}, linear3(STEEL), axis = {0, 0, 1}, angle = 90)
	for k in 0 ..< 12 {
		a := f32(k) * math.TAU / 12
		add_prop(.Sphere, {0.02, 0, 0, 0}, 0.02, c + {0.53 * math.cos(a), 0.07, 0.53 * math.sin(a)}, linear3(STEEL))
	}
	assert(len(room.objects) - room.lid_first == LID_PARTS)
}

// The lamp: a metal can hanging from the ceiling with a glowing bulb under it, and its light
place_lamp :: proc() {
	top := LAMP_POS.y + 0.09 // of the shade
	cord := (ROOM_HEIGHT - top) / 2
	room.lamp_first = len(room.objects)
	add_prop(.Capsule, {0.008, cord, 0, 0}, cord + 0.008, {LAMP_POS.x, top + cord, LAMP_POS.z}, linear3(LAMP_METAL), pattern = .Plain)
	add_prop(.Cylinder, {0.2, 0.09, 0, 0.02}, 0.22, LAMP_POS, linear3(LAMP_METAL), pattern = .Plain)
	bulb := LAMP_POS - {0, 0.12, 0}
	add_prop(.Sphere, {0.08, 0, 0, 0}, 0.08, bulb, LAMP_COLOR * 0.8, pattern = .Plain, emission = BULB_GLOW)
	room.lamp = Light {
		color = {LAMP_COLOR.x, LAMP_COLOR.y, LAMP_COLOR.z, LAMP_INTENSITY},
		range = LAMP_RANGE,
		pos   = bulb,
	}
}

// A random solid: its kind, size, bounding radius and the height it stands at on the floor
// (upright: boxes, cylinders and ellipsoids on a face, tori lying flat, capsules on end)
random_solid :: proc() -> (o: Object) {
	o.kind = rand.choice_enum(fx.Solid)
	in_range :: proc(lo, hi: f32) -> f32 {return rand.float32_range(lo, hi)}
	switch o.kind {
	case .Sphere:
		r := in_range(0.22, 0.5)
		o.size, o.bound, o.rest = {r, 0, 0, 0}, r, r
	case .Box:
		h := Vec3{in_range(0.15, 0.42), in_range(0.15, 0.42), in_range(0.15, 0.42)}
		o.size = {h.x, h.y, h.z, in_range(0.03, 0.07)}
		o.bound, o.rest = linalg.length(h), h.y
	case .Cylinder:
		radius, half := in_range(0.15, 0.38), in_range(0.15, 0.45)
		o.size = {radius, half, 0, 0.04}
		o.bound, o.rest = linalg.length([2]f32{radius, half}), half
	case .Ellipsoid:
		r := Vec3{in_range(0.15, 0.45), in_range(0.15, 0.45), in_range(0.15, 0.45)}
		o.size = {r.x, r.y, r.z, 0}
		o.bound, o.rest = max(r.x, r.y, r.z), r.y
	case .Torus:
		major, tube := in_range(0.25, 0.4), in_range(0.07, 0.13)
		o.size = {major, tube, 0, 0}
		o.bound, o.rest = major + tube, tube
	case .Capsule:
		radius, half := in_range(0.1, 0.2), in_range(0.1, 0.32)
		o.size = {radius, half, 0, 0}
		o.bound, o.rest = radius + half, radius + half
	case .Blob:
		scale := in_range(0.2, 0.3)
		o.size = {scale, in_range(0, 100), 0, 0}
		o.bound, o.rest = 1.7 * scale, 1.7 * scale // its shape is the shader's: it floats
	case .Twisted:
		h := Vec3{in_range(0.1, 0.2), in_range(0.32, 0.45), in_range(0.1, 0.2)}
		o.size = {h.x, h.y, h.z, 0.03}
		o.bound, o.rest = linalg.length(h), h.y
	case .Carved:
		e := in_range(0.22, 0.34)
		h := Vec3{e, e * in_range(0.8, 1.2), e * in_range(0.8, 1.2)}
		o.size = {h.x, h.y, h.z, 0.05}
		o.bound, o.rest = linalg.length(h), h.y
	}
	return
}

// The capsule standing in for an object when it shades others (shadows, occlusion): along
// its longest axis, as thick as its other two (local axis 0..2, radius, half length)
occluder_shape :: proc(o: Object) -> (axis: int, radius, half: f32) {
	s := o.size
	switch o.kind {
	case .Sphere:
		return 1, s.x, 0
	case .Blob:
		return 1, 1.1 * s.x, 0 // about as big as its spheres together
	case .Box, .Ellipsoid, .Twisted, .Carved:
		axis = 0 if s.x >= s.y && s.x >= s.z else (1 if s.y >= s.z else 2)
		radius = (s.x + s.y + s.z - s[axis]) / 2
		return axis, radius, max(s[axis] - radius, 0)
	case .Cylinder:
		if s.y >= s.x {
			return 1, s.x, s.y - s.x
		}
		return 0, s.y, s.x - s.y
	case .Torus:
		return 0, s.y + 0.3 * s.x, 0.7 * s.x
	case .Capsule:
		return 1, s.x, s.y
	}
	return
}

// Objects placed at random where the camera sees them wholly from some point of its path,
// clear of the path (CAMERA_CLEARANCE), of the hatch's column (HATCH_CLEARANCE, for what
// comes out of it), of the logo and its cables, and none closer than OBJECT_GAP to another
// (counting the bob of floating ones) or hiding the logo or the hatch from the path
place_objects :: proc(count: int) {
	screen := eng.screen_size()
	target := len(room.objects) + count
	for len(room.objects) < target {
		placed := false
		for _ in 0 ..< 400 {
			o := random_solid()
			r := o.bound
			o.floating = rand.float32() < FLOATING_SHARE || o.kind == .Blob
			y := o.rest
			if o.floating {
				y = rand.float32_range(r + 0.5, ROOM_HEIGHT - r - 0.5)
			}
			o.center = {rand.float32_range(-ROOM_HALF_WIDTH + r + 0.2, ROOM_HALF_WIDTH - r - 0.2), y, rand.float32_range(r + 0.5, ROOM_DEPTH - r - 0.2)}
			reach := r + (BOB_AMPLITUDE if o.floating else 0)
			if linalg.length(o.center.xz - ROOM_CENTER.xz) < reach + HATCH_CLEARANCE {
				continue
			}
			// Low ones also keep clear of the way the lid flies and slides in the transition
			lid_way := linalg.distance(o.center.xz, nearest_on_segment(o.center, LID_HOME, LID_REST).xz)
			if o.center.y - reach < 1 && lid_way < reach + HATCH_LID + 0.2 {
				continue
			}
			clear_of_path, in_view := true, false
			for k in 0 ..= 20 {
				sweep := f32(k) / 20
				// The path of scene 1's camera, and of the flood's as it arcs down (arc_position)
				if linalg.distance(o.center, orbit_position(sweep)) < reach + CAMERA_CLEARANCE || linalg.distance(o.center, arc_position(sweep)) < reach + CAMERA_CLEARANCE {
					clear_of_path = false
					break
				}
				if k % 5 == 0 {
					center, size, ok := project_sphere(camera_at(sweep * SCENE1_LEG), o.center, reach)
					lo, hi := center - size / 2, center + size / 2
					in_view ||= ok && lo.x > 0.02 * screen.x && hi.x < 0.98 * screen.x && lo.y > 0.05 * screen.y && hi.y < 0.98 * screen.y
				}
			}
			if !clear_of_path || !in_view {
				continue
			}
			if d, _ := nearest_on_logo(o.center); d < reach + LOGO_TUBE + OBJECT_GAP + LETTER_ROOM {
				continue
			}
			near_cable := false
			for letter in room.logo.letters {
				for cable in letter.cables {
					near_cable ||= linalg.distance(o.center, nearest_on_segment(o.center, cable.at, cable.anchor)) < reach + OBJECT_GAP
				}
			}
			if near_cable {
				continue
			}
			// Not hiding the logo or the hatch from any point of the path
			hiding := false
			for k in 0 ..= 4 {
				cam := camera_at(f32(k) / 4 * SCENE1_LEG)
				center, size, _ := project_sphere(cam, o.center, reach)
				_, depth := project(cam, o.center)
				logo_center, logo_size, _ := project_bounds(cam, room.logo.box[:])
				_, logo_depth := project(cam, room.logo.center)
				hatch_center, hatch_size, _ := project_sphere(cam, ROOM_CENTER, HATCH_LID + 0.15)
				_, hatch_depth := project(cam, ROOM_CENTER)
				hiding ||= depth < logo_depth && overlaps(center, size, logo_center, logo_size)
				hiding ||= depth < hatch_depth && overlaps(center, size, hatch_center, hatch_size)
			}
			if hiding {
				continue
			}
			free_spot := true
			for other in room.objects {
				margin := f32(OBJECT_GAP) + (BOB_AMPLITUDE if o.floating else 0) + (BOB_AMPLITUDE if other.floating else 0)
				if linalg.distance(o.center, other.center) < o.bound + other.bound + margin {
					free_spot = false
					break
				}
			}
			if !free_spot {
				continue
			}
			o.pattern = Pattern(rand.int_max(3)) // marble, checker or bands
			o.bob_freq = rand.float32_range(0.6, 1.4)
			o.bob_phase = rand.float32_range(0, math.TAU)
			o.axis = random_unit() if o.floating else Vec3{0, 1, 0}
			o.spin = rand.float32_range(0.15, 0.6) * (f32(1) if rand.float32() < 0.5 else -1)
			o.spin_phase = rand.float32_range(0, math.TAU)
			hue := rand.float32()
			a := hue_color(hue, rand.float32_range(0.55, 0.9)) * rand.float32_range(0.35, 0.8)
			b := hue_color(math.mod(hue + rand.float32_range(0.08, 0.5), 1), rand.float32_range(0.1, 0.6)) * rand.float32_range(0.5, 0.9)
			o.col_a, o.col_b = a * a, b * b // to linear
			#partial switch o.pattern {
			case .Marble:
				o.scale = rand.float32_range(1.2, 2.5)
			case .Checker:
				o.scale = f32(rand.int_max(3) + 2)
			case .Bands:
				o.scale = rand.float32_range(0.8, 1.8)
			}
			o.seed = rand.float32_range(0, 50)
			glossy := rand.float32()
			o.specular, o.shininess = 0.15 + 0.7 * glossy, 12 + 100 * glossy * glossy
			o.pos = o.center
			append(&room.objects, o)
			placed = true
			break
		}
		if !placed {
			break // the room is full
		}
	}
}

// All MAX_LIGHTS lights, so that changing how many are in use needs nothing new
make_lights :: proc() {
	hue := rand.float32()
	for &l in room.lights {
		hue = math.mod(hue + 0.618034, 1)
		rgb := hue_color(hue, rand.float32_range(0.88, 1))
		l = Light {
			color = {rgb.x, rgb.y, rgb.z, rand.float32_range(5.5, 9)},
			glow  = rl.ColorFromNormalized({rgb.x, rgb.y, rgb.z, 1}),
			range = rand.float32_range(5.5, 7.5),
			mid   = {0, ROOM_HEIGHT / 2, (2 + ROOM_DEPTH) / 2},
			amp   = {
				rand.float32_range(1.5, ROOM_HALF_WIDTH - 0.6),
				rand.float32_range(0.6, ROOM_HEIGHT / 2 - 0.35),
				rand.float32_range(1.5, (ROOM_DEPTH - 2) / 2 - 0.4),
			},
			freq  = {rand.float32_range(0.3, 0.9), rand.float32_range(0.3, 0.9), rand.float32_range(0.3, 0.9)},
			phase = {rand.float32_range(0, math.TAU), rand.float32_range(0, math.TAU), rand.float32_range(0, math.TAU)},
		}
	}
}

// Makes the whole scene again (a new room, a different number of objects, an effect
// switched: the effects are shader structure). The looks don't depend on the numbers of
// objects or lights, so the shaders are the same each time.
build_room :: proc() {
	eng.clear_scene()
	clear(&room.objects)
	rand.reset(room.seed)
	room.camera = camera_at(0)
	place_logo()
	hatch := len(room.objects)
	place_hatch()
	for &o in room.objects[hatch:] {
		o.presence = .Always // in the deep too, the lid where it landed
	}
	place_lamp()
	place_objects(room.object_count)
	make_lights()
	place_rubble() // after the rest has its random numbers: scene 1 stays as it was
	find_neighbors()

	fx_on := room.effects
	room.shadow_buffer = -1
	if fx_on.shadows {
		room.shadow_buffer = eng.add_entity(shadow_buffer_look(), {}, {1, 1}, {z_index = LAYER_SHADOW_BUFFER, blend = .Premultiplied})
	}
	room.air_buffer = -1
	if fx_on.occlusion || fx_on.haze {
		room.air_buffer = eng.add_entity(air_buffer_look(fx_on), {}, {1, 1}, {z_index = LAYER_AIR_BUFFER, blend = .Premultiplied})
	}
	room.room = eng.add_entity(room_look(fx_on), {}, {1, 1}, {z_index = LAYER_ROOM})
	eng.set_layer_bloom(LAYER_BLOOM, BLOOM_THRESHOLD, BLOOM_STRENGTH if fx_on.bloom else 0)
	room.views[0].on, room.views[1].on = true, fx_on.reflections
	for &view, v in room.views {
		view.mirror = v == 1
		if !view.on {
			continue
		}
		// The reflection: drawn premultiplied into its layer's image; no shadows or occlusion
		// (they hardly show in a blurred reflection)
		layer, blend, glow_blend := LAYER_OBJECTS, eng.BlendMode.Alpha, eng.BlendMode.Additive
		looks := fx_on
		if view.mirror {
			layer, blend, glow_blend = LAYER_REFLECTION, .Premultiplied, .Premultiplied
			looks = {haze = fx_on.haze}
		}
		for &b in view.buckets {
			b = eng.add_entity(object_look(looks, view.mirror), {}, {1, 1}, {z_index = layer, blend = blend})
		}
		for letter, i in room.logo.letters {
			capsules := room.logo.capsules[letter.capsules[0]:][:letter.capsules[1]]
			id := eng.add_entity(logo_look(capsules, looks, view.mirror), {}, {1, 1}, {z_index = layer, blend = blend})
			view.letters[i] = id
		}
		for &id, side in view.cables {
			count := FRONT_CABLES if side == 0 else CABLES - FRONT_CABLES
			id = eng.add_entity(cables_look(count * LOGO_LETTERS, looks, view.mirror), {}, {1, 1}, {z_index = layer, blend = blend})
		}
		for l, i in room.lights {
			id := eng.add_entity(light_glow_look(looks, view.mirror), {}, {1, 1}, {z_index = LAYER_REFLECTION if view.mirror else LAYER_GLOWS, blend = glow_blend})
			view.glows[i] = id
			eng.set_param(id, "glow", l.glow)
			eng.set_sort_key(id, -1e9) // in the reflection's sorted layer, over the objects
		}
	}
	// The transition's: the jet and the spray among the objects (sorted), the lens over all
	room.jet = eng.add_entity(jet_look(), {}, {1, 1}, {z_index = LAYER_OBJECTS})
	for &id in room.drops {
		id = eng.add_entity(drops_look(), {}, {1, 1}, {z_index = LAYER_OBJECTS})
	}
	room.lens = eng.add_entity(lens_look(), {}, {1, 1}, {z_index = LAYER_LENS})
	room.text = eng.add_text("", {12, 10}, 18, HUD_TEXT, LAYER_TEXT)
	room.fade = eng.add_entity(fade_look(), {}, {1, 1}, {z_index = LAYER_FADE})
	room.hint = eng.add_text("", {}, 28, HUD_TEXT, LAYER_TEXT, .Center)
	add_deep_entities()
}

// Each object's NEIGHBORS nearest occluders (surface to surface): the other objects and the
// logo's proxies; each letter's: the nearest objects. The objects don't move far, so once
// per room is enough.
find_neighbors :: proc() {
	Gap :: struct {
		gap:      f32,
		occluder: int,
	}
	by_gap :: proc(a, b: Gap) -> bool {return a.gap < b.gap}
	n := len(room.objects)
	for &o, i in room.objects {
		gaps := make([dynamic]Gap, context.temp_allocator)
		for other, k in room.objects {
			apart := (o.presence == .Before && other.presence == .Deep) || (o.presence == .Deep && other.presence == .Before) // never in a scene together
			if k != i && !apart {
				append(&gaps, Gap{linalg.distance(o.center, other.center) - o.bound - other.bound, k})
			}
		}
		for c, k in room.logo.proxies {
			if o.presence != .Deep {
				append(&gaps, Gap{linalg.distance(o.center, nearest_on_segment(o.center, c.a, c.b)) - o.bound - LOGO_TUBE, n + k})
			}
		}
		slice.sort_by(gaps[:], by_gap)
		for k in 0 ..< NEIGHBORS {
			o.neighbors[k] = gaps[k].occluder if k < len(gaps) else -1
		}
	}
	for &letter in room.logo.letters {
		gaps := make([dynamic]Gap, context.temp_allocator)
		for o, k in room.objects {
			d := f32(math.F32_MAX)
			for c in room.logo.proxies[letter.proxies[0]:][:letter.proxies[1]] {
				d = min(d, linalg.distance(o.center, nearest_on_segment(o.center, c.a, c.b)))
			}
			append(&gaps, Gap{d - o.bound, k})
		}
		slice.sort_by(gaps[:], by_gap)
		for k in 0 ..< NEIGHBORS {
			letter.neighbors[k] = gaps[k].occluder if k < len(gaps) else -1
		}
	}
}

// How many of the objects were placed at random (the rest are props)
random_objects :: proc() -> (n: int) {
	for o in room.objects {
		n += 0 if o.prop else 1
	}
	return
}

// The frame rate over the last METER_WINDOW seconds and the average frame time since the
// first METER_SKIP seconds (startup), in real time whatever ZSE_FIXED_DT says
METER_WINDOW :: 0.5
METER_SKIP :: 1

Meter :: struct {
	window_start, run_start:   f64,
	window_frames, run_frames: int,
}

update_text :: proc() {
	m := &room.meter
	now := rl.GetTime()
	if now < METER_SKIP {
		m.window_start, m.run_start = now, now
		return
	}
	m.window_frames += 1
	m.run_frames += 1
	if now - m.window_start >= METER_WINDOW {
		fps := f64(m.window_frames) / (now - m.window_start)
		average := 1000 * (now - m.run_start) / f64(m.run_frames)
		eng.set_text(room.text, fmt.tprintf("%.0f fps   %.2f ms average", fps, average))
		m.window_start, m.window_frames = now, 0
	}
}

// ---------------------------------------------------------------------------------------
// Every frame

// Rows of the rotation from room space to object space: the transpose of turning by
// `angle` around `axis` (Rodrigues)
object_rows :: proc(axis: Vec3, angle: f32) -> (rows: [3]Vec3) {
	m := linalg.matrix3_rotate_f32(angle, axis)
	for i in 0 ..< 3 {
		rows[i] = {m[0, i], m[1, i], m[2, i]} // column i of m = row i of its transpose
	}
	return
}

update_objects :: proc(t: f32) {
	eng.profile_scope("objects")
	place_lid(transition_length() if in_deep() else transition_time()) // in the deep, where it landed
	lid := room.lid_first
	for &o, i in room.objects {
		if i < lid || i >= lid + LID_PARTS { // the lid's parts are placed already
			o.pos = o.center
			if o.floating {
				o.pos.y += BOB_AMPLITUDE * math.sin(o.bob_freq * t + o.bob_phase)
			}
			o.rows = object_rows(o.axis, o.spin * t + o.spin_phase)
		}
		// Its occluding capsule: along a local axis, which is that column of the rows
		axis, radius, half := occluder_shape(o)
		dir := Vec3{o.rows[0][axis], o.rows[1][axis], o.rows[2][axis]}
		a, b := o.pos - dir * half, o.pos + dir * half
		capsule := [fx.CAPSULE3_STRIDE]f32{a.x, a.y, a.z, radius, b.x, b.y, b.z, 0}
		if room.lit < 4 && i >= room.lamp_first && i < room.lamp_first + 3 {
			capsule = far_away // the lamp casts shadows (see update_lights): not its own parts'
		}
		if !shown(o) {
			capsule = far_away // not in this scene
		}
		copy(room.occluders[i * fx.CAPSULE3_STRIDE:], capsule[:])
	}
}

// The flying lights, then the lamp's (right after the lit ones: once they are out it is the
// first, and lights 0..3 cast shadows, so the lamp's own parts stop occluding, see
// update_objects). In the transition their flight slows to a stop and they flicker out.
update_lights :: proc(t: f32) {
	eng.profile_scope("lights")
	tau := transition_time()
	flight := t
	if tau >= 0 {
		flight = t - tau + LIGHT_STOP * (1 - math.exp(-tau / LIGHT_STOP))
	}
	for &l, i in room.lights {
		if i >= room.lit {
			slice.zero(room.light_values[i * fx.LIGHT_STRIDE:][:fx.LIGHT_STRIDE])
			continue
		}
		l.brightness = shimmer(i, tau)
		for k in 0 ..< 3 {
			l.pos[k] = l.mid[k] + l.amp[k] * math.sin(l.freq[k] * LIGHT_PACE * flight + l.phase[k])
		}
		// Out of the objects and the logo
		for o in room.objects {
			if !shown(o) {
				continue
			}
			v := l.pos - o.pos
			reach := o.bound + LIGHT_CLEARANCE
			if d := linalg.length(v); d < reach {
				l.pos = o.pos + (v / d if d > 1e-4 else Vec3{0, 1, 0}) * reach
			}
		}
		if d, at := nearest_on_logo(l.pos); d < LOGO_TUBE + LIGHT_CLEARANCE {
			l.pos = at + ((l.pos - at) / d if d > 1e-4 else Vec3{0, 1, 0}) * (LOGO_TUBE + LIGHT_CLEARANCE)
		}
		// and out of the camera's way
		if v := l.pos - room.camera.pos; linalg.length(v) < CAMERA_CLEARANCE {
			l.pos = room.camera.pos + linalg.normalize0(v) * CAMERA_CLEARANCE
		}
		values := [fx.LIGHT_STRIDE]f32{l.pos.x, l.pos.y, l.pos.z, l.range, l.color.r, l.color.g, l.color.b, l.color.a * l.brightness}
		copy(room.light_values[i * fx.LIGHT_STRIDE:], values[:])
	}
	lamp := room.lamp
	values := [fx.LIGHT_STRIDE]f32{lamp.pos.x, lamp.pos.y, lamp.pos.z, lamp.range, lamp.color.r, lamp.color.g, lamp.color.b, lamp.color.a}
	copy(room.light_values[room.lit * fx.LIGHT_STRIDE:], values[:])
	for &view in room.views {
		if view.on {
			update_glows(&view)
		}
	}
	// Which lights reach each object
	for &o in room.objects {
		o.mask = 0
		for l, i in room.lights[:room.lit] {
			if linalg.distance(l.pos, o.pos) < l.range + o.bound {
				o.mask |= 1 << u32(i)
			}
		}
		if linalg.distance(room.lamp.pos, o.pos) < room.lamp.range + o.bound {
			o.mask |= 1 << u32(room.lit)
		}
	}
}

// How much of the light coming up through the floor at `rise` (the sine of its angle to the
// floor) the floor reflects: Schlick's approximation, as reflectivity in looks.odin
floor_reflect :: proc(rise: f32) -> f32 {
	return math.lerp(f32(REFLECT_FACING), REFLECT_GRAZING, math.pow(1 - math.saturate(rise), 5))
}

// Each light's glow in a view, hidden where an object or a letter stands between it and the
// view's camera; in the reflection, as strong as the floor reflects where the light shows
update_glows :: proc(view: ^View) {
	cam := view.camera.pos
	for l, i in room.lights {
		id := view.glows[i]
		e := eng.get_entity(id)
		if i >= room.lit {
			e.visible = false
			continue
		}
		to_light := l.pos - cam
		dist := linalg.length(to_light)
		dir := to_light / dist
		vis: f32 = 1
		for _, k in room.objects {
			s := room.occluders[k * fx.CAPSULE3_STRIDE:]
			if ray_t, gap := ray_segment(cam, dir, {s[0], s[1], s[2]}, {s[4], s[5], s[6]}); ray_t > 0 && ray_t < dist {
				vis *= math.smoothstep(f32(-0.04), 0.04, gap - s[3])
			}
		}
		for c in room.logo.capsules {
			if ray_t, gap := ray_segment(cam, dir, c.a, c.b); ray_t > 0 && ray_t < dist {
				vis *= math.smoothstep(f32(-0.04), 0.04, gap - LOGO_TUBE)
			}
		}
		at, depth := project(view.camera, l.pos)
		vis *= l.brightness
		e.visible = depth > 0.1 && vis > 0.01
		e.pos = at
		glow_size := 2 * GLOW_RADIUS * view.camera.focal / max(depth, 0.1) * (0.6 + 0.4 * l.brightness)
		e.size = {glow_size, glow_size}
		eng.set_param(id, "vis", vis)
		if view.mirror {
			eng.set_param(id, "reflect", floor_reflect(dir.y))
		}
	}
}

// The occluder list after the objects: the logo's proxies; and for the room's occlusion,
// each occluder's reach on screen (as a circle), binned
update_occluders :: proc() {
	n := len(room.objects)
	for c, k in room.logo.proxies {
		capsule := [fx.CAPSULE3_STRIDE]f32{c.a.x, c.a.y, c.a.z, LOGO_TUBE, c.b.x, c.b.y, c.b.z, 0}
		copy(room.occluders[(n + k) * fx.CAPSULE3_STRIDE:], capsule[:])
	}
	room.occluder_n = n + len(room.logo.proxies)
	if room.effects.shadows {
		update_shadow_bins()
	}
	if !room.effects.occlusion {
		return
	}
	eng.profile_scope("occlusion bins")
	screen := eng.screen_size()
	for k in 0 ..< room.occluder_n {
		s := room.occluders[k * fx.CAPSULE3_STRIDE:]
		a, b := Vec3{s[0], s[1], s[2]}, Vec3{s[4], s[5], s[6]}
		reach := s[3] * OCCLUSION_REACH + linalg.distance(a, b) / 2
		at, depth := project(room.camera, (a + b) / 2)
		radius := room.camera.focal * reach / max(depth - reach, 0.05)
		if depth - reach < 0.05 {
			at, radius = screen / 2, linalg.length(screen) // reaching around the camera: everywhere
		}
		circle := [fx.GLOW_STRIDE]f32{at.x, at.y, radius, 0}
		copy(room.reach[k * fx.GLOW_STRIDE:], circle[:])
	}
	used := eng.bin_shapes(room.bins[:], room.reach[:room.occluder_n * fx.GLOW_STRIDE], .Glow_Points, 2, BIN_CELL)
	eng.set_param_array(room.air_buffer, "occlusion_bins", room.bins[:used])
}

// A convex polygon, clipped plane by plane (each clip adds at most one corner)
Polygon :: struct {
	points: [24]Vec3,
	n:      int,
}

// The part of a polygon where dot(normal, p) <= d
clip_polygon :: proc(poly: Polygon, normal: Vec3, d: f32) -> (out: Polygon) {
	for i in 0 ..< poly.n {
		a, b := poly.points[i], poly.points[(i + 1) % poly.n]
		da, db := linalg.dot(normal, a) - d, linalg.dot(normal, b) - d
		if da <= 0 {
			out.points[out.n] = a
			out.n += 1
		}
		if (da <= 0) != (db <= 0) {
			out.points[out.n] = a + (b - a) * (da / (da - db))
			out.n += 1
		}
	}
	return
}

// The room's six faces, as polygons
room_faces :: proc() -> (faces: [6]Polygon) {
	lo := Vec3{-ROOM_HALF_WIDTH, 0, 0}
	hi := Vec3{ROOM_HALF_WIDTH, ROOM_HEIGHT, ROOM_DEPTH}
	for axis in 0 ..< 3 {
		u, v := (axis + 1) % 3, (axis + 2) % 3
		for side in 0 ..< 2 {
			f := &faces[2 * axis + side]
			f.n = 4
			for k in 0 ..< 4 {
				p := lo
				p[axis] = lo[axis] if side == 0 else hi[axis]
				p[u] = hi[u] if k == 1 || k == 2 else lo[u]
				p[v] = hi[v] if k >= 2 else lo[v]
				f.points[k] = p
			}
		}
	}
	return
}

// Where on screen the room can be in the shadow of a sphere (c, radius) from a light at l:
// each face clipped to the shadow (a pyramid of SHADOW_FAN sides around the cone from the
// light over the sphere, from the sphere's near side on) and to the front of the camera.
// `everywhere` if the light is inside the sphere.
shadow_extent :: proc(faces: []Polygon, l, c: Vec3, radius: f32) -> (lo, hi: [2]f32, any, everywhere: bool) {
	to := c - l
	d := linalg.length(to)
	if d <= radius * 1.01 {
		return {}, {}, true, true
	}
	w := to / d
	sin_a := radius / d
	cos_a := math.sqrt(1 - sin_a * sin_a)
	u := linalg.normalize(linalg.cross(w, Vec3{0, 1, 0} if abs(w.y) < 0.9 else Vec3{1, 0, 0}))
	v := linalg.cross(w, u)
	cam := room.camera
	// The camera's near plane (first: it drops whole faces), the sphere's near side, then
	// the planes touching the cone along SHADOW_FAN sides (the cone inside them)
	normals: [SHADOW_FAN + 2]Vec3
	limits: [SHADOW_FAN + 2]f32
	normals[0], limits[0] = -cam.fwd, -(linalg.dot(cam.fwd, cam.pos) + 0.05)
	normals[1], limits[1] = -w, -(linalg.dot(w, l) + d - radius)
	for k in 0 ..< SHADOW_FAN {
		angle := f32(k) * math.TAU / SHADOW_FAN
		normals[k + 2] = -sin_a * w + cos_a * (math.cos(angle) * u + math.sin(angle) * v)
		limits[k + 2] = linalg.dot(normals[k + 2], l)
	}
	lo, hi = {math.F32_MAX, math.F32_MAX}, {-math.F32_MAX, -math.F32_MAX}
	for face in faces {
		poly := face
		for k in 0 ..< len(normals) {
			if poly.n == 0 {
				break
			}
			poly = clip_polygon(poly, normals[k], limits[k])
		}
		for p in poly.points[:poly.n] {
			s, _ := project(cam, p)
			lo = linalg.min(lo, s)
			hi = linalg.max(hi, s)
			any = true
		}
	}
	return
}

// The shadow buffer's bins: per occluder, the screen rectangle around where it can shade
// the room from any of lights 0..3 (fx.capsule_shadows: within its bounding sphere grown
// by LIGHT_SIZE of the line to the light)
update_shadow_bins :: proc() {
	eng.profile_scope("shadow bins")
	screen := eng.screen_size()
	faces := room_faces()
	for k in 0 ..< room.occluder_n {
		s := room.occluders[k * fx.CAPSULE3_STRIDE:]
		a, b := Vec3{s[0], s[1], s[2]}, Vec3{s[4], s[5], s[6]}
		radius := s[3] + linalg.distance(a, b) / 2 + LIGHT_SIZE
		lo, hi := [2]f32{math.F32_MAX, math.F32_MAX}, [2]f32{-math.F32_MAX, -math.F32_MAX}
		for k in 0 ..< min(room.lit + 1, 4) { // with the lamp, when it comes among the first four
			l := room.lights[k].pos if k < room.lit else room.lamp.pos
			l_lo, l_hi, any, everywhere := shadow_extent(faces[:], l, (a + b) / 2, radius)
			if everywhere {
				lo, hi = {0, 0}, screen
				break
			}
			if any {
				lo, hi = linalg.min(lo, l_lo), linalg.max(hi, l_hi)
			}
		}
		lo, hi = linalg.clamp(lo, 0, screen), linalg.clamp(hi, 0, screen)
		if lo.x > hi.x || lo.y > hi.y {
			lo, hi = {}, {} // no shadow on screen: listed in the corner cell only
		}
		rect := [fx.CAPSULE_STRIDE]f32{lo.x, lo.y, hi.x, hi.y, 0, 0, 0, 0}
		copy(room.shadow_rects[k * fx.CAPSULE_STRIDE:], rect[:])
	}
	used := eng.bin_shapes(room.shadow_bins[:], room.shadow_rects[:room.occluder_n * fx.CAPSULE_STRIDE], .Capsules, 2, BIN_CELL)
	eng.set_param_array(room.shadow_buffer, "shadow_bins", room.shadow_bins[:used])
}

// The objects into a view's buckets: those beyond the farthest letter, those between it and
// the next, and so on, each bucket ordered far to near and drawn as one instanced quad per
// object, its key placing it between the letters in the sorted layer. The jet divides them
// too (in the camera's view, while there is one; else its key is far beyond everything), and
// in the deep the plants (their own entities in the same layer). Only the stretches holding
// objects take a bucket; past the last one it takes all that is left.
update_buckets :: proc(view: ^View) {
	eng.profile_scope("buckets")
	cam := view.camera
	Far :: struct {
		distance: f32,
		index:    int,
	}
	order := make([dynamic]Far, 0, len(room.objects), context.temp_allocator)
	for o, i in room.objects {
		if shown(o) {
			append(&order, Far{linalg.distance(o.pos, cam.pos), i})
		}
	}
	slice.sort_by(order[:], proc(a, b: Far) -> bool {return a.distance > b.distance})
	dividers := make([dynamic]f32, 0, LOGO_LETTERS + 1 + len(plants), context.temp_allocator)
	for l in room.logo.letters {
		append(&dividers, linalg.distance(l.center, cam.pos))
	}
	append(&dividers, 1e6 if view.mirror else room.jet_key)
	if in_deep() && !view.mirror {
		for p in plants {
			append(&dividers, p.key)
		}
	}
	slice.sort(dividers[:])
	slice.reverse(dividers[:]) // far to near
	shaded := !view.mirror && (room.effects.shadows || room.effects.occlusion)
	records := make([]f32, len(order) * OBJECT_RECORD, context.temp_allocator)
	neighbors := make([]f32, len(order) * NEIGHBORS * fx.CAPSULE3_STRIDE, context.temp_allocator)
	next, used := 0, 0
	for stretch := 0; stretch <= len(dividers) && next < len(order); stretch += 1 {
		// Between dividers[stretch - 1] and dividers[stretch]
		near_end: f32 = dividers[stretch] if stretch < len(dividers) && used < len(view.buckets) - 1 else -1e6
		far_end: f32 = dividers[stretch - 1] if stretch > 0 else 1e6
		if order[next].distance <= near_end {
			continue // nothing between
		}
		id := view.buckets[used]
		used += 1
		first := next
		for next < len(order) && order[next].distance > near_end {
			o := room.objects[order[next].index]
			k := next - first
			corners := sphere_corners(o.pos, o.bound)
			center, size, ok := screen_quad(cam, corners[:])
			if !ok {
				size = {}
			}
			rec := records[k * OBJECT_RECORD:][:OBJECT_RECORD]
			rec[0], rec[1], rec[2], rec[3] = center.x, center.y, size.x / 2, size.y / 2
			rec[4], rec[5], rec[6], rec[7] = o.pos.x, o.pos.y, o.pos.z, o.bound
			for r, j in o.rows {
				data := [3]f32{f32(o.kind), f32(o.pattern), f32(o.mask)}
				rec[8 + 4 * j], rec[9 + 4 * j], rec[10 + 4 * j], rec[11 + 4 * j] = r.x, r.y, r.z, data[j]
			}
			rec[20], rec[21], rec[22], rec[23] = o.size[0], o.size[1], o.size[2], o.size[3]
			rec[24], rec[25], rec[26], rec[27] = o.col_a.x, o.col_a.y, o.col_a.z, o.scale
			rec[28], rec[29], rec[30], rec[31] = o.col_b.x, o.col_b.y, o.col_b.z, o.seed
			rec[32], rec[33], rec[34], rec[35] = o.specular, o.shininess, o.emission, 0
			for nb, j in o.neighbors {
				slot := neighbors[(k * NEIGHBORS + j) * fx.CAPSULE3_STRIDE:][:fx.CAPSULE3_STRIDE]
				if nb >= 0 {
					copy(slot, room.occluders[nb * fx.CAPSULE3_STRIDE:][:fx.CAPSULE3_STRIDE])
				} else {
					copy(slot, far_away[:])
				}
			}
			next += 1
		}
		count := next - first
		eng.set_instances(id, "objects", records[:count * OBJECT_RECORD])
		if shaded {
			eng.set_param_array(id, "neighbors", neighbors[:count * NEIGHBORS * fx.CAPSULE3_STRIDE])
		}
		eng.set_sort_key(id, (near_end + far_end) / 2)
		eng.get_entity(id).visible = true
		set_shared(id, cam, pix = view_pixel(view))
	}
	for id in view.buckets[used:] {
		eng.get_entity(id).visible = false
	}
}

// The size of a view's pixels in screen pixels
view_pixel :: proc(view: ^View) -> f32 {return REFLECTION_DIVISOR if view.mirror else 1}

// A view's letters: quads, distances, where their capsules and cables are, camera, lights and
// nearest objects
update_letters :: proc(view: ^View) {
	for &letter, i in room.logo.letters {
		id := view.letters[i]
		center, size, ok := screen_quad(view.camera, letter.box[:])
		e := eng.get_entity(id)
		e.visible = ok
		e.pos, e.size = center, size
		eng.set_sort_key(id, linalg.distance(letter.center, view.camera.pos))
		set_shared(id, view.camera, pix = view_pixel(view))
		capsules := room.logo.capsules[letter.capsules[0]:][:letter.capsules[1]]
		for c, k in capsules {
			eng.set_param(id, logo_a_names[k], [4]f32{c.a.x, c.a.y, c.a.z, 0})
			eng.set_param(id, logo_b_names[k], [4]f32{c.b.x, c.b.y, c.b.z, 0})
		}
		f := letter.facing
		eng.set_param(id, "facing", [4]f32{f.x, f.y, f.z, 0})
		m := letter.center
		eng.set_param(id, "pivot", [4]f32{m.x, m.y, m.z, 0})
		if !view.mirror && (room.effects.shadows || room.effects.occlusion) {
			values: [NEIGHBORS * fx.CAPSULE3_STRIDE]f32
			for nb, j in letter.neighbors {
				src := room.occluders[nb * fx.CAPSULE3_STRIDE:][:fx.CAPSULE3_STRIDE] if nb >= 0 else far_away[:]
				copy(values[j * fx.CAPSULE3_STRIDE:], src)
			}
			eng.set_param_array(id, "neighbors", values[:])
		}
	}
}

// A view's cables: those in front of the letters, drawn after all of them, and those
// behind, drawn before
update_cables :: proc(view: ^View) {
	near, far := f32(math.F32_MAX), f32(0)
	for letter in room.logo.letters {
		d := linalg.distance(letter.center, view.camera.pos)
		near, far = min(near, d - letter.bound), max(far, d + letter.bound)
	}
	for id, side in view.cables {
		lo := Vec3{math.F32_MAX, math.F32_MAX, math.F32_MAX}
		hi := -lo
		n := 0
		for letter in room.logo.letters {
			for cable, k in letter.cables {
				if (k < FRONT_CABLES) != (side == 0) {
					continue
				}
				eng.set_param(id, cable_a_names[n], [4]f32{cable.at.x, cable.at.y, cable.at.z, 0})
				eng.set_param(id, cable_b_names[n], [4]f32{cable.anchor.x, cable.anchor.y, cable.anchor.z, 0})
				lo = linalg.min(lo, linalg.min(cable.at, cable.anchor) - CABLE_RADIUS)
				hi = linalg.max(hi, linalg.max(cable.at, cable.anchor) + CABLE_RADIUS)
				n += 1
			}
		}
		box: [8]Vec3
		for k in 0 ..< 8 {
			box[k] = {lo.x if k & 1 == 0 else hi.x, lo.y if k & 2 == 0 else hi.y, lo.z if k & 4 == 0 else hi.z}
		}
		center, size, ok := screen_quad(view.camera, box[:])
		e := eng.get_entity(id)
		e.visible = ok
		e.pos, e.size = center, size
		eng.set_sort_key(id, near if side == 0 else far)
		set_shared(id, view.camera, pix = view_pixel(view))
	}
}

update_room :: proc() {
	screen := eng.screen_size()
	e := eng.get_entity(room.room)
	e.pos, e.size, e.visible = screen / 2, screen, true // hide_drowned may hide it after
	set_shared(room.room, room.camera)
	if room.air_buffer >= 0 {
		b := eng.get_entity(room.air_buffer)
		b.pos, b.size, b.visible = screen / 2, screen, true
		set_camera(room.air_buffer, room.camera, 0)
		if room.effects.haze {
			eng.set_param_array(room.air_buffer, "lights", room.light_values[:])
			eng.set_param(room.air_buffer, "light_count", f32(room.lit))
		}
		if room.effects.occlusion {
			eng.set_param_array(room.air_buffer, "occluders", room.occluders[:room.occluder_n * fx.CAPSULE3_STRIDE])
			eng.set_param(room.air_buffer, "occluder_count", f32(room.occluder_n))
		}
	}
	if room.shadow_buffer >= 0 {
		b := eng.get_entity(room.shadow_buffer)
		b.pos, b.size, b.visible = screen / 2, screen, true
		set_shared(room.shadow_buffer, room.camera, lit = false)
		eng.set_param_array(room.shadow_buffer, "occluders", room.occluders[:room.occluder_n * fx.CAPSULE3_STRIDE])
		eng.set_param(room.shadow_buffer, "occluder_count", f32(room.occluder_n))
	}
}

handle_keys :: proc() {
	rebuild := false
	if rl.IsKeyPressed(.UP) && room.light_count < MAX_LIGHTS - 1 { // the lamp takes the last
		room.light_count += 1 // only a param: no rebuild
	}
	if rl.IsKeyPressed(.DOWN) && room.light_count > 1 {
		room.light_count -= 1
	}
	if rl.IsKeyPressed(.RIGHT) && room.object_count < MAX_OBJECTS {
		room.object_count = min(random_objects() + 8, MAX_OBJECTS)
		rebuild = true
	}
	if rl.IsKeyPressed(.LEFT) && room.object_count > 8 {
		room.object_count = max(random_objects() - 8, 8)
		rebuild = true
	}
	if rl.IsKeyPressed(.R) {
		room.seed = u64(rand.int63())
		rebuild = true
	}
	toggles := [5]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR, .FIVE}
	flags := [5]^bool{&room.effects.shadows, &room.effects.occlusion, &room.effects.haze, &room.effects.reflections, &room.effects.bloom}
	for key, i in toggles {
		if rl.IsKeyPressed(key) {
			flags[i]^ = !flags[i]^
			rebuild = true
		}
	}
	if rl.IsKeyPressed(.SPACE) {
		#partial switch room.stage {
		case .Waiting:
			room.stage, room.stage_time, room.scene_time = .Playing, 0, 0
		case .Ended:
			room.stage, room.stage_time, room.flood_time = .Flooding, 0, 0
		case .Flooded:
			room.stage, room.stage_time, room.deep_time = .Deep, 0, 0
		case .Deep:
			if room.deep_time >= deep_first_circle() {
				room.stage, room.stage_time = .Closing, 0
			}
		}
	}
	if rl.IsKeyPressed(.C) {
		room.clock_running = !room.clock_running
	}
	if rl.IsKeyPressed(.ESCAPE) {
		eng.quit()
	}
	if rebuild {
		build_room()
	}
}

// The sequence: the scene's clock runs while it plays; the end holds the last frame; Space
// goes on to the transition (flood.odin), which ends under water; the black fades in after
// Space and out before the demo closes; the hint says what Space does
update_stage :: proc(dt: f32) {
	room.stage_time += dt
	switch room.stage {
	case .Waiting, .Ended:
	case .Playing:
		if room.clock_running {
			room.scene_time += dt
		}
		if !room.autoplay && room.scene_time >= SCENE1_LENGTH {
			room.scene_time = SCENE1_LENGTH // back at the start of its flight
			room.stage, room.stage_time = .Ended, 0
		}
	case .Flooding, .Flooded:
		room.flood_time += dt
		if room.stage == .Flooding && room.flood_time >= transition_length() {
			if room.autoplay {
				room.flood_time = 0 // again
			} else {
				room.stage, room.stage_time = .Flooded, 0
			}
		}
		if room.stage == .Flooded && room.autoplay && room.stage_time >= AUTO_CONTINUE {
			room.stage, room.stage_time, room.deep_time = .Deep, 0, 0 // ROOM_PART=deep
		}
	case .Deep:
		room.deep_time += dt // round and round
	case .Closing:
		if room.stage_time >= FADE_SECONDS {
			eng.quit()
		}
	}
	fade: f32
	switch room.stage {
	case .Waiting:
		fade = 1
	case .Playing:
		fade = 0 if room.autoplay else 1 - math.saturate(room.stage_time / FADE_SECONDS)
	case .Ended, .Flooding, .Flooded, .Deep:
		fade = 0
	case .Closing:
		fade = math.saturate(room.stage_time / FADE_SECONDS)
	}
	screen := eng.screen_size()
	e := eng.get_entity(room.fade)
	e.pos, e.size, e.visible = screen / 2, screen, fade > 0
	eng.set_param(room.fade, "fade", fade)
	h := eng.get_entity(room.hint)
	h.pos = screen / 2
	hint := ""
	#partial switch room.stage {
	case .Waiting:
		hint = "Press Space to start"
	case .Ended:
		hint = "Press Space to continue"
	case .Flooded:
		hint = "Press Space to continue"
	case .Deep:
		if room.deep_time >= deep_first_circle() {
			hint = "Press Space to exit"
			h.pos.y = screen.y * 0.88 // under the scene going on
		}
	}
	eng.set_text(room.hint, hint)
	// The lights are on until they go out in the transition
	room.lit = room.light_count
	if transition_time() >= LIGHTS_OUT + LIGHT_FADE || in_deep() {
		room.lit = 0
	}
}

on_update :: proc(dt: f32) {
	handle_keys()
	t := eng.time()
	update_stage(dt)
	if in_deep() {
		update_deep(t)
		update_text()
		return
	}
	hide_deep()
	room.camera = camera_at(room.scene_time)
	if tau := transition_time(); tau >= 0 {
		room.camera = flood_camera(tau)
	}
	room.views[0].camera, room.views[1].camera = room.camera, mirrored(room.camera)
	update_logo(t)
	update_objects(t)
	update_lights(t)
	update_flood()
	update_occluders()
	for &view in room.views {
		if view.on {
			update_buckets(&view)
			update_letters(&view)
			update_cables(&view)
		}
	}
	update_room()
	update_text()
	hide_drowned()
}

// Saves light_room.png once the scene time reaches ROOM_SHOT seconds, then quits
take_shot :: proc() {
	if room.shot_at > 0 && f64(eng.time()) >= room.shot_at {
		rl.BeginScissorMode(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight()) // draws the batched text
		rl.TakeScreenshot("light_room.png")
		os.exit(0)
	}
}

parse_size :: proc(s: string) -> (w, h: i32, ok: bool) {
	parts := strings.split(s, "x", context.temp_allocator)
	if len(parts) != 2 {
		return
	}
	pw, okw := strconv.parse_int(parts[0])
	ph, okh := strconv.parse_int(parts[1])
	return i32(pw), i32(ph), okw && okh && pw > 0 && ph > 0
}

env_int :: proc(name: string, default, lo, hi: int) -> int {
	if v, ok := strconv.parse_int(os.get_env(name, context.temp_allocator)); ok {
		return clamp(v, lo, hi)
	}
	return default
}

main :: proc() {
	width, height: i32 = 1280, 720
	if w, h, ok := parse_size(os.get_env("ROOM_SIZE", context.temp_allocator)); ok {
		width, height = w, h
	}
	room.seed = u64(time.now()._nsec % 1_000_000_000)
	if os.get_env("ZSE_PROFILE_SECONDS", context.temp_allocator) != "" {
		room.seed = BENCH_SEED
	}
	if s, ok := strconv.parse_u64(os.get_env("ROOM_SEED", context.temp_allocator)); ok {
		room.seed = s
	}
	room.object_count = env_int("ROOM_OBJECTS", DEFAULT_OBJECTS, 1, MAX_OBJECTS)
	room.light_count = env_int("ROOM_LIGHTS", DEFAULT_LIGHTS, 1, MAX_LIGHTS - 1)
	room.lit = room.light_count
	room.clock_running = os.get_env("ROOM_CAMERA", context.temp_allocator) != "still"
	room.autoplay = os.get_env("ZSE_PROFILE_SECONDS", context.temp_allocator) != "" || os.get_env("ROOM_SHOT", context.temp_allocator) != ""
	room.stage = .Playing if room.autoplay else .Waiting
	switch os.get_env("ROOM_PART", context.temp_allocator) {
	case "flood":
		// Straight into the transition (benchmarks and screenshots loop it)
		room.stage, room.scene_time = .Flooding, SCENE1_LENGTH
	case "deep":
		// Straight to the bubble screen before scene 2 (with autoplay, on after AUTO_CONTINUE;
		// scene 2 loops)
		room.stage, room.scene_time, room.flood_time = .Flooded, SCENE1_LENGTH, transition_length()
	}
	room.effects = {
		shadows     = os.get_env("ROOM_SHADOWS", context.temp_allocator) != "off",
		occlusion   = os.get_env("ROOM_AO", context.temp_allocator) != "off",
		haze        = os.get_env("ROOM_HAZE", context.temp_allocator) == "on",
		reflections = os.get_env("ROOM_REFLECTIONS", context.temp_allocator) != "off",
		bloom       = os.get_env("ROOM_BLOOM", context.temp_allocator) != "off",
	}

	eng.init_context(
		eng.InitOptions {
			width = width,
			height = height,
			vsync = .Off if os.get_env("ROOM_VSYNC", context.temp_allocator) == "off" else .On,
			title = "Light Room",
			num_layers = LAYER_COUNT,
			bg_color = BACKGROUND,
			resizable = true,
			match_window = true,
			bake_constants = true, // looks differ by params, never by constants
		},
	)
	if os.get_env("ROOM_FULLSCREEN", context.temp_allocator) != "off" {
		monitor := -1 // the one the window is on (on Wayland raylib can't tell: the first)
		if name := os.get_env("ROOM_MONITOR", context.temp_allocator); name != "" {
			if monitor = eng.find_monitor(name); monitor < 0 {
				fmt.eprintfln("ROOM_MONITOR=%s: no such monitor; there are:", name)
				for i in 0 ..< rl.GetMonitorCount() {
					fmt.eprintfln("  %d  %s  %dx%d", i, rl.GetMonitorName(i), rl.GetMonitorWidth(i), rl.GetMonitorHeight(i))
				}
			}
		}
		eng.fill_monitor(monitor)
	}
	eng.set_layer_buffer(LAYER_SHADOW_BUFFER, SHADOW_BUFFER_DIVISOR)
	eng.set_layer_buffer(LAYER_AIR_BUFFER, AIR_BUFFER_DIVISOR)
	eng.set_layer_sorted(LAYER_OBJECTS, true)
	eng.set_layer_resolution(LAYER_SEA, BACKDROP_DIVISOR)
	for layer, i in JELLY_LAYERS {
		// Drawn small and stretched, which blurs it, then added as light (softened first by a
		// Gaussian of 1.2 small pixels, as AlgoGame's blur filter)
		eng.set_layer_resolution(LAYER_JELLY + i, layer.blur, layer.alpha, 1.2)
	}
	eng.set_layer_resolution(LAYER_REFLECTION, REFLECTION_DIVISOR, 1, REFLECTION_BLUR)
	eng.set_layer_sorted(LAYER_REFLECTION, true)
	init_param_names()
	build_room()
	if s, ok := strconv.parse_f64(os.get_env("ROOM_SHOT", context.temp_allocator)); ok {
		room.shot_at = s
		eng.set_overlay(take_shot)
	}
	eng.run(on_update)
}
