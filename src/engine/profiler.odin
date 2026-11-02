package engine

// Built-in profiler. F3 toggles the overlay and F4 writes a report; ZSE_PROFILE=1 starts
// with the overlay on and writes a report on exit, ZSE_PROFILE_SECONDS=N also quits after
// N seconds (for repeatable benchmarks).
//
// What it measures:
// - CPU time per zone: the engine's frame phases plus any profile_scope() in game code
// - GPU time per look, from timestamp queries around every material draw
// - frame time consistency: percentiles, hitches and a frame graph
// - process memory (RSS), CPU usage and allocations per frame

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import rl "vendor:raylib"

PROFILE_HISTORY :: 240 // frames in the overlay graph and rolling statistics
PROFILE_SMOOTHING :: 0.05 // weight of the newest frame in rolling averages
PROFILE_REPORT_DIR :: "profiles"

// A zone is identified by its name and its parent zone, so the zones form a call tree.
@(private)
Zone :: struct {
	name:      string,
	parent:    int, // -1 for top-level zones
	depth:     int,
	frame_ns:  i64,
	calls:     int,
	avg_ms:    f64,
	max_ms:    f64, // slowly decaying peak
	avg_calls: f64,
	total_ms:  f64,
	frames:    int,
}

@(private)
LookStats :: struct {
	frame_ms:     f64,
	frame_draws:  int,
	frame_pixels: f64,
	avg_ms:       f64,
	avg_draws:    f64,
	avg_pixels:   f64,
	total_ms:     f64,
	total_draws:  int,
	total_pixels: f64,
}

// Wraps an allocator to count allocations and bytes requested per frame.
@(private)
Counting :: struct {
	backing:     mem.Allocator,
	allocations: int,
	bytes:       int,
}

@(private)
counting_allocator_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	c := (^Counting)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		c.allocations += 1
		c.bytes += size
	case .Resize, .Resize_Non_Zeroed:
		c.allocations += 1
		c.bytes += max(size - old_size, 0)
	}
	return c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(private)
counting_allocator :: proc(c: ^Counting) -> mem.Allocator {
	return {counting_allocator_proc, c}
}

@(private)
LateCompile :: struct {
	label: string, // owned
	ms:    f64,
}

@(private)
Profiler :: struct {
	active:          bool, // collecting zones, GPU timings and memory
	overlay:         bool,
	report_on_exit:  bool,
	quit_after:      f64,
	title:           string,
	session_start:   time.Tick,
	frame_start:     time.Tick,
	zones:           [dynamic]Zone,
	stack:           [32]struct {
		zone:  int,
		start: time.Tick,
	},
	depth:           int,
	// Frame times
	history:         [PROFILE_HISTORY]f32, // ms, ring
	gpu_history:     [PROFILE_HISTORY]f32,
	history_index:   int,
	frames:          [dynamic]f32, // whole profiled session, for percentiles
	presents:        [dynamic]f32, // time each of those frames spent in present
	avg_frame_ms:    f64,
	// GPU
	looks:           [dynamic]LookStats, // indexed like shader_cache.entries
	avg_gpu_ms:      f64,
	total_gpu_ms:    f64,
	gpu_frames:      int,
	frame_draws:     int,
	avg_draws:       f64,
	avg_overdraw:    f64,
	// Memory and CPU
	heap, temp:      Counting,
	avg_allocations: f64,
	avg_alloc_bytes: f64,
	avg_temp_bytes:  f64,
	total_allocs:    int,
	rss, rss_start:  int,
	rss_peak:        int,
	cpu_percent:     f64,
	cpu_sum:         f64,
	cpu_samples:     int,
	last_sample:     time.Tick,
	last_cpu_ticks:  int,
	max_entities:    int,
	// Shader work, counted whether or not profiling is active
	startup_ms:      f64, // from init_context to the end of the first frame
	first_frame:     bool, // still starting up: until the first frame has been drawn
	frames_begun:    int,
	materials:       int,
	compiles:        int,
	compile_ms:      f64,
	compile_max_ms:  f64,
	late_compiles:   [dynamic]LateCompile, // shaders first compiled after startup
	// Hitches spent almost entirely inside the buffer swap: the compositor or vsync held the
	// frame back (e.g. while the window isn't visible), not the game's own work.
	present_stalls:  int,
}

@(private)
profiler: Profiler

@(private)
init_profiler :: proc(title: string) {
	profiler.title = strings.clone(title)
	profiler.session_start = time.tick_now()
	profiler.frame_start = profiler.session_start
	profiler.first_frame = true
	if os.get_env("ZSE_PROFILE", context.temp_allocator) != "" {
		set_profiling(true)
		profiler.report_on_exit = true
	}
	if s := os.get_env("ZSE_PROFILE_SECONDS", context.temp_allocator); s != "" {
		profiler.quit_after = strconv.parse_f64(s) or_else 0
		profiler.report_on_exit = true
		set_profiling(true)
	}
}

@(private)
set_profiling :: proc(on: bool) {
	profiler.overlay = on
	if on && !profiler.active {
		profiler.active = true
		profiler.session_start = time.tick_now()
		profiler.rss_start = read_rss()
	}
}

// Times the rest of the enclosing scope as a named zone (no-op while the profiler is off).
@(deferred_none = profile_end)
profile_scope :: proc(name: string) {
	profile_begin(name)
}

profile_begin :: proc(name: string) {
	if !profiler.active || profiler.depth >= len(profiler.stack) {
		return
	}
	parent := profiler.stack[profiler.depth - 1].zone if profiler.depth > 0 else -1
	index := -1
	for z, i in profiler.zones {
		if z.parent == parent && z.name == name {
			index = i
			break
		}
	}
	if index < 0 {
		append(&profiler.zones, Zone{name = strings.clone(name), parent = parent, depth = profiler.depth})
		index = len(profiler.zones) - 1
	}
	profiler.stack[profiler.depth] = {index, time.tick_now()}
	profiler.depth += 1
}

profile_end :: proc() {
	if !profiler.active || profiler.depth == 0 {
		return
	}
	profiler.depth -= 1
	top := profiler.stack[profiler.depth]
	z := &profiler.zones[top.zone]
	z.frame_ns += i64(time.tick_diff(top.start, time.tick_now()))
	z.calls += 1
}

// Called once per frame before anything else: closes the previous frame's statistics.
@(private)
profiler_begin_frame :: proc() {
	now := time.tick_now()
	frame_ms := f32(time.duration_milliseconds(time.tick_diff(profiler.frame_start, now)))
	profiler.frame_start = now
	profiler.depth = 0
	profiler.frames_begun += 1
	if profiler.frames_begun <= 2 {
		// Everything up to the end of the first frame is startup, not gameplay: level setup,
		// shader compiles, and the driver's own work when each shader is first drawn. Zones
		// timed during it are discarded.
		profiler.first_frame = profiler.frames_begun < 2
		profiler.startup_ms += f64(frame_ms)
		profiler.session_start = now
		for &z in profiler.zones {
			z.frame_ns, z.calls = 0, 0
		}
		gpu_begin_frame(profiler.active)
		return
	}

	if rl.IsKeyPressed(.F3) {
		set_profiling(!profiler.overlay)
	}
	if rl.IsKeyPressed(.F4) && profiler.active {
		write_report()
	}

	profiler.history_index = (profiler.history_index + 1) % PROFILE_HISTORY
	profiler.history[profiler.history_index] = frame_ms
	// Seed the average with the first real frame rather than letting it climb from zero.
	previous_avg := profiler.avg_frame_ms if profiler.avg_frame_ms > 0 else f64(frame_ms)
	profiler.avg_frame_ms = math.lerp(previous_avg, f64(frame_ms), PROFILE_SMOOTHING)

	if profiler.active {
		present: f32
		for z in profiler.zones {
			if z.parent == -1 && z.name == "present" {
				present = f32(f64(z.frame_ns) / 1e6)
			}
		}
		append(&profiler.frames, frame_ms)
		append(&profiler.presents, present)
		if is_present_stall(frame_ms, present, f32(previous_avg)) {
			profiler.present_stalls += 1
		}
		for &z in profiler.zones {
			ms := f64(z.frame_ns) / 1e6
			z.avg_ms = math.lerp(z.avg_ms, ms, PROFILE_SMOOTHING)
			z.max_ms = max(z.max_ms * 0.995, ms)
			z.avg_calls = math.lerp(z.avg_calls, f64(z.calls), PROFILE_SMOOTHING)
			z.total_ms += ms
			z.frames += 1
			z.frame_ns, z.calls = 0, 0
		}
		h, t := &profiler.heap, &profiler.temp
		profiler.avg_allocations = math.lerp(profiler.avg_allocations, f64(h.allocations), PROFILE_SMOOTHING)
		profiler.avg_alloc_bytes = math.lerp(profiler.avg_alloc_bytes, f64(h.bytes), PROFILE_SMOOTHING)
		profiler.avg_temp_bytes = math.lerp(profiler.avg_temp_bytes, f64(t.bytes), PROFILE_SMOOTHING)
		profiler.total_allocs += h.allocations
		profiler.avg_draws = math.lerp(profiler.avg_draws, f64(profiler.frame_draws), PROFILE_SMOOTHING)
		profiler.max_entities = max(profiler.max_entities, len(scene.entities))
		read_gpu_results()
		sample_process()
	}
	profiler.heap.allocations, profiler.heap.bytes = 0, 0
	profiler.temp.allocations, profiler.temp.bytes = 0, 0
	profiler.frame_draws = 0
	gpu_begin_frame(profiler.active)
}

@(private)
profiler_should_quit :: proc() -> bool {
	return profiler.quit_after > 0 && time.duration_seconds(time.tick_diff(profiler.session_start, time.tick_now())) >= profiler.quit_after
}

@(private)
read_gpu_results :: proc() {
	stamps, durations, ok := gpu_read_finished()
	if !ok {
		return
	}
	for len(profiler.looks) < len(shader_cache.entries) {
		append(&profiler.looks, LookStats{})
	}
	total, pixels: f64
	for s, i in stamps {
		ms := f64(durations[i]) / 1e6
		total += ms
		if s.shader >= 0 && s.shader < len(profiler.looks) {
			l := &profiler.looks[s.shader]
			l.frame_ms += ms
			l.frame_draws += 1
			l.frame_pixels += f64(s.pixels)
			pixels += f64(s.pixels)
		}
	}
	for &l in profiler.looks {
		l.avg_ms = math.lerp(l.avg_ms, l.frame_ms, PROFILE_SMOOTHING)
		l.avg_draws = math.lerp(l.avg_draws, f64(l.frame_draws), PROFILE_SMOOTHING)
		l.avg_pixels = math.lerp(l.avg_pixels, l.frame_pixels, PROFILE_SMOOTHING)
		l.total_ms += l.frame_ms
		l.total_draws += l.frame_draws
		l.total_pixels += l.frame_pixels
		l.frame_ms, l.frame_draws, l.frame_pixels = 0, 0, 0
	}
	screen := f64(rl.GetRenderWidth() * rl.GetRenderHeight())
	profiler.avg_overdraw = math.lerp(profiler.avg_overdraw, pixels / max(screen, 1), PROFILE_SMOOTHING)
	profiler.avg_gpu_ms = math.lerp(profiler.avg_gpu_ms, total, PROFILE_SMOOTHING)
	profiler.gpu_history[profiler.history_index] = f32(total)
	profiler.total_gpu_ms += total
	profiler.gpu_frames += 1
}

// Resident memory in bytes, from /proc/self/statm (Linux; 0 elsewhere).
@(private)
read_rss :: proc() -> int {
	data, err := os.read_entire_file("/proc/self/statm", context.temp_allocator)
	if err != nil {
		return 0
	}
	fields := strings.fields(string(data), context.temp_allocator)
	if len(fields) < 2 {
		return 0
	}
	pages := strconv.parse_int(fields[1]) or_else 0
	return pages * int(posix.sysconf(._PAGE_SIZE))
}

// User + system CPU time of the process in clock ticks, from /proc/self/stat.
@(private)
read_cpu_ticks :: proc() -> int {
	data, err := os.read_entire_file("/proc/self/stat", context.temp_allocator)
	if err != nil {
		return 0
	}
	s := string(data)
	// Fields after the command name, which is parenthesized and may contain spaces.
	fields := strings.fields(s[strings.last_index_byte(s, ')') + 1:], context.temp_allocator)
	if len(fields) < 13 {
		return 0
	}
	return (strconv.parse_int(fields[11]) or_else 0) + (strconv.parse_int(fields[12]) or_else 0)
}

@(private)
sample_process :: proc() {
	now := time.tick_now()
	elapsed := time.duration_seconds(time.tick_diff(profiler.last_sample, now))
	if elapsed < 0.5 {
		return
	}
	ticks := read_cpu_ticks()
	if profiler.last_cpu_ticks > 0 {
		ticks_per_second := f64(posix.sysconf(._CLK_TCK))
		profiler.cpu_percent = f64(ticks - profiler.last_cpu_ticks) / ticks_per_second / elapsed * 100
		profiler.cpu_sum += profiler.cpu_percent
		profiler.cpu_samples += 1
	}
	profiler.last_cpu_ticks = ticks
	profiler.last_sample = now
	profiler.rss = read_rss()
	profiler.rss_peak = max(profiler.rss_peak, profiler.rss)
}

// Top-level zone's rolling average.
@(private)
zone_avg :: proc(name: string) -> f64 {
	for z in profiler.zones {
		if z.parent == -1 && z.name == name {
			return z.avg_ms
		}
	}
	return 0
}

// Zones that ran during the session, in call-tree order (depth first, siblings by first use).
@(private)
zone_tree :: proc() -> []int {
	order := make([dynamic]int, context.temp_allocator)
	visit :: proc(parent: int, order: ^[dynamic]int) {
		for z, i in profiler.zones {
			if z.parent == parent && z.total_ms > 0 {
				append(order, i)
				visit(i, order)
			}
		}
	}
	visit(-1, &order)
	return order[:]
}

// What limits the frame rate, judged from rolling averages.
@(private)
verdict :: proc() -> (text: string, color: rl.Color) {
	cpu := zone_avg("update") + zone_avg("render") + zone_avg("cleanup")
	gpu := profiler.avg_gpu_ms
	frame := max(profiler.avg_frame_ms, 0.001)
	switch {
	case gpu > cpu && gpu > 0.75 * frame:
		return fmt.tprintf("GPU-bound: %.1f ms shading per %.1f ms frame", gpu, frame), {255, 120, 90, 255}
	case cpu > 0.75 * frame:
		return fmt.tprintf("CPU-bound: %.1f ms work per %.1f ms frame", cpu, frame), {255, 120, 90, 255}
	case engine.frame_budget == 0 && !engine.vsync_on && zone_avg("present") > 0.5 * frame:
		// Nothing caps the frame rate, yet most of the frame goes into the buffer swap.
		return fmt.tprintf("Present-bound: %.1f ms of a %.1f ms frame in the buffer swap (driver/compositor)", zone_avg("present"), frame), {255, 120, 90, 255}
	}
	return fmt.tprintf("Headroom: CPU %.0f%%, GPU %.0f%% of frame (vsync/FPS cap)", cpu / frame * 100, gpu / frame * 100), {140, 230, 140, 255}
}

// Percentile of a sorted slice.
@(private)
percentile :: proc(sorted: []f32, p: f64) -> f32 {
	if len(sorted) == 0 {
		return 0
	}
	return sorted[min(int(p * f64(len(sorted) - 1) + 0.5), len(sorted) - 1)]
}

// A hitch that went almost entirely into waiting in present: the compositor or vsync held the
// frame back, not the game's own work.
@(private)
is_present_stall :: proc(frame, present, typical: f32) -> bool {
	return frame > 2 * typical && present > 0.8 * frame
}

// Frames slower than twice the median count as hitches.
@(private)
frame_stats :: proc(frames: []f32) -> (p50, p90, p99, p999, worst: f32, hitches: int) {
	sorted := slice.clone(frames, context.temp_allocator)
	slice.sort(sorted)
	p50, p90, p99, p999 = percentile(sorted, 0.5), percentile(sorted, 0.9), percentile(sorted, 0.99), percentile(sorted, 0.999)
	worst = sorted[len(sorted) - 1] if len(sorted) > 0 else 0
	for f in frames {
		if f > 2 * p50 {
			hitches += 1
		}
	}
	return
}

@(private)
LookRow :: struct {
	name:                 string,
	ms, draws, megapixels: f64,
}

// GPU cost per look, most expensive first. `session` uses whole-session averages instead of
// rolling ones; `short` groups by the function that built the look, ignoring the call site.
@(private)
look_rows :: proc(session, short: bool) -> []LookRow {
	rows := make([dynamic]LookRow, context.temp_allocator)
	frames := f64(max(profiler.gpu_frames, 1))
	for l, i in profiler.looks {
		row := LookRow{look_label(i), l.avg_ms, l.avg_draws, l.avg_pixels / 1e6}
		if session {
			row = {row.name, l.total_ms / frames, f64(l.total_draws) / frames, l.total_pixels / frames / 1e6}
		}
		if row.draws < 0.01 {
			continue
		}
		if cut := strings.index(row.name, " ("); short && cut >= 0 {
			row.name = row.name[:cut]
		}
		merged := false
		for &r in rows {
			if r.name == row.name {
				r.ms, r.draws, r.megapixels = r.ms + row.ms, r.draws + row.draws, r.megapixels + row.megapixels
				merged = true
				break
			}
		}
		if !merged {
			append(&rows, row)
		}
	}
	slice.sort_by(rows[:], proc(a, b: LookRow) -> bool {return a.ms > b.ms})
	return rows[:]
}

@(private)
look_label :: proc(index: int) -> string {
	label := shader_cache.entries[index].label
	return label if label != "" else fmt.tprintf("shader %d", index)
}

@(private)
megabytes :: proc(bytes: int) -> f64 {
	return f64(bytes) / (1024 * 1024)
}

// ---------------------------------------------------------------------------------------
// Overlay

@(private)
draw_profiler_overlay :: proc() {
	if !profiler.overlay {
		return
	}
	FONT :: 20
	LINE :: 22
	COLUMN :: 300 // where the number columns start
	x: i32 = 12
	y: i32 = 12
	text :: proc(s: string, x, y: i32, color := rl.Color{230, 235, 245, 255}) {
		rl.DrawText(strings.clone_to_cstring(s, context.temp_allocator), x, y, FONT, color)
	}
	dim := rl.Color{150, 160, 180, 255}
	header := rl.Color{255, 210, 100, 255}

	zones := zone_tree()
	looks := look_rows(false, true)
	looks = looks[:min(len(looks), 8)]
	graph_h: i32 = 60
	extra_lines := (1 if len(profiler.late_compiles) > 0 else 0) + (1 if profiler.present_stalls > 0 else 0)
	height := i32(LINE * (11 + len(zones) + len(looks) + extra_lines)) + graph_h + 24
	rl.DrawRectangle(x - 6, y - 6, PROFILE_HISTORY * 2 + 132, height, {8, 10, 16, 215})

	text("PROFILER   F3 hide   F4 report", x, y, header)
	y += LINE
	text(gpu_renderer(), x, y, dim)
	y += LINE
	_, _, p99, _, worst, hitches := frame_stats(profiler.history[:])
	text(fmt.tprintf("FPS %.0f   %.2f ms   p99 %.2f   max %.2f   hitches %d", 1000 / max(profiler.avg_frame_ms, 0.001), profiler.avg_frame_ms, p99, worst, hitches), x, y)
	if profiler.present_stalls > 0 {
		y += LINE
		text(fmt.tprintf("%d stalls waiting on the compositor in present (not game work)", profiler.present_stalls), x, y, dim)
	}
	y += LINE + 2

	// Frame graph: frame times as bars, GPU time as dots; lines at 60 and 30 FPS.
	scale := f32(graph_h) / 40 // 40 ms full height
	rl.DrawRectangle(x, y, PROFILE_HISTORY * 2, graph_h, {20, 24, 34, 255})
	for i in 0 ..< PROFILE_HISTORY {
		k := (profiler.history_index + 1 + i) % PROFILE_HISTORY
		ms := profiler.history[k]
		h := i32(min(ms * scale, f32(graph_h)))
		color := rl.Color{90, 200, 120, 255} if ms < 17.5 else rl.Color{240, 200, 80, 255} if ms < 34 else rl.Color{240, 90, 80, 255}
		rl.DrawRectangle(x + i32(i) * 2, y + graph_h - h, 2, h, color)
		if g := i32(min(profiler.gpu_history[k] * scale, f32(graph_h))); g > 0 {
			rl.DrawRectangle(x + i32(i) * 2, y + graph_h - g, 2, 2, {120, 170, 255, 255})
		}
	}
	for ms in ([2]f32{16.67, 33.33}) {
		ly := y + graph_h - i32(ms * scale)
		rl.DrawLine(x, ly, x + PROFILE_HISTORY * 2, ly, {255, 255, 255, 70})
	}
	text("60 fps", x + PROFILE_HISTORY * 2 + 6, y + graph_h - i32(16.67 * scale) - 8, dim)
	text("30 fps", x + PROFILE_HISTORY * 2 + 6, y + graph_h - i32(33.33 * scale) - 8, dim)
	y += graph_h + 4
	text("bars: frame time   dots: GPU time", x, y, dim)
	y += LINE + 2

	v, vc := verdict()
	text(v, x, y, vc)
	y += LINE + 4

	text("CPU ZONE", x, y, header)
	text("   avg     max   calls", x + COLUMN, y, header)
	y += LINE
	for index in zones {
		z := profiler.zones[index]
		text(fmt.tprintf("%*s%s", z.depth * 2, "", z.name), x, y)
		text(fmt.tprintf("% 6.2f  % 6.2f  % 6.1f", z.avg_ms, z.max_ms, z.avg_calls), x + COLUMN, y)
		y += LINE
	}
	y += 4
	text(fmt.tprintf("GPU %.2f ms", profiler.avg_gpu_ms), x, y, header)
	text("    ms   share  draws", x + COLUMN, y, header)
	y += LINE
	for r in looks {
		name := r.name[:min(len(r.name), 26)]
		text(name, x, y)
		text(fmt.tprintf("% 6.2f  % 5.1f%%  % 5.0f", r.ms, r.ms / max(profiler.avg_gpu_ms, 0.0001) * 100, r.draws), x + COLUMN, y)
		y += LINE
	}
	y += 4
	text(fmt.tprintf("RSS %.1f MB (peak %.1f)   CPU %.0f%%", megabytes(profiler.rss), megabytes(profiler.rss_peak), profiler.cpu_percent), x, y)
	y += LINE
	text(fmt.tprintf("allocs/frame %.0f (%.1f KB)   temp %.1f KB/frame", profiler.avg_allocations, profiler.avg_alloc_bytes / 1024, profiler.avg_temp_bytes / 1024), x, y)
	y += LINE
	text(fmt.tprintf("entities %d   draws %.0f   overdraw %.2fx", len(scene.entities), profiler.avg_draws, profiler.avg_overdraw), x, y)
	y += LINE
	text(fmt.tprintf("shaders %d   compiling %.0f ms (max %.0f)   startup %.0f ms", len(shader_cache.entries), profiler.compile_ms, profiler.compile_max_ms, profiler.startup_ms), x, y)
	if n := len(profiler.late_compiles); n > 0 {
		y += LINE
		worst: f64
		for c in profiler.late_compiles {
			worst = max(worst, c.ms)
		}
		text(fmt.tprintf("%d shaders compiled mid-game (worst %.0f ms): precompile them", n, worst), x, y, {255, 120, 90, 255})
	}
}

// ---------------------------------------------------------------------------------------
// Report

// Writes the session's statistics to profiles/<title>-<date>.txt.
@(private)
write_report :: proc() {
	if len(profiler.frames) == 0 {
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	w :: fmt.sbprintf
	seconds := time.duration_seconds(time.tick_diff(profiler.session_start, time.tick_now()))
	frames := len(profiler.frames)
	p50, p90, p99, p999, worst, hitches := frame_stats(profiler.frames[:])
	total: f64
	for f in profiler.frames {
		total += f64(f)
	}
	avg := total / f64(frames)
	// 1% low: average FPS over the slowest 1% of frames.
	sorted := slice.clone(profiler.frames[:], context.temp_allocator)
	slice.sort(sorted)
	slowest := sorted[len(sorted) - max(len(sorted) / 100, 1):]
	slow_sum: f64
	for f in slowest {
		slow_sum += f64(f)
	}

	w(&sb, "Zero Sprite Engine profile: %s\n", profiler.title)
	w(&sb, "GPU: %s   window %dx%d\n", gpu_renderer(), rl.GetRenderWidth(), rl.GetRenderHeight())
	w(&sb, "Duration %.1f s, %d frames\n\n", seconds, frames)

	w(&sb, "FRAME TIME (ms)\n")
	w(&sb, "  average %.2f (%.1f FPS)   1%% low %.1f FPS\n", avg, 1000 / avg, 1000 / (slow_sum / f64(len(slowest))))
	w(&sb, "  median %.2f   p90 %.2f   p99 %.2f   p99.9 %.2f   max %.2f\n", p50, p90, p99, p999, worst)
	w(&sb, "  hitches (> 2x median): %d (%.2f%% of frames)\n", hitches, f64(hitches) / f64(frames) * 100)
	stalls, longest_stall := 0, f32(0)
	for f, i in profiler.frames {
		if is_present_stall(f, profiler.presents[i], p50) {
			stalls += 1
			longest_stall = max(longest_stall, f)
		}
	}
	if stalls > 0 {
		w(&sb, "    of which %d were spent waiting in present (longest %.0f ms): the compositor or vsync\n", stalls, longest_stall)
		w(&sb, "    held the frame back, e.g. while the window wasn't visible; not the game's own work\n")
	}
	v, _ := verdict()
	w(&sb, "  %s\n\n", v)

	w(&sb, "CPU ZONES                              avg ms/frame   peak ms   calls/frame   %% of frame\n")
	for index in zone_tree() {
		z := profiler.zones[index]
		mean := z.total_ms / f64(max(z.frames, 1))
		name := fmt.tprintf("%*s%s", z.depth * 2, "", z.name)
		w(&sb, "  %-36s % 10.3f % 9.2f % 13.1f % 11.1f\n", name, mean, z.max_ms, z.avg_calls, mean / avg * 100)
	}

	gpu_avg := profiler.total_gpu_ms / f64(max(profiler.gpu_frames, 1))
	w(&sb, "\nGPU BY LOOK (%.3f ms/frame measured over %d frames)\n", gpu_avg, profiler.gpu_frames)
	w(&sb, "  %-58s %9s %7s %12s %10s\n", "look (created in, at)", "ms/frame", "share", "draws/frame", "Mpx/frame")
	for r in look_rows(true, false) {
		w(&sb, "  %-58s % 9.3f % 6.1f%% % 12.1f % 10.2f\n", r.name, r.ms, r.ms / max(gpu_avg, 0.0001) * 100, r.draws, r.megapixels)
	}

	w(&sb, "\nMEMORY AND CPU\n")
	w(&sb, "  RSS at start %.1f MB, now %.1f MB, peak %.1f MB\n", megabytes(profiler.rss_start), megabytes(read_rss()), megabytes(profiler.rss_peak))
	w(&sb, "  heap allocations %.1f per frame (%d total)\n", f64(profiler.total_allocs) / f64(frames), profiler.total_allocs)
	w(&sb, "  CPU usage %.0f%% of one core on average\n", profiler.cpu_sum / f64(max(profiler.cpu_samples, 1)))
	w(&sb, "  entities now %d, peak %d\n", len(scene.entities), profiler.max_entities)
	w(&sb, "\nSHADERS\n")
	w(&sb, "  startup (init to first frame) %.0f ms\n", profiler.startup_ms)
	if n := len(manifest.warm); n > 0 {
		used := 0
		for s in manifest.warm {
			used += 1 if s.taken else 0
		}
		w(&sb, "  %d shaders compiled ahead from the shader manifest in %.0f ms, %d of them used\n", n, manifest.ms, used)
	}
	w(&sb, "  %d materials made, %d distinct shaders compiled in %.0f ms (slowest %.0f ms)\n", profiler.materials, profiler.compiles, profiler.compile_ms, profiler.compile_max_ms)
	if len(profiler.late_compiles) > 0 {
		w(&sb, "  compiled mid-game, each a hitch; precompile() these at load time:\n")
		for c in profiler.late_compiles {
			w(&sb, "    % 8.1f ms  %s\n", c.ms, c.label)
		}
	}

	_ = os.make_directory(PROFILE_REPORT_DIR)
	now := time.now()
	year, month, day := time.date(now)
	hour, minute, second := time.clock(now)
	safe_title, _ := strings.replace_all(profiler.title, " ", "_", context.temp_allocator)
	path := fmt.tprintf(
		"%s/%s-%04d%02d%02d-%02d%02d%02d.txt",
		PROFILE_REPORT_DIR,
		safe_title,
		year,
		int(month),
		day,
		hour,
		minute,
		second,
	)
	if err := os.write_entire_file(path, transmute([]byte)strings.to_string(sb)); err != nil {
		fmt.eprintln("profiler: could not write", path, err)
		return
	}
	fmt.println("profiler: report written to", path)
}

