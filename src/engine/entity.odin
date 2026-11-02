package engine

import "core:fmt"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"
import "vfx"

BlendMode :: enum {
	Alpha,
	Additive,
}

TextAlign :: enum {
	Left,
	Center,
	Right,
}

Text :: struct {
	text:      string, // owned
	font_size: f32,
	color:     Color,
	align:     TextAlign,
}

Drawable :: union {
	Material,
	Text,
}

Entity :: struct {
	id:         int,
	pos:        Vector2, // center
	size:       Vector2, // logical size; the look's coord() spans ±size/2
	pad:        f32, // extra drawn margin around size, for glows and flying debris
	rotation:   f32, // degrees, around the center
	z_index:    int,
	layer_idx:  int,
	visible:    bool,
	blend:      BlendMode,
	drawable:   Drawable,
	collider:   Collider,
	spawn_time: f64,
	lifetime:   f32, // seconds of scene time until auto-removal; 0 = forever
	cache:      LookCache,
}

// A still look rendered once into a texture and redrawn from it (SpawnOptions.cache).
LookCache :: struct {
	enabled: bool,
	texture: rl.RenderTexture2D,
	scale:   f32, // viewport scale it was rendered at
	dirty:   bool, // a param changed since
}

@(private)
Layer :: struct {
	entity_ids: [dynamic]int,
	y_sorted:   bool,
}

@(private)
Scene :: struct {
	entities: map[int]Entity,
	layers:   [dynamic]Layer,
	next_id:  int,
}

@(private)
scene: Scene

@(private)
init_scene :: proc(num_layers: int) {
	scene.layers = make([dynamic]Layer, max(num_layers, 1))
}

// Draws the layer's entities ordered by the bottom edge of their logical size, so that in
// top-down / three-quarter views whatever stands further down the screen is in front.
set_layer_y_sorted :: proc(z_index: int, y_sorted: bool) {
	scene.layers[z_index].y_sorted = y_sorted
}

SpawnOptions :: struct {
	z_index:  int,
	pad:      f32,
	lifetime: f32,
	blend:    BlendMode,
	rotation: f32,
	// Render the look once into a texture and redraw that, re-rendering when the window
	// scale or a param changes. For still, expensive looks; ignored if the look reads time()
	// or age().
	cache:    bool,
}

// Adds an entity whose appearance is the shader compiled from `look`.
add_entity :: proc(look: vfx.Expr, pos, size: Vector2, opts := SpawnOptions{}, loc := #caller_location) -> int {
	id := add_drawable(make_material(look, loc), pos, size, opts.z_index)
	e := get_entity(id)
	e.pad = opts.pad
	e.lifetime = opts.lifetime
	e.blend = opts.blend
	e.rotation = opts.rotation
	e.cache.enabled = opts.cache && !shader_cache.entries[e.drawable.(Material).shader].program.animated
	return id
}

add_text :: proc(text: string, pos: Vector2, font_size: f32, color: Color, z_index := 0, align := TextAlign.Left) -> int {
	t := Text {
		text      = strings.clone(text),
		font_size = font_size,
		color     = color,
		align     = align,
	}
	return add_drawable(t, pos, {}, z_index)
}

set_text :: proc(id: int, text: string) {
	t := &get_entity(id).drawable.(Text)
	if t.text != text {
		delete(t.text)
		t.text = strings.clone(text)
	}
}

set_text_color :: proc(id: int, color: Color) {
	(&get_entity(id).drawable.(Text)).color = color
}

@(private)
add_drawable :: proc(drawable: Drawable, pos, size: Vector2, z_index: int) -> int {
	assert(z_index >= 0 && z_index < len(scene.layers), fmt.tprintf("Invalid layer index: %d", z_index))
	id := scene.next_id
	scene.next_id += 1
	layer := &scene.layers[z_index]
	scene.entities[id] = Entity {
		id         = id,
		pos        = pos,
		size       = size,
		z_index    = z_index,
		layer_idx  = len(layer.entity_ids),
		visible    = true,
		drawable   = drawable,
		spawn_time = engine.time,
	}
	append(&layer.entity_ids, id)
	return id
}

get_entity :: proc(id: int) -> ^Entity {
	e, ok := &scene.entities[id]
	assert(ok, fmt.tprintf("Unknown entity: %d", id))
	return e
}

entity_exists :: proc(id: int) -> bool {
	return id in scene.entities
}

set_collider :: proc(id: int, collider: Collider) {
	get_entity(id).collider = collider
}

remove_entity :: proc(id: int) {
	e, ok := scene.entities[id]
	if !ok {
		return
	}
	// Swap-remove from the layer, fixing up the moved entity's index.
	layer := &scene.layers[e.z_index]
	last_id := layer.entity_ids[len(layer.entity_ids) - 1]
	layer.entity_ids[e.layer_idx] = last_id
	(&scene.entities[last_id]).layer_idx = e.layer_idx
	pop(&layer.entity_ids)

	switch d in e.drawable {
	case Material:
		delete(d.params)
	case Text:
		delete(d.text)
	}
	if e.cache.texture.id != 0 {
		rl.UnloadRenderTexture(e.cache.texture)
	}
	delete_key(&scene.entities, id)
}

clear_scene :: proc() {
	for &layer in scene.layers {
		for len(layer.entity_ids) > 0 {
			remove_entity(layer.entity_ids[0])
		}
	}
}

@(private)
remove_expired_entities :: proc() {
	expired := make([dynamic]int, context.temp_allocator)
	for id, e in scene.entities {
		if e.lifetime > 0 && engine.time - e.spawn_time >= f64(e.lifetime) {
			append(&expired, id)
		}
	}
	for id in expired {
		remove_entity(id)
	}
}

@(private)
render_entities :: proc() {
	for layer in scene.layers {
		ids := layer.entity_ids[:]
		if layer.y_sorted {
			ids = slice.clone(ids, context.temp_allocator)
			slice.sort_by(ids, proc(a, b: int) -> bool {
				ea, eb := &scene.entities[a], &scene.entities[b]
				return ea.pos.y + ea.size.y / 2 < eb.pos.y + eb.size.y / 2
			})
		}
		for id in ids {
			e := &scene.entities[id]
			if !e.visible {
				continue
			}
			assert(e.drawable != nil, "Entity drawable cannot be nil!")
			switch &d in e.drawable {
			case Material:
				draw_material(&scene_draws, e, &d)
			case Text:
				append(&scene_draws.steps, RaylibDraw{id})
			}
		}
	}
	submit_draws(&scene_draws)
}

@(private)
draw_text :: proc(e: ^Entity, t: Text) {
	font := rl.GetFontDefault()
	text := strings.clone_to_cstring(t.text, context.temp_allocator)
	spacing := t.font_size / 10
	dims := rl.MeasureTextEx(font, text, t.font_size, spacing)
	pos := e.pos - {0, dims.y / 2}
	switch t.align {
	case .Left:
	case .Center:
		pos.x -= dims.x / 2
	case .Right:
		pos.x -= dims.x
	}
	rl.DrawTextEx(font, text, pos, t.font_size, spacing, t.color)
	gpu_timer.dirty = true
}
