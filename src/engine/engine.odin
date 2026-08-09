package engine

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

Vector2 :: rl.Vector2

InitOptions :: struct {
	width, height, fps: i32,
	title:              string,
	resize_strategy:    ResizeStrategy,
	num_layers:         int,
	bg_color:           rl.Color,
	show_fps:           bool,
}

ResizeStrategy :: enum {
	STRETCH,
	STATIC,
}

ID_COUNTER := 0

RenderObject :: struct {
	id:        int,
	drawable:  Drawable,
	collider:  Collider,
	pos:       rl.Vector2,
	size:      rl.Vector2,
	rotation:  f32, // degrees; applied around top-left corner
	z_index:   int,
	layer_idx: int,
	visible:   bool,
}

Layer :: struct {
	object_ids: [dynamic]int,
}

RenderScene :: struct {
	render_texture: rl.RenderTexture2D,
	objects:        map[int]RenderObject,
	layers:         [dynamic]Layer,
	bg_color:       rl.Color,
	show_fps:       bool,
}

@(private)
render_scene: RenderScene

get_render_object :: proc(object_id: int) -> ^RenderObject {
	return &render_scene.objects[object_id]
}

get_drawable :: proc(object_id: int, $T: typeid) -> ^T {
	return &get_render_object(object_id).drawable.(T)
}

get_object_and_drawable :: proc(object_id: int, $T: typeid) -> (^RenderObject, ^T) {
	obj := get_render_object(object_id)
	return obj, &obj.drawable.(T)
}

init_context :: proc(init: InitOptions) {
	screen_width: i32 = init.width
	screen_height: i32 = init.height
	render_scene.layers = make([dynamic]Layer, init.num_layers)
	render_scene.bg_color = init.bg_color
	render_scene.show_fps = init.show_fps

	if init.resize_strategy == ResizeStrategy.STRETCH {
		rl.SetConfigFlags({.WINDOW_RESIZABLE})
	}
	rl.InitWindow(screen_width, screen_height, strings.clone_to_cstring(init.title))
	rl.SetTargetFPS(init.fps)

	render_scene.render_texture = rl.LoadRenderTexture(init.width, init.height)
	init_audio()
}

draw_render_texture :: proc() {
	rl.BeginDrawing()
	rl.ClearBackground(rl.RAYWHITE)

	game_w := f32(render_scene.render_texture.texture.width)
	game_h := f32(render_scene.render_texture.texture.height)
	win_w := f32(rl.GetScreenWidth())
	win_h := f32(rl.GetScreenHeight())
	scale := min(win_w / game_w, win_h / game_h)
	dst_w := game_w * scale
	dst_h := game_h * scale

	rl.DrawTexturePro(
		render_scene.render_texture.texture,
		{0, 0, game_w, -game_h}, // negative height corrects render texture Y-flip
		{(win_w - dst_w) * 0.5, (win_h - dst_h) * 0.5, dst_w, dst_h},
		{0, 0},
		0,
		rl.WHITE,
	)
	if (render_scene.show_fps) {
		rl.DrawFPS(10, 10)
	}
	rl.EndDrawing()
}

render_objects :: proc(delta_time: f32) {
	for &layer in render_scene.layers {
		for id in layer.object_ids {
			obj := &render_scene.objects[id]
			if !obj.visible {
				continue
			}

			dst := rl.Rectangle{obj.pos.x, obj.pos.y, obj.size.x, obj.size.y}

			assert(obj.drawable != nil, "Render object drawable cannot be nil!")

			switch &d in obj.drawable {
			case Text:
				rl.DrawText(
					strings.clone_to_cstring(d.text),
					i32(obj.pos.x),
					i32(obj.pos.y),
					d.font_size,
					d.color,
				)
			case RectShape:
				if fbm_p, ok := d.fbm.?; ok {
					switch d.fill {
					case .Fill:
						draw_fbm_rect(dst, fbm_p)
					case .Outline:
						rl.DrawRectangleLinesEx(dst, d.thickness, d.line_color)
					case .FillOutline:
						draw_fbm_rect(dst, fbm_p)
						rl.DrawRectangleLinesEx(dst, d.thickness, d.line_color)
					}
				} else {
					switch d.fill {
					case .Fill:
						rl.DrawRectanglePro(dst, {0, 0}, obj.rotation, d.fill_color)
					case .Outline:
						rl.DrawRectangleLinesEx(dst, d.thickness, d.line_color)
					case .FillOutline:
						rl.DrawRectanglePro(dst, {0, 0}, obj.rotation, d.fill_color)
						rl.DrawRectangleLinesEx(dst, d.thickness, d.line_color)
					}
				}
			case CircleShape:
				center := rl.Vector2{obj.pos.x, obj.pos.y}
				if fbm_p, ok := d.fbm.?; ok {
					switch d.fill {
					case .Fill:
						draw_fbm_circle(center, obj.size.x, fbm_p)
					case .Outline:
						rl.DrawCircleLines(i32(obj.pos.x), i32(obj.pos.y), obj.size.x, d.line_color)
					case .FillOutline:
						draw_fbm_circle(center, obj.size.x, fbm_p)
						rl.DrawCircleLines(i32(obj.pos.x), i32(obj.pos.y), obj.size.x, d.line_color)
					}
				} else {
					switch d.fill {
					case .Fill:
						rl.DrawCircle(i32(obj.pos.x), i32(obj.pos.y), obj.size.x, d.fill_color)
					case .Outline:
						rl.DrawCircleLines(i32(obj.pos.x), i32(obj.pos.y), obj.size.x, d.line_color)
					case .FillOutline:
						rl.DrawCircle(i32(obj.pos.x), i32(obj.pos.y), obj.size.x, d.fill_color)
						rl.DrawCircleLines(i32(obj.pos.x), i32(obj.pos.y), obj.size.x, d.line_color)
					}
				}
			}
		}
	}
}

add_scene_object :: proc(drawable: Drawable, pos, size: rl.Vector2, z_index: int) -> int {
	assert(
		z_index >= 0 && z_index < len(render_scene.layers),
		fmt.tprintf("Invalid layer index: %d", z_index),
	)
	new_id := ID_COUNTER
	layer_idx := len(render_scene.layers[z_index].object_ids)

	obj := RenderObject {
		id        = new_id,
		pos       = pos,
		size      = size,
		drawable  = drawable,
		z_index   = z_index,
		layer_idx = layer_idx,
		visible   = true,
	}
	render_scene.objects[new_id] = obj
	append(&render_scene.layers[z_index].object_ids, new_id)
	ID_COUNTER += 1
	return new_id
}

set_collider :: proc(id: int, collider: Collider) {
	obj := &render_scene.objects[id]
	obj.collider = collider
}

remove_scene_object :: proc(id: int) {
	// Remove from specific layer
	z_index := render_scene.objects[id].z_index
	layer_index := render_scene.objects[id].layer_idx

	layer := &render_scene.layers[z_index]
	layer_last_idx := len(layer.object_ids) - 1
	layer_last_id := layer.object_ids[layer_last_idx]

	layer.object_ids[layer_index] = layer_last_id
	obj := &render_scene.objects[layer_last_id]
	obj.layer_idx = layer_index
	pop(&layer.object_ids)

	// Remove from object map
	delete_key(&render_scene.objects, id)
}

run :: proc(on_update: proc(delta_time: f32)) {
	for (!rl.WindowShouldClose()) {
		delta_time := rl.GetFrameTime()

		rl.BeginTextureMode(render_scene.render_texture)
		rl.ClearBackground(render_scene.bg_color)

		on_update(delta_time)
		render_objects(delta_time)

		rl.EndTextureMode()

		draw_render_texture()
	}

	deinit_audio()
	rl.CloseWindow()
}
