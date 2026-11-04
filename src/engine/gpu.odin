package engine

// Direct OpenGL access for what raylib doesn't expose: instanced draws of looks, GPU timer
// queries for the profiler, shader compile logs for reporting errors in generated GLSL, float
// render targets and the disk cache of compiled programs. The rlgl symbols and the GL loader
// differ per platform (gpu_posix.odin, gpu_windows.odin).

import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "vfx"
import gl "vendor:OpenGL"
import rl "vendor:raylib"

@(private)
init_gpu :: proc() {
	load_gl()
	init_instances()
	init_program_cache()
}

gpu_renderer :: proc() -> string {
	return string(gl.GetString(gl.RENDERER))
}

// Compiled shader programs kept on disk (glGetProgramBinary), so that a look compiled once
// loads at once next time, in any build of any game: the file name is a hash of the
// program's sources and the GPU and driver. A driver that rejects a saved program (after an
// update) gets it compiled and saved again. Off with ZSE_SHADER_CACHE=off or where the driver
// has no program binaries.
@(private)
ProgramCache :: struct {
	dir:      string, // "" = off
	identity: string, // GPU and driver
}

@(private)
program_cache: ProgramCache

@(private)
init_program_cache :: proc() {
	if os.get_env("ZSE_SHADER_CACHE", context.temp_allocator) == "off" {
		return
	}
	formats: i32
	gl.GetIntegerv(gl.NUM_PROGRAM_BINARY_FORMATS, &formats)
	if formats <= 0 || gl.impl_ProgramBinary == nil || gl.impl_GetProgramBinary == nil {
		return
	}
	base := os.get_env("LOCALAPPDATA", context.temp_allocator)
	if base == "" {
		base = os.get_env("XDG_CACHE_HOME", context.temp_allocator)
	}
	if base == "" {
		base = fmt.tprintf("%s/.cache", os.get_env("HOME", context.temp_allocator))
	}
	dir := fmt.aprintf("%s/zero_sprite_engine/shaders", base)
	if os.make_directory_all(dir) != nil && !os.exists(dir) {
		delete(dir)
		return
	}
	program_cache.dir = dir
	program_cache.identity = fmt.aprintf("%s|%s", gl.GetString(gl.RENDERER), gl.GetString(gl.VERSION))
}

// Where a program of these sources is saved
@(private)
program_cache_path :: proc(vertex, fragment: string) -> string {
	key := strings.concatenate({program_cache.identity, "\x00", vertex, "\x00", fragment}, context.temp_allocator)
	a, b := hash.fnv64a(transmute([]u8)key), hash.fnv64a(transmute([]u8)key, 0x84222325cbf29ce4)
	return fmt.tprintf("%s/%016x%016x.bin", program_cache.dir, a, b)
}

// The saved program of these sources, linked; 0 if there is none or the driver refuses it
@(private)
load_cached_program :: proc(vertex, fragment: string) -> u32 {
	if program_cache.dir == "" {
		return 0
	}
	data, err := os.read_entire_file(program_cache_path(vertex, fragment), context.temp_allocator)
	if err != nil || len(data) <= 4 {
		return 0
	}
	format := (^u32le)(raw_data(data))^ // the file: binary format, then the binary
	id := gl.CreateProgram()
	gl.ProgramBinary(id, u32(format), &data[4], i32(len(data) - 4))
	linked: i32
	gl.GetProgramiv(id, gl.LINK_STATUS, &linked)
	if linked == 0 {
		gl.DeleteProgram(id)
		return 0
	}
	return id
}

// Saves a linked program for load_cached_program
@(private)
save_program :: proc(id: u32, vertex, fragment: string) {
	if program_cache.dir == "" {
		return
	}
	length: i32
	gl.GetProgramiv(id, gl.PROGRAM_BINARY_LENGTH, &length)
	if length <= 0 {
		return
	}
	data := make([]u8, 4 + int(length), context.temp_allocator)
	written: i32
	format: u32
	gl.GetProgramBinary(id, length, &written, &format, &data[4])
	if written <= 0 {
		return
	}
	(^u32le)(raw_data(data))^ = u32le(format)
	_ = os.write_entire_file(program_cache_path(vertex, fragment), data[:4 + int(written)])
}

// A render texture with half-float color (raylib's LoadRenderTexture makes 8-bit ones): light
// adds up without rounding to 1/255 at every draw, and values may be negative or above 1
// (layer buffers hold e.g. a field and its slope). No depth buffer; filtered bilinearly.
// raylib draws into it and unloads it like its own.
@(private)
load_float_target :: proc(w, h: i32) -> rl.RenderTexture2D {
	t: rl.RenderTexture2D
	tex: u32
	gl.GenTextures(1, &tex)
	gl.BindTexture(gl.TEXTURE_2D, tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.FLOAT, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.GenFramebuffers(1, &t.id)
	gl.BindFramebuffer(gl.FRAMEBUFFER, t.id)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0)
	assert(gl.CheckFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE, "float render target incomplete")
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	t.texture = {id = tex, width = w, height = h, mipmaps = 1, format = .UNCOMPRESSED_R16G16B16A16}
	return t
}

// Compiles a fragment shader on its own to get the driver's verdict and error log; raylib
// only prints the log, it doesn't return it.
@(private)
check_fragment_shader :: proc(source: string, allocator := context.temp_allocator) -> (ok: bool, log: string) {
	return check_shader(gl.FRAGMENT_SHADER, source, allocator)
}

@(private)
check_shader :: proc(kind: u32, source: string, allocator := context.temp_allocator) -> (ok: bool, log: string) {
	shader := gl.CreateShader(kind)
	defer gl.DeleteShader(shader)
	src := strings.clone_to_cstring(source, context.temp_allocator)
	gl.ShaderSource(shader, 1, &src, nil)
	gl.CompileShader(shader)
	status: i32
	gl.GetShaderiv(shader, gl.COMPILE_STATUS, &status)
	if status != 0 {
		return true, ""
	}
	length: i32
	gl.GetShaderiv(shader, gl.INFO_LOG_LENGTH, &length)
	buf := make([]u8, max(length, 1), allocator)
	gl.GetShaderInfoLog(shader, i32(len(buf)), &length, &buf[0])
	return false, string(buf[:length])
}

// Compiles the GLSL library every look shader starts with (vfx/glsl/*.glsl) on its own, so a
// mistake in it is reported once instead of breaking every look.
check_glsl_library :: proc() -> (ok: bool, log: string) {
	if ok, log = check_shader(gl.VERTEX_SHADER, vfx.VERTEX_SHADER); !ok {
		return
	}
	if ok, log = check_shader(gl.VERTEX_SHADER, vfx.VERTEX_INSTANCED_SHADER); !ok {
		return
	}
	if ok, log = check_fragment_shader(vfx.library_test_source()); !ok {
		return
	}
	return check_fragment_shader(vfx.batched_source(vfx.library_test_source(), context.temp_allocator))
}

// Instance records of look draws (see vfx/glsl/vertex.glsl), in a uniform buffer: each draw
// call binds a 64 KB window of it as its shader's `Instances` block, starting at its first
// record: a call of one instance reads its parameters at constant indices, as cheaply as
// uniforms, and a batched call (the shader's batched variant) at its instance's offset,
// which costs some drivers a memory load per parameter (see vfx.batched_source). All records of
// a draw list are uploaded at once, into fresh storage (draws already issued keep the old
// one): writing the buffer once per draw call either stalled on it or, when mapped, made the
// driver keep it in system memory, where large quads read their parameters slowly.
INSTANCE_VEC4S :: 4096 // vec4s in the Instances block (64 KB, see vfx/glsl/header.glsl)

@(private)
INSTANCE_BINDING :: 0

@(private)
Instances :: struct {
	buffer: u32,
	vao:    u32, // empty: the vertex shader has no attributes, but core GL needs a VAO bound
	align:  int, // GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT in vec4s: where a draw call's records may start
}

@(private)
instances: Instances

@(private)
init_instances :: proc() {
	max_block, align: i32
	gl.GetIntegerv(gl.MAX_UNIFORM_BLOCK_SIZE, &max_block)
	gl.GetIntegerv(gl.UNIFORM_BUFFER_OFFSET_ALIGNMENT, &align)
	assert(max_block >= INSTANCE_VEC4S * size_of([4]f32), "the GPU's uniform blocks are too small for the instance records")
	instances.align = max(int(align) / size_of([4]f32), 1)
	gl.GenBuffers(1, &instances.buffer)
	gl.GenVertexArrays(1, &instances.vao)
}

@(private)
upload_instances :: proc(records: [][4]f32) {
	if len(records) == 0 {
		return
	}
	// Every draw call binds a whole block, so there must be one block of room after the last
	// call's first record.
	size := len(records) * size_of([4]f32)
	gl.BindBuffer(gl.UNIFORM_BUFFER, instances.buffer)
	gl.BufferData(gl.UNIFORM_BUFFER, size + INSTANCE_VEC4S * size_of([4]f32), nil, gl.STREAM_DRAW)
	gl.BufferSubData(gl.UNIFORM_BUFFER, 0, size, raw_data(records))
	gl.BindBuffer(gl.UNIFORM_BUFFER, 0)
}

// Issues a draw call of a look shader (see DrawCall) from the records last uploaded, with
// the uniforms and textures every look reads. Anything raylib has batched must have been
// flushed before.
@(private)
draw_instances :: proc(entry: ^ShaderEntry, program: ^LookProgram, call: DrawCall) {
	gl.BindBufferRange(gl.UNIFORM_BUFFER, INSTANCE_BINDING, instances.buffer, call.first * size_of([4]f32), INSTANCE_VEC4S * size_of([4]f32))
	gl.UseProgram(program.shader.id)
	modelview := rl.MatrixToFloatV(rlGetMatrixModelview())
	projection := rl.MatrixToFloatV(rlGetMatrixProjection())
	gl.UniformMatrix4fv(program.loc_modelview, 1, false, &modelview[0])
	gl.UniformMatrix4fv(program.loc_projection, 1, false, &projection[0])
	gl.Uniform1f(program.loc_time, f32(engine.time))
	gl.Uniform1f(program.loc_px, call.px)
	// Uniforms persist in the program, so the lights are uploaded once per frame per program.
	if program.loc_light_count >= 0 && program.lights_frame != engine.frame {
		program.lights_frame = engine.frame
		l := light_uniforms()
		gl.Uniform1i(program.loc_light_count, l.count)
		gl.Uniform4fv(program.loc_light_pos, MAX_LIGHTS, &l.pos[0][0])
		gl.Uniform4fv(program.loc_light_color, MAX_LIGHTS, &l.color[0][0])
		gl.Uniform3fv(program.loc_ambient, 1, &l.ambient[0])
	}
	// The samplers' units are set once per program (make_look_program)
	if call.texture != 0 {
		gl.ActiveTexture(gl.TEXTURE0 + DATA_UNIT)
		gl.BindTexture(gl.TEXTURE_2D, call.texture)
	}
	if layer := entry.program.layer; layer >= 0 {
		// Buffer layers, drawn before the frame (render_layer_images)
		gl.ActiveTexture(gl.TEXTURE0 + LAYER_UNIT)
		gl.BindTexture(gl.TEXTURE_2D, layer_texture(layer).id)
		gl.Uniform2f(program.loc_screen, engine.width, engine.height)
	}
	if layer2 := entry.program.layer2; layer2 >= 0 {
		gl.ActiveTexture(gl.TEXTURE0 + LAYER2_UNIT)
		gl.BindTexture(gl.TEXTURE_2D, layer_texture(layer2).id)
	}
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindVertexArray(instances.vao)
	gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, i32(call.count))
	gl.BindVertexArray(0)
	gl.UseProgram(0)
}

// Texture units of the textures looks read (unit 0 stays raylib's)
@(private)
DATA_UNIT :: 1
@(private)
LAYER_UNIT :: 2
@(private)
LAYER2_UNIT :: 3

// GPU timestamps: one pool of queries per frame in flight, read back a few frames later so
// the CPU never waits on the GPU.
@(private)
GPU_FRAMES_IN_FLIGHT :: 4

@(private)
GpuStamp :: struct {
	query:  u32,
	shader: int, // whose draw ended at this stamp; -1 for anything else
	pixels: f32, // screen pixels covered by that draw
}

@(private)
GpuFrame :: struct {
	queries: [dynamic]u32, // grows to the most stamps a frame has needed
	stamps:  [dynamic]GpuStamp,
}

@(private)
GpuTimer :: struct {
	frames: [GPU_FRAMES_IN_FLIGHT]GpuFrame,
	frame:  int, // monotonically increasing frame counter
	active: bool, // stamping this frame
	dirty:  bool, // raylib has batched draws that no stamp accounts for yet
}

@(private)
gpu_timer: GpuTimer

@(private)
gpu_current :: proc() -> ^GpuFrame {
	return &gpu_timer.frames[gpu_timer.frame % GPU_FRAMES_IN_FLIGHT]
}

// Records a timestamp once everything submitted so far has been flushed to the GPU.
@(private)
gpu_stamp :: proc(shader: int, pixels: f32) {
	if !gpu_timer.active {
		return
	}
	rlDrawRenderBatchActive()
	f := gpu_current()
	i := len(f.stamps)
	if i >= len(f.queries) {
		q: u32
		gl.GenQueries(1, &q)
		append(&f.queries, q)
	}
	gl.QueryCounter(f.queries[i], gl.TIMESTAMP)
	append(&f.stamps, GpuStamp{f.queries[i], shader, pixels})
	gpu_timer.dirty = false
}

// Attributes whatever raylib batched since the last stamp (text, primitives) to "other".
@(private)
gpu_stamp_pending :: proc() {
	if gpu_timer.active && gpu_timer.dirty {
		gpu_stamp(-1, 0)
	}
}

@(private)
gpu_begin_frame :: proc(active: bool) {
	gpu_timer.frame += 1
	clear(&gpu_current().stamps)
	gpu_timer.active = active
	gpu_timer.dirty = false
	gpu_stamp(-1, 0)
}

@(private)
gpu_end_frame :: proc() {
	gpu_timer.dirty = true
	gpu_stamp_pending()
	gpu_timer.active = false
}

// The oldest frame in flight, if the GPU has finished it: nanoseconds between consecutive
// stamps, attributed to the stamp that closes each interval.
@(private)
gpu_read_finished :: proc() -> (stamps: []GpuStamp, durations: []u64, ok: bool) {
	if gpu_timer.frame < GPU_FRAMES_IN_FLIGHT {
		return
	}
	f := &gpu_timer.frames[(gpu_timer.frame + 1) % GPU_FRAMES_IN_FLIGHT]
	if len(f.stamps) < 2 {
		return
	}
	available: i32
	gl.GetQueryObjectiv(f.stamps[len(f.stamps) - 1].query, gl.QUERY_RESULT_AVAILABLE, &available)
	if available == 0 {
		return
	}
	durations = make([]u64, len(f.stamps), context.temp_allocator)
	previous: u64
	for s, i in f.stamps {
		t: u64
		gl.GetQueryObjectui64v(s.query, gl.QUERY_RESULT, &t)
		if i > 0 {
			durations[i] = t - previous
		}
		previous = t
	}
	stamps = f.stamps[:]
	clear(&f.stamps)
	return stamps, durations, true
}
