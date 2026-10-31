package main

// A small code editor widget for look scripts: syntax colors, selection, clipboard,
// undo/redo and line comments. ASCII only; tabs become four spaces.

import fx "../../engine/vfx"
import "core:strings"
import rl "vendor:raylib"

UNDO_LIMIT :: 200
GUTTER_W :: 44

@(private = "file")
Snapshot :: struct {
	text:   string,
	cursor: int,
}

TextEditor :: struct {
	text:        [dynamic]u8,
	cursor:      int, // byte offset
	anchor:      int, // selection is anchor..cursor; equal means no selection
	scroll:      f32, // first visible line
	goal_x:      f32, // x to keep when moving up/down; < 0 = take it from the cursor
	undo, redo:  [dynamic]Snapshot,
	typing:      bool, // last edit was plain typing (merged into one undo step)
	dragging:    bool,
	last_click:  f64,
	blink_start: f64,
}

editor_set_text :: proc(e: ^TextEditor, s: string) {
	clear(&e.text)
	for c in transmute([]u8)s {
		switch c {
		case '\t':
			append(&e.text, "    ")
		case '\r':
		case:
			append(&e.text, c)
		}
	}
	e.cursor, e.anchor, e.scroll, e.goal_x = 0, 0, 0, -1
	clear_history(&e.undo)
	clear_history(&e.redo)
}

editor_text :: proc(e: ^TextEditor) -> string {
	return string(e.text[:])
}

@(private = "file")
clear_history :: proc(h: ^[dynamic]Snapshot) {
	for s in h {
		delete(s.text)
	}
	clear(h)
}

@(private = "file")
selection :: proc(e: ^TextEditor) -> (lo, hi: int) {
	return min(e.cursor, e.anchor), max(e.cursor, e.anchor)
}

@(private = "file")
snapshot :: proc(e: ^TextEditor, typing := false) {
	if typing && e.typing {
		return // keep extending the current typing run
	}
	e.typing = typing
	append(&e.undo, Snapshot{strings.clone(editor_text(e)), e.cursor})
	if len(e.undo) > UNDO_LIMIT {
		delete(e.undo[0].text)
		ordered_remove(&e.undo, 0)
	}
	clear_history(&e.redo)
}

@(private = "file")
restore :: proc(e: ^TextEditor, from, to: ^[dynamic]Snapshot) -> bool {
	if len(from) == 0 {
		return false
	}
	append(to, Snapshot{strings.clone(editor_text(e)), e.cursor})
	s := pop(from)
	clear(&e.text)
	append(&e.text, s.text)
	e.cursor, e.anchor = s.cursor, s.cursor
	delete(s.text)
	e.typing = false
	return true
}

// Replaces the selection with `s`.
@(private = "file")
insert :: proc(e: ^TextEditor, s: string) {
	lo, hi := selection(e)
	remove_range(&e.text, lo, hi)
	inject_at(&e.text, lo, s)
	e.cursor = lo + len(s)
	e.anchor = e.cursor
}

@(private = "file")
line_start :: proc(text: []u8, pos: int) -> int {
	i := pos
	for i > 0 && text[i - 1] != '\n' {
		i -= 1
	}
	return i
}

@(private = "file")
line_end :: proc(text: []u8, pos: int) -> int {
	i := pos
	for i < len(text) && text[i] != '\n' {
		i += 1
	}
	return i
}

@(private = "file")
is_word :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

@(private = "file")
word_left :: proc(text: []u8, pos: int) -> int {
	i := pos
	for i > 0 && !is_word(text[i - 1]) {
		i -= 1
	}
	for i > 0 && is_word(text[i - 1]) {
		i -= 1
	}
	return i
}

@(private = "file")
word_right :: proc(text: []u8, pos: int) -> int {
	i := pos
	for i < len(text) && !is_word(text[i]) {
		i += 1
	}
	for i < len(text) && is_word(text[i]) {
		i += 1
	}
	return i
}

@(private = "file")
measure :: proc(s: string) -> f32 {
	if len(s) == 0 {
		return 0
	}
	return rl.MeasureTextEx(rl.GetFontDefault(), strings.clone_to_cstring(s, context.temp_allocator), FONT, FONT / 10).x
}

// Byte offset in the line [start, end) closest to x pixels from its left edge.
@(private = "file")
offset_at_x :: proc(text: []u8, start, end: int, x: f32) -> int {
	best, best_dist := start, abs(x)
	for i in start + 1 ..= end {
		w := measure(string(text[start:i])) + FONT / 10
		if d := abs(w - x); d < best_dist {
			best, best_dist = i, d
		}
	}
	return best
}

@(private = "file")
pressed :: proc(key: rl.KeyboardKey) -> bool {
	return rl.IsKeyPressed(key) || rl.IsKeyPressedRepeat(key)
}

// Toggles a "// " comment on every line the selection touches.
@(private = "file")
toggle_comment :: proc(e: ^TextEditor) {
	lo, hi := selection(e)
	first := line_start(e.text[:], lo)
	starts := make([dynamic]int, context.temp_allocator)
	pos := first
	for {
		append(&starts, pos)
		end := line_end(e.text[:], pos)
		if end >= hi || end >= len(e.text) {
			break
		}
		pos = end + 1
	}
	commented := true
	for s in starts {
		rest := strings.trim_left_space(string(e.text[s:line_end(e.text[:], s)]))
		commented &&= strings.has_prefix(rest, "//")
	}
	snapshot(e)
	#reverse for s in starts {
		if commented {
			at := s + strings.index(string(e.text[s:]), "//")
			n := 3 if at + 2 < len(e.text) && e.text[at + 2] == ' ' else 2
			remove_range(&e.text, at, at + n)
		} else {
			inject_at(&e.text, s, "// ")
		}
	}
	e.cursor = min(e.cursor, len(e.text))
	e.anchor = min(e.anchor, len(e.text))
}

// Handles keyboard and mouse input and draws the editor in `rect`. Returns true when the
// text changed. `error_line` (1-based, 0 = none) is highlighted.
text_editor :: proc(e: ^TextEditor, rect: rl.Rectangle, error_line: int) -> (changed: bool) {
	text := e.text[:]
	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	moved := false
	move :: proc(e: ^TextEditor, to: int, shift: bool) {
		e.cursor = clamp(to, 0, len(e.text))
		if !shift {
			e.anchor = e.cursor
		}
		e.typing = false
	}

	// Typing
	for c := rl.GetCharPressed(); c != 0; c = rl.GetCharPressed() {
		if c >= 32 && c < 127 && !ctrl {
			snapshot(e, typing = true)
			buf := [1]u8{u8(c)}
			insert(e, string(buf[:]))
			changed = true
		}
	}

	// Editing keys
	lo, hi := selection(e)
	switch {
	case pressed(.ENTER) || pressed(.KP_ENTER):
		snapshot(e)
		start := line_start(text, e.cursor)
		indent := 0
		for start + indent < len(text) && text[start + indent] == ' ' {
			indent += 1
		}
		insert(e, strings.concatenate({"\n", strings.repeat(" ", indent, context.temp_allocator)}, context.temp_allocator))
		changed = true
	case pressed(.BACKSPACE):
		snapshot(e)
		if lo == hi {
			e.anchor = word_left(text, e.cursor) if ctrl else max(e.cursor - 1, 0)
		}
		insert(e, "")
		changed = true
	case pressed(.DELETE):
		snapshot(e)
		if lo == hi {
			e.anchor = word_right(text, e.cursor) if ctrl else min(e.cursor + 1, len(text))
		}
		insert(e, "")
		changed = true
	case pressed(.TAB):
		snapshot(e)
		if shift {
			start := line_start(text, e.cursor)
			n := 0
			for n < 4 && start + n < len(text) && text[start + n] == ' ' {
				n += 1
			}
			remove_range(&e.text, start, start + n)
			e.cursor = max(e.cursor - n, start)
			e.anchor = e.cursor
		} else {
			insert(e, "    ")
		}
		changed = true
	case ctrl && rl.IsKeyPressed(.A):
		e.anchor, e.cursor = 0, len(text)
	case ctrl && (rl.IsKeyPressed(.C) || rl.IsKeyPressed(.X)):
		if lo != hi {
			rl.SetClipboardText(strings.clone_to_cstring(string(text[lo:hi]), context.temp_allocator))
			if rl.IsKeyPressed(.X) {
				snapshot(e)
				insert(e, "")
				changed = true
			}
		}
	case ctrl && rl.IsKeyPressed(.V):
		clip := string(rl.GetClipboardText())
		clip, _ = strings.replace_all(clip, "\r", "", context.temp_allocator)
		clip, _ = strings.replace_all(clip, "\t", "    ", context.temp_allocator)
		snapshot(e)
		insert(e, clip)
		changed = true
	case ctrl && rl.IsKeyPressed(.Z) && !shift:
		changed = restore(e, &e.undo, &e.redo)
	case ctrl && (rl.IsKeyPressed(.Y) || (rl.IsKeyPressed(.Z) && shift)):
		changed = restore(e, &e.redo, &e.undo)
	case ctrl && rl.IsKeyPressed(.SLASH):
		toggle_comment(e)
		changed = true
	}
	text = e.text[:]

	// Cursor movement
	visible_lines := int(rect.height / LINE)
	vertical := 0
	switch {
	case pressed(.LEFT):
		target := e.cursor - 1
		if ctrl {
			target = word_left(text, e.cursor)
		} else if lo != hi && !shift {
			target = lo
		}
		move(e, target, shift)
		moved = true
	case pressed(.RIGHT):
		target := e.cursor + 1
		if ctrl {
			target = word_right(text, e.cursor)
		} else if lo != hi && !shift {
			target = hi
		}
		move(e, target, shift)
		moved = true
	case pressed(.HOME):
		move(e, 0 if ctrl else line_start(text, e.cursor), shift)
		moved = true
	case pressed(.END):
		move(e, len(text) if ctrl else line_end(text, e.cursor), shift)
		moved = true
	case pressed(.UP):
		vertical = -1
	case pressed(.DOWN):
		vertical = 1
	case pressed(.PAGE_UP):
		vertical = -visible_lines
	case pressed(.PAGE_DOWN):
		vertical = visible_lines
	}
	if vertical != 0 {
		start := line_start(text, e.cursor)
		if e.goal_x < 0 {
			e.goal_x = measure(string(text[start:e.cursor]))
		}
		for _ in 0 ..< abs(vertical) {
			if vertical < 0 {
				if start == 0 {
					break
				}
				start = line_start(text, start - 1)
			} else {
				end := line_end(text, start)
				if end >= len(text) {
					break
				}
				start = end + 1
			}
		}
		goal := e.goal_x
		move(e, offset_at_x(text, start, line_end(text, start), goal), shift)
		e.goal_x = goal
		moved = true
	} else if moved || changed {
		e.goal_x = -1
	}

	// Line layout
	starts := make([dynamic]int, context.temp_allocator)
	append(&starts, 0)
	for c, i in text {
		if c == '\n' {
			append(&starts, i + 1)
		}
	}
	line_of :: proc(starts: []int, pos: int) -> int {
		line := 0
		for s, i in starts {
			if s <= pos {
				line = i
			}
		}
		return line
	}
	cursor_line := line_of(starts[:], e.cursor)
	if moved || changed {
		e.blink_start = rl.GetTime()
		if f32(cursor_line) < e.scroll {
			e.scroll = f32(cursor_line)
		}
		if f32(cursor_line) > e.scroll + f32(visible_lines) - 2 {
			e.scroll = f32(cursor_line - visible_lines + 2)
		}
	}

	// Mouse
	mouse := rl.GetMousePosition()
	text_x := rect.x + GUTTER_W + 8
	if rl.CheckCollisionPointRec(mouse, rect) {
		e.scroll -= rl.GetMouseWheelMove() * 3
		if rl.IsMouseButtonPressed(.LEFT) {
			e.dragging = true
		}
	}
	e.scroll = clamp(e.scroll, 0, max(f32(len(starts) - 2), 0))
	if e.dragging {
		line := clamp(int((mouse.y - rect.y) / LINE + e.scroll), 0, len(starts) - 1)
		end := starts[line + 1] - 1 if line + 1 < len(starts) else len(text)
		pos := offset_at_x(text, starts[line], end, mouse.x - text_x)
		if rl.IsMouseButtonPressed(.LEFT) {
			now := rl.GetTime()
			if now - e.last_click < 0.3 {
				e.anchor, e.cursor = word_left(text, min(pos + 1, len(text))), word_right(text, pos)
			} else {
				move(e, pos, shift)
			}
			e.last_click = now
		} else {
			e.cursor = pos
		}
		e.goal_x = -1
		e.blink_start = rl.GetTime()
		if !rl.IsMouseButtonDown(.LEFT) {
			e.dragging = false
		}
		// The click may have put the cursor on another line.
		cursor_line = line_of(starts[:], e.cursor)
	}

	// Drawing
	rl.DrawRectangleRec(rect, EDITOR_BG)
	rl.DrawRectangleRec({rect.x, rect.y, GUTTER_W, rect.height}, GUTTER_BG)
	rl.BeginScissorMode(i32(rect.x), i32(rect.y), i32(rect.width), i32(rect.height))
	defer rl.EndScissorMode()
	lo, hi = selection(e)
	first := int(e.scroll)
	for line in first ..< min(first + visible_lines + 1, len(starts)) {
		y := rect.y + f32(line - first) * LINE + 2
		start := starts[line]
		end := starts[line + 1] - 1 if line + 1 < len(starts) else len(text)
		if line + 1 == error_line {
			rl.DrawRectangleRec({rect.x + GUTTER_W, y - 2, rect.width - GUTTER_W, LINE}, ERROR_LINE_BG)
		} else if line == cursor_line && lo == hi {
			rl.DrawRectangleRec({rect.x + GUTTER_W, y - 2, rect.width - GUTTER_W, LINE}, CURRENT_LINE_BG)
		}
		number := strings.clone_to_cstring(fmt_int(line + 1), context.temp_allocator)
		rl.DrawTextEx(rl.GetFontDefault(), number, {rect.x + GUTTER_W - 6 - measure(string(number)), y}, FONT, FONT / 10, ERROR if line + 1 == error_line else DIM)
		// Selection
		if lo < hi && hi >= start && lo <= end {
			a, b := max(lo, start), min(hi, end)
			x0 := text_x + measure(string(text[start:a])) + (FONT / 10 if a > start else 0)
			x1 := text_x + measure(string(text[start:b])) + (FONT / 10 if b > start else 0)
			if hi > end {
				x1 += 8 // the selected line break
			}
			rl.DrawRectangleRec({x0, y - 2, max(x1 - x0, 2), LINE}, SELECTION)
		}
		draw_highlighted(string(text[start:end]), text_x, y)
	}
	// Caret
	if int((rl.GetTime() - e.blink_start) * 2) % 2 == 0 && cursor_line >= first {
		start := starts[cursor_line]
		x := text_x + measure(string(text[start:e.cursor])) + (FONT / 10 if e.cursor > start else 0)
		y := rect.y + f32(cursor_line - first) * LINE
		rl.DrawRectangleRec({x - 1, y + 2, 2, LINE - 2}, CARET)
	}
	return
}

// Draws one line of script with syntax colors.
@(private = "file")
draw_highlighted :: proc(line: string, x, y: f32) {
	x := x
	span :: proc(s: string, x: ^f32, y: f32, color: rl.Color) {
		if len(s) == 0 {
			return
		}
		rl.DrawTextEx(rl.GetFontDefault(), strings.clone_to_cstring(s, context.temp_allocator), {x^, y}, FONT, FONT / 10, color)
		x^ += measure(s) + FONT / 10
	}
	i := 0
	for i < len(line) {
		c := line[i]
		start := i
		switch {
		case c == '/' && i + 1 < len(line) && line[i + 1] == '/':
			span(line[i:], &x, y, COMMENT)
			return
		case c == '#':
			i += 1
			for i < len(line) && is_word(line[i]) {
				i += 1
			}
			// Underline color literals with their own color.
			x0 := x
			span(line[start:i], &x, y, NUMBER)
			if color, ok := parse_hex_color(line[start + 1:i]); ok {
				rl.DrawRectangleRec({x0, y + FONT - 1, x - x0 - FONT / 10, 4}, color)
			}
		case c >= '0' && c <= '9' || (c == '.' && i + 1 < len(line) && line[i + 1] >= '0' && line[i + 1] <= '9'):
			for i < len(line) && (line[i] >= '0' && line[i] <= '9' || line[i] == '.') {
				i += 1
			}
			span(line[start:i], &x, y, NUMBER)
		case is_word(c):
			for i < len(line) && is_word(line[i]) {
				i += 1
			}
			word := line[start:i]
			color := TEXT
			switch word {
			case "let", "param", "in", "animate", "size", "pad", "lifetime", "sine", "saw", "pingpong":
				color = KEYWORD
			case:
				if _, builtin := fx.find_builtin(word); builtin {
					color = FUNCTION
				}
			}
			span(word, &x, y, color)
		case:
			i += 1
			span(line[start:i], &x, y, PUNCTUATION if c != ' ' else TEXT)
		}
	}
}

parse_hex_color :: proc(hex: string) -> (rl.Color, bool) {
	if len(hex) != 6 && len(hex) != 8 {
		return {}, false
	}
	value: u32
	for c in transmute([]u8)hex {
		digit: u32
		switch c {
		case '0' ..= '9':
			digit = u32(c - '0')
		case 'a' ..= 'f':
			digit = u32(c - 'a' + 10)
		case 'A' ..= 'F':
			digit = u32(c - 'A' + 10)
		case:
			return {}, false
		}
		value = value << 4 | digit
	}
	if len(hex) == 6 {
		value = value << 8 | 0xff
	}
	return {u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value)}, true
}
