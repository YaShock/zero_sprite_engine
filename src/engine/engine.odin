package engine

import "core:math"
import "core:math/rand"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

Vector2 :: rl.Vector2
Color :: rl.Color
Rectangle :: rl.Rectangle

InitOptions :: struct {
	width, height: i32, // virtual resolution; the window letterboxes it at any size
	fps:           i32,
	title:         string,
	num_layers:    int,
	bg_color:      Color, // letterbox bars
	show_fps:      bool,
	resizable:     bool,
	match_window:  bool, // virtual resolution follows the window at 1:1 (for tools)
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
	shake:         f32,
	viewport:      Viewport,
	match_window:  bool,
	overlay:       proc(),
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
		match_window = init.match_window,
	}
	init_scene(init.num_layers)

	flags: rl.ConfigFlags = {.VSYNC_HINT}
	if init.resizable {
		flags += {.WINDOW_RESIZABLE}
	}
	rl.SetConfigFlags(flags)
	rl.SetTraceLogLevel(.WARNING)
	rl.InitWindow(init.width, init.height, strings.clone_to_cstring(init.title, context.temp_allocator))
	// raylib's own frame limiter busy-waits; vsync paces frames and run() sleeps when it
	// doesn't (see limit_frame_rate).
	rl.SetTargetFPS(0)
	engine.frame_budget = 1 / f64(init.fps) if init.fps > 0 else 0
	rl.SetExitKey(.KEY_NULL)
	init_gpu()
	init_profiler(init.title)
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

// When vsync doesn't pace the swap (disabled, or a compositor that doesn't block), sleeps off
// the rest of the frame budget instead of spinning.
@(private)
limit_frame_rate :: proc() {
	@(static) frame_start: time.Tick
	if engine.frame_budget > 0 && frame_start != {} {
		elapsed := time.duration_seconds(time.tick_diff(frame_start, time.tick_now()))
		if remaining := engine.frame_budget - elapsed; remaining > 0.001 {
			time.sleep(time.Duration(remaining * f64(time.Second)))
		}
	}
	frame_start = time.tick_now()
}

run :: proc(on_update: proc(delta_time: f32)) {
	// Count allocations per frame for the profiler.
	profiler.heap.backing = context.allocator
	profiler.temp.backing = context.temp_allocator
	context.allocator = counting_allocator(&profiler.heap)
	context.temp_allocator = counting_allocator(&profiler.temp)

	for !rl.WindowShouldClose() && !profiler_should_quit() {
		profiler_begin_frame()
		dt := rl.GetFrameTime() * engine.time_scale
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
		refresh_caches()
		rl.BeginDrawing()
		rl.ClearBackground(engine.bg_color)
		rl.BeginScissorMode(
			i32(vp.offset.x),
			i32(vp.offset.y),
			i32(engine.width * vp.scale),
			i32(engine.height * vp.scale),
		)
		rl.BeginMode2D(camera)
		render_entities()
		if engine.overlay != nil {
			engine.overlay()
		}
		rl.EndMode2D()
		rl.EndScissorMode()
		if engine.show_fps {
			rl.DrawFPS(10, 10)
		}
		gpu_end_frame()
		draw_profiler_overlay()
		profile_end()

		// Swapping waits for vsync / the target frame rate, so this is mostly idle time.
		profile_begin("present")
		rl.EndDrawing()
		profile_end()

		profile_begin("cleanup")
		remove_expired_entities()
		profile_end()
		free_all(context.temp_allocator)
		limit_frame_rate()
	}

	if profiler.report_on_exit {
		write_report()
	}
	clear_scene()
	unload_materials()
	rl.CloseWindow()
}
