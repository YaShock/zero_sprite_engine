package main

// Entity editor: write a look script on the left, see it rendered live on the right, and
// tweak its params with sliders. Params declared with `animate` swing between their bounds.
//
//     odin run src/tools/editor            open the editor
//     odin run src/tools/editor -- --check compile every preset and exit (non-zero on errors)

import eng "../../engine"
import fx "../../engine/vfx"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

PRESET_DIR :: #directory + "/presets"
RECOMPILE_DELAY :: 0.25 // seconds without typing before the script is recompiled

TOOLBAR_H :: 48
SIDEBAR_W :: 170
STATUS_H :: 56

View :: enum {
	Params,
	Reference,
	Glsl,
}

ParamState :: struct {
	spec:    fx.ScriptParam, // name owned
	value:   [4]f32,
	playing: bool, // animated params can be held still to tweak them
}

App :: struct {
	editor:       TextEditor,
	path:         string, // owned
	modified:     bool,
	presets:      [dynamic]string, // owned paths
	pending_open: int, // preset clicked while there were unsaved changes
	// Current look
	material:     eng.Material,
	has_look:     bool,
	look_size:    [2]f32,
	pad:          f32,
	lifetime:     f32,
	params:       [dynamic]ParamState,
	nodes:        int,
	compile_ms:   f64,
	glsl:         string, // owned: generated source, or the driver's error log
	// Errors from the last compile; the previous look stays on screen meanwhile
	error:        string, // owned
	error_line:   int,
	// Editing and preview state
	dirty:        bool,
	idle:         f32,
	spawn_time:   f32,
	paused:       bool,
	zoom:         f32,
	view:         View,
	scroll:       f32,
	status:       string, // owned
	status_time:  f64,
}

app: App

main :: proc() {
	check := slice.contains(os.args, "--check")
	eng.init_context(
		eng.InitOptions {
			width = 1600,
			height = 900,
			fps = 60,
			title = "VFX Editor",
			num_layers = 1,
			bg_color = BACKGROUND,
			resizable = true,
			match_window = true,
			no_shader_manifest = true,
		},
	)
	app.zoom = 1
	app.pending_open = -1
	load_preset_list()
	if check {
		os.exit(0 if check_presets() else 1)
	}
	if len(app.presets) > 0 {
		open_file(app.presets[0])
	} else {
		new_file()
	}
	eng.set_overlay(draw)
	eng.run(update)
}

load_preset_list :: proc() {
	entries, err := os.read_directory_by_path(PRESET_DIR, -1, context.temp_allocator)
	if err != nil {
		fmt.eprintln("editor: can't read", PRESET_DIR, err)
		return
	}
	for p in app.presets {
		delete(p)
	}
	clear(&app.presets)
	for entry in entries {
		if strings.has_suffix(entry.name, ".look") {
			append(&app.presets, strings.clone(entry.fullpath))
		}
	}
	slice.sort(app.presets[:])
}

// Checks the shared GLSL library, then compiles every preset, printing errors; true if all of
// them compile.
check_presets :: proc() -> bool {
	if ok, log := eng.check_glsl_library(); !ok {
		fmt.eprintf("FAIL glsl library (src/engine/vfx/glsl)\n%s\n", log)
		return false
	}
	fmt.println("ok   glsl library")
	all_ok := true
	for path in app.presets {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			fmt.eprintln("FAIL", path, err)
			all_ok = false
			continue
		}
		script, script_err, parsed := fx.parse_script(string(data))
		if !parsed {
			fmt.eprintf("FAIL %s:%d:%d: %s\n", filepath.base(path), script_err.line, script_err.col, script_err.message)
			all_ok = false
			continue
		}
		m, glsl_err, compiled := eng.try_make_material(script.look, filepath.base(path))
		if !compiled {
			fmt.eprintf("FAIL %s: generated GLSL rejected\n%s\n", filepath.base(path), glsl_err)
			all_ok = false
			continue
		}
		fmt.printf("ok   %-16s % 3d calls  % 2d params\n", filepath.base(path), script.nodes, len(script.params))
		eng.delete_material(m)
	}
	return all_ok
}

set_owned :: proc(field: ^string, value: string) {
	delete(field^)
	field^ = strings.clone(value)
}

show_status :: proc(text: string) {
	set_owned(&app.status, text)
	app.status_time = rl.GetTime()
}

open_file :: proc(path: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		show_status(fmt.tprintf("can't open %s: %v", path, err))
		return
	}
	editor_set_text(&app.editor, string(data))
	set_owned(&app.path, path)
	app.modified = false
	app.pending_open = -1
	app.zoom = 1
	recompile()
	restart()
}

new_file :: proc() {
	n := 1
	for {
		path := fmt.tprintf("%s/untitled_%d.look", PRESET_DIR, n)
		if !os.exists(path) {
			set_owned(&app.path, path)
			break
		}
		n += 1
	}
	editor_set_text(&app.editor, "// A new look\nsize 160 160\nparam radius = 50 in [10, 80] animate 3\n\nlet d = sd_circle(coord, radius)\nstack(mask(#ff8a3c, glow(d, 16)), mask(#fff3c4, fill(d)))\n")
	app.modified = true
	recompile()
	restart()
}

save_file :: proc() {
	if err := os.write_entire_file(app.path, transmute([]byte)editor_text(&app.editor)); err != nil {
		show_status(fmt.tprintf("can't save %s: %v", app.path, err))
		return
	}
	app.modified = false
	load_preset_list()
	show_status(fmt.tprintf("saved %s", filepath.base(app.path)))
}

// Restarts age() for one-shot effects.
restart :: proc() {
	app.spawn_time = eng.time()
}

// Parses and compiles the script. On failure the previous look stays and the error is shown.
recompile :: proc() {
	app.dirty = false
	script, err, ok := fx.parse_script(editor_text(&app.editor))
	if !ok {
		set_owned(&app.error, err.message)
		app.error_line = err.line
		return
	}
	start := time.tick_now()
	m, glsl_err, compiled := eng.try_make_material(script.look, "editor")
	app.compile_ms = time.duration_milliseconds(time.tick_diff(start, time.tick_now()))
	if !compiled {
		set_owned(&app.error, "the driver rejected the generated GLSL (see the GLSL tab)")
		set_owned(&app.glsl, glsl_err)
		app.error_line = 0
		return
	}
	set_owned(&app.error, "")
	app.error_line = 0
	if app.has_look {
		eng.delete_material(app.material)
	}
	app.material, app.has_look = m, true
	app.look_size, app.pad, app.lifetime = script.size, script.pad, script.lifetime
	app.nodes = len(script.params) + script.nodes
	set_owned(&app.glsl, eng.material_source(m))

	// Keep slider positions for params that didn't change in the script.
	next := make([dynamic]ParamState)
	for sp in script.params {
		state := ParamState {
			spec    = sp,
			value   = sp.default,
			playing = sp.animate > 0,
		}
		for old in app.params {
			s := old.spec
			if s.name == sp.name && s.type == sp.type && s.default == sp.default && s.min == sp.min && s.max == sp.max && s.animate == sp.animate {
				state.value, state.playing = old.value, old.playing
			}
		}
		state.spec.name = strings.clone(sp.name)
		append(&next, state)
	}
	for old in app.params {
		delete(old.spec.name)
	}
	delete(app.params)
	app.params = next
	apply_params()
}

apply_params :: proc() {
	for p in app.params {
		eng.set_material_param(&app.material, p.spec.name, p.value)
	}
}

// Animated params swing between their bounds (every component of a vector the same way).
animate_params :: proc() {
	seconds := f64(eng.time())
	for &p in app.params {
		if !p.playing || p.spec.animate <= 0 {
			continue
		}
		k := fx.animation_phase(p.spec, seconds)
		for i in 0 ..< 4 {
			p.value[i] = p.spec.min + (p.spec.max - p.spec.min) * k
		}
		if p.spec.type == .Vec4 {
			p.value[3] = 1
		}
	}
}

update :: proc(dt: f32) {
	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	if ctrl && rl.IsKeyPressed(.S) {
		save_file()
	}
	if ctrl && rl.IsKeyPressed(.R) {
		restart()
	}
	if ctrl && rl.IsKeyPressed(.N) {
		new_file()
	}
	if ctrl && rl.IsKeyPressed(.P) {
		app.paused = !app.paused
	}
	if rl.IsKeyPressed(.F1) {
		app.view = .Params if app.view == .Reference else .Reference
		app.scroll = 0
	}
	if rl.IsKeyPressed(.F2) {
		app.view = .Params if app.view == .Glsl else .Glsl
		app.scroll = 0
	}
	eng.set_time_scale(0 if app.paused else 1)

	app.idle += rl.GetFrameTime()
	if app.dirty && (app.idle > RECOMPILE_DELAY || (ctrl && rl.IsKeyPressed(.ENTER))) {
		recompile()
	}
	if app.has_look {
		if app.lifetime > 0 && eng.time() - app.spawn_time > app.lifetime {
			restart()
		}
		animate_params()
		apply_params()
	}
}

// ---------------------------------------------------------------------------------------
// Layout and drawing (immediate mode: widgets draw and report clicks)

draw :: proc() {
	w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	body_h := h - TOOLBAR_H - STATUS_H
	code_w := (w - SIDEBAR_W) * 0.52
	right_x := SIDEBAR_W + code_w
	right_w := w - right_x
	preview_h := body_h * 0.6

	draw_toolbar({0, 0, w, TOOLBAR_H})
	draw_sidebar({0, TOOLBAR_H, SIDEBAR_W, body_h})
	if text_editor(&app.editor, {SIDEBAR_W, TOOLBAR_H, code_w, body_h}, app.error_line) {
		app.dirty, app.idle, app.modified = true, 0, true
	}
	draw_preview({right_x, TOOLBAR_H, right_w, preview_h})
	lower := rl.Rectangle{right_x, TOOLBAR_H + preview_h, right_w, body_h - preview_h}
	switch app.view {
	case .Params:
		draw_params(lower)
	case .Reference:
		draw_reference(lower)
	case .Glsl:
		draw_glsl(lower)
	}
	draw_status({0, h - STATUS_H, w, STATUS_H})
}

draw_toolbar :: proc(r: rl.Rectangle) {
	panel(r)
	name := filepath.base(app.path)
	label_clipped(fmt.tprintf("%s%s", name, " *" if app.modified else ""), 12, r.y + 14, SIDEBAR_W - 16, ACCENT)
	x := f32(SIDEBAR_W) + 10
	y := r.y + 8
	bw: f32 = 86
	if button({x, y, bw, 32}, "New") {
		new_file()
	}
	x += bw + 8
	if button({x, y, bw, 32}, "Save") {
		save_file()
	}
	x += bw + 8
	if button({x, y, bw, 32}, "Restart") {
		restart()
	}
	x += bw + 8
	if button({x, y, bw, 32}, "Play" if app.paused else "Pause", app.paused) {
		app.paused = !app.paused
	}
	x += bw + 20
	tabs := [View]string {
		.Params    = "Params",
		.Reference = "Reference",
		.Glsl      = "GLSL",
	}
	for v in View {
		tw := text_width(tabs[v]) + 28
		if button({x, y, tw, 32}, tabs[v], app.view == v) {
			app.view = v
			app.scroll = 0
		}
		x += tw + 8
	}
}

draw_sidebar :: proc(r: rl.Rectangle) {
	panel(r)
	label("PRESETS", r.x + 12, r.y + 12, DIM)
	y := r.y + 44
	for path, i in app.presets {
		name := strings.trim_suffix(filepath.base(path), ".look")
		if list_item({r.x + 4, y, r.width - 8, LINE + 6}, name, path == app.path) && path != app.path {
			if app.modified && app.pending_open != i {
				app.pending_open = i
				show_status("unsaved changes: click the preset again to discard them")
			} else {
				open_file(path)
			}
		}
		y += LINE + 8
	}
}

draw_preview :: proc(r: rl.Rectangle) {
	// Checkerboard backdrop, so transparency shows.
	rl.BeginScissorMode(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	cell: f32 = 16
	for y := r.y; y < r.y + r.height; y += cell {
		for x := r.x; x < r.x + r.width; x += cell {
			even := (int((x - r.x) / cell) + int((y - r.y) / cell)) % 2 == 0
			rl.DrawRectangleRec({x, y, cell, cell}, CHECKER_A if even else CHECKER_B)
		}
	}
	center := eng.Vector2{r.x + r.width / 2, r.y + r.height / 2}
	if hovered(r) {
		wheel := rl.GetMouseWheelMove()
		if wheel != 0 {
			app.zoom = clamp(app.zoom * (1.1 if wheel > 0 else 1 / 1.1), 0.1, 8)
		}
	}
	if app.has_look {
		eng.draw_material_at(&app.material, center, app.look_size, app.pad, app.zoom, eng.time() - app.spawn_time, world_center = eng.Vector2{0, 0})
		// The logical size, as a faint frame.
		s := app.look_size * app.zoom
		rl.DrawRectangleLinesEx({center.x - s.x / 2, center.y - s.y / 2, s.x, s.y}, 1, {255, 255, 255, 40})
	}
	rl.EndScissorMode()
	label(fmt.tprintf("%.0f x %.0f   zoom %.0f%% (wheel)", app.look_size.x, app.look_size.y, app.zoom * 100), r.x + 10, r.y + r.height - LINE - 4, DIM)
	rl.DrawRectangleLinesEx(r, 1, PANEL_EDGE)
}

draw_params :: proc(r: rl.Rectangle) {
	panel(r)
	if len(app.params) == 0 {
		label("No params. Declare one with:", r.x + 14, r.y + 14, DIM)
		label("param speed = 1 in [0, 4] animate 2", r.x + 14, r.y + 14 + LINE, KEYWORD)
		return
	}
	if hovered(r) {
		app.scroll = max(app.scroll - rl.GetMouseWheelMove() * LINE * 2, 0)
	}
	rl.BeginScissorMode(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	defer rl.EndScissorMode()
	// Two lines per param: name, value and hold/play button; then its slider(s).
	x := r.x + 12
	width := r.width - 24
	y := r.y + 10 - app.scroll
	for &p, index in app.params {
		value_text: string
		switch p.spec.type {
		case .Float:
			value_text = fmt.tprintf("%.3g", p.value[0])
		case .Vec2:
			value_text = fmt.tprintf("%.3g, %.3g", p.value[0], p.value[1])
		case .Vec4:
			c := [3]u8{u8(clamp(p.value[0], 0, 1) * 255), u8(clamp(p.value[1], 0, 1) * 255), u8(clamp(p.value[2], 0, 1) * 255)}
			value_text = fmt.tprintf("#%02x%02x%02x", c[0], c[1], c[2])
		}
		button_w: f32 = 70 if p.spec.animate > 0 else 0
		label_clipped(p.spec.name, x, y, width * 0.5)
		label(value_text, x + width - button_w - 10 - text_width(value_text), y, DIM)
		if p.spec.animate > 0 && button({x + width - button_w, y - 3, button_w, LINE + 2}, "hold" if p.playing else "play", !p.playing) {
			p.playing = !p.playing
		}
		y += LINE + 4

		row := rl.Rectangle{x, y, width, 14}
		before := p.value
		switch p.spec.type {
		case .Float:
			p.value[0] = slider(index * 4, row, p.value[0], p.spec.min, p.spec.max)
		case .Vec2:
			half := (width - 16) / 2
			for i in 0 ..< 2 {
				p.value[i] = slider(index * 4 + i, {x + f32(i) * (half + 16), y, half, 14}, p.value[i], p.spec.min, p.spec.max)
			}
		case .Vec4:
			swatch := rl.Color{u8(clamp(p.value[0], 0, 1) * 255), u8(clamp(p.value[1], 0, 1) * 255), u8(clamp(p.value[2], 0, 1) * 255), 255}
			rl.DrawRectangleRec({x, y - 3, 30, 20}, swatch)
			rl.DrawRectangleLinesEx({x, y - 3, 30, 20}, 1, PANEL_EDGE)
			third := (width - 40 - 24) / 3
			channel_colors := [3]rl.Color{{200, 70, 70, 255}, {70, 170, 80, 255}, {70, 110, 210, 255}}
			for i in 0 ..< 3 {
				p.value[i] = slider(index * 4 + i, {x + 40 + f32(i) * (third + 12), y, third, 14}, p.value[i], 0, 1, channel_colors[i])
			}
		}
		if p.value != before {
			p.playing = false // dragging an animated param's slider holds it there
		}
		y += 30
	}
}

draw_reference :: proc(r: rl.Rectangle) {
	panel(r)
	if hovered(r) {
		app.scroll = max(app.scroll - rl.GetMouseWheelMove() * LINE * 3, 0)
	}
	rl.BeginScissorMode(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	defer rl.EndScissorMode()
	y := r.y + 10 - app.scroll
	lines := [?]string {
		"size W H  /  pad N  /  lifetime N",
		"param NAME = VALUE in [MIN, MAX] animate PERIOD [sine|saw|pingpong]",
		"let NAME = EXPR      then end with the look expression",
		"numbers, #rrggbb colors, [x, y] vectors, + - * /, .x .yx .rgba, pi, tau",
	}
	for l in lines {
		label(l, r.x + 12, y, KEYWORD)
		y += LINE
	}
	y += 8
	for b in fx.BUILTINS {
		label(fx.builtin_signature(b), r.x + 12, y, FUNCTION)
		y += LINE
		label(b.help, r.x + 32, y, DIM)
		y += LINE + 4
	}
}

draw_glsl :: proc(r: rl.Rectangle) {
	panel(r)
	if hovered(r) {
		app.scroll = max(app.scroll - rl.GetMouseWheelMove() * LINE * 3, 0)
	}
	rl.BeginScissorMode(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	defer rl.EndScissorMode()
	y := r.y + 8 - app.scroll
	small: f32 = 10
	for line, i in strings.split_lines(app.glsl, context.temp_allocator) {
		if y > r.y - LINE && y < r.y + r.height {
			label(fmt.tprintf("%4d  %s", i + 1, line), r.x + 8, y, TEXT, small)
		}
		y += 12
	}
}

// The function call the cursor is inside: "name(" before the innermost open parenthesis.
call_at_cursor :: proc() -> (fx.Builtin, bool) {
	text := editor_text(&app.editor)
	depth := 0
	for i := min(app.editor.cursor, len(text)) - 1; i >= 0; i -= 1 {
		switch text[i] {
		case ')':
			depth += 1
		case '(':
			if depth > 0 {
				depth -= 1
				continue
			}
			end := i
			start := end
			for start > 0 && (text[start - 1] == '_' || (text[start - 1] >= 'a' && text[start - 1] <= 'z') || (text[start - 1] >= '0' && text[start - 1] <= '9')) {
				start -= 1
			}
			return fx.find_builtin(text[start:end])
		}
	}
	return {}, false
}

draw_status :: proc(r: rl.Rectangle) {
	panel(r)
	y := r.y + 6
	switch {
	case app.error != "":
		where_ := fmt.tprintf("line %d: ", app.error_line) if app.error_line > 0 else ""
		label_clipped(fmt.tprintf("%s%s", where_, app.error), r.x + 12, y, r.width - 24, ERROR)
	case rl.GetTime() - app.status_time < 4 && app.status != "":
		label(app.status, r.x + 12, y, ACCENT)
	case:
		label(fmt.tprintf("compiled: %d calls, %d params, %.1f ms", app.nodes, len(app.params), app.compile_ms), r.x + 12, y, SUCCESS)
	}
	y += LINE
	if b, found := call_at_cursor(); found {
		label(fmt.tprintf("%s  -  %s", fx.builtin_signature(b), b.help), r.x + 12, y, FUNCTION)
	} else {
		label("Ctrl+S save   Ctrl+N new   Ctrl+R restart age   Ctrl+P pause   Ctrl+/ comment   Ctrl+Z / Ctrl+Y undo / redo", r.x + 12, y, DIM)
	}
}
