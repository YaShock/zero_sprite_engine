package engine

// Lookup grids for long lists of shapes. A look that draws hundreds of capsules or lights
// would otherwise test every one of them at every pixel; with bins, vfx.sd_capsules and
// vfx.glow_points visit only the shapes listed in the grid cell under the pixel.
//
// Layout of a bins data_array: x0, y0, cell size, columns | rows, start of the lists, 0, 0 |
// per cell the start (relative to the lists) and length of its list | the lists, each the
// indices of the shapes reaching into that cell, ascending.

import "core:math"
import "vfx"

BIN_HEADER :: 8

BinShape :: enum {
	Capsules, // vfx.CAPSULE_STRIDE values each: ax, ay, bx, by, ra, rb
	Glow_Points, // vfx.GLOW_STRIDE values each: x, y, radius, strength
}

// Writes the bins for `shapes` (in the same coordinates the look reads them in) into `out`
// and returns how many values it used. Every shape is listed in each cell that its extent,
// grown by `margin` (anti-aliasing, glow around a stroke), touches. `cell` is the grid
// size; it is made coarser when the lists would not fit in `out`. Only shapes
// first ..< last are listed (last < 0: all the rest), by their index in `shapes`, so groups
// that need different margins can get bins of their own.
bin_shapes :: proc(out: []f32, shapes: []f32, kind: BinShape, margin, cell: f32, first := 0, last := -1) -> int {
	stride := vfx.CAPSULE_STRIDE if kind == .Capsules else vfx.GLOW_STRIDE
	n := len(shapes) / stride
	if last >= 0 {
		n = math.min(n, last)
	}
	extent :: proc(s: []f32, kind: BinShape, margin: f32) -> (lo, hi: [2]f32) {
		if kind == .Capsules {
			r := math.max(s[4], s[5]) + margin
			return {math.min(s[0], s[2]) - r, math.min(s[1], s[3]) - r}, {math.max(s[0], s[2]) + r, math.max(s[1], s[3]) + r}
		}
		r := s[2] + margin
		return {s[0] - r, s[1] - r}, {s[0] + r, s[1] + r}
	}
	lo, hi := [2]f32{math.F32_MAX, math.F32_MAX}, [2]f32{-math.F32_MAX, -math.F32_MAX}
	for i in first ..< n {
		a, b := extent(shapes[i * stride:], kind, margin)
		lo = {math.min(lo.x, a.x), math.min(lo.y, a.y)}
		hi = {math.max(hi.x, b.x), math.max(hi.y, b.y)}
	}
	if n <= first {
		out[3], out[4] = 0, 0 // no cells: every pixel is outside the grid
		return BIN_HEADER
	}
	cell := cell
	for {
		cols := math.max(1, int(math.ceil((hi.x - lo.x) / cell)))
		rows := math.max(1, int(math.ceil((hi.y - lo.y) / cell)))
		lists := BIN_HEADER + 2 * cols * rows
		if lists > len(out) {
			cell *= 2
			continue
		}
		cells_of :: proc(a, b, lo: [2]f32, cell: f32, cols, rows: int) -> (x0, y0, x1, y1: int) {
			x0 = clamp(int((a.x - lo.x) / cell), 0, cols - 1)
			y0 = clamp(int((a.y - lo.y) / cell), 0, rows - 1)
			x1 = clamp(int((b.x - lo.x) / cell), 0, cols - 1)
			y1 = clamp(int((b.y - lo.y) / cell), 0, rows - 1)
			return
		}
		// Count each cell's shapes
		for i in BIN_HEADER ..< lists {
			out[i] = 0
		}
		total := 0
		for i in first ..< n {
			a, b := extent(shapes[i * stride:], kind, margin)
			x0, y0, x1, y1 := cells_of(a, b, lo, cell, cols, rows)
			for y in y0 ..= y1 {
				for x in x0 ..= x1 {
					out[BIN_HEADER + 2 * (y * cols + x) + 1] += 1
				}
			}
			total += (x1 - x0 + 1) * (y1 - y0 + 1)
		}
		if lists + total > len(out) {
			cell *= 2
			continue
		}
		// Where each list starts; the lengths count up again as the lists are filled
		at: f32 = 0
		for c in 0 ..< cols * rows {
			k := BIN_HEADER + 2 * c
			out[k], at, out[k + 1] = at, at + out[k + 1], 0
		}
		for i in first ..< n {
			a, b := extent(shapes[i * stride:], kind, margin)
			x0, y0, x1, y1 := cells_of(a, b, lo, cell, cols, rows)
			for y in y0 ..= y1 {
				for x in x0 ..= x1 {
					k := BIN_HEADER + 2 * (y * cols + x)
					out[lists + int(out[k]) + int(out[k + 1])] = f32(i)
					out[k + 1] += 1
				}
			}
		}
		out[0], out[1], out[2], out[3] = lo.x, lo.y, cell, f32(cols)
		out[4], out[5], out[6], out[7] = f32(rows), f32(lists), 0, 0
		return lists + total
	}
}
