package engine

import "core:strings"
import rl "vendor:raylib"

Color :: rl.Color
Rectangle :: rl.Rectangle

Text :: struct {
	text:      string,
	color:     Color,
	font_size: i32,
}

RectFill :: enum {
	Fill,
	Outline,
	FillOutline,
}

RectShape :: struct {
	fill_color: Color,
	line_color: Color,
	thickness:  f32,
	fill:       RectFill,
}

CircleShape :: struct {
	fill_color: Color,
	line_color: Color,
	thickness:  f32,
	fill:       RectFill,
}

Drawable :: union {
	Text,
	RectShape,
	CircleShape,
}

TextAlignment :: enum {
	Left,
	Center,
	Right,
}

add_text_object :: proc(
	text: string,
	pos: Vector2,
	font_size: i32,
	color: Color,
	z_index: int,
) -> int {
	return add_scene_object(
		Text{color = color, font_size = font_size, text = text},
		pos,
		{0, 0},
		z_index,
	)
}

add_text_object_align :: proc(
	text: string,
	pos: Vector2,
	font_size: i32,
	color: Color,
	z_index: int,
	align: TextAlignment,
) -> int {
	text_width := f32(
		rl.MeasureText(strings.clone_to_cstring(text, context.temp_allocator), font_size),
	)
	adjusted_pos := pos
	switch align {
	case .Left:
	// pos.x is the left edge of the text
	case .Center:
		adjusted_pos.x = pos.x - text_width / 2
	case .Right:
		adjusted_pos.x = pos.x - text_width
	}
	adjusted_pos.y = pos.y - f32(font_size) / 2
	return add_text_object(text, adjusted_pos, font_size, color, z_index)
}

add_rect_shape :: proc(
	pos, size: Vector2,
	fill: RectFill,
	fill_color, line_color: Color,
	thickness: f32,
	z_index: int,
) -> int {
	return add_scene_object(
		RectShape {
			fill_color = fill_color,
			line_color = line_color,
			thickness = thickness,
			fill = fill,
		},
		pos,
		size,
		z_index,
	)
}

add_circle_shape :: proc(
	pos: Vector2,
	radius: f32,
	fill: RectFill,
	fill_color, line_color: Color,
	thickness: f32,
	z_index: int,
) -> int {
	return add_scene_object(
		CircleShape {
			fill_color = fill_color,
			line_color = line_color,
			thickness = thickness,
			fill = fill,
		},
		pos,
		{radius, radius},
		z_index,
	)
}
