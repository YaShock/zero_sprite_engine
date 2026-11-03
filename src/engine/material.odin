package engine

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import gl "vendor:OpenGL"
import rl "vendor:raylib"
import "vfx"

// Per-entity instance of a compiled look: a shared shader plus this entity's parameter values.
Material :: struct {
	shader: int, // index into shader_cache.entries
	params: []f32, // owned
}

@(private)
ShaderEntry :: struct {
	shader:         rl.Shader,
	program:        vfx.Program,
	label:          string, // where the first material using it was made, for the profiler
	stride:         int, // vec4s per instance record: 3 + parameter vec4s (see vfx/glsl/vertex.glsl)
	loc_modelview:  i32,
	loc_projection: i32,
	loc_time:       i32,
	loc_px:         i32,
	// Scene lights (only in shaders using vfx.lit_scene; -1 otherwise)
	loc_light_count: i32,
	loc_light_pos:   i32,
	loc_light_color: i32,
	loc_ambient:     i32,
	lights_frame:    int, // last frame the lights were uploaded to this shader
}

@(private)
ShaderCache :: struct {
	by_key:  map[u64]int, // vfx.Layout.key -> index into entries
	entries: [dynamic]ShaderEntry,
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
//
// Looks whose structure was seen before only need their layout (a hash and the parameter
// values); GLSL is generated only for new structures.
try_make_material :: proc(look: vfx.Expr, label := "") -> (m: Material, err: string, ok: bool) {
	profile_scope("material")
	profiler.materials += 1
	layout := vfx.layout(look)
	idx, found := shader_cache.by_key[layout.key]
	if !found {
		prog := vfx.compile(look, context.temp_allocator)
		assert(slice.equal(prog.defaults, layout.defaults), "vfx: layout() disagrees with compile() on the parameter slots")
		loaded: bool
		idx, err, loaded = load_shader(prog, label)
		if !loaded {
			delete(layout.defaults)
			return {}, err, false
		}
		shader_cache.by_key[layout.key] = idx
	}
	return Material{shader = idx, params = layout.defaults}, "", true

	load_shader :: proc(temp: vfx.Program, label: string) -> (idx: int, err: string, ok: bool) {
		// Compiled at startup from the manifest: no driver work now.
		if shader, warm := take_warm_shader(temp.source); warm {
			return add_shader_entry(shader, temp, label), "", true
		}
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
		shader, loaded := load_glsl(temp.source)
		if !loaded {
			return -1, "raylib failed to load a shader the driver compiled", false
		}
		return add_shader_entry(shader, temp, label), "", true
	}
}

@(private)
load_glsl :: proc(source: string) -> (rl.Shader, bool) {
	vertex := strings.clone_to_cstring(vfx.VERTEX_SHADER, context.temp_allocator)
	shader := rl.LoadShaderFromMemory(vertex, strings.clone_to_cstring(source, context.temp_allocator))
	return shader, rl.IsShaderValid(shader) && shader.id != rlGetShaderIdDefault()
}

@(private)
add_shader_entry :: proc(shader: rl.Shader, temp: vfx.Program, label: string) -> int {
	append(
		&shader_cache.entries,
		ShaderEntry {
			shader = shader,
			program = vfx.clone_program(temp),
			label = strings.clone(label),
			stride = 3 + len(temp.defaults) / 4,
			loc_modelview = rl.GetShaderLocation(shader, "u_modelview"),
			loc_projection = rl.GetShaderLocation(shader, "u_projection"),
			loc_time = rl.GetShaderLocation(shader, "u_time"),
			loc_px = rl.GetShaderLocation(shader, "u_px"),
			loc_light_count = rl.GetShaderLocation(shader, "u_light_count"),
			loc_light_pos = rl.GetShaderLocation(shader, "u_light_pos"),
			loc_light_color = rl.GetShaderLocation(shader, "u_light_color"),
			loc_ambient = rl.GetShaderLocation(shader, "u_ambient"),
			lights_frame = -1,
		},
	)
	// Constant per shader: where the instance records are and how long each one is.
	entry := &shader_cache.entries[len(shader_cache.entries) - 1]
	stride := i32(entry.stride)
	rl.SetShaderValue(shader, rl.GetShaderLocation(shader, "u_stride"), &stride, .INT)
	gl.UniformBlockBinding(shader.id, gl.GetUniformBlockIndex(shader.id, "Instances"), INSTANCE_BINDING)
	return len(shader_cache.entries) - 1
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
	delete(shader_cache.by_key)
	delete(scene_draws.records)
	delete(scene_draws.steps)
	delete_batcher(&scene_batcher)
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

// Draws collected before any is issued, so that all their instance records reach the GPU
// in one upload (see upload_instances). Consecutive instances of one shader with the same
// blending share an instanced draw call (the scene is grouped into such runs first, see
// batching.odin); whatever raylib draws (text, cached looks) goes between calls.
@(private)
DrawList :: struct {
	records: [dynamic][4]f32, // instance records, see vfx/glsl/vertex.glsl
	steps:   [dynamic]DrawStep,
}

@(private)
DrawStep :: union {
	DrawCall,
	RaylibDraw,
}

// `count` instances of a look shader whose records start at `first` in DrawList.records.
@(private)
DrawCall :: struct {
	shader: int,
	blend:  BlendMode,
	px:     f32,
	first:  int,
	count:  int,
	pixels: f32, // screen pixels covered, for the profiler
}

@(private)
RaylibDraw :: struct {
	entity: int,
}

@(private)
scene_draws: DrawList

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
	draw_now(m, center, size, pad, zoom, px, age, rotation, blend, world_center.? or_else center)
}

@(private)
draw_now :: proc(m: ^Material, center, size: Vector2, pad, quad_scale, px, age, rotation: f32, blend: BlendMode, origin: Vector2) {
	list := DrawList {
		records = make([dynamic][4]f32, context.temp_allocator),
		steps   = make([dynamic]DrawStep, context.temp_allocator),
	}
	add_instance(&list, m, center, size, pad, quad_scale, px, age, rotation, blend, origin)
	submit_draws(&list)
}

// Adds a material's quad to the list, in the last draw call if it can take it. `quad_scale`
// maps virtual units to the current drawing space and `px` is the size of one target pixel
// in virtual units (for anti-aliasing).
@(private)
add_instance :: proc(list: ^DrawList, m: ^Material, center, size: Vector2, pad, quad_scale, px, age, rotation: f32, blend: BlendMode, origin: Vector2) {
	stride := shader_cache.entries[m.shader].stride
	call: ^DrawCall
	if len(list.steps) > 0 {
		last, is_call := &list.steps[len(list.steps) - 1].(DrawCall)
		if is_call && last.shader == m.shader && last.blend == blend && last.px == px && len(list.records) - last.first + stride <= INSTANCE_VEC4S {
			call = last
		}
	}
	if call == nil {
		for len(list.records) % instances.align != 0 {
			append(&list.records, [4]f32{})
		}
		append(&list.steps, DrawCall{shader = m.shader, blend = blend, px = px, first = len(list.records)})
		call = &list.steps[len(list.steps) - 1].(DrawCall)
	}
	extent := size + 2 * pad
	screen_extent := extent * quad_scale
	rot := rotation * math.RAD_PER_DEG
	append(&list.records, [4]f32{center.x, center.y, screen_extent.x, screen_extent.y})
	append(&list.records, [4]f32{size.x, size.y, rot, age})
	append(&list.records, [4]f32{extent.x, extent.y, origin.x, origin.y})
	for i := 0; i < len(m.params); i += 4 {
		append(&list.records, [4]f32{m.params[i], m.params[i + 1], m.params[i + 2], m.params[i + 3]})
	}
	call.count += 1
	pixels := extent / px
	call.pixels += pixels.x * pixels.y
}

// Uploads the list's instance records, issues its draws in order and empties it.
@(private)
submit_draws :: proc(list: ^DrawList) {
	upload_instances(list.records[:])
	for step in list.steps {
		switch s in step {
		case DrawCall:
			gpu_stamp_pending()
			rlDrawRenderBatchActive() // raylib's queued draws come first
			if s.blend == .Additive {
				rl.BeginBlendMode(.ADDITIVE)
			}
			draw_instances(&shader_cache.entries[s.shader], s.first, s.count, s.px)
			if s.blend == .Additive {
				rl.EndBlendMode()
			}
			gpu_stamp(s.shader, s.pixels)
			profiler.frame_draws += 1
		case RaylibDraw:
			e := get_entity(s.entity)
			switch &d in e.drawable {
			case Material:
				draw_cached(e, &d)
			case Text:
				draw_text(e, d)
			}
		}
	}
	clear(&list.records)
	clear(&list.steps)
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
		draw_now(m, {f32(w), f32(h)} / 2, e.size, e.pad, scale, 1 / scale, 0, 0, .Alpha, e.pos)
		rlEnableColorBlend()
		rl.EndTextureMode()
		c.scale, c.dirty = scale, false
	}
}
