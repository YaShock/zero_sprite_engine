package engine

// Shader manifest: every shader a game compiles is remembered in .shader-cache/<title>.shaders
// and compiled again at the next startup, before the first frame, so effects that appear
// mid-game don't stall it while the driver compiles them. It's the automatic counterpart of
// precompile(), covering everything a previous run has seen.
//
// Entries are matched by their complete generated source, so an outdated manifest (after
// engine or look changes) only costs startup time, never a wrong shader. Entries that go
// unused for MANIFEST_MAX_UNUSED_RUNS runs in a row are dropped.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import rl "vendor:raylib"
import "vfx"

SHADER_MANIFEST_DIR :: ".shader-cache"
MANIFEST_MAX_UNUSED_RUNS :: 5

@(private)
MANIFEST_HEADER :: "zse-shader-manifest 1"

@(private)
WarmShader :: struct {
	source:      string, // owned
	label:       string, // owned
	shader:      rl.Shader,
	unused_runs: int, // consecutive earlier runs that didn't use it
	taken:       bool, // handed over to the shader cache this run
}

@(private)
Manifest :: struct {
	path: string, // owned; empty when the manifest is disabled
	warm: [dynamic]WarmShader,
	ms:   f64, // startup time spent compiling the warm shaders
}

@(private)
manifest: Manifest

// Compiles every shader listed in the game's manifest. The file holds records of
//     shader <unused runs> <source length in bytes> <label>
//     <source>
@(private)
load_shader_manifest :: proc(title: string) {
	safe_title, _ := strings.replace_all(title, " ", "_", context.temp_allocator)
	manifest.path = fmt.aprintf("%s/%s.shaders", SHADER_MANIFEST_DIR, safe_title)
	data, err := os.read_entire_file(manifest.path, context.temp_allocator)
	if err != nil {
		return // first run
	}
	start := time.tick_now()
	rest := string(data)
	if header, _ := next_line(&rest); header != MANIFEST_HEADER {
		return
	}
	for {
		line := next_line(&rest) or_break
		fields := strings.split_n(line, " ", 4, context.temp_allocator)
		if len(fields) < 3 || fields[0] != "shader" {
			break
		}
		unused := strconv.parse_int(fields[1]) or_else 0
		length, length_ok := strconv.parse_int(fields[2])
		if !length_ok || length > len(rest) {
			break
		}
		source := rest[:length]
		rest = rest[length:]
		next_line(&rest) // the line break after the source
		if shader, loaded := load_glsl(source); loaded {
			label := fields[3] if len(fields) > 3 else ""
			append(&manifest.warm, WarmShader{strings.clone(source), strings.clone(label), shader, unused, false})
		}
	}
	manifest.ms = time.duration_milliseconds(time.tick_diff(start, time.tick_now()))

	next_line :: proc(s: ^string) -> (line: string, ok: bool) {
		if len(s^) == 0 {
			return "", false
		}
		i := strings.index_byte(s^, '\n')
		if i < 0 {
			line, s^ = s^, ""
		} else {
			line, s^ = s^[:i], s^[i + 1:]
		}
		return line, true
	}
}

// The precompiled shader for exactly this source, if the manifest had it.
@(private)
take_warm_shader :: proc(source: string) -> (rl.Shader, bool) {
	for &w in manifest.warm {
		if !w.taken && w.source == source {
			w.taken = true
			return w.shader, true
		}
	}
	return {}, false
}

// Records every shader used this run, plus the manifest's unused entries until they've been
// unused for too long.
@(private)
write_shader_manifest :: proc() {
	if manifest.path == "" {
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, MANIFEST_HEADER)
	strings.write_byte(&sb, '\n')
	record :: proc(sb: ^strings.Builder, unused_runs: int, source, label: string) {
		one_line, _ := strings.replace_all(label, "\n", " ", context.temp_allocator)
		fmt.sbprintf(sb, "shader %d %d %s\n%s\n", unused_runs, len(source), one_line, source)
	}
	for e in shader_cache.entries {
		record(&sb, 0, e.program.source, e.label)
		if e.batched.shader.id != 0 {
			record(&sb, 0, vfx.batched_source(e.program.source, context.temp_allocator), e.label)
		}
	}
	for w in manifest.warm {
		if !w.taken && w.unused_runs < MANIFEST_MAX_UNUSED_RUNS {
			record(&sb, w.unused_runs + 1, w.source, w.label)
		}
	}
	_ = os.make_directory(SHADER_MANIFEST_DIR)
	if err := os.write_entire_file(manifest.path, transmute([]byte)strings.to_string(sb)); err != nil {
		fmt.eprintln("shader manifest: could not write", manifest.path, err)
	}
}

@(private)
unload_shader_manifest :: proc() {
	for w in manifest.warm {
		if !w.taken {
			rl.UnloadShader(w.shader) // taken ones belong to the shader cache now
		}
		delete(w.source)
		delete(w.label)
	}
	delete(manifest.warm)
	delete(manifest.path)
}
