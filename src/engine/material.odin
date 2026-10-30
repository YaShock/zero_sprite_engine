package engine

import "core:fmt"
import "core:math"
import "core:strings"
import rl "vendor:raylib"
import "vfx"

// vendor:raylib/rlgl links its own bundled static library, which distro/Nix builds of raylib
// don't ship; the two symbols needed here are exported by the system raylib anyway.
foreign import raylib_lib "system:raylib"

@(private, default_calling_convention = "c")
foreign raylib_lib {
	rlGetTextureIdDefault :: proc() -> u32 ---
	rlGetShaderIdDefault :: proc() -> u32 ---
}

// Per-entity instance of a compiled look: a shared shader plus this entity's parameter values.
Material :: struct {
	shader: int, // index into shader_cache.entries
	params: []f32, // owned
}

@(private)
ShaderEntry :: struct {
	shader:      rl.Shader,
	program:     vfx.Program,
	loc_time:    i32,
	loc_age:     i32,
	loc_px:      i32,
	loc_rot:     i32,
	loc_size:    i32,
	loc_extent:  i32,
	loc_origin:  i32,
	loc_params:  i32,
}

@(private)
ShaderCache :: struct {
	by_source: map[string]int, // keys are owned by the entries' programs
	entries:   [dynamic]ShaderEntry,
}

@(private)
shader_cache: ShaderCache

// Compiles `look`, reusing an existing shader when the tree's structure was seen before.
make_material :: proc(look: vfx.Expr) -> Material {
	prog := vfx.compile(look, context.temp_allocator)
	idx, found := shader_cache.by_source[prog.source]
	if !found {
		idx = load_shader(prog)
	}
	params := make([]f32, len(prog.defaults))
	copy(params, prog.defaults)
	return Material{shader = idx, params = params}
}

@(private)
load_shader :: proc(temp: vfx.Program) -> int {
	shader := rl.LoadShaderFromMemory(nil, strings.clone_to_cstring(temp.source, context.temp_allocator))
	if !rl.IsShaderValid(shader) || shader.id == rlGetShaderIdDefault() {
		lines := strings.split_lines(temp.source, context.temp_allocator)
		for line, i in lines {
			fmt.eprintf("%4d  %s\n", i + 1, line)
		}
		panic("vfx: generated shader failed to compile (source above)")
	}

	prog := vfx.clone_program(temp)
	entry := ShaderEntry {
		shader     = shader,
		program    = prog,
		loc_time   = rl.GetShaderLocation(shader, "u_time"),
		loc_age    = rl.GetShaderLocation(shader, "u_age"),
		loc_px     = rl.GetShaderLocation(shader, "u_px"),
		loc_rot    = rl.GetShaderLocation(shader, "u_rot"),
		loc_size   = rl.GetShaderLocation(shader, "u_size"),
		loc_extent = rl.GetShaderLocation(shader, "u_extent"),
		loc_origin = rl.GetShaderLocation(shader, "u_origin"),
		loc_params = rl.GetShaderLocation(shader, "u_p"),
	}
	append(&shader_cache.entries, entry)
	idx := len(shader_cache.entries) - 1
	shader_cache.by_source[prog.source] = idx
	return idx
}

@(private)
unload_materials :: proc() {
	for e in shader_cache.entries {
		rl.UnloadShader(e.shader)
		vfx.delete_program(e.program)
	}
	delete(shader_cache.entries)
	delete(shader_cache.by_source)
}

@(private)
find_param :: proc(id: int, name: string) -> (params: []f32, slot: vfx.ParamSlot) {
	m := &get_entity(id).drawable.(Material)
	for s in shader_cache.entries[m.shader].program.params {
		if s.name == name {
			return m.params, s
		}
	}
	panic(fmt.tprintf("Entity %d has no param named '%s'", id, name))
}

has_param :: proc(id: int, name: string) -> bool {
	m, ok := get_entity(id).drawable.(Material)
	if !ok {
		return false
	}
	for s in shader_cache.entries[m.shader].program.params {
		if s.name == name {
			return true
		}
	}
	return false
}

set_param_f32 :: proc(id: int, name: string, value: f32) {
	params, slot := find_param(id, name)
	assert(slot.type == .Float, "set_param: type mismatch")
	params[slot.offset] = value
}

set_param_vec2 :: proc(id: int, name: string, value: Vector2) {
	params, slot := find_param(id, name)
	assert(slot.type == .Vec2, "set_param: type mismatch")
	params[slot.offset] = value.x
	params[slot.offset + 1] = value.y
}

set_param_vec4 :: proc(id: int, name: string, value: [4]f32) {
	params, slot := find_param(id, name)
	assert(slot.type == .Vec4, "set_param: type mismatch")
	for v, i in value {
		params[slot.offset + i] = v
	}
}

set_param_color :: proc(id: int, name: string, value: Color) {
	set_param_vec4(id, name, [4]f32{f32(value.r), f32(value.g), f32(value.b), f32(value.a)} / 255)
}

// Changes a named vfx.param of an entity's look; shaders pick it up on the next frame.
set_param :: proc {
	set_param_f32,
	set_param_vec2,
	set_param_vec4,
	set_param_color,
}

get_param :: proc(id: int, name: string) -> f32 {
	params, slot := find_param(id, name)
	return params[slot.offset]
}

@(private)
draw_material :: proc(e: ^Entity, m: ^Material) {
	entry := &shader_cache.entries[m.shader]
	sh := entry.shader
	extent := e.size + 2 * e.pad
	age := f32(engine.time - e.spawn_time)
	t := f32(engine.time)
	px := 1 / engine.viewport.scale
	rot := e.rotation * math.RAD_PER_DEG

	if e.blend == .Additive {
		rl.BeginBlendMode(.ADDITIVE)
	}
	// Begin/End per entity flushes the batch, so each draw sees its own uniforms.
	rl.BeginShaderMode(sh)
	rl.SetShaderValue(sh, entry.loc_time, &t, .FLOAT)
	rl.SetShaderValue(sh, entry.loc_age, &age, .FLOAT)
	rl.SetShaderValue(sh, entry.loc_px, &px, .FLOAT)
	rl.SetShaderValue(sh, entry.loc_rot, &rot, .FLOAT)
	rl.SetShaderValue(sh, entry.loc_size, &e.size, .VEC2)
	rl.SetShaderValue(sh, entry.loc_extent, &extent, .VEC2)
	rl.SetShaderValue(sh, entry.loc_origin, &e.pos, .VEC2)
	if len(m.params) > 0 {
		rl.SetShaderValueV(sh, entry.loc_params, &m.params[0], .VEC4, i32(len(m.params) / 4))
	}

	// The default 1x1 white texture just carries texture coordinates across the quad.
	quad := rl.Texture2D {
		id      = rlGetTextureIdDefault(),
		width   = 1,
		height  = 1,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	rl.DrawTexturePro(quad, {0, 0, 1, 1}, {e.pos.x, e.pos.y, extent.x, extent.y}, extent / 2, e.rotation, rl.WHITE)
	rl.EndShaderMode()
	if e.blend == .Additive {
		rl.EndBlendMode()
	}
}
