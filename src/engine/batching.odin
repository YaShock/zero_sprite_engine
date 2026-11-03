package engine

// Groups the scene's draws so that entities with the same look share an instanced draw call
// even when other looks come between them in scene order. An entity joins the newest group
// drawing its shader with its blending, i.e. it may be drawn earlier than its place in the
// scene order, as long as nothing it then moves in front of overlaps its quad: only the order
// of overlapping quads is visible. Overlaps are looked up in a grid over the virtual screen
// that holds the quads placed so far.

import "core:math"

@(private)
BATCH_GRID :: 32 // cells per axis

@(private)
DrawGroup :: struct {
	shader:  int, // -1 for something raylib draws (text, a cached look): a group of one
	blend:   BlendMode,
	head:    int, // first member, the rest linked through Batcher.next
	tail:    int,
	created: int, // members placed before the group was created
}

@(private)
GridEntry :: struct {
	lo, hi: Vector2, // the member's quad, axis-aligned
	member: int,
	next:   int, // the cell's entry placed before this one, -1 at the end
}

@(private)
Batcher :: struct {
	members:  [dynamic]^Entity, // in scene order
	group_of: [dynamic]int, // per member
	next:     [dynamic]int, // per member: the next member of its group, -1 at the end
	groups:   [dynamic]DrawGroup,
	newest:   [dynamic]int, // per shader and blend mode: the newest group drawing it, -1 if none
	cells:    [BATCH_GRID * BATCH_GRID]int, // per cell: the newest entry, -1 if none
	entries:  [dynamic]GridEntry,
}

@(private)
scene_batcher: Batcher

@(private)
begin_batching :: proc(b: ^Batcher) {
	clear(&b.members)
	clear(&b.group_of)
	clear(&b.next)
	clear(&b.groups)
	clear(&b.entries)
	resize(&b.newest, len(shader_cache.entries) * len(BlendMode))
	for &g in b.newest {
		g = -1
	}
	for &c in b.cells {
		c = -1
	}
}

// Places a visible entity in the newest group it can join, or in a new group at the end.
@(private)
batch_entity :: proc(b: ^Batcher, e: ^Entity) {
	shader := -1
	lo, hi: Vector2
	switch d in e.drawable {
	case Material:
		if !e.cache.enabled || e.cache.texture.id == 0 {
			shader = d.shader
		}
		// The rotated quad's bounding box.
		half := e.size / 2 + e.pad
		s, c := math.sincos(e.rotation * math.RAD_PER_DEG)
		box := Vector2{abs(c) * half.x + abs(s) * half.y, abs(s) * half.x + abs(c) * half.y}
		lo, hi = e.pos - box, e.pos + box
	case Text:
		pos, dims := text_rect(e, d)
		lo, hi = pos, pos + dims
	}
	// Quads that only share an edge don't overlap.
	EPSILON :: 0.01
	lo += EPSILON
	hi -= EPSILON

	member := len(b.members)
	group := -1
	key := shader * len(BlendMode) + int(e.blend)
	if shader >= 0 {
		newest := b.newest[key]
		if newest >= 0 && (newest == len(b.groups) - 1 || !overlaps_since(b, newest + 1, lo, hi)) {
			group = newest
		}
	}
	if group < 0 {
		group = len(b.groups)
		append(&b.groups, DrawGroup{shader = shader, blend = e.blend, head = member, tail = member, created = member})
		if shader >= 0 {
			b.newest[key] = group
		}
	} else {
		g := &b.groups[group]
		b.next[g.tail] = member
		g.tail = member
	}
	append(&b.members, e)
	append(&b.group_of, group)
	append(&b.next, -1)

	x0, y0, x1, y1 := cell_range(lo, hi)
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			cell := &b.cells[y * BATCH_GRID + x]
			append(&b.entries, GridEntry{lo, hi, member, cell^})
			cell^ = len(b.entries) - 1
		}
	}
}

// Whether a member of group `first` or a later one overlaps the box.
@(private)
overlaps_since :: proc(b: ^Batcher, first: int, lo, hi: Vector2) -> bool {
	// Members placed before the group was created belong to earlier groups, and every cell
	// lists its entries newest first, so the search stops at them.
	created := b.groups[first].created
	x0, y0, x1, y1 := cell_range(lo, hi)
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			for i := b.cells[y * BATCH_GRID + x]; i >= 0; i = b.entries[i].next {
				entry := &b.entries[i]
				if entry.member < created {
					break
				}
				if b.group_of[entry.member] >= first && lo.x < entry.hi.x && entry.lo.x < hi.x && lo.y < entry.hi.y && entry.lo.y < hi.y {
					return true
				}
			}
		}
	}
	return false
}

// The grid cells a box touches; boxes beyond the screen use the cells at its edge.
@(private)
cell_range :: proc(lo, hi: Vector2) -> (x0, y0, x1, y1: int) {
	cell := Vector2{engine.width, engine.height} / BATCH_GRID
	to_cell :: proc(v, size: f32) -> int {
		return clamp(int(math.floor(v / size)), 0, BATCH_GRID - 1)
	}
	return to_cell(lo.x, cell.x), to_cell(lo.y, cell.y), to_cell(hi.x, cell.x), to_cell(hi.y, cell.y)
}

// Adds the groups' draws to the list, in group order.
@(private)
emit_batches :: proc(b: ^Batcher, list: ^DrawList) {
	px := 1 / engine.viewport.scale
	for g in b.groups {
		if g.shader < 0 {
			append(&list.steps, RaylibDraw{b.members[g.head].id})
			continue
		}
		for m := g.head; m >= 0; m = b.next[m] {
			e := b.members[m]
			add_instance(list, &e.drawable.(Material), e.pos, e.size, e.pad, 1, px, f32(engine.time - e.spawn_time), e.rotation, e.blend, e.pos)
		}
	}
}

@(private)
delete_batcher :: proc(b: ^Batcher) {
	delete(b.members)
	delete(b.group_of)
	delete(b.next)
	delete(b.groups)
	delete(b.newest)
	delete(b.entries)
}
