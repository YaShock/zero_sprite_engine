package engine

// Direct OpenGL access for what raylib doesn't expose: instanced draws of looks, GPU timer
// queries for the profiler and shader compile logs for reporting errors in generated GLSL.

import "core:strings"
import "vfx"
import gl "vendor:OpenGL"
import rl "vendor:raylib"
import "vendor:glfw"

// vendor:raylib/rlgl links its own bundled static library, which distro/Nix builds of raylib
// don't ship; the few rlgl symbols needed here are exported by the system raylib anyway.
foreign import raylib_lib "system:raylib"

@(private, default_calling_convention = "c")
foreign raylib_lib {
	rlGetShaderIdDefault :: proc() -> u32 ---
	rlDrawRenderBatchActive :: proc() ---
	rlEnableColorBlend :: proc() ---
	rlDisableColorBlend :: proc() ---
	rlGetMatrixModelview :: proc() -> rl.Matrix ---
	rlGetMatrixProjection :: proc() -> rl.Matrix ---
}

// raylib creates its window through the system GLFW, so GLFW's loader sees its context.
@(private)
init_gpu :: proc() {
	gl.load_up_to(3, 3, proc(p: rawptr, name: cstring) {
		(^rawptr)(p)^ = glfw.GetProcAddress(name)
	})
	init_instances()
}

gpu_renderer :: proc() -> string {
	return string(gl.GetString(gl.RENDERER))
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
	return check_fragment_shader(vfx.library_test_source())
}

// Instance records of look draws (see vfx/glsl/vertex.glsl), in a uniform buffer: each draw
// call binds a 64 KB window of it as its shader's `Instances` block, so a look reads its
// parameters as cheaply as uniforms while a warp stays within one instance. All records of
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

// Draws `count` instances of a look shader whose records start at `first` in the records
// last uploaded, with the uniforms that every look reads set to the values given. Anything
// raylib has batched must have been flushed before.
@(private)
draw_instances :: proc(entry: ^ShaderEntry, first, count: int, px: f32) {
	gl.BindBufferRange(gl.UNIFORM_BUFFER, INSTANCE_BINDING, instances.buffer, first * size_of([4]f32), INSTANCE_VEC4S * size_of([4]f32))
	gl.UseProgram(entry.shader.id)
	modelview := rl.MatrixToFloatV(rlGetMatrixModelview())
	projection := rl.MatrixToFloatV(rlGetMatrixProjection())
	gl.UniformMatrix4fv(entry.loc_modelview, 1, false, &modelview[0])
	gl.UniformMatrix4fv(entry.loc_projection, 1, false, &projection[0])
	gl.Uniform1f(entry.loc_time, f32(engine.time))
	gl.Uniform1f(entry.loc_px, px)
	// Uniforms persist in the program, so the lights are uploaded once per frame per shader.
	if entry.loc_light_count >= 0 && entry.lights_frame != engine.frame {
		entry.lights_frame = engine.frame
		l := light_uniforms()
		gl.Uniform1i(entry.loc_light_count, l.count)
		gl.Uniform4fv(entry.loc_light_pos, MAX_LIGHTS, &l.pos[0][0])
		gl.Uniform4fv(entry.loc_light_color, MAX_LIGHTS, &l.color[0][0])
		gl.Uniform3fv(entry.loc_ambient, 1, &l.ambient[0])
	}
	gl.BindVertexArray(instances.vao)
	gl.DrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, i32(count))
	gl.BindVertexArray(0)
	gl.UseProgram(0)
}

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
