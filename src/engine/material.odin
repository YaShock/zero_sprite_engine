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
	shader:    int, // index into shader_cache.entries
	params:    []f32, // owned
	data:      []f32, // owned: the data_array values, mirrored in `texture`; nil if none
	texture:   rl.Texture2D, // float texture, DATA_TEXTURE_WIDTH texels of 4 values per row
	dirty_lo:  int, // the values of `data` changed since the last upload: dirty_lo ..< dirty_hi
	dirty_hi:  int,
	instances: int, // instanced looks: how many records to draw (see set_instances)
}

// Texels per row of a material's data texture (prelude.glsl's dget reads it this way).
@(private)
DATA_TEXTURE_WIDTH :: 1024

@(private)
ShaderEntry :: struct {
	single:  LookProgram, // draws calls of one instance, and instanced looks
	batched: LookProgram, // draws calls of several instances; compiled when first needed (shader.id 0 until then)
	program: vfx.Program,
	label:   string, // where the first material using it was made, for the profiler
	stride:  int, // vec4s per instance record: 3 + parameter vec4s (see vfx/glsl/vertex.glsl)
	slot_of: map[string]int, // param name -> index into program.params
}

// One linked variant of a look shader (see vfx.batched_source) and its uniform locations.
@(private)
LookProgram :: struct {
	shader:         rl.Shader,
	loc_modelview:  i32,
	loc_projection: i32,
	loc_time:       i32,
	loc_px:         i32,
	// Scene lights (only in shaders using vfx.lit_scene; -1 otherwise)
	loc_light_count: i32,
	loc_light_pos:   i32,
	loc_light_color: i32,
	loc_ambient:     i32,
	lights_frame:    int, // last frame the lights were uploaded to this program
	loc_screen:      i32, // looks that sample a buffer layer (vfx.layer_sample)
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
// Such looks are often drawn several to a call, so the batched variant is compiled too.
precompile :: proc(look: vfx.Expr, loc := #caller_location) {
	m := make_material(look, loc)
	call_program(&shader_cache.entries[m.shader], DrawCall{count = 2, instanced = shader_cache.entries[m.shader].program.instances[1] > 0})
	delete_material(m)
}

// Like make_material, but reports a shader the driver rejects instead of panicking. `err`
// holds the numbered source and the driver's log, allocated with the temp allocator.
//
// Looks whose structure was seen before only need their layout (a hash and the parameter
// values); GLSL is generated only for new structures.
try_make_material :: proc(look: vfx.Expr, label := "") -> (m: Material, err: string, ok: bool) {
	profile_scope("material")
	profiler.materials += 1
	layout := vfx.layout(look, engine.bake_constants)
	idx, found := shader_cache.by_key[layout.key]
	if !found {
		prog := vfx.compile(look, context.temp_allocator, engine.bake_constants)
		assert(slice.equal(prog.defaults, layout.defaults), "vfx: layout() disagrees with compile() on the parameter slots")
		loaded: bool
		idx, err, loaded = load_shader(prog, label)
		if !loaded {
			delete(layout.defaults)
			return {}, err, false
		}
		shader_cache.by_key[layout.key] = idx
	}
	m = Material{shader = idx, params = layout.defaults}
	if size := shader_cache.entries[idx].program.data_size; size > 0 {
		rows := (size + 4 * DATA_TEXTURE_WIDTH - 1) / (4 * DATA_TEXTURE_WIDTH)
		m.data = make([]f32, rows * 4 * DATA_TEXTURE_WIDTH)
		image := rl.Image{raw_data(m.data), DATA_TEXTURE_WIDTH, i32(rows), 1, .UNCOMPRESSED_R32G32B32A32}
		m.texture = rl.LoadTextureFromImage(image)
	}
	return m, "", true

	load_shader :: proc(temp: vfx.Program, label: string) -> (idx: int, err: string, ok: bool) {
		shader: rl.Shader
		if shader, err, ok = load_look_shader(temp.source, label); !ok {
			return -1, err, false
		}
		return add_shader_entry(shader, temp, label), "", true
	}
}

// The program of a look's fragment shader: compiled at startup from the manifest, saved by
// an earlier run (see init_program_cache), or compiled now, which the profiler times.
@(private)
load_look_shader :: proc(source, label: string) -> (shader: rl.Shader, err: string, ok: bool) {
	if warm, found := take_warm_shader(source); found {
		return warm, "", true
	}
	profile_scope("shader compile")
	start := time.tick_now()
	vertex := vfx.vertex_shader_of(source)
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
	if id := load_cached_program(vertex, source); id != 0 {
		return rl.Shader{id = id}, "", true
	}
	if valid, log := check_fragment_shader(source); !valid {
		sb := strings.builder_make(context.temp_allocator)
		for line, i in strings.split_lines(source, context.temp_allocator) {
			fmt.sbprintf(&sb, "%4d  %s\n", i + 1, line)
		}
		fmt.sbprintf(&sb, "\n%s", log)
		return {}, strings.to_string(sb), false
	}
	loaded: bool
	if shader, loaded = compile_glsl(vertex, source); !loaded {
		return {}, "raylib failed to load a shader the driver compiled", false
	}
	return shader, "", true
}

// The program of a generated fragment shader: from the program cache if it has it, else
// compiled (and saved there).
@(private)
load_glsl :: proc(source: string) -> (rl.Shader, bool) {
	vertex := vfx.vertex_shader_of(source)
	// A cached program needs no raylib locations: looks set their uniforms by name and are
	// drawn without raylib.
	if id := load_cached_program(vertex, source); id != 0 {
		return rl.Shader{id = id}, true
	}
	return compile_glsl(vertex, source)
}

@(private)
compile_glsl :: proc(vertex, fragment: string) -> (rl.Shader, bool) {
	shader := rl.LoadShaderFromMemory(strings.clone_to_cstring(vertex, context.temp_allocator), strings.clone_to_cstring(fragment, context.temp_allocator))
	if !rl.IsShaderValid(shader) || shader.id == rlGetShaderIdDefault() {
		return shader, false
	}
	save_program(shader.id, vertex, fragment)
	return shader, true
}

@(private)
add_shader_entry :: proc(shader: rl.Shader, temp: vfx.Program, label: string) -> int {
	append(&shader_cache.entries, ShaderEntry{program = vfx.clone_program(temp), label = strings.clone(label), stride = 3 + len(temp.defaults) / 4})
	entry := &shader_cache.entries[len(shader_cache.entries) - 1]
	assert(entry.stride <= INSTANCE_VEC4S, "vfx: a look's parameters don't fit in an instance record")
	for s, i in entry.program.params {
		entry.slot_of[s.name] = i
	}
	entry.single = make_look_program(shader, entry^)
	return len(shader_cache.entries) - 1
}

@(private)
make_look_program :: proc(shader: rl.Shader, entry: ShaderEntry) -> LookProgram {
	// Uniforms are looked up by name: a program from the program cache has no raylib locations.
	uniform :: proc(id: u32, name: cstring) -> i32 {return gl.GetUniformLocation(id, name)}
	id := shader.id
	p := LookProgram {
		shader          = shader,
		loc_modelview   = uniform(id, "u_modelview"),
		loc_projection  = uniform(id, "u_projection"),
		loc_time        = uniform(id, "u_time"),
		loc_px          = uniform(id, "u_px"),
		loc_light_count = uniform(id, "u_light_count"),
		loc_light_pos   = uniform(id, "u_light_pos"),
		loc_light_color = uniform(id, "u_light_color"),
		loc_ambient     = uniform(id, "u_ambient"),
		lights_frame    = -1,
		loc_screen      = uniform(id, "u_screen"),
	}
	// Constant per shader: where the instance records are and how long each one is, and the
	// texture units of its samplers.
	gl.UseProgram(id)
	gl.Uniform1i(uniform(id, "u_stride"), i32(entry.stride))
	gl.Uniform1i(uniform(id, "u_data"), DATA_UNIT)
	gl.Uniform1i(uniform(id, "u_layer"), LAYER_UNIT)
	gl.Uniform1i(uniform(id, "u_layer2"), LAYER2_UNIT)
	gl.Uniform2i(uniform(id, "u_instances"), i32(entry.program.instances[0]), i32(entry.program.instances[1]))
	gl.UseProgram(0)
	gl.UniformBlockBinding(id, gl.GetUniformBlockIndex(id, "Instances"), INSTANCE_BINDING)
	return p
}

// The variant of the shader that draws `call`. Calls of several instances need the batched
// one, compiled the first time a look is drawn batched (in later runs, at startup from the
// shader manifest).
@(private)
call_program :: proc(entry: ^ShaderEntry, call: DrawCall) -> ^LookProgram {
	if call.count == 1 || call.instanced {
		return &entry.single
	}
	if entry.batched.shader.id == 0 {
		shader, err, ok := load_look_shader(vfx.batched_source(entry.program.source, context.temp_allocator), entry.label)
		if !ok {
			fmt.eprintln(err)
			panic("vfx: the batched variant of a look shader failed to compile")
		}
		entry.batched = make_look_program(shader, entry^)
	}
	return &entry.batched
}

delete_material :: proc(m: Material) {
	delete(m.params)
	if m.data != nil {
		delete(m.data)
		rl.UnloadTexture(m.texture)
	}
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
	for &e in shader_cache.entries {
		delete(e.slot_of)
		rl.UnloadShader(e.single.shader)
		if e.batched.shader.id != 0 {
			rl.UnloadShader(e.batched.shader)
		}
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
	entry := &shader_cache.entries[m.shader]
	if i, ok := entry.slot_of[name]; ok {
		return m.params, entry.program.params[i]
	}
	panic(fmt.tprintf("Entity %d has no param named '%s'", id, name))
}

has_param :: proc(id: int, name: string) -> bool {
	m, ok := get_entity(id).drawable.(Material)
	return ok && name in shader_cache.entries[m.shader].slot_of
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

// Replaces the values of a vfx.param_array or vfx.data_array (as many as given, up to its
// length).
set_param_array :: proc(id: int, name: string, values: []f32) {
	params, slot := find_param(id, name)
	assert(slot.count > 0, "set_param_array: not a param_array or data_array")
	if slot.texture {
		m := &get_entity(id).drawable.(Material)
		// Only what was written is uploaded (often a small part of a long list)
		n := copy(m.data[slot.offset:slot.offset + slot.count], values)
		if m.dirty_hi <= m.dirty_lo {
			m.dirty_lo, m.dirty_hi = slot.offset, slot.offset + n
		} else {
			m.dirty_lo, m.dirty_hi = min(m.dirty_lo, slot.offset), max(m.dirty_hi, slot.offset + n)
		}
		return
	}
	copy(params[slot.offset:slot.offset + slot.count], values)
}

// Sets the records of an instanced look's vfx.instances array and draws one quad per record
// (len(values) / its stride of them, up to its max_count; none draws nothing).
set_instances :: proc(id: int, name: string, values: []f32) {
	set_param_array(id, name, values)
	m := &get_entity(id).drawable.(Material)
	prog := shader_cache.entries[m.shader].program
	assert(prog.instances[1] > 0, "set_instances: not an instanced look")
	_, slot := find_param(id, name)
	m.instances = min(len(values), slot.count) / prog.instances[1]
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

// `count` instances of a look shader whose records start at `first` in DrawList.records. An
// instanced look's call (vfx.instances) draws one entity, the first record, `count` times:
// once per record of its instances array.
@(private)
DrawCall :: struct {
	shader:    int,
	blend:     BlendMode,
	px:        f32,
	first:     int,
	count:     int,
	pixels:    f32, // screen pixels covered, for the profiler
	texture:   u32, // the materials' data texture (one per material, so its own call); 0 = none
	instanced: bool,
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
	entry := &shader_cache.entries[m.shader]
	instanced := entry.program.instances[1] > 0
	if instanced && m.instances == 0 {
		return
	}
	upload_data(m)
	stride := entry.stride
	call: ^DrawCall
	if len(list.steps) > 0 && !instanced {
		last, is_call := &list.steps[len(list.steps) - 1].(DrawCall)
		if is_call && last.shader == m.shader && last.blend == blend && last.px == px && last.texture == m.texture.id && len(list.records) - last.first + stride <= INSTANCE_VEC4S {
			call = last
		}
	}
	if call == nil {
		for len(list.records) % instances.align != 0 {
			append(&list.records, [4]f32{})
		}
		append(&list.steps, DrawCall{shader = m.shader, blend = blend, px = px, first = len(list.records), texture = m.texture.id, instanced = instanced})
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
	if instanced {
		call.count = m.instances
		first, record := entry.program.instances[0], entry.program.instances[1]
		for i in 0 ..< m.instances {
			half := m.data[first + i * record + 2:][:2]
			call.pixels += 4 * half[0] * half[1] / (px * px)
		}
	} else {
		call.count += 1
		pixels := extent / px
		call.pixels += pixels.x * pixels.y
	}
}

// Uploads the rows of a material's data texture that changed since it was last drawn.
@(private)
upload_data :: proc(m: ^Material) {
	if m.dirty_hi <= m.dirty_lo {
		return
	}
	// 4 values per texel, DATA_TEXTURE_WIDTH texels per row
	row_values := 4 * DATA_TEXTURE_WIDTH
	first, last := m.dirty_lo / row_values, (m.dirty_hi - 1) / row_values
	rows := rl.Rectangle{0, f32(first), DATA_TEXTURE_WIDTH, f32(last - first + 1)}
	rl.UpdateTextureRec(m.texture, rows, &m.data[first * row_values])
	m.dirty_lo, m.dirty_hi = 0, 0
}

// The box around the quads of an instanced look's records, in the drawing space of the
// entity at `pos` (rotation in degrees); ok = false when it draws nothing.
@(private)
instances_bounds :: proc(m: ^Material, pos: Vector2, rotation: f32) -> (lo, hi: Vector2, ok: bool) {
	prog := &shader_cache.entries[m.shader].program
	if m.instances == 0 {
		return
	}
	first, record := prog.instances[0], prog.instances[1]
	a, b := Vector2{math.F32_MAX, math.F32_MAX}, Vector2{-math.F32_MAX, -math.F32_MAX}
	for i in 0 ..< m.instances {
		q := m.data[first + i * record:][:4]
		a = {min(a.x, q[0] - abs(q[2])), min(a.y, q[1] - abs(q[3]))}
		b = {max(b.x, q[0] + abs(q[2])), max(b.y, q[1] + abs(q[3]))}
	}
	// The box turned with the entity, then boxed again
	center, half := (a + b) / 2, (b - a) / 2
	s, c := math.sincos(rotation * math.RAD_PER_DEG)
	at := pos + {c * center.x - s * center.y, s * center.x + c * center.y}
	box := Vector2{abs(c) * half.x + abs(s) * half.y, abs(s) * half.x + abs(c) * half.y}
	return at - box, at + box, true
}

// Uploads the list's instance records, issues its draws in order and empties it.
@(private)
submit_draws :: proc(list: ^DrawList) {
	upload_instances(list.records[:])
	for step in list.steps {
		switch s in step {
		case DrawCall:
			entry := &shader_cache.entries[s.shader]
			program := call_program(entry, s)
			gpu_stamp_pending()
			rlDrawRenderBatchActive() // raylib's queued draws come first
			begin_blend(s.blend)
			draw_instances(entry, program, s)
			end_blend(s.blend)
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
begin_blend :: proc(blend: BlendMode) {
	switch blend {
	case .Alpha:
	case .Additive:
		rl.BeginBlendMode(.ADDITIVE)
	case .Premultiplied:
		rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
	case .Max:
		// raylib has no max mode: its additive mode, with the equation switched to max
		rl.BeginBlendMode(.ADDITIVE)
		gl.BlendEquation(gl.MAX)
	}
}

@(private)
end_blend :: proc(blend: BlendMode) {
	if blend == .Max {
		gl.BlendEquation(gl.FUNC_ADD)
	}
	if blend != .Alpha {
		rl.EndBlendMode()
	}
}

@(private)
draw_cached :: proc(e: ^Entity, m: ^Material) {
	texture := e.cache.texture.texture
	extent := e.size + 2 * e.pad
	gpu_stamp_pending()
	begin_blend(e.blend)
	source := rl.Rectangle{0, 0, f32(texture.width), -f32(texture.height)} // render textures are upside down
	rl.DrawTexturePro(texture, source, {e.pos.x, e.pos.y, extent.x, extent.y}, extent / 2, e.rotation, rl.WHITE)
	end_blend(e.blend)
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
