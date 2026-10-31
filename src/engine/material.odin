package engine

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "core:time"
import rl "vendor:raylib"
import "vfx"

// Per-entity instance of a compiled look: a shared shader plus this entity's parameter values.
Material :: struct {
	shader: int, // index into shader_cache.entries
	params: []f32, // owned
}

@(private)
ShaderEntry :: struct {
	shader:     rl.Shader,
	program:    vfx.Program,
	label:      string, // where the first material using it was made, for the profiler
	loc_time:   i32,
	loc_age:    i32,
	loc_px:     i32,
	loc_rot:    i32,
	loc_size:   i32,
	loc_extent: i32,
	loc_origin: i32,
	loc_params: i32,
}

@(private)
ShaderCache :: struct {
	by_source: map[string]int, // keys are owned by the entries' programs
	entries:   [dynamic]ShaderEntry,
}

@(private)
shader_cache: ShaderCache

// Compiles `look`, reusing an existing shader when the tree's structure was seen before.
// Panics with the generated source if the driver rejects it.
make_material :: proc(look: vfx.Expr, loc := #caller_location) -> Material {
	m, err, ok := try_make_material(look, look_label_at(look, loc))
	if !ok {
		fmt.eprintln(err)
		panic("vfx: generated shader failed to compile")
	}
	return m
}

// Compiles a look's shader now, so the first entity using it later doesn't stall the game
// while the driver compiles it. Call it at load time for looks that appear mid-game
// (explosions, enemies, projectiles); parameter values don't matter, only the structure.
precompile :: proc(look: vfx.Expr, loc := #caller_location) {
	delete_material(make_material(look, loc))
}

// Like make_material, but reports a shader the driver rejects instead of panicking. `err`
// holds the numbered source and the driver's log, allocated with the temp allocator.
try_make_material :: proc(look: vfx.Expr, label := "") -> (m: Material, err: string, ok: bool) {
	profile_scope("material")
	prog := vfx.compile(look, context.temp_allocator)
	profiler.materials += 1
	idx, found := shader_cache.by_source[prog.source]
	if !found {
		loaded: bool
		idx, err, loaded = load_shader(prog, label)
		if !loaded {
			return {}, err, false
		}
	}
	params := make([]f32, len(prog.defaults))
	copy(params, prog.defaults)
	return Material{shader = idx, params = params}, "", true

	load_shader :: proc(temp: vfx.Program, label: string) -> (idx: int, err: string, ok: bool) {
		profile_scope("shader compile")
		start := time.tick_now()
		defer {
			ms := time.duration_milliseconds(time.tick_diff(start, time.tick_now()))
			profiler.compile_ms += ms
			profiler.compile_max_ms = max(profiler.compile_max_ms, ms)
			profiler.compiles += 1
			if !profiler.first_frame {
				// Compiled mid-game: a hitch the game could avoid with precompile().
				append(&profiler.late_compiles, LateCompile{strings.clone(label), ms})
			}
		}
		if valid, log := check_fragment_shader(temp.source); !valid {
			sb := strings.builder_make(context.temp_allocator)
			for line, i in strings.split_lines(temp.source, context.temp_allocator) {
				fmt.sbprintf(&sb, "%4d  %s\n", i + 1, line)
			}
			fmt.sbprintf(&sb, "\n%s", log)
			return -1, strings.to_string(sb), false
		}
		shader := rl.LoadShaderFromMemory(nil, strings.clone_to_cstring(temp.source, context.temp_allocator))
		if !rl.IsShaderValid(shader) || shader.id == rlGetShaderIdDefault() {
			return -1, "raylib failed to load a shader the driver compiled", false
		}

		prog := vfx.clone_program(temp)
		append(
			&shader_cache.entries,
			ShaderEntry {
				shader = shader,
				program = prog,
				label = strings.clone(label),
				loc_time = rl.GetShaderLocation(shader, "u_time"),
				loc_age = rl.GetShaderLocation(shader, "u_age"),
				loc_px = rl.GetShaderLocation(shader, "u_px"),
				loc_rot = rl.GetShaderLocation(shader, "u_rot"),
				loc_size = rl.GetShaderLocation(shader, "u_size"),
				loc_extent = rl.GetShaderLocation(shader, "u_extent"),
				loc_origin = rl.GetShaderLocation(shader, "u_origin"),
				loc_params = rl.GetShaderLocation(shader, "u_p"),
			},
		)
		idx = len(shader_cache.entries) - 1
		shader_cache.by_source[prog.source] = idx
		return idx, "", true
	}
}

delete_material :: proc(m: Material) {
	delete(m.params)
}

// The generated GLSL behind a material.
material_source :: proc(m: Material) -> string {
	return shader_cache.entries[m.shader].program.source
}

// The material's named params (from vfx.param), in declaration order.
material_params :: proc(m: Material) -> []vfx.ParamSlot {
	return shader_cache.entries[m.shader].program.params
}

// Sets a named param directly on a material; the components beyond the param's width are
// ignored. Returns false if the material has no such param.
set_material_param :: proc(m: ^Material, name: string, value: [4]f32) -> bool {
	for s in material_params(m^) {
		if s.name == name {
			width := [vfx.Type]int {
				.Float = 1,
				.Vec2  = 2,
				.Vec4  = 4,
			}
			for i in 0 ..< width[s.type] {
				m.params[s.offset + i] = value[i]
			}
			return true
		}
	}
	return false
}

// "terrain_look (create_game, tower_defense.odin:253)": the function that built the look and
// where the material was made.
@(private)
look_label_at :: proc(look: vfx.Expr, loc: runtime.Source_Code_Location) -> string {
	site := fmt.tprintf("%s, %s:%d", loc.procedure, filepath.base(loc.file_path), loc.line)
	root, is_node := look.(^vfx.Node)
	if !is_node || root.origin == "" || root.origin == loc.procedure {
		return site
	}
	return fmt.tprintf("%s (%s)", root.origin, site)
}

@(private)
unload_materials :: proc() {
	for e in shader_cache.entries {
		rl.UnloadShader(e.shader)
		vfx.delete_program(e.program)
		delete(e.label)
	}
	delete(shader_cache.entries)
	delete(shader_cache.by_source)
}

@(private)
find_param :: proc(id: int, name: string, writing := true) -> (params: []f32, slot: vfx.ParamSlot) {
	e := get_entity(id)
	e.cache.dirty ||= writing
	m := &e.drawable.(Material)
	for s in material_params(m^) {
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
	for s in material_params(m) {
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
	params, slot := find_param(id, name, writing = false)
	return params[slot.offset]
}

@(private)
draw_material :: proc(e: ^Entity, m: ^Material) {
	if e.cache.enabled && e.cache.texture.id != 0 {
		draw_cached(e, m)
		return
	}
	px := 1 / engine.viewport.scale
	draw_quad(m, e.pos, e.size, e.pad, 1, px, f32(engine.time - e.spawn_time), e.rotation, e.blend, e.pos)
}

// Draws a material outside the scene, e.g. a preview in a tool. `zoom` scales it on screen
// without changing its logical size; `world_center` is what world() reads at its center
// (default: `center`).
draw_material_at :: proc(
	m: ^Material,
	center, size: Vector2,
	pad: f32 = 0,
	zoom: f32 = 1,
	age: f32 = 0,
	rotation: f32 = 0,
	blend := BlendMode.Alpha,
	world_center: Maybe(Vector2) = nil,
) {
	px := 1 / (engine.viewport.scale * zoom)
	draw_quad(m, center, size, pad, zoom, px, age, rotation, blend, world_center.? or_else center)
}

// Draws the shader quad: `quad_scale` maps virtual units to the current drawing space and
// `px` is the size of one target pixel in virtual units (for anti-aliasing).
@(private)
draw_quad :: proc(m: ^Material, center, size: Vector2, pad, quad_scale, px, age, rotation: f32, blend: BlendMode, origin: Vector2) {
	entry := &shader_cache.entries[m.shader]
	sh := entry.shader
	size, origin, age, px := size, origin, age, px
	extent := size + 2 * pad
	screen_extent := extent * quad_scale
	t := f32(engine.time)
	rot := rotation * math.RAD_PER_DEG

	gpu_stamp_pending()
	if blend == .Additive {
		rl.BeginBlendMode(.ADDITIVE)
	}
	// Begin/End per entity flushes the batch, so each draw sees its own uniforms.
	rl.BeginShaderMode(sh)
	rl.SetShaderValue(sh, entry.loc_time, &t, .FLOAT)
	rl.SetShaderValue(sh, entry.loc_age, &age, .FLOAT)
	rl.SetShaderValue(sh, entry.loc_px, &px, .FLOAT)
	rl.SetShaderValue(sh, entry.loc_rot, &rot, .FLOAT)
	rl.SetShaderValue(sh, entry.loc_size, &size, .VEC2)
	rl.SetShaderValue(sh, entry.loc_extent, &extent, .VEC2)
	rl.SetShaderValue(sh, entry.loc_origin, &origin, .VEC2)
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
	dest := rl.Rectangle{center.x, center.y, screen_extent.x, screen_extent.y}
	rl.DrawTexturePro(quad, {0, 0, 1, 1}, dest, screen_extent / 2, rotation, rl.WHITE)
	rl.EndShaderMode()
	if blend == .Additive {
		rl.EndBlendMode()
	}
	pixels := extent / px
	gpu_stamp(m.shader, pixels.x * pixels.y)
	profiler.frame_draws += 1
}

@(private)
draw_cached :: proc(e: ^Entity, m: ^Material) {
	texture := e.cache.texture.texture
	extent := e.size + 2 * e.pad
	gpu_stamp_pending()
	if e.blend == .Additive {
		rl.BeginBlendMode(.ADDITIVE)
	}
	source := rl.Rectangle{0, 0, f32(texture.width), -f32(texture.height)} // render textures are upside down
	rl.DrawTexturePro(texture, source, {e.pos.x, e.pos.y, extent.x, extent.y}, extent / 2, e.rotation, rl.WHITE)
	if e.blend == .Additive {
		rl.EndBlendMode()
	}
	gpu_stamp(m.shader, f32(texture.width * texture.height))
	profiler.frame_draws += 1
}

// Renders cached looks whose texture is missing or stale. Runs before the frame is drawn,
// since render textures can't be used inside the scene's camera mode.
@(private)
refresh_caches :: proc() {
	scale := engine.viewport.scale
	for _, &e in scene.entities {
		m, is_material := &e.drawable.(Material)
		c := &e.cache
		if !is_material || !c.enabled || (c.texture.id != 0 && !c.dirty && c.scale == scale) {
			continue
		}
		extent := e.size + 2 * e.pad
		w, h := i32(math.ceil(extent.x * scale)), i32(math.ceil(extent.y * scale))
		if c.texture.id == 0 || c.texture.texture.width != w || c.texture.texture.height != h {
			if c.texture.id != 0 {
				rl.UnloadRenderTexture(c.texture)
			}
			c.texture = rl.LoadRenderTexture(w, h)
			rl.SetTextureFilter(c.texture.texture, .BILINEAR)
		}
		rl.BeginTextureMode(c.texture)
		rl.ClearBackground({0, 0, 0, 0})
		// Write the shader's color and alpha as they are, not blended over the cleared texture.
		rlDisableColorBlend()
		draw_quad(m, {f32(w), f32(h)} / 2, e.size, e.pad, scale, 1 / scale, 0, 0, .Alpha, e.pos)
		rlEnableColorBlend()
		rl.EndTextureMode()
		c.scale, c.dirty = scale, false
	}
}
