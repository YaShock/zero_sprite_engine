package main

// The transition from scene 1 to the flooded room (Stage.Flooding), all of it a function of
// the seconds since it began (room.flood_time), so a screenshot or a benchmark sees the same
// frame at the same time. The camera stays where scene 1 left it.
//
//   0 .. BURST         the hatch's lid rattles harder and harder, water squirting from the gap
//                      round it; the flying lights stop, flicker for LIGHTS_OUT seconds and go
//                      out (the lamp stays: it moves to the front of the light list and casts
//                      the shadows from then on)
//   BURST              the lid is thrown off towards the far left corner (barely up: it is
//                      heavy), turning over, and lands upside down and slides; a jet of murky
//                      seawater shoots up out of the opening and hits the ceiling, where it
//                      spreads and runs down the walls and falls as rain
//                      (the camera zooms in on the lid, then arcs out round the jet:
//                      flood_camera)
//   + FLOOD_DELAY      a sheet of water spreads over the floor from the hatch, its front
//                      foaming; once the camera has stopped, the room floods (up to the
//                      ceiling, steadily) and the water climbs up over the camera's
//                      lens (LENS_HALF above and below its middle), bubbling
//   covered + UNDER_HOLD   the transition ends, under water (Stage.Flooded)
//
// The looks are in water_looks.odin; every lit look reads the param `water`.

import eng "../../engine"
import fx "../../engine/vfx"
import "core:math"
import "core:math/linalg"
import "core:slice"

BURST :: 4 // seconds of rattling before the lid flies
LIGHTS_OUT :: 2 // seconds of flickering before the lights go out
LIGHT_FADE :: 0.15 // seconds of going out
LIGHT_STOP :: 0.3 // the lights' flight slows to a stop over about this many seconds
LEAK_START :: 1.6 // water starts squirting round the rattling lid
EYE_ADAPT :: 0.8 // the exposure rises by this share as the eye gets used to the lamp alone

// The lid's flight: from its place to LID_REST, LID_FLIGHT of the way through the air in
// LID_AIRBORNE seconds (its middle up to LID_PEAK, or higher where it must be to clear the
// floor), turning over (a half-turn round the axis across its way: the jet lifts its
// trailing edge) and turning by LID_SPIN degrees a second round the vertical; then it lands
// on its other side, on the handwheel, and slides to a stop. LID_REST keeps it clear of the
// logo's cables; objects keep clear of its path (place_objects).
LID_HOME :: Vec3{ROOM_CENTER.x, 0.035, ROOM_CENTER.z} // its middle, on the hatch
LID_REST :: Vec3{-4, 0.035, 7.6}
LID_FLIGHT :: 0.5
LID_AIRBORNE :: 1.1
LID_PEAK :: 0.35
LID_SPIN :: 60
LID_PARTS :: 17 // the lid, the hub, the wheel and its spokes, the rivets (place_hatch)
LID_HALF :: 0.035 // half the lid's thickness
LID_WHEEL :: 0.157 // how far the handwheel's top stands above the lid's middle
LID_WHEEL_RADIUS :: 0.32
RATTLE_PACE :: 0.6 // how fast it rattles (1: the first version's pace)
RATTLE_TILT :: 9 // degrees it rocks by at most, on its edge
RATTLE_HOP :: 0.05 // meters it hops by at most
RATTLE_TWIST :: 3 // degrees it twists by at most
GRAVITY :: 9.81

// The jet: JET_RADIUS at the floor (the opening), JET_FLARE wider at the ceiling, rising at
// JET_SPEED; its water spreads over the ceiling at CEILING_SPREAD, runs down the walls at
// FILM_SPEED and falls as rain at RAIN_SPEED
JET_RADIUS :: 0.6
JET_FLARE :: 0.5
JET_BELL :: 0.9 // over the last this many meters below the ceiling it spreads out
JET_BELL_SPREAD :: 1.1 // by this many meters more
JET_STEPS :: 10 // steps marching in to where a ray enters the jet (jet_look)
JET_SPEED :: 16
JET_MURK :: 9 // how quickly light dies in the jet, per meter
WATER_SCATTER :: 0.06 // the lamp's light aerated water scatters every way (times its color), wherever it faces
CEILING_SPREAD :: 5
FILM_SPEED :: 2.5
RAIN_SPEED :: 6

// The flood: FLOOD_DELAY seconds after the burst (the jet's water first goes up) a sheet of
// water SHEET_DEPTH deep spreads over the floor from the hatch, its front at FRONT_SPEED
// after FRONT_DELAY, sloping down over FRONT_SLOPE; once the camera has stopped
// (rise_after) the level rises steadily (the jet pours in at a constant rate) at RISE_SPEED,
// taking LENS_CROSSING seconds to climb over the lens, waves and all. Light dies in the water
// at WATER_MURK per meter.
FLOOD_DELAY :: 1
SHEET_DEPTH :: 0.03
LENS_CROSSING :: 1.5
RISE_SPEED :: (1 + LENS_WAVE) * 2 * LENS_HALF / LENS_CROSSING // meters a second
FRONT_SPEED :: 3.5
FRONT_DELAY :: 0.2
FRONT_SLOPE :: 0.8
WATER_MURK :: 4
FOAM_PERIOD :: 2 // the flood's foam pattern spreads out from the jet by FOAM_SPREAD (log of the scale) every FOAM_PERIOD seconds
FOAM_SPREAD :: 0.7

// The lens: covered from the bottom up as the water rises from LENS_HALF below its middle
// to LENS_HALF above (its waterline waving by LENS_WAVE of the screen); the transition ends
// UNDER_HOLD seconds after it is wholly under
LENS_HALF :: 0.35
LENS_WAVE :: 0.12
UNDER_HOLD :: 1.5

// Spray: drops squirting round the rattling lid, thrown out by the burst, shed by the jet
MAX_DROPS :: 160
LEAK_DROPS :: 24
BURST_DROPS :: 64
DROP_RECORD :: 12 // quad | a.xyz, radius | b.xyz, foam (drops_look)
DROP_BLUR :: 0.012 // seconds of motion each drop is drawn smeared over
DROP_NEAREST :: 2 // drops nearer the camera than this would have hit the lens: not drawn

// Seconds into the transition, or -1 outside it
transition_time :: proc() -> f32 {
	return room.flood_time if room.stage == .Flooding || room.stage == .Flooded else -1
}

// s seconds after the burst
water_level :: proc(s: f32) -> f32 {
	sheet := SHEET_DEPTH * math.smoothstep(f32(FLOOD_DELAY), FLOOD_DELAY + 1, s)
	rising := s - rise_after()
	if rising <= 0 {
		return sheet
	}
	return max(sheet, min(rising * RISE_SPEED, ROOM_HEIGHT))
}

front_radius :: proc(s: f32) -> f32 {return max(s - FLOOD_DELAY - FRONT_DELAY, 0) * FRONT_SPEED}

// The waterline on the lens (0 its bottom, 1 its top) s seconds after the burst
lens_line :: proc(s: f32) -> f32 {
	bottom := room.camera.pos.y - LENS_HALF
	return (water_level(s) - bottom) / (2 * LENS_HALF)
}

// Seconds after the burst at which the lens is wholly under, waves and all (the camera
// stands where its arc ended by then)
covered_after :: proc() -> f32 {
	h := f32(ARC_END_HEIGHT - LENS_HALF + (1 + LENS_WAVE) * 2 * LENS_HALF)
	return rise_after() + h / RISE_SPEED
}

transition_length :: proc() -> f32 {return BURST + covered_after() + UNDER_HOLD}

// The camera in the transition, with a first-person touch: as the lid is thrown it zooms in
// on it (narrowing to ZOOM_FOV in ZOOM_IN seconds, moving ZOOM_DOLLY towards it) and follows
// it; HOLD_SECONDS after it lies still it zooms out in an arc, in ARC_SECONDS (arc_position):
// ARC_DEGREES round the jet, onto the line from the room's near left corner to the jet,
// sliding down to ARC_END_HEIGHT, turning to the right towards the jet and tilting up at it
// (ARC_LOOK, widening to ARC_END_FOV), so that the jet is seen from the floor to where it
// hits the ceiling. A slight hand-held sway while it is off its tripod, so to speak. It then
// stays still, looking up, and only then does the water rise (rise_after).
ZOOM_FOV :: 24
ZOOM_IN :: 0.8
ZOOM_DOLLY :: 0.5
HOLD_SECONDS :: 0.4
ARC_SECONDS :: 3
ARC_DEGREES :: 45 // the near left corner's line through the hatch
ARC_END_HEIGHT :: 1
ARC_END_FOV :: 60
ARC_LOOK :: Vec3{ROOM_CENTER.x, 2, ROOM_CENTER.z} // the jet, seen tilted up by about 14 degrees
SWAY :: 0.015 // meters

// Seconds after the burst at which the lid lies still (lid_pose)
lid_stops_after :: proc() -> f32 {
	total := linalg.length(LID_REST.xz - LID_HOME.xz)
	fly := LID_FLIGHT * total
	return LID_AIRBORNE + 2 * (total - fly) / (fly / LID_AIRBORNE) // sliding at an even deceleration
}

arc_starts_after :: proc() -> f32 {return lid_stops_after() + HOLD_SECONDS}

rise_after :: proc() -> f32 {return arc_starts_after() + ARC_SECONDS}

// Where the arc has taken the camera at u (0..1): round the hatch at scene 1's orbit radius,
// from where scene 1 ended, sliding down; objects keep clear of it (place_objects)
arc_position :: proc(u: f32) -> Vec3 {
	angle := -f32(ARC_DEGREES) * math.RAD_PER_DEG * u // to the left
	height := math.lerp(f32(CAMERA_HEIGHT), ARC_END_HEIGHT, u)
	return ROOM_CENTER + Vec3{ORBIT_RADIUS * math.sin(angle), height, -ORBIT_RADIUS * math.cos(angle)}
}

flood_camera :: proc(tau: f32) -> Camera {
	ease :: proc(x: f32) -> f32 {
		x := math.saturate(x)
		return x * x * x * (x * (6 * x - 15) + 10)
	}
	start := camera_at(SCENE1_LENGTH)
	s := tau - BURST
	if s <= 0 {
		return start
	}
	lid, _ := lid_pose(tau)
	zoom := ease(s / ZOOM_IN)
	arc := ease((s - arc_starts_after()) / ARC_SECONDS)
	toward := lid - start.pos
	toward.y = 0
	near := start.pos + linalg.normalize(toward) * ZOOM_DOLLY * zoom
	pos := math.lerp(near, arc_position(arc), arc)
	aim := math.lerp(math.lerp(CAMERA_LOOK_AT, lid, zoom), ARC_LOOK, arc)
	fov := math.lerp(math.lerp(f32(CAMERA_FOV), ZOOM_FOV, zoom), ARC_END_FOV, arc)
	held := zoom * (1 - arc)
	sway := Vec3{noise1(tau * 0.9, 3), noise1(tau * 0.8, 4), noise1(tau * 0.7, 5)} - 0.5
	pos += sway * (2 * SWAY * held)
	aim += sway.zxy * (6 * SWAY * held)
	return camera_looking(pos, aim, fov)
}

// A random number in 0..1 from three integers, the same every time
rnd :: proc(a, b, c: int) -> f32 {
	h := u32(a) * 0x9E3779B1 ~ u32(b) * 0x85EBCA77 ~ u32(c) * 0xC2B2AE3D
	h ~= h >> 15
	h *= 0x2C1B3C6D
	h ~= h >> 12
	h *= 0x297A2D39
	h ~= h >> 15
	return f32(h >> 8) / f32(1 << 24)
}

// Smooth noise in 0..1 along one dimension (per `seed`)
noise1 :: proc(x: f32, seed: int) -> f32 {
	i := int(math.floor(x))
	f := x - f32(i)
	f = f * f * (3 - 2 * f)
	return math.lerp(rnd(i, seed, 77), rnd(i + 1, seed, 77), f)
}

// How bright flying light i is `tau` seconds into the transition: flickering deeper and more
// often, then going out
shimmer :: proc(i: int, tau: f32) -> f32 {
	if tau < 0 {
		return 1
	}
	if tau >= LIGHTS_OUT + LIGHT_FADE {
		return 0
	}
	k := math.saturate(tau / LIGHTS_OUT)
	n := noise1(tau * 18, i)
	b := 1 - 0.7 * k * n
	if noise1(tau * 9, i + 50) > 1 - 0.4 * k {
		b *= 0.12 // dropping out
	}
	if tau > LIGHTS_OUT {
		b *= 1 - (tau - LIGHTS_OUT) / LIGHT_FADE
	}
	return b
}

// The lid `tau` seconds into the transition: its middle, and how it is turned
lid_pose :: proc(tau: f32) -> (pos: Vec3, turn: matrix[3, 3]f32) {
	up := Vec3{0, 1, 0}
	rad :: math.RAD_PER_DEG
	if tau < BURST {
		// Rattling: rocking on its edge round a wandering axis and hopping, harder and harder
		a := tau / BURST
		a *= a
		r := tau * RATTLE_PACE
		around := 1.7 * r + 0.8 * math.sin(r * 5.3)
		axis := Vec3{math.cos(around), 0, math.sin(around)}
		rock := 0.5 + 0.5 * math.sin(r * 23 + 2 * math.sin(r * 4.3))
		tilt := a * RATTLE_TILT * rad * rock
		hop := a * RATTLE_HOP * math.pow(max(math.sin(r * 13.7) * math.sin(r * 7.3), 0), 2)
		twist := a * RATTLE_TWIST * rad * math.sin(r * 6.1)
		turn = linalg.matrix3_rotate_f32(tilt, axis) * linalg.matrix3_rotate_f32(twist, up)
		pos = LID_HOME + {0, HATCH_LID * math.sin(tilt) + hop, 0}
		return
	}
	s := tau - BURST
	way := LID_REST - LID_HOME
	way.y = 0
	total := linalg.length(way)
	way /= total
	flip_axis := linalg.cross(up, way) // turning its trailing edge up and over
	fly := LID_FLIGHT * total
	speed := fly / LID_AIRBORNE
	flip, spin, along, lift: f32
	if s < LID_AIRBORNE {
		u := s / LID_AIRBORNE
		along = speed * s
		lift = LID_PEAK * 4 * u * (1 - u)
		flip = math.PI * u * u * (3 - 2 * u)
		spin = LID_SPIN * rad * s
	} else {
		// Sliding to a stop on its handwheel, clanging as it lands
		u := s - LID_AIRBORNE
		slide := total - fly
		decel := speed * speed / (2 * slide)
		u = min(u, speed / decel)
		along = fly + speed * u - decel / 2 * u * u
		after := s - LID_AIRBORNE
		flip = math.PI + 5 * rad * math.exp(-after * 5) * math.sin(after * 22)
		spin = LID_SPIN * rad * (LID_AIRBORNE + (along - fly) / speed)
	}
	// Its middle high enough that nothing goes through the floor: the lid's rim, or upside
	// down its handwheel
	c, sn := math.cos(flip), abs(math.sin(flip))
	floor_clear := max(HATCH_LID * sn + LID_HALF * abs(c), LID_WHEEL_RADIUS * sn - LID_WHEEL * c)
	turn = linalg.matrix3_rotate_f32(flip, flip_axis) * linalg.matrix3_rotate_f32(spin, up)
	pos = LID_HOME + way * along + {0, max(lift, floor_clear) - LID_HALF, 0}
	return
}

// Where the lid's parts are this frame (they are props: update_objects leaves them be)
place_lid :: proc(tau: f32) {
	pos, turn := LID_HOME, linalg.MATRIX3F32_IDENTITY
	if tau >= 0 {
		pos, turn = lid_pose(tau)
	}
	for &o in room.objects[room.lid_first:][:LID_PARTS] {
		o.pos = pos + turn * (o.center - LID_HOME)
		m := turn * linalg.matrix3_rotate_f32(o.spin_phase, o.axis)
		for i in 0 ..< 3 {
			o.rows[i] = {m[0, i], m[1, i], m[2, i]}
		}
	}
}

// A drop of spray `tau` seconds into the transition: where it is, how fast it goes, how big
// it is, how foamy; ok = false if it isn't flying (not yet, or it fell back into the water)
drop_at :: proc(slot: int, tau: f32) -> (p, v: Vec3, r, foam: f32, ok: bool) {
	s := tau - BURST
	p0, v0: Vec3
	age: f32
	switch {
	case slot < LEAK_DROPS:
		// Squirting from the gap round the rattling lid, more and more often
		period := 0.3 + 0.3 * rnd(slot, 0, 1)
		phase := period * rnd(slot, 0, 2)
		if tau < phase {
			return
		}
		cycle := int((tau - phase) / period)
		t0 := phase + f32(cycle) * period
		if t0 < LEAK_START || t0 >= BURST || rnd(slot, cycle, 3) > (t0 - LEAK_START) / (BURST - LEAK_START) {
			return
		}
		age = tau - t0
		angle := math.TAU * rnd(slot, cycle, 4)
		out := Vec3{math.cos(angle), 0, math.sin(angle)}
		p0 = ROOM_CENTER + out * (HATCH_LID + 0.01) + {0, 0.06, 0}
		v0 = out * (0.3 + 0.9 * rnd(slot, cycle, 5)) + {0, 1.2 + 1.8 * rnd(slot, cycle, 6), 0}
		r = 0.005 + 0.007 * rnd(slot, cycle, 7)
		foam = 0.3
	case slot < LEAK_DROPS + BURST_DROPS:
		// Thrown out round the opening as the lid goes, once
		t0 := 0.2 * rnd(slot, 0, 1) * rnd(slot, 0, 2)
		if s < t0 {
			return
		}
		age = s - t0
		angle := math.TAU * rnd(slot, 0, 3)
		out := Vec3{math.cos(angle), 0, math.sin(angle)}
		p0 = ROOM_CENTER + out * (JET_RADIUS * (0.8 + 0.3 * rnd(slot, 0, 4))) + {0, 0.1 + 0.5 * rnd(slot, 0, 5), 0}
		v0 = out * (1.5 + 4.5 * rnd(slot, 0, 6)) + {0, 2 + 5 * rnd(slot, 0, 7), 0}
		r = 0.008 + 0.018 * rnd(slot, 0, 8)
		foam = rnd(slot, 0, 9)
	case:
		// Shed by the jet: torn off its side and thrown out in an arc
		period := 0.6 + 0.5 * rnd(slot, 0, 1)
		phase := period * rnd(slot, 0, 2)
		if s < phase {
			return
		}
		cycle := int((s - phase) / period)
		t0 := phase + f32(cycle) * period
		if t0 < 0.08 {
			return
		}
		age = s - t0
		y := 0.3 + 2.4 * rnd(slot, cycle, 3)
		angle := math.TAU * rnd(slot, cycle, 4)
		out := Vec3{math.cos(angle), 0, math.sin(angle)}
		p0 = ROOM_CENTER + out * (JET_RADIUS * (1 + JET_FLARE * y / ROOM_HEIGHT)) + {0, y, 0}
		v0 = out * (0.8 + 2.2 * rnd(slot, cycle, 5)) + {0, 2 + 4 * rnd(slot, cycle, 6), 0}
		r = 0.006 + 0.014 * rnd(slot, cycle, 7)
		foam = 0.6 * rnd(slot, cycle, 8)
	}
	p = p0 + v0 * age + {0, -GRAVITY / 2 * age * age, 0}
	v = v0 + {0, -GRAVITY * age, 0}
	inside := abs(p.x) < ROOM_HALF_WIDTH && p.z > 0 && p.z < ROOM_DEPTH && p.y < ROOM_HEIGHT
	ok = inside && p.y > max(water_level(s), 0.0)
	return
}

// The transition's things this frame (the lid is place_lid's, from update_objects): the water
// every lit look reads, the jet, the spray (behind the jet and in front of it), the lens
update_flood :: proc() {
	tau := transition_time()
	s := tau - BURST
	room.water = {}
	if tau >= 0 && s >= 0 {
		room.water = {water_level(s), front_radius(s), s, 1}
	}
	cam := room.camera
	// The jet: between the drawing buckets at its distance (update_buckets)
	jet := eng.get_entity(room.jet)
	jet.visible = false
	room.jet_key = 1e6
	if tau >= 0 && s >= 0 {
		head := min(s * JET_SPEED, ROOM_HEIGHT)
		reach := f32(JET_RADIUS * (1 + JET_FLARE) * 1.3) + (1 if head >= ROOM_HEIGHT else 0)
		box: [8]Vec3
		for k in 0 ..< 8 {
			box[k] = ROOM_CENTER + {reach if k & 1 != 0 else -reach, head if k & 2 != 0 else 0, reach if k & 4 != 0 else -reach}
		}
		center, size, ok := screen_quad(cam, box[:])
		jet.visible = ok
		jet.pos, jet.size = center, size
		axis := Vec3{ROOM_CENTER.x, math.clamp(cam.pos.y, 0, head), ROOM_CENTER.z}
		room.jet_key = linalg.distance(cam.pos, axis)
		eng.set_sort_key(room.jet, room.jet_key)
		set_shared(room.jet, cam)
		eng.set_param(room.jet, "jet", [4]f32{head, s, 0, 0})
	}
	update_drops(tau)
	line := lens_line(s) if tau >= 0 else -1
	set_lens(line, max(s, 0), 1e6, 0, line > -LENS_WAVE * 2)
}

update_drops :: proc(tau: f32) {
	Far :: struct {
		distance: f32,
		values:   [DROP_RECORD]f32,
	}
	sides: [2][dynamic]Far
	for &side in sides {
		side = make([dynamic]Far, context.temp_allocator)
	}
	cam := room.camera
	if tau >= LEAK_START {
		for slot in 0 ..< MAX_DROPS {
			p, v, r, foam, ok := drop_at(slot, tau)
			if !ok || linalg.distance(p, cam.pos) < DROP_NEAREST {
				continue
			}
			smear := v * DROP_BLUR
			if linalg.length(smear) < 0.003 {
				smear = {0, 0.003, 0}
			}
			b := p - smear
			corners := sphere_corners((p + b) / 2, linalg.length(smear) / 2 + r)
			center, size, in_view := screen_quad(cam, corners[:])
			if !in_view {
				continue
			}
			d := linalg.distance(cam.pos, p)
			append(&sides[0 if d > room.jet_key else 1], Far{d, {center.x, center.y, size.x / 2, size.y / 2, p.x, p.y, p.z, r, b.x, b.y, b.z, foam}})
		}
	}
	for &side, k in sides {
		slice.sort_by(side[:], proc(a, b: Far) -> bool {return a.distance > b.distance})
		records := make([]f32, len(side) * DROP_RECORD, context.temp_allocator)
		for &d, i in side {
			copy(records[i * DROP_RECORD:], d.values[:])
		}
		id := room.drops[k]
		eng.set_instances(id, "drops", records)
		eng.get_entity(id).visible = len(side) > 0
		eng.set_sort_key(id, room.jet_key + (0.01 if k == 0 else -0.01))
		set_shared(id, cam)
	}
}

// Hides what can no longer be seen: the reflection once the whole floor is under water,
// everything but the lens once the lens is wholly under (a view's update shows its things
// again every frame, so this comes last)
hide_drowned :: proc() {
	tau := transition_time()
	if tau < 0 {
		return
	}
	s := tau - BURST
	floor_gone := s > 0 && front_radius(s) > math.sqrt(f32(ROOM_HALF_WIDTH * ROOM_HALF_WIDTH + ROOM_DEPTH * ROOM_DEPTH / 4)) + FRONT_SLOPE
	lens_under := s > covered_after()
	for &view in room.views {
		if !view.on || !(lens_under || (view.mirror && floor_gone)) {
			continue
		}
		for id in view.buckets {
			eng.get_entity(id).visible = false
		}
		for id in view.letters {
			eng.get_entity(id).visible = false
		}
		for id in view.glows {
			eng.get_entity(id).visible = false
		}
		for id in view.cables {
			eng.get_entity(id).visible = false
		}
	}
	if lens_under {
		for id in ([?]int{room.room, room.shadow_buffer, room.air_buffer, room.jet, room.drops[0], room.drops[1]}) {
			if id >= 0 {
				eng.get_entity(id).visible = false
			}
		}
	}
}

// The exposure every lit look uses: more lights add up to more light, so keep the room about
// as bright as with 4; once they have gone out, the eye gets used to the dark (EYE_ADAPT), and
// stays so in the deep
exposure :: proc() -> f32 {
	if in_deep() {
		return DEEP_EXPOSURE
	}
	adapt := math.smoothstep(f32(LIGHTS_OUT), LIGHTS_OUT + 1.5, transition_time())
	return math.sqrt(4 / f32(room.light_count)) * (1 + EYE_ADAPT * adapt)
}

// The lens over the screen: its waterline, the bubbles' clock, when their stream stops and
// how clear the murk has become (lens_look)
set_lens :: proc(line, s, stream_end, clear: f32, visible: bool) {
	lens := eng.get_entity(room.lens)
	lens.visible = visible
	screen := eng.screen_size()
	lens.pos, lens.size = screen / 2, screen
	eng.set_param(room.lens, "lens", [4]f32{line, s, stream_end, clear})
	eng.set_param(room.lens, "exposure", exposure())
}
