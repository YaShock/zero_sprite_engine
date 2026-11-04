package engine

import "base:intrinsics"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

Vector2 :: rl.Vector2
Color :: rl.Color
Rectangle :: rl.Rectangle

VSync :: enum {
	// On, unless it holds the game below its target FPS (e.g. fps = 144 on a 60 Hz monitor);
	// then frames are paced by the engine's own limiter instead. Off when fps is 0.
	Auto,
	On, // never faster than the monitor's refresh rate
	Off,
}

InitOptions :: struct {
	width, height: i32, // virtual resolution; the window letterboxes it at any size
	fps:           i32, // target frame rate; 0 = unlimited
	vsync:         VSync,
	title:         string,
	num_layers:    int,
	bg_color:      Color, // letterbox bars
	show_fps:      bool,
	resizable:     bool,
	match_window:  bool, // virtual resolution follows the window at 1:1 (for tools)
	// Don't remember compiled shaders across runs (see shader_manifest.odin); for tools that
	// compile many throwaway shaders.
	no_shader_manifest: bool,
	// Constants in looks become literals in their shaders (see vfx.compile): faster shaders,
	// but looks that differ only in a constant compile apart. For games whose looks don't
	// differ that way between many entities.
	bake_constants: bool,
}

@(private)
Viewport :: struct {
	scale:  f32,
	offset: Vector2,
}

@(private)
Engine :: struct {
	width, height: f32,
	bg_color:      Color,
	show_fps:      bool,
	time:          f64, // scene time, advances with time_scale
	time_scale:    f32,
	frame_budget:  f64, // seconds per frame at the target FPS; 0 = unlimited
	vsync:         VSync,
	vsync_on:      bool, // whether the swap currently waits for the monitor
	pacing:        Pacing,
	shake:         f32,
	viewport:      Viewport,
	match_window:  bool,
	overlay:       proc(),
	frame:         int, // frames rendered so far
	px_factor:     f32, // target pixels per screen pixel: > 1 while drawing an out-of-focus layer's image
	bake_constants: bool, // see InitOptions
	quitting:      bool, // quit() was called: run() ends after this frame
	fixed_dt:      f32, // ZSE_FIXED_DT: every frame advances this many seconds (repeatable frames for comparing builds); 0 = real time
}

// Frame timing gathered while VSync.Auto decides whether vsync holds the game back.
@(private)
Pacing :: struct {
	frames:          int,
	frame_seconds:   f64,
	present_seconds: f64,
	decided:         bool,
}

@(private)
engine: Engine

init_context :: proc(init: InitOptions) {
	engine = Engine {
		width        = f32(init.width),
		height       = f32(init.height),
		bg_color     = init.bg_color,
		show_fps     = init.show_fps,
		time_scale   = 1,
		px_factor    = 1,
		match_window = init.match_window,
		bake_constants = init.bake_constants,
	}
	init_scene(init.num_layers)
	init_lighting()

	engine.frame_budget = 1 / f64(init.fps) if init.fps > 0 else 0
	engine.vsync = init.vsync
	engine.vsync_on = init.vsync == .On || (init.vsync == .Auto && init.fps > 0)
	flags: rl.ConfigFlags = {.VSYNC_HINT} if engine.vsync_on else {}
	if init.resizable {
		flags += {.WINDOW_RESIZABLE}
	}
	rl.SetConfigFlags(flags)
	rl.SetTraceLogLevel(.WARNING)
	rl.InitWindow(init.width, init.height, strings.clone_to_cstring(init.title, context.temp_allocator))
	// raylib's own frame limiter busy-waits; vsync paces frames and run() sleeps when it
	// doesn't (see limit_frame_rate).
	rl.SetTargetFPS(0)
	rl.SetExitKey(.KEY_NULL)
	init_gpu()
	init_profiler(init.title)
	if !init.no_shader_manifest {
		load_shader_manifest(init.title)
	}
	update_viewport()
}

// Sets a procedure that draws after the scene each frame, in virtual coordinates (tool UIs,
// debug drawing). Pass nil to remove it.
set_overlay :: proc(overlay: proc()) {
	engine.overlay = overlay
}

// Scene time in seconds, as seen by shaders through time().
time :: proc() -> f32 {
	return f32(engine.time)
}

// Ends run() after the current frame, as closing the window does.
quit :: proc() {
	engine.quitting = true
}

// Makes the window cover a whole monitor without decorations (borderless windowed): the
// monitor at `monitor` in raylib's list (rl.GetMonitorName etc.), or with -1 the one the
// window is on. On Wayland, applications can't see or set where their window is, so raylib
// takes "the one it's on" to be monitor 0: games should let the player choose
// (find_monitor).
fill_monitor :: proc(monitor := -1) {
	if monitor < 0 || monitor >= int(rl.GetMonitorCount()) {
		rl.ToggleBorderlessWindowed()
		return
	}
	if fill_monitor_wayland(monitor) {
		return
	}
	// Elsewhere raylib finds the monitor from the window's position
	rl.SetWindowMonitor(i32(monitor))
	rl.ToggleBorderlessWindowed()
}

// The index of a monitor for fill_monitor, from its number in raylib's list or its name
// ("HDMI-A-1"); -1 if there is none such.
find_monitor :: proc(number_or_name: string) -> int {
	count := int(rl.GetMonitorCount())
	if i, ok := strconv.parse_int(number_or_name); ok {
		return i if i >= 0 && i < count else -1
	}
	for i in 0 ..< count {
		if string(rl.GetMonitorName(i32(i))) == number_or_name {
			return i
		}
	}
	return -1
}

// Scales how fast scene time (shader animation, lifetimes) advances; 0 freezes the scene.
set_time_scale :: proc(scale: f32) {
	engine.time_scale = scale
}

screen_size :: proc() -> Vector2 {
	return {engine.width, engine.height}
}

// Mouse position in virtual coordinates.
mouse_position :: proc() -> Vector2 {
	return (rl.GetMousePosition() - engine.viewport.offset) / engine.viewport.scale
}

// Kicks the camera; the shake decays on its own.
add_shake :: proc(strength: f32) {
	engine.shake = max(engine.shake, strength)
}

@(private)
update_viewport :: proc() {
	win := Vector2{f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	if engine.match_window {
		engine.width, engine.height = win.x, win.y
	}
	scale := min(win.x / engine.width, win.y / engine.height)
	engine.viewport = {
		scale  = scale,
		offset = (win - Vector2{engine.width, engine.height} * scale) * 0.5,
	}
}

// Switches vsync on or off at runtime. Auto starts with vsync on and turns it off if it keeps
// the game below its target FPS.
set_vsync :: proc(mode: VSync) {
	engine.vsync = mode
	engine.pacing = {}
	apply_vsync(mode == .On || (mode == .Auto && engine.frame_budget > 0))
}

@(private)
apply_vsync :: proc(on: bool) {
	set_swap_interval(on)
	engine.vsync_on = on
}

// For VSync.Auto: after the frame rate settles, turns vsync off if frames run slower than the
// target while most of their time is spent waiting in the swap, i.e. the monitor's refresh
// rate is below the target. Monitor refresh rates can't be queried reliably (Wayland doesn't
// say which monitor a window is on), so this measures instead.
@(private)
check_vsync :: proc(frame_seconds, present_seconds: f64) {
	WARMUP :: 30
	SAMPLE :: 60
	pacing := &engine.pacing
	if engine.vsync != .Auto || !engine.vsync_on || pacing.decided || engine.frame_budget <= 0 {
		return
	}
	pacing.frames += 1
	if pacing.frames <= WARMUP {
		return
	}
	pacing.frame_seconds += frame_seconds
	pacing.present_seconds += present_seconds
	if pacing.frames < WARMUP + SAMPLE {
		return
	}
	pacing.decided = true
	frame := pacing.frame_seconds / SAMPLE
	present := pacing.present_seconds / SAMPLE
	if frame > engine.frame_budget * 1.1 && present > 0.5 * frame {
		apply_vsync(false)
	}
}

// Sleeps through all but the last millisecond and spins through that, for pacing accurate to
// well under a millisecond without burning a core (time.accurate_sleep spins up to ~5 ms).
@(private)
precise_sleep :: proc(d: time.Duration) {
	start := time.tick_now()
	if d > 2 * time.Millisecond {
		time.sleep(d - time.Millisecond)
	}
	for time.tick_since(start) < d {
		intrinsics.cpu_relax()
	}
}

// Sleeps off the rest of the frame budget when vsync doesn't already pace frames at or below
// the target. Without vsync it spins only for the last moment, for accurate pacing.
@(private)
limit_frame_rate :: proc() -> (frame_seconds: f64) {
	@(static) frame_start: time.Tick
	if frame_start != {} {
		elapsed := time.duration_seconds(time.tick_diff(frame_start, time.tick_now()))
		if remaining := engine.frame_budget - elapsed; engine.frame_budget > 0 && remaining > 0.0005 {
			wait := time.Duration(remaining * f64(time.Second))
			if engine.vsync_on {
				time.sleep(wait)
			} else {
				precise_sleep(wait)
			}
		}
		frame_seconds = time.duration_seconds(time.tick_diff(frame_start, time.tick_now()))
	}
	frame_start = time.tick_now()
	return
}

run :: proc(on_update: proc(delta_time: f32)) {
	// Count allocations per frame for the profiler.
	profiler.heap.backing = context.allocator
	profiler.temp.backing = context.temp_allocator
	context.allocator = counting_allocator(&profiler.heap)
	context.temp_allocator = counting_allocator(&profiler.temp)

	if s, ok := strconv.parse_f32(os.get_env("ZSE_FIXED_DT", context.temp_allocator)); ok && s > 0 {
		engine.fixed_dt = s
	}
	for !rl.WindowShouldClose() && !engine.quitting && !profiler_should_quit() {
		engine.frame += 1
		profiler_begin_frame()
		dt := (engine.fixed_dt if engine.fixed_dt > 0 else rl.GetFrameTime()) * engine.time_scale
		engine.time += f64(dt)
		update_viewport()

		profile_begin("update")
		on_update(dt)
		profile_end()

		vp := engine.viewport
		jitter: Vector2
		if engine.shake > 0.01 {
			jitter = {rand.float32_range(-1, 1), rand.float32_range(-1, 1)} * engine.shake
			engine.shake *= math.pow(0.002, dt) // falls to 0.2% after one second
		}
		camera := rl.Camera2D {
			offset = vp.offset + jitter * vp.scale,
			zoom   = vp.scale,
		}

		profile_begin("render")
		// The frame's first GPU work: where some drivers wait for the display (see FLUSH_ZONE)
		profile_begin(OFFSCREEN_ZONE)
		refresh_caches()
		render_layer_images(camera)
		profile_end()
		rl.BeginDrawing()
		rl.ClearBackground(engine.bg_color)
		rl.BeginScissorMode(
			i32(vp.offset.x),
			i32(vp.offset.y),
			i32(engine.width * vp.scale),
			i32(engine.height * vp.scale),
		)
		rl.BeginMode2D(camera)
		render_entities(camera)
		if engine.overlay != nil {
			engine.overlay()
		}
		// Some drivers (e.g. NVIDIA on Windows) return from the buffer swap at once and block
		// here instead, where raylib hands over its batched drawing, until the display is
		// ready for another frame; that wait is timed apart from the work.
		profile_begin(FLUSH_ZONE)
		rl.EndMode2D()
		rl.EndScissorMode()
		profile_end()
		if engine.show_fps {
			rl.DrawFPS(10, 10)
		}
		gpu_end_frame()
		draw_profiler_overlay()
		profile_end()

		// Swapping waits for vsync / the target frame rate, so this is mostly idle time.
		profile_begin("present")
		present_start := time.tick_now()
		rl.EndDrawing()
		present_seconds := time.duration_seconds(time.tick_diff(present_start, time.tick_now()))
		profile_end()

		profile_begin("cleanup")
		remove_expired_entities()
		profile_end()
		free_all(context.temp_allocator)
		check_vsync(limit_frame_rate(), present_seconds)
	}

	if profiler.report_on_exit {
		write_report()
	}
	write_shader_manifest()
	clear_scene()
	unload_materials()
	unload_shader_manifest()
	rl.CloseWindow()
}
