package engine

import "core:math"
import rl "vendor:raylib"

FbmParams :: struct {
	octaves:    int,
	frequency:  f32,
	lacunarity: f32, // frequency multiplier per octave
	gain:       f32, // amplitude multiplier per octave
	color_a:    Color,
	color_b:    Color,
	cell_size:  f32,
	seed:       f32,
}

@(private)
noise_hash :: proc(ix, iy: int) -> f32 {
	h := u32(ix) ~ (u32(iy) * 2654435761)
	h = h ~ (h >> 16)
	h *= 0x45d9f3b
	h = h ~ (h >> 16)
	return f32(h) / 4294967295.0
}

@(private)
smooth_noise :: proc(x, y: f32) -> f32 {
	ix := int(math.floor(x))
	iy := int(math.floor(y))
	fx := x - f32(ix)
	fy := y - f32(iy)
	ux := fx * fx * (3 - 2 * fx)
	uy := fy * fy * (3 - 2 * fy)
	v00 := noise_hash(ix, iy)
	v10 := noise_hash(ix + 1, iy)
	v01 := noise_hash(ix, iy + 1)
	v11 := noise_hash(ix + 1, iy + 1)
	return v00 + (v10 - v00) * ux + (v01 - v00) * uy + (v00 - v10 - v01 + v11) * ux * uy
}

fbm :: proc(x, y: f32, p: FbmParams) -> f32 {
	value: f32 = 0
	amplitude: f32 = 1
	total_amplitude: f32 = 0
	freq := p.frequency
	for _ in 0 ..< p.octaves {
		value += smooth_noise(x * freq + p.seed, y * freq + p.seed * 1.618) * amplitude
		total_amplitude += amplitude
		amplitude *= p.gain
		freq *= p.lacunarity
	}
	return value / total_amplitude
}

lerp_color :: proc(ca, cb: Color, t: f32) -> Color {
	return Color{
		u8(f32(ca.r) + (f32(cb.r) - f32(ca.r)) * t),
		u8(f32(ca.g) + (f32(cb.g) - f32(ca.g)) * t),
		u8(f32(ca.b) + (f32(cb.b) - f32(ca.b)) * t),
		u8(f32(ca.a) + (f32(cb.a) - f32(ca.a)) * t),
	}
}

draw_fbm_rect :: proc(rect: rl.Rectangle, p: FbmParams) {
	cs := p.cell_size
	for y := rect.y; y < rect.y + rect.height; y += cs {
		for x := rect.x; x < rect.x + rect.width; x += cs {
			cw := i32(min(cs, rect.x + rect.width - x) + 0.5)
			ch := i32(min(cs, rect.y + rect.height - y) + 0.5)
			if cw <= 0 || ch <= 0 {continue}
			t := fbm(x, y, p)
			color := lerp_color(p.color_a, p.color_b, t)
			rl.DrawRectangle(i32(x), i32(y), cw, ch, color)
		}
	}
}

draw_fbm_circle :: proc(center: rl.Vector2, radius: f32, p: FbmParams) {
	cs := p.cell_size
	r2 := radius * radius
	for y := center.y - radius; y < center.y + radius; y += cs {
		for x := center.x - radius; x < center.x + radius; x += cs {
			cw := min(cs, center.x + radius - x)
			ch := min(cs, center.y + radius - y)
			if cw <= 0 || ch <= 0 {continue}
			cx := x + cw * 0.5
			cy := y + ch * 0.5
			dx := cx - center.x
			dy := cy - center.y
			if dx * dx + dy * dy > r2 {continue}
			t := fbm(x, y, p)
			color := lerp_color(p.color_a, p.color_b, t)
			rl.DrawRectangle(i32(x), i32(y), i32(cw + 0.5), i32(ch + 0.5), color)
		}
	}
}
