package engine

import "core:math"
import "core:math/rand"
import "core:strings"
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
	shake:         f32,
	viewport:      Viewport,
}

@(private)
engine: Engine

init_context :: proc(init: InitOptions) {
	engine = Engine {
		width      = f32(init.width),
		height     = f32(init.height),
		bg_color   = init.bg_color,
		show_fps   = init.show_fps,
		time_scale = 1,
	}
	init_scene(init.num_layers)

	flags: rl.ConfigFlags = {.VSYNC_HINT}
	if init.resizable {
		flags += {.WINDOW_RESIZABLE}
	}
	rl.SetConfigFlags(flags)
	rl.SetTraceLogLevel(.WARNING)
	rl.InitWindow(init.width, init.height, strings.clone_to_cstring(init.title, context.temp_allocator))
	rl.SetTargetFPS(init.fps)
	rl.SetExitKey(.KEY_NULL)
	update_viewport()
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
	scale := min(win.x / engine.width, win.y / engine.height)
	engine.viewport = {
		scale  = scale,
		offset = (win - Vector2{engine.width, engine.height} * scale) * 0.5,
	}
}

run :: proc(on_update: proc(delta_time: f32)) {
	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime() * engine.time_scale
		engine.time += f64(dt)
		update_viewport()

		on_update(dt)

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
		rl.EndMode2D()
		rl.EndScissorMode()
		if engine.show_fps {
			rl.DrawFPS(10, 10)
		}
		rl.EndDrawing()

		remove_expired_entities()
		free_all(context.temp_allocator)
	}

	clear_scene()
	unload_materials()
	rl.CloseWindow()
}
