package engine

// Scene lights, shared by every look built with vfx.lit_scene. The engine starts with an
// ambient light and one key light matching vfx.lit's fixed direction, so a look switched
// from lit to lit_scene keeps its appearance until the game sets up its own lighting.

import "core:math/linalg"

MAX_LIGHTS :: 8 // matches MAX_LIGHTS in vfx/glsl/header.glsl

LightKind :: enum {
	Point,
	Directional,
}

Light :: struct {
	kind:      LightKind,
	pos:       Vector2, // Point: world position. Directional: screen direction towards the light
	height:    f32, // how high above the scene the light is; low lights rake across the relief
	color:     Color,
	intensity: f32,
	radius:    f32, // Point: distance at which it has faded out completely
}

@(private)
Lighting :: struct {
	slots:   [MAX_LIGHTS]Maybe(Light),
	ambient: [3]f32,
	// Uniform values, rebuilt once per frame for all shaders
	frame:   int,
	count:   i32,
	pos:     [MAX_LIGHTS][4]f32,
	color:   [MAX_LIGHTS][4]f32,
}

@(private)
lighting: Lighting

@(private)
init_lighting :: proc() {
	lighting = {}
	lighting.frame = -1
	set_ambient({255, 255, 255, 255}, 0.25)
	// Same light as vfx.lit's default: from the top left, bright enough that a flat surface
	// keeps its color (0.25 ambient + 0.75 diffuse).
	key := linalg.normalize([3]f32{-0.6, -0.8, 0.9})
	add_light({kind = .Directional, pos = {-0.6, -0.8}, height = 0.9, color = {255, 255, 255, 255}, intensity = 0.75 / key.z})
}

// Adds a light and returns its id; at most MAX_LIGHTS can exist at once.
add_light :: proc(light: Light) -> int {
	for &slot, id in lighting.slots {
		if slot == nil {
			slot = light
			return id
		}
	}
	panic("add_light: no free light slot (MAX_LIGHTS)")
}

// The light with this id, to move or recolor it.
get_light :: proc(id: int) -> ^Light {
	return &lighting.slots[id].?
}

remove_light :: proc(id: int) {
	lighting.slots[id] = nil
}

// Removes every light, including the default key light; the ambient light stays.
clear_lights :: proc() {
	lighting.slots = {}
}

set_ambient :: proc(color: Color, intensity: f32 = 1) {
	lighting.ambient = [3]f32{f32(color.r), f32(color.g), f32(color.b)} / 255 * intensity
}

// Packs the lights into uniform arrays once per frame.
@(private)
light_uniforms :: proc() -> ^Lighting {
	if lighting.frame == engine.frame {
		return &lighting
	}
	lighting.frame = engine.frame
	lighting.count = 0
	for slot in lighting.slots {
		light := slot.? or_continue
		i := lighting.count
		color := [3]f32{f32(light.color.r), f32(light.color.g), f32(light.color.b)} / 255 * light.intensity
		switch light.kind {
		case .Point:
			lighting.pos[i] = {light.pos.x, light.pos.y, light.height, 1}
			lighting.color[i] = {color.r, color.g, color.b, light.radius}
		case .Directional:
			dir := linalg.normalize([3]f32{light.pos.x, light.pos.y, light.height})
			lighting.pos[i] = {dir.x, dir.y, dir.z, 0}
			lighting.color[i] = {color.r, color.g, color.b, 0}
		}
		lighting.count += 1
	}
	return &lighting
}
