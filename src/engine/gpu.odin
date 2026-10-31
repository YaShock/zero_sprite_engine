package engine

// Direct OpenGL access for what raylib doesn't expose: GPU timer queries for the profiler and
// shader compile logs for reporting errors in generated GLSL.

import "core:strings"
import "vfx"
import gl "vendor:OpenGL"
import "vendor:glfw"

// vendor:raylib/rlgl links its own bundled static library, which distro/Nix builds of raylib
// don't ship; the few rlgl symbols needed here are exported by the system raylib anyway.
foreign import raylib_lib "system:raylib"

@(private, default_calling_convention = "c")
foreign raylib_lib {
	rlGetTextureIdDefault :: proc() -> u32 ---
	rlGetShaderIdDefault :: proc() -> u32 ---
	rlDrawRenderBatchActive :: proc() ---
	rlEnableColorBlend :: proc() ---
	rlDisableColorBlend :: proc() ---
}

// raylib creates its window through the system GLFW, so GLFW's loader sees its context.
@(private)
init_gpu :: proc() {
	gl.load_up_to(3, 3, proc(p: rawptr, name: cstring) {
		(^rawptr)(p)^ = glfw.GetProcAddress(name)
	})
}

gpu_renderer :: proc() -> string {
	return string(gl.GetString(gl.RENDERER))
}

// Compiles a fragment shader on its own to get the driver's verdict and error log; raylib
// only prints the log, it doesn't return it.
@(private)
check_fragment_shader :: proc(source: string, allocator := context.temp_allocator) -> (ok: bool, log: string) {
	shader := gl.CreateShader(gl.FRAGMENT_SHADER)
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
	return check_fragment_shader(vfx.library_test_source())
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
