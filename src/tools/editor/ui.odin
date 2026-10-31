package main

// Immediate-mode widgets for the editor's own interface. Tool chrome is drawn with plain
// raylib primitives; only the preview goes through the vfx pipeline.

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

FONT :: 20
LINE :: 24

// Interface colors
BACKGROUND :: rl.Color{0x12, 0x14, 0x1a, 0xff}
PANEL :: rl.Color{0x1a, 0x1d, 0x25, 0xff}
PANEL_EDGE :: rl.Color{0x2c, 0x31, 0x3d, 0xff}
EDITOR_BG :: rl.Color{0x15, 0x17, 0x1e, 0xff}
GUTTER_BG :: rl.Color{0x1b, 0x1e, 0x26, 0xff}
CURRENT_LINE_BG :: rl.Color{0x1e, 0x22, 0x2c, 0xff}
ERROR_LINE_BG :: rl.Color{0x4a, 0x1c, 0x22, 0xff}
SELECTION :: rl.Color{0x2e, 0x4a, 0x78, 0xff}
CARET :: rl.Color{0xf0, 0xf2, 0xf8, 0xff}
TEXT :: rl.Color{0xdc, 0xe0, 0xea, 0xff}
DIM :: rl.Color{0x7c, 0x84, 0x96, 0xff}
ACCENT :: rl.Color{0xff, 0xc8, 0x5a, 0xff}
ERROR :: rl.Color{0xff, 0x6a, 0x5c, 0xff}
SUCCESS :: rl.Color{0x7c, 0xe0, 0x8a, 0xff}
KEYWORD :: rl.Color{0xc8, 0x8c, 0xff, 0xff}
FUNCTION :: rl.Color{0x6c, 0xb8, 0xff, 0xff}
NUMBER :: rl.Color{0xff, 0xb0, 0x6a, 0xff}
COMMENT :: rl.Color{0x62, 0x6c, 0x7e, 0xff}
PUNCTUATION :: rl.Color{0x9a, 0xa2, 0xb4, 0xff}
BUTTON :: rl.Color{0x2a, 0x2f, 0x3b, 0xff}
BUTTON_HOVER :: rl.Color{0x38, 0x3f, 0x50, 0xff}
SLIDER_TRACK :: rl.Color{0x10, 0x12, 0x18, 0xff}
SLIDER_FILL :: rl.Color{0x3c, 0x6c, 0xb0, 0xff}
CHECKER_A :: rl.Color{0x24, 0x27, 0x2f, 0xff}
CHECKER_B :: rl.Color{0x1c, 0x1f, 0x26, 0xff}

fmt_int :: proc(n: int) -> string {
	return fmt.tprintf("%d", n)
}

text_width :: proc(s: string, size: f32 = FONT) -> f32 {
	return rl.MeasureTextEx(rl.GetFontDefault(), strings.clone_to_cstring(s, context.temp_allocator), size, size / 10).x
}

label :: proc(s: string, x, y: f32, color := TEXT, size: f32 = FONT) {
	rl.DrawTextEx(rl.GetFontDefault(), strings.clone_to_cstring(s, context.temp_allocator), {x, y}, size, size / 10, color)
}

// Draws `s` cut to fit `width`, with an ellipsis when it doesn't.
label_clipped :: proc(s: string, x, y, width: f32, color := TEXT) {
	if text_width(s) <= width {
		label(s, x, y, color)
		return
	}
	n := len(s)
	for n > 0 && text_width(fmt.tprintf("%s...", s[:n])) > width {
		n -= 1
	}
	label(fmt.tprintf("%s...", s[:n]), x, y, color)
}

hovered :: proc(r: rl.Rectangle) -> bool {
	return rl.CheckCollisionPointRec(rl.GetMousePosition(), r)
}

button :: proc(r: rl.Rectangle, text: string, active := false) -> bool {
	over := hovered(r)
	rl.DrawRectangleRec(r, BUTTON_HOVER if over || active else BUTTON)
	if active {
		rl.DrawRectangleLinesEx(r, 1, ACCENT)
	}
	label(text, r.x + (r.width - text_width(text)) / 2, r.y + (r.height - FONT) / 2, ACCENT if active else TEXT)
	return over && rl.IsMouseButtonPressed(.LEFT)
}

// A row in a list; returns true when clicked.
list_item :: proc(r: rl.Rectangle, text: string, selected: bool) -> bool {
	over := hovered(r)
	if selected || over {
		rl.DrawRectangleRec(r, SELECTION if selected else BUTTON)
	}
	label_clipped(text, r.x + 10, r.y + (r.height - FONT) / 2, r.width - 14, ACCENT if selected else TEXT)
	return over && rl.IsMouseButtonPressed(.LEFT)
}

// Slider state: which one is being dragged (by id), shared by all sliders.
@(private = "file")
active_slider: int = -1

// Horizontal slider; returns the (possibly dragged) value.
slider :: proc(id: int, r: rl.Rectangle, value, lo, hi: f32, fill := SLIDER_FILL) -> f32 {
	if hovered(r) && rl.IsMouseButtonPressed(.LEFT) {
		active_slider = id
	}
	if !rl.IsMouseButtonDown(.LEFT) && active_slider == id {
		active_slider = -1
	}
	value := value
	if active_slider == id && hi > lo {
		t := clamp((rl.GetMousePosition().x - r.x) / r.width, 0, 1)
		value = lo + (hi - lo) * t
	}
	t := clamp((value - lo) / (hi - lo), 0, 1) if hi > lo else 0
	rl.DrawRectangleRec(r, SLIDER_TRACK)
	rl.DrawRectangleRec({r.x, r.y, r.width * t, r.height}, fill)
	rl.DrawRectangleRec({r.x + r.width * t - 2, r.y - 2, 4, r.height + 4}, TEXT)
	return value
}

slider_dragging :: proc() -> bool {
	return active_slider >= 0
}

panel :: proc(r: rl.Rectangle) {
	rl.DrawRectangleRec(r, PANEL)
	rl.DrawRectangleLinesEx(r, 1, PANEL_EDGE)
}
