package vfx

import "core:fmt"
import "core:hash"
import "core:strings"

ParamSlot :: struct {
	name:   string,
	offset: int,
	type:   Type,
}

// Result of compiling a look. `source` doubles as the cache key for the shader: two trees
// with the same structure (and parameter names) produce identical sources.
Program :: struct {
	source:   string,
	defaults: []f32, // initial value of every uniform slot, padded to a multiple of 4
	params:   []ParamSlot, // named slots, settable at runtime
	animated: bool, // reads time(), age() or the scene lights, so it changes from frame to frame
}

@(private)
Gen :: struct {
	funcs:  strings.Builder,
	ids:    map[^Node]int,
	values: [dynamic]f32,
	named:    [dynamic]ParamSlot,
	animated: bool,
}

@(private)
GLSL_TYPE := [Type]string {
	.Float = "float",
	.Vec2  = "vec2",
	.Vec4  = "vec4",
}

@(private)
TYPE_WIDTH := [Type]int {
	.Float = 1,
	.Vec2  = 2,
	.Vec4  = 4,
}

// Compiles a look into a fragment shader. Everything is allocated with `allocator`.
compile :: proc(root: Expr, allocator := context.allocator) -> Program {
	context.allocator = context.temp_allocator
	g: Gen
	strings.builder_init(&g.funcs)

	r := to_node(root)
	root_id := emit(&g, r)

	sb := strings.builder_make()
	// Slots are packed into vec4s, as they're laid out in the instance records.
	for len(g.values) % 4 != 0 {
		append(&g.values, 0)
	}
	strings.write_string(&sb, FRAGMENT_HEADER)
	for s in g.named {
		fmt.sbprintf(&sb, "// param %s @ %d\n", s.name, s.offset)
	}
	strings.write_string(&sb, PRELUDE)
	strings.write_string(&sb, strings.to_string(g.funcs))
	to_rgba := [Type]string {
		.Float = "vec4(vec3(v), 1.0)",
		.Vec2  = "vec4(v, 0.0, 1.0)",
		.Vec4  = "v",
	}
	fmt.sbprintf(
		&sb,
		`void main() {{
	u_size = v_shape.xy; u_rot = v_shape.z; u_age = v_shape.w;
	u_extent = v_frame.xy; u_origin = v_frame.zw;
	vec2 p = (fragTexCoord - 0.5) * u_extent;
	%s v = n%d(p);
	finalColor = %s;
}}
`,
		GLSL_TYPE[r.type],
		root_id,
		to_rgba[r.type],
	)

	return clone_program({strings.to_string(sb), g.values[:], g.named[:], g.animated}, allocator)
}

// What the shader cache needs from a look, without generating any GLSL: a key for its
// structure (equal keys mean identical generated shaders) and the initial values of its
// parameter slots, laid out exactly as compile lays them out.
Layout :: struct {
	key:      u64,
	defaults: []f32, // padded to a multiple of 4, like Program.defaults
}

layout :: proc(root: Expr, allocator := context.allocator) -> Layout {
	w: Walker
	{
		context.allocator = context.temp_allocator
		walk(&w, to_node(root))
		for len(w.values) % 4 != 0 {
			append(&w.values, 0)
		}
	}
	defaults := make([]f32, len(w.values), allocator)
	copy(defaults, w.values[:])
	return {hash.fnv64a(w.bytes[:]), defaults}
}

@(private)
Walker :: struct {
	ids:    map[^Node]int,
	bytes:  [dynamic]u8, // everything that shapes the generated code, in emission order
	values: [dynamic]f32,
	named:  [dynamic]ParamSlot,
}

// Mirrors emit: children first, every shared node once, with ids in emission order. Records
// each node's op, type, compile-time counts, names and child ids, which together determine
// the generated source, and allocates parameter slots in the same order as alloc_slot.
@(private)
walk :: proc(w: ^Walker, n: ^Node) -> int {
	if id, ok := w.ids[n]; ok {
		return id
	}
	c: [MAX_ARGS]int
	for i in 0 ..< n.nargs {
		c[i] = walk(w, n.args[i])
	}
	id := len(w.ids)
	w.ids[n] = id

	put :: proc(w: ^Walker, v: int) {
		bytes := transmute([8]u8)u64(v)
		append(&w.bytes, ..bytes[:])
	}
	put(w, int(n.op))
	put(w, int(n.type))
	put(w, n.nargs)
	for i in 0 ..< n.nargs {
		put(w, c[i])
	}
	put(w, n.count[0])
	put(w, n.count[1])
	if n.op == .Param || n.op == .Swizzle {
		put(w, len(n.name))
		append(&w.bytes, n.name)
	}

	#partial switch n.op {
	case .Const:
		for i in 0 ..< TYPE_WIDTH[n.type] {
			append(&w.values, n.value[i])
		}
	case .Param:
		for s in w.named {
			if s.name == n.name {
				return id
			}
		}
		append(&w.named, ParamSlot{n.name, len(w.values), n.type})
		for i in 0 ..< TYPE_WIDTH[n.type] {
			append(&w.values, n.value[i])
		}
	}
	return id
}

clone_program :: proc(prog: Program, allocator := context.allocator) -> Program {
	out := Program {
		source   = strings.clone(prog.source, allocator),
		defaults = make([]f32, len(prog.defaults), allocator),
		params   = make([]ParamSlot, len(prog.params), allocator),
		animated = prog.animated,
	}
	copy(out.defaults, prog.defaults)
	for s, i in prog.params {
		out.params[i] = {strings.clone(s.name, allocator), s.offset, s.type}
	}
	return out
}

delete_program :: proc(prog: Program, allocator := context.allocator) {
	delete(prog.source, allocator)
	delete(prog.defaults, allocator)
	for s in prog.params {
		delete(s.name, allocator)
	}
	delete(prog.params, allocator)
}

@(private)
slot_expr :: proc(offset: int, type: Type) -> string {
	slot :: proc(i: int) -> string {
		components := "xyzw"
		return fmt.tprintf("u_p(%d).%c", i / 4, components[i % 4])
	}
	switch type {
	case .Float:
		return slot(offset)
	case .Vec2:
		return fmt.tprintf("vec2(%s, %s)", slot(offset), slot(offset + 1))
	case .Vec4:
		return fmt.tprintf("vec4(%s, %s, %s, %s)", slot(offset), slot(offset + 1), slot(offset + 2), slot(offset + 3))
	}
	unreachable()
}

@(private)
alloc_slot :: proc(g: ^Gen, n: ^Node) -> int {
	offset := len(g.values)
	for i in 0 ..< TYPE_WIDTH[n.type] {
		append(&g.values, n.value[i])
	}
	return offset
}

// Emits the GLSL function for `n` (after its children) and returns its index. Every node
// becomes `T n<id>(vec2 p)`, so any subtree can be re-evaluated at another position.
@(private)
emit :: proc(g: ^Gen, n: ^Node) -> int {
	if id, ok := g.ids[n]; ok {
		return id
	}
	c: [MAX_ARGS]int
	for i in 0 ..< n.nargs {
		c[i] = emit(g, n.args[i])
	}
	id := len(g.ids)
	g.ids[n] = id

	// a(i) = call of the i-th argument at the current position
	a :: proc(c: [MAX_ARGS]int, i: int) -> string {
		return fmt.tprintf("n%d(p)", c[i])
	}

	sb := &g.funcs
	fmt.sbprintf(sb, "%s n%d(vec2 p) {{ ", GLSL_TYPE[n.type], id)
	body: string
	switch n.op {
	case .Const:
		body = slot_expr(alloc_slot(g, n), n.type)
	case .Param:
		offset := -1
		for s in g.named {
			if s.name == n.name {
				assert(s.type == n.type, "vfx: param used with two different types")
				offset = s.offset
			}
		}
		if offset < 0 {
			offset = alloc_slot(g, n)
			append(&g.named, ParamSlot{n.name, offset, n.type})
		}
		body = slot_expr(offset, n.type)
	case .Coord:
		body = "p"
	case .World:
		body = "u_origin + rot2(p, u_rot)"
	case .Uv:
		body = "p / u_size + 0.5"
	case .Size:
		body = "u_size"
	case .Time:
		body = "u_time"
		g.animated = true
	case .Age:
		body = "u_age"
		g.animated = true
	case .Px:
		body = "u_px"
	case .Add:
		body = fmt.tprintf("%s + %s", a(c, 0), a(c, 1))
	case .Sub:
		body = fmt.tprintf("%s - %s", a(c, 0), a(c, 1))
	case .Mul:
		body = fmt.tprintf("%s * %s", a(c, 0), a(c, 1))
	case .Div:
		body = fmt.tprintf("%s / %s", a(c, 0), a(c, 1))
	case .Min:
		body = binary_call(n, "min", a(c, 0), a(c, 1))
	case .Max:
		body = binary_call(n, "max", a(c, 0), a(c, 1))
	case .Mix:
		body = fmt.tprintf(
			"mix(%s(%s), %s(%s), %s)",
			GLSL_TYPE[n.type],
			a(c, 0),
			GLSL_TYPE[n.type],
			a(c, 1),
			a(c, 2),
		)
	case .Smoothstep:
		body = fmt.tprintf("smoothstep(%s, %s, %s)", a(c, 0), a(c, 1), a(c, 2))
	case .Step:
		body = fmt.tprintf("step(%s, %s)", a(c, 0), a(c, 1))
	case .Saturate:
		body = fmt.tprintf("clamp(%s, 0.0, 1.0)", a(c, 0))
	case .Abs:
		body = fmt.tprintf("abs(%s)", a(c, 0))
	case .Neg:
		body = fmt.tprintf("-%s", a(c, 0))
	case .Sin:
		body = fmt.tprintf("sin(%s)", a(c, 0))
	case .Cos:
		body = fmt.tprintf("cos(%s)", a(c, 0))
	case .Exp:
		body = fmt.tprintf("exp(%s)", a(c, 0))
	case .Sqrt:
		body = fmt.tprintf("sqrt(max(%s, 0.0))", a(c, 0))
	case .Asin:
		body = fmt.tprintf("asin(clamp(%s, -1.0, 1.0))", a(c, 0))
	case .Pow:
		body = fmt.tprintf("pow(max(%s, 0.0), %s(%s))", a(c, 0), GLSL_TYPE[n.type], a(c, 1))
	case .Floor:
		body = fmt.tprintf("floor(%s)", a(c, 0))
	case .Fract:
		body = fmt.tprintf("fract(%s)", a(c, 0))
	case .Length:
		body = fmt.tprintf("length(%s)", a(c, 0))
	case .Angle:
		body = fmt.tprintf("angle2(%s)", a(c, 0))
	case .Dot:
		body = fmt.tprintf("dot(%s, %s)", a(c, 0), a(c, 1))
	case .Swizzle:
		body = fmt.tprintf("(%s).%s", a(c, 0), n.name)
	case .MakeVec2:
		body = fmt.tprintf("vec2(%s, %s)", a(c, 0), a(c, 1))
	case .MakeRgba:
		body = fmt.tprintf("vec4(%s, %s, %s, %s)", a(c, 0), a(c, 1), a(c, 2), a(c, 3))
	case .Rotate:
		body = fmt.tprintf("rot2(%s, %s)", a(c, 0), a(c, 1))
	case .Tile:
		body = fmt.tprintf("tile2(%s, vec2(%s))", a(c, 0), a(c, 1))
	case .CellId:
		body = fmt.tprintf("floor(%s / vec2(%s))", a(c, 0), a(c, 1))
	case .BrickLocal:
		body = fmt.tprintf("brick_local(%s, vec2(%s), %s)", a(c, 0), a(c, 1), a(c, 2))
	case .BrickId:
		body = fmt.tprintf("brick_id(%s, vec2(%s), %s)", a(c, 0), a(c, 1), a(c, 2))
	case .At:
		body = fmt.tprintf("n%d(%s)", c[0], a(c, 1))
	case .Hash:
		if n.args[0].type == .Float {
			body = fmt.tprintf("hash11(%s)", a(c, 0))
		} else {
			body = fmt.tprintf("hash12(vec2(%s))", a(c, 0))
		}
	case .Noise:
		body = fmt.tprintf("vnoise(%s)", a(c, 0))
	case .Fbm:
		body = fmt.tprintf("fbm(%s, %d, %s, %s)", a(c, 0), n.count[0], a(c, 1), a(c, 2))
	case .Voronoi:
		body = fmt.tprintf("voronoi(%s)", a(c, 0))
	case .VoronoiEdge:
		body = fmt.tprintf("voronoi_edge(%s)", a(c, 0))
	case .SdBox:
		body = fmt.tprintf("sd_box(%s, vec2(%s), %s)", a(c, 0), a(c, 1), a(c, 2))
	case .SdCircle:
		body = fmt.tprintf("length(%s) - %s", a(c, 0), a(c, 1))
	case .SdSegment:
		body = fmt.tprintf("sd_segment(%s, %s, %s)", a(c, 0), a(c, 1), a(c, 2))
	case .Fill:
		body = fmt.tprintf("fill_aa(%s)", a(c, 0))
	case .Stroke:
		body = fmt.tprintf("fill_aa(abs(%s) - 0.5 * %s)", a(c, 0), a(c, 1))
	case .Glow:
		body = fmt.tprintf("exp(-max(%s, 0.0) / max(%s, 1e-4))", a(c, 0), a(c, 1))
	case .Palette:
		body = fmt.tprintf(
			"vec4(clamp(%s.rgb + %s.rgb * cos(6.2831853 * (%s.rgb * %s + %s.rgb)), 0.0, 1.0), 1.0)",
			a(c, 1),
			a(c, 2),
			a(c, 3),
			a(c, 0),
			a(c, 4),
		)
	case .Over:
		body = fmt.tprintf("over(%s, %s)", a(c, 0), a(c, 1))
	case .Shade:
		body = fmt.tprintf("vec4(%s.rgb * %s, %s.a)", a(c, 0), vec3_of(n.args[1].type, a(c, 1)), a(c, 0))
	case .Mask:
		body = fmt.tprintf("%s * vec4(1.0, 1.0, 1.0, %s)", a(c, 0), a(c, 1))
	case .Lit:
		// Surface normal from central differences of the height field.
		h := c[1]
		fmt.sbprintf(
			sb,
			"float e = %s; vec2 g = vec2(n%d(p + vec2(e, 0.0)) - n%d(p - vec2(e, 0.0)), n%d(p + vec2(0.0, e)) - n%d(p - vec2(0.0, e))) / (2.0 * e); ",
			a(c, 6),
			h,
			h,
			h,
			h,
		)
		body = fmt.tprintf("light(%s, g * %s, %s, %s, %s)", a(c, 0), a(c, 2), a(c, 3), a(c, 4), a(c, 5))
	case .LitScene:
		h := c[1]
		fmt.sbprintf(
			sb,
			"float e = %s; vec2 g = vec2(n%d(p + vec2(e, 0.0)) - n%d(p - vec2(e, 0.0)), n%d(p + vec2(0.0, e)) - n%d(p - vec2(0.0, e))) / (2.0 * e); ",
			a(c, 5),
			h,
			h,
			h,
			h,
		)
		body = fmt.tprintf("scene_light(%s, g * %s, %s, %s, u_origin + rot2(p, u_rot))", a(c, 0), a(c, 2), a(c, 3), a(c, 4))
		g.animated = true
	case .Shatter:
		emit_shatter(sb, n, c)
	case .Sparks:
		body = fmt.tprintf(
			"sparks(p, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %d)",
			a(c, 0),
			a(c, 1),
			a(c, 2),
			a(c, 3),
			a(c, 4),
			a(c, 5),
			a(c, 6),
			a(c, 7),
			a(c, 8),
			a(c, 9),
			n.count[0],
		)
	}
	if body != "" {
		fmt.sbprintf(sb, "return %s; ", body)
	}
	strings.write_string(sb, "}\n")
	return id
}

@(private)
binary_call :: proc(n: ^Node, fn, x, y: string) -> string {
	// GLSL min/max accept (genType, float) but not (float, genType).
	if n.args[0].type == .Float && n.type != .Float {
		return fmt.tprintf("%s(%s, %s)", fn, y, x)
	}
	return fmt.tprintf("%s(%s, %s)", fn, x, y)
}

@(private)
vec3_of :: proc(t: Type, s: string) -> string {
	switch t {
	case .Float:
		return s
	case .Vec2:
		return fmt.tprintf("vec3(%s, 1.0)", s)
	case .Vec4:
		return fmt.tprintf("(%s).rgb", s)
	}
	unreachable()
}

// Inverse-maps the pixel into every shard's rest frame and keeps the first shard that owns
// it (Voronoi ownership test against all shard seeds).
@(private)
emit_shatter :: proc(sb: ^strings.Builder, n: ^Node, c: [MAX_ARGS]int) {
	cols, rows := n.count[0], n.count[1]
	fmt.sbprintf(
		sb,
		`
	const int COLS = %d; const int N = %d;
	float t = n%d(p); vec2 imp = n%d(p); float sd = n%d(p);
	float speed = n%d(p); float grav = n%d(p); float spin = n%d(p);
	vec2 hs = u_size * 0.5; vec2 cell = u_size / vec2(%d.0, %d.0);
	vec2 seeds[N];
	for (int i = 0; i < N; i++) {{
		vec2 h = hash22(vec2(float(i) * 3.17, sd));
		seeds[i] = -hs + cell * (vec2(float(i %% COLS), float(i / COLS)) + 0.15 + 0.7 * h);
	}}
	for (int i = 0; i < N; i++) {{
		vec2 s = seeds[i];
		float r = hash11(float(i) * 7.31 + sd);
		vec2 away = s - imp; away /= max(length(away), 1e-3);
		vec2 vel = (away * (0.55 + 0.9 * r) + vec2(0.0, -0.5)) * speed;
		vec2 off = vel * t + vec2(0.0, 0.5 * grav * t * t);
		vec2 q = s + rot2(p - s - off, -(r - 0.5) * 2.0 * spin * t);
		if (abs(q.x) > hs.x || abs(q.y) > hs.y) continue;
		float edge = 1e9;
		for (int j = 0; j < N; j++) {{
			if (j == i) continue;
			vec2 sj = seeds[j]; vec2 dir = normalize(sj - s);
			edge = min(edge, dot(0.5 * (s + sj) - q, dir));
		}}
		if (edge < 0.0) continue;
		vec4 col = n%d(q);
		if (col.a < 0.01) continue;
		col.rgb *= mix(0.55, 1.0, smoothstep(0.0, 2.5, edge));
		col.a *= clamp(edge / u_px + step(t, 0.0), 0.0, 1.0);
		return col;
	}}
	return vec4(0.0);
`,
		cols,
		cols * rows,
		c[1],
		c[2],
		c[3],
		c[4],
		c[5],
		c[6],
		cols,
		rows,
		c[0],
	)
}
