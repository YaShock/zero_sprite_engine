package vfx

import "core:fmt"
import "core:hash"
import "core:strconv"
import "core:strings"

ParamSlot :: struct {
	name:   string,
	offset: int,
	type:   Type,
	count:   int, // param_array / data_array: number of values; 0 for a single value
	texture: bool, // data_array: `offset` is into the material's data texture, not the uniforms
}

// Result of compiling a look. Two trees with the same structure (and parameter names)
// produce identical sources; layout() tells that without generating the source.
Program :: struct {
	source:   string,
	defaults: []f32, // initial value of every parameter slot, padded to a multiple of 4
	params:   []ParamSlot, // named slots, settable at runtime
	animated: bool, // reads time(), age() or the scene lights, so it changes from frame to frame
	data_size: int, // floats in the data texture that the look's data_arrays need; 0 = none
	instances: [2]int, // instanced looks: first value and values per record of the instance records in the data texture; {0, 0} = not instanced
	layer:     int, // the buffer layer the look samples (vfx.layer_sample); -1 = none
	layer2:    int, // a second one it samples (u_layer2); -1 = none
}

@(private)
Gen :: struct {
	w:        ^Walker, // the tree's slots, assigned before anything is emitted (see walk)
	funcs:    strings.Builder,
	ids:      map[^Node]int, // nodes emitted as functions
	animated: bool,
	layer:    int, // see Program
	layer2:   int, // see Program
}

// Inputs of an instanced look, from vertex_instanced.glsl
@(private)
INSTANCED_HEADER :: `flat in int v_instance; // this pixel's instance
in vec2 v_local;  // position from the instance's center (coord())
in vec2 v_center; // the instance's center in the entity's frame
uniform ivec2 u_instances; // first value and values per record of the instance records in u_data
int instance_base() {
	return u_instances.x + v_instance * u_instances.y;
}
`

// The prelude function behind each GlowFalloff
@(private)
FALLOFF_FUNCTION := [GlowFalloff]string {
	.Soft      = "glow_falloff",
	.Dot       = "dot_falloff",
	.Quadratic = "quadratic_falloff",
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
// `bake_constants` writes constants into the source as literals instead of uniform slots: the
// driver can fold them (and unroll loops of a fixed length), at the price of looks that
// differ only in a constant no longer sharing one shader.
compile :: proc(root: Expr, allocator := context.allocator, bake_constants := false) -> Program {
	context.allocator = context.temp_allocator
	r := to_node(root)
	w := walk_tree(r, bake_constants)
	g := Gen {
		w      = &w,
		layer  = -1,
		layer2 = -1,
	}
	strings.builder_init(&g.funcs)
	locals: Locals
	strings.builder_init(&locals.sb)
	value := emit_local(&g, &locals, r)

	sb := strings.builder_make()
	strings.write_string(&sb, FRAGMENT_HEADER)
	instanced := w.instances[1] > 0
	if instanced {
		strings.write_string(&sb, INSTANCED_MARKER)
		strings.write_string(&sb, INSTANCED_HEADER)
	}
	for s in w.named {
		fmt.sbprintf(&sb, "// param %s @ %d\n", s.name, s.offset)
	}
	if g.layer >= 0 {
		// Looks that differ only in the layer they read must not share a program
		fmt.sbprintf(&sb, "// samples layer %d\n", g.layer)
	}
	if g.layer2 >= 0 {
		fmt.sbprintf(&sb, "uniform sampler2D u_layer2; // samples layer %d too\n", g.layer2)
	}
	strings.write_string(&sb, PRELUDE)
	strings.write_string(&sb, strings.to_string(g.funcs))
	to_rgba := [Type]string {
		.Float = "vec4(vec3(%s), 1.0)",
		.Vec2  = "vec4(%s, 0.0, 1.0)",
		.Vec4  = "%s",
	}
	fmt.sbprintf(
		&sb,
		`void main() {{
	u_size = v_shape.xy; u_rot = v_shape.z; u_age = v_shape.w;
	u_extent = v_frame.xy; u_origin = v_frame.zw;
	vec2 p = %s;
%s	finalColor = %s;
}}
`,
		"v_local" if instanced else "(fragTexCoord - 0.5) * u_extent",
		strings.to_string(locals.sb),
		fmt.tprintf(to_rgba[r.type], value),
	)

	return clone_program({strings.to_string(sb), w.values[:], w.named[:], g.animated, w.data_size, w.instances, g.layer, g.layer2}, allocator)
}

// What the shader cache needs from a look, without generating any GLSL: a key for its
// structure (equal keys mean identical generated shaders) and the initial values of its
// parameter slots, laid out exactly as compile lays them out.
Layout :: struct {
	key:      u64,
	defaults: []f32, // padded to a multiple of 4, like Program.defaults
}

layout :: proc(root: Expr, bake_constants := false, allocator := context.allocator) -> Layout {
	w: Walker
	{
		context.allocator = context.temp_allocator
		w = walk_tree(to_node(root), bake_constants)
	}
	defaults := make([]f32, len(w.values), allocator)
	copy(defaults, w.values[:])
	return {hash.fnv64a(w.bytes[:]), defaults}
}

// The tree's structure and slots, from one pass over it that both layout and compile use, so
// they always agree on where every slot is.
@(private)
Walker :: struct {
	ids:       map[^Node]int, // in walk order: children first, every shared node once
	bytes:     [dynamic]u8, // everything that shapes the generated code
	values:    [dynamic]f32, // initial values of the parameter slots
	named:     [dynamic]ParamSlot,
	slots:     [dynamic]int, // per node id: the slot of a Const or Param; -1 for others
	data_size: int, // see Program
	instances: [2]int, // see Program
	bake:      bool, // constants are literals (see compile)
}

@(private)
walk_tree :: proc(root: ^Node, bake: bool) -> (w: Walker) {
	w.bake = bake
	put(&w, int(bake))
	walk(&w, root)
	// Slots are packed into vec4s, as they're laid out in the instance records.
	for len(w.values) % 4 != 0 {
		append(&w.values, 0)
	}
	return
}

@(private)
put :: proc(w: ^Walker, v: int) {
	bytes := transmute([8]u8)u64(v)
	append(&w.bytes, ..bytes[:])
}

// Records each node's op, type, compile-time counts, names and child ids, which together
// determine the generated source (with constants' values when they are baked in), and
// assigns the parameter slots.
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

	put(w, int(n.op))
	put(w, int(n.type))
	put(w, n.nargs)
	for i in 0 ..< n.nargs {
		put(w, c[i])
	}
	put(w, n.count[0])
	put(w, n.count[1])
	if len(n.name) > 0 {
		put(w, len(n.name))
		append(&w.bytes, n.name)
	}

	slot := -1
	#partial switch n.op {
	case .Const:
		if w.bake {
			for i in 0 ..< TYPE_WIDTH[n.type] {
				put(w, int(transmute(u32)n.value[i]))
			}
		} else {
			slot = len(w.values)
			for i in 0 ..< TYPE_WIDTH[n.type] {
				append(&w.values, n.value[i])
			}
		}
	case .Param:
		for s in w.named {
			if s.name == n.name {
				assert(s.type == n.type && s.count == 0, "vfx: param used with two different types")
				slot = s.offset
			}
		}
		if slot < 0 {
			slot = len(w.values)
			append(&w.named, ParamSlot{n.name, slot, n.type, 0, false})
			for i in 0 ..< TYPE_WIDTH[n.type] {
				append(&w.values, n.value[i])
			}
		}
	case .ParamArray:
		put(w, int(n.value[0])) // an instances array's record length
		array_slot(w, n)
	case .Instance, .InstanceOf, .Instanced:
		// The instance records: an instanced look computes world() and coord() differently
		records := n.args[1] if n.op == .Instanced else n.args[0]
		offset := array_slot(w, records)
		assert(w.instances[1] == 0 || w.instances[0] == offset, "vfx: a look reads one instances array")
		w.instances = {offset, int(records.value[0])}
	}
	append(&w.slots, slot)
	return id
}

// First slot of a param_array or data_array (an offset into the data texture for a
// data_array), allocated (zeros) the first time the name is seen.
@(private)
array_slot :: proc(w: ^Walker, n: ^Node) -> int {
	count, texture := n.count[0], n.count[1] != 0
	for s in w.named {
		if s.name == n.name {
			assert(s.count == count && s.texture == texture, "vfx: array used with two different lengths or kinds")
			return s.offset
		}
	}
	// Arrays start on a group of four, so their readers can fetch four values at once
	offset: int
	if texture {
		w.data_size = (w.data_size + 3) &~ 3
		offset = w.data_size
		w.data_size += count
	} else {
		for len(w.values) % 4 != 0 {
			append(&w.values, 0)
		}
		offset = len(w.values)
		for _ in 0 ..< count {
			append(&w.values, 0)
		}
	}
	append(&w.named, ParamSlot{n.name, offset, .Float, count, texture})
	return offset
}

// The slot walk assigned to a Const or Param node
@(private)
slot_of :: proc(g: ^Gen, n: ^Node) -> int {
	return g.w.slots[g.w.ids[n]]
}

clone_program :: proc(prog: Program, allocator := context.allocator) -> Program {
	out := Program {
		source   = strings.clone(prog.source, allocator),
		defaults = make([]f32, len(prog.defaults), allocator),
		params   = make([]ParamSlot, len(prog.params), allocator),
		animated = prog.animated,
		data_size = prog.data_size,
		instances = prog.instances,
		layer = prog.layer,
		layer2 = prog.layer2,
	}
	copy(out.defaults, prog.defaults)
	for s, i in prog.params {
		out.params[i] = {strings.clone(s.name, allocator), s.offset, s.type, s.count, s.texture}
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

// A constant as GLSL: each component the shortest decimal that reads back as the same f32
@(private)
literal :: proc(value: [4]f32, type: Type) -> string {
	number :: proc(v: f32) -> string {
		assert(v == v && v - v == 0, "vfx: a constant must be a finite number")
		buf: [32]u8
		s := strconv.write_float(buf[:], f64(v), 'g', -1, 32)
		if s[0] == '+' {
			s = s[1:]
		}
		if !strings.contains_any(s, ".e") {
			return fmt.tprintf("%s.0", s)
		}
		return strings.clone(s, context.temp_allocator)
	}
	switch type {
	case .Float:
		return number(value[0])
	case .Vec2:
		return fmt.tprintf("vec2(%s, %s)", number(value[0]), number(value[1]))
	case .Vec4:
		return fmt.tprintf("vec4(%s, %s, %s, %s)", number(value[0]), number(value[1]), number(value[2]), number(value[3]))
	}
	unreachable()
}

// Emits the GLSL function for `n` (after its children) and returns its index: `T n<id>(vec2 p)`,
// for the subtrees that are evaluated at other positions (`at`, `lit`, `shatter`). Inside
// a function, a child used twice is called twice; main avoids that (see emit_local).
@(private)
emit :: proc(g: ^Gen, n: ^Node) -> int {
	if id, ok := g.ids[n]; ok {
		return id
	}
	c: [MAX_ARGS]int
	args: [MAX_ARGS]string // call of each argument at the current position
	for i in 0 ..< n.nargs {
		c[i] = emit(g, n.args[i])
		args[i] = fmt.tprintf("n%d(p)", c[i])
	}
	id := len(g.ids)
	g.ids[n] = id

	sb := &g.funcs
	fmt.sbprintf(sb, "%s n%d(vec2 p) {{ ", GLSL_TYPE[n.type], id)
	if n.op == .Gate {
		// The value's function is only called past the test
		fmt.sbprintf(sb, "if (%s <= 0.0) return %s(0.0); ", args[0], GLSL_TYPE[n.type])
	}
	body := node_code(g, sb, n, args, c)
	if body != "" {
		fmt.sbprintf(sb, "return %s; ", body)
	}
	strings.write_string(sb, "}\n")
	return id
}

// Straight-line evaluation at p, for main: every node is computed once into a local
// (t<k>), however many parents use it. A gate's value is computed inside its `if`, and the
// locals made there are forgotten after it. Nodes that evaluate a child at other positions
// call their function (see emit).
@(private)
Locals :: struct {
	sb:    strings.Builder,
	names: map[^Node]string,
	made:  [dynamic]^Node, // in order, so a gate can forget the ones made inside it
	count: int,
}

@(private)
emit_local :: proc(g: ^Gen, l: ^Locals, n: ^Node) -> string {
	if name, ok := l.names[n]; ok {
		return name
	}
	type := GLSL_TYPE[n.type]
	name: string
	#partial switch n.op {
	case .At, .Lit, .LitScene, .Shatter:
		id := emit(g, n)
		name = fmt.tprintf("t%d", l.count)
		fmt.sbprintf(&l.sb, "\t%s %s = n%d(p);\n", type, name, id)
	case .Gate:
		cond := emit_local(g, l, n.args[0])
		name = fmt.tprintf("t%d", l.count)
		l.count += 1
		// The test as the function form makes it, so a NaN condition behaves the same
		fmt.sbprintf(&l.sb, "\t%s %s = %s(0.0);\n\tif (!(%s <= 0.0)) {{\n", type, name, type, cond)
		mark := len(l.made)
		value := emit_local(g, l, n.args[1])
		fmt.sbprintf(&l.sb, "\t%s = %s;\n\t}}\n", name, value)
		for made in l.made[mark:] {
			delete_key(&l.names, made)
		}
		resize(&l.made, mark)
	case:
		args: [MAX_ARGS]string
		for i in 0 ..< n.nargs {
			args[i] = emit_local(g, l, n.args[i])
		}
		name = fmt.tprintf("t%d", l.count)
		stmts := strings.builder_make()
		body := node_code(g, &stmts, n, args, {})
		if strings.builder_len(stmts) == 0 {
			fmt.sbprintf(&l.sb, "\t%s %s = %s;\n", type, name, body)
		} else {
			// Statements in a block of their own, so their names don't clash
			fmt.sbprintf(&l.sb, "\t%s %s; {{ %s%s = %s; }}\n", type, name, strings.to_string(stmts), name, body)
		}
	}
	if n.op != .Gate {
		l.count += 1
	}
	l.names[n] = name
	append(&l.made, n)
	return name
}

// The GLSL for one node: statements written to `sb`, then the expression of its value (empty
// when the statements return it themselves). `args` are the arguments' values; `c` their
// function ids, only for the nodes that call a child at another position (function form).
@(private)
node_code :: proc(g: ^Gen, sb: ^strings.Builder, n: ^Node, args: [MAX_ARGS]string, c: [MAX_ARGS]int) -> (body: string) {
	switch n.op {
	case .Const:
		if g.w.bake {
			body = literal(n.value, n.type)
		} else {
			body = slot_expr(slot_of(g, n), n.type)
		}
	case .Param:
		body = slot_expr(slot_of(g, n), n.type)
	case .Coord:
		body = "p"
	case .World:
		body = "u_origin + rot2(v_center + p, u_rot)" if g.w.instances[1] > 0 else "u_origin + rot2(p, u_rot)"
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
		body = fmt.tprintf("%s + %s", args[0], args[1])
	case .Sub:
		body = fmt.tprintf("%s - %s", args[0], args[1])
	case .Mul:
		body = fmt.tprintf("%s * %s", args[0], args[1])
	case .Div:
		body = fmt.tprintf("%s / %s", args[0], args[1])
	case .Min:
		body = binary_call(n, "min", args[0], args[1])
	case .Max:
		body = binary_call(n, "max", args[0], args[1])
	case .Mix:
		body = fmt.tprintf(
			"mix(%s(%s), %s(%s), %s)",
			GLSL_TYPE[n.type],
			args[0],
			GLSL_TYPE[n.type],
			args[1],
			args[2],
		)
	case .Smoothstep:
		body = fmt.tprintf("smoothstep(%s, %s, %s)", args[0], args[1], args[2])
	case .Step:
		body = fmt.tprintf("step(%s, %s)", args[0], args[1])
	case .Saturate:
		body = fmt.tprintf("clamp(%s, 0.0, 1.0)", args[0])
	case .Abs:
		body = fmt.tprintf("abs(%s)", args[0])
	case .Neg:
		body = fmt.tprintf("-%s", args[0])
	case .Sin:
		body = fmt.tprintf("sin(%s)", args[0])
	case .Cos:
		body = fmt.tprintf("cos(%s)", args[0])
	case .Exp:
		body = fmt.tprintf("exp(%s)", args[0])
	case .Sqrt:
		body = fmt.tprintf("sqrt(max(%s, 0.0))", args[0])
	case .Asin:
		body = fmt.tprintf("asin(clamp(%s, -1.0, 1.0))", args[0])
	case .Pow:
		body = fmt.tprintf("pow(max(%s, 0.0), %s(%s))", args[0], GLSL_TYPE[n.type], args[1])
	case .Floor:
		body = fmt.tprintf("floor(%s)", args[0])
	case .Fract:
		body = fmt.tprintf("fract(%s)", args[0])
	case .Length:
		body = fmt.tprintf("length(%s)", args[0])
	case .Angle:
		body = fmt.tprintf("angle2(%s)", args[0])
	case .Dot:
		body = fmt.tprintf("dot(%s, %s)", args[0], args[1])
	case .Swizzle:
		body = fmt.tprintf("(%s).%s", args[0], n.name)
	case .MakeVec2:
		body = fmt.tprintf("vec2(%s, %s)", args[0], args[1])
	case .MakeRgba:
		body = fmt.tprintf("vec4(%s, %s, %s, %s)", args[0], args[1], args[2], args[3])
	case .Rotate:
		body = fmt.tprintf("rot2(%s, %s)", args[0], args[1])
	case .Tile:
		body = fmt.tprintf("tile2(%s, vec2(%s))", args[0], args[1])
	case .CellId:
		body = fmt.tprintf("floor(%s / vec2(%s))", args[0], args[1])
	case .BrickLocal:
		body = fmt.tprintf("brick_local(%s, vec2(%s), %s)", args[0], args[1], args[2])
	case .BrickId:
		body = fmt.tprintf("brick_id(%s, vec2(%s), %s)", args[0], args[1], args[2])
	case .At:
		body = fmt.tprintf("n%d(%s)", c[0], args[1])
	case .Hash:
		if n.args[0].type == .Float {
			body = fmt.tprintf("hash11(%s)", args[0])
		} else {
			body = fmt.tprintf("hash12(vec2(%s))", args[0])
		}
	case .Noise:
		body = fmt.tprintf("vnoise(%s)", args[0])
	case .Fbm:
		body = fmt.tprintf("fbm(%s, %d, %s, %s)", args[0], n.count[0], args[1], args[2])
	case .Voronoi:
		body = fmt.tprintf("voronoi(%s)", args[0])
	case .VoronoiEdge:
		body = fmt.tprintf("voronoi_edge(%s)", args[0])
	case .SdBox:
		body = fmt.tprintf("sd_box(%s, vec2(%s), %s)", args[0], args[1], args[2])
	case .SdCircle:
		body = fmt.tprintf("length(%s) - %s", args[0], args[1])
	case .SdSegment:
		body = fmt.tprintf("sd_segment(%s, %s, %s)", args[0], args[1], args[2])
	case .Fill:
		body = fmt.tprintf("fill_aa(%s)", args[0])
	case .Stroke:
		body = fmt.tprintf("fill_aa(abs(%s) - 0.5 * %s)", args[0], args[1])
	case .Glow:
		body = fmt.tprintf("exp(-max(%s, 0.0) / max(%s, 1e-4))", args[0], args[1])
	case .Palette:
		body = fmt.tprintf(
			"vec4(clamp(%s.rgb + %s.rgb * cos(6.2831853 * (%s.rgb * %s + %s.rgb)), 0.0, 1.0), 1.0)",
			args[1],
			args[2],
			args[3],
			args[0],
			args[4],
		)
	case .Over:
		body = fmt.tprintf("over(%s, %s)", args[0], args[1])
	case .Shade:
		body = fmt.tprintf("vec4(%s.rgb * %s, %s.a)", args[0], vec3_of(n.args[1].type, args[1]), args[0])
	case .Mask:
		body = fmt.tprintf("%s * vec4(1.0, 1.0, 1.0, %s)", args[0], args[1])
	case .Lit:
		// Surface normal from central differences of the height field.
		h := c[1]
		fmt.sbprintf(
			sb,
			"float e = %s; vec2 g = vec2(n%d(p + vec2(e, 0.0)) - n%d(p - vec2(e, 0.0)), n%d(p + vec2(0.0, e)) - n%d(p - vec2(0.0, e))) / (2.0 * e); ",
			args[6],
			h,
			h,
			h,
			h,
		)
		body = fmt.tprintf("light(%s, g * %s, %s, %s, %s)", args[0], args[2], args[3], args[4], args[5])
	case .LitScene:
		h := c[1]
		fmt.sbprintf(
			sb,
			"float e = %s; vec2 g = vec2(n%d(p + vec2(e, 0.0)) - n%d(p - vec2(e, 0.0)), n%d(p + vec2(0.0, e)) - n%d(p - vec2(0.0, e))) / (2.0 * e); ",
			args[5],
			h,
			h,
			h,
			h,
		)
		body = fmt.tprintf("scene_light(%s, g * %s, %s, %s, u_origin + rot2(p, u_rot))", args[0], args[2], args[3], args[4])
		g.animated = true
	case .ParamArray:
		// As a value it reads as its first number; its readers index the slots directly.
		offset, get := array_offset(g, n)
		body = fmt.tprintf("%s(%d)", get, offset)
	case .Curve:
		offset, get := array_offset(g, n.args[0])
		count := n.args[0].count[0]
		fmt.sbprintf(sb, "float t = clamp(%s, 0.0, %d.0); int i = min(int(t), %d); ", args[1], count - 1, count - 2)
		body = fmt.tprintf("mix(%s(%d + i), %s(%d + i + 1), t - float(i))", get, offset, get, offset)
	case .SdCapsules:
		offset, get := array_offset(g, n.args[1])
		shape := fmt.tprintf(
			"int k = %d + i * %d; vec4 s = %s4(k); vec4 r = %s4(k + 4); d = min(d, sd_capsule(q, s.xy, s.zw, r.x, r.y));",
			offset,
			CAPSULE_STRIDE,
			get,
			get,
		)
		emit_shape_loop(g, sb, n, args[0], args[2], args[3], n.args[1].count[0] / CAPSULE_STRIDE, "float d = 1e9;", shape, n.args[4])
		body = "d"
	case .Metaballs:
		offset, get := array_offset(g, n.args[1])
		shape := fmt.tprintf(
			"vec4 l = %s4(%d + i * %d); vec2 dq = q - l.xy; float r2 = l.z * l.z; float k = 1.0 - dot(dq, dq) / max(r2, 1e-12); if (k > 0.0) {{ f.x += l.w * k * k; f.yz += l.w * (-4.0 * k / r2) * dq; }}",
			get,
			offset,
			GLOW_STRIDE,
		)
		emit_shape_loop(g, sb, n, args[0], args[2], args[3], n.args[1].count[0] / GLOW_STRIDE, "vec4 f = vec4(0.0);", shape, n.args[4])
		body = "f"
	case .Gate:
		body = args[1] // the test is the caller's (emit, emit_local)
	case .Instance:
		body = fmt.tprintf("%s(instance_base() + %d)", "dget4" if n.type == .Vec4 else "dget", n.count[0])
	case .InstanceOf:
		body = fmt.tprintf("dget4(u_instances.x + int(%s) * u_instances.y + %d)", args[1], n.count[0])
	case .Instanced:
		body = args[0]
	case .InstanceIndex:
		body = "float(v_instance)"
	case .Falloff:
		body = fmt.tprintf("%s(%s)", FALLOFF_FUNCTION[GlowFalloff(n.count[0])], args[0])
	case .SdCapsuleGroups:
		offset, get := array_offset(g, n.args[1])
		shape := fmt.tprintf(
			"int k = %d + i * %d; vec4 s = %s4(k); vec4 r = %s4(k + 4); float e = sd_capsule(q, s.xy, s.zw, r.x, r.y); " +
			"if (i < e0) d.x = min(d.x, e); else if (i < e1) d.y = min(d.y, e); else if (i < e2) d.z = min(d.z, e); else d.w = min(d.w, e);",
			offset,
			CAPSULE_STRIDE,
			get,
			get,
		)
		// Where each group ends (first is the clamped start the loop sets up)
		init := fmt.tprintf("vec4 d = vec4(1e9); int e0 = first + int(%s); int e1 = e0 + int(%s); int e2 = e1 + int(%s);", args[3], args[4], args[5])
		total := fmt.tprintf("(%s + %s + %s + %s)", args[3], args[4], args[5], args[6])
		emit_shape_loop(g, sb, n, args[0], args[2], total, n.args[1].count[0] / CAPSULE_STRIDE, init, shape, n.args[7])
		body = "d"
	case .LayerSample:
		// The first layer a look samples is u_layer, a second one u_layer2
		sampler := "u_layer"
		if g.layer < 0 || g.layer == n.count[0] {
			g.layer = n.count[0]
		} else {
			assert(g.layer2 < 0 || g.layer2 == n.count[0], "vfx: a look samples two layers at most")
			g.layer2 = n.count[0]
			sampler = "u_layer2"
		}
		// Render textures are upside down: the screen's top is the image's last row
		body = fmt.tprintf("texture(%s, vec2(%s.x / u_screen.x, 1.0 - %s.y / u_screen.y))", sampler, args[0], args[0])
	case .IntFbm:
		body = fmt.tprintf("int_fbm(%s, uint(%s) * 65536u + uint(%s) + %du, %d)", args[0], args[1], args[2], n.count[1], n.count[0])
	case .GlowPoints:
		offset, get := array_offset(g, n.args[1])
		shape := fmt.tprintf(
			"vec4 l = %s4(%d + i * %d); light += l.w * %s(length(q - l.xy) / max(l.z, 1e-6));",
			get,
			offset,
			GLOW_STRIDE,
			FALLOFF_FUNCTION[GlowFalloff(n.count[0])],
		)
		emit_shape_loop(g, sb, n, args[0], args[2], args[3], n.args[1].count[0] / GLOW_STRIDE, "float light = 0.0;", shape, n.args[4])
		body = "light"
	case .Shatter:
		emit_shatter(sb, n, c)
	case .Sparks:
		body = fmt.tprintf(
			"sparks(p, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %d)",
			args[0],
			args[1],
			args[2],
			args[3],
			args[4],
			args[5],
			args[6],
			args[7],
			args[8],
			args[9],
			n.count[0],
		)
	case .PointLights:
		offset, get := array_offset(g, n.args[5])
		entries := n.args[5].count[0] / LIGHT_STRIDE
		fmt.sbprintf(
			sb,
			"vec3 P = (%s).xyz; vec3 N = (%s).xyz; vec3 V = (%s).xyz; vec3 albedo = (%s).rgb; vec4 m = %s; vec4 sh = %s; float maskf = %s; int mask = int(maskf); " +
			"int count = int(%s); int last = count < 0 ? %d : min(count, %d); vec3 sum = vec3(0.0); " +
			"for (int i = 0; i < last; i++) {{ if (maskf >= 0.0 && ((mask >> i) & 1) == 0) continue; " +
			"vec4 lp = %s4(%d + i * %d); vec4 lc = %s4(%d + i * %d + 4); vec3 l = lp.xyz - P; float d2 = dot(l, l); vec3 ln = l * inversesqrt(d2); " +
			"float x = d2 / (lp.w * lp.w); float w = clamp(1.0 - x * x, 0.0, 1.0); float fall = w * w / (d2 + 1.0) * (i < 4 ? sh[min(i, 3)] : 1.0); " +
			"float ndl = dot(N, ln); if (ndl <= 0.0 || fall <= 0.0) continue; " +
			"float spec = m.x * pow(max(dot(N, normalize(ln + V)), 0.0), m.y); sum += (albedo + spec) * ndl * fall * lc.rgb * lc.w; }} ",
			args[0],
			args[1],
			args[2],
			args[3],
			args[4],
			args[7],
			args[8],
			args[6],
			entries,
			entries,
			get,
			offset,
			LIGHT_STRIDE,
			get,
			offset,
			LIGHT_STRIDE,
		)
		body = "vec4(sum, 0.0)"
	case .CapsuleShadows:
		lights, lget := array_offset(g, n.args[1])
		offset, get := array_offset(g, n.args[2])
		// The first four lights' directions and distances, then per capsule a quick test of its
		// bounding sphere (grown by the penumbra) against each light's ray before the real one
		init := fmt.tprintf(
			"vec3 P = (%s).xyz; float size = %s; vec4 vis = vec4(1.0); vec3 L[4]; float D[4]; " +
			"for (int j = 0; j < 4; j++) {{ vec3 l = %s4(%d + min(j, %d) * %d).xyz - P; D[j] = max(length(l), 1e-6); L[j] = l / D[j]; }}",
			args[0],
			args[5],
			lget,
			lights,
			n.args[1].count[0] / LIGHT_STRIDE - 1,
			LIGHT_STRIDE,
		)
		shape := fmt.tprintf(
			"vec4 s0 = %s4(%d + i * %d); vec4 s1 = %s4(%d + i * %d + 4); vec3 cm = 0.5 * (s0.xyz + s1.xyz); float reach = s0.w + 0.5 * length(s1.xyz - s0.xyz); " +
			"vec3 to = cm - P; float to2 = dot(to, to); " +
			"for (int j = 0; j < 4; j++) {{ float tc = dot(to, L[j]); if (tc < -reach || tc > D[j] + reach) continue; " +
			"float r2 = reach + size * max(tc, 0.0) / D[j]; if (to2 - tc * tc > r2 * r2) continue; " +
			"vis[j] *= capsule_light(P, L[j], D[j], s0.xyz, s1.xyz, s0.w, size); }}",
			get,
			offset,
			CAPSULE3_STRIDE,
			get,
			offset,
			CAPSULE3_STRIDE,
		)
		bins: ^Node = n.args[7] if n.nargs > 7 else nil
		emit_shape_loop(g, sb, n, args[6], args[3], args[4], n.args[2].count[0] / CAPSULE3_STRIDE, init, shape, bins)
		body = "vis"
	case .CapsuleOcclusion:
		offset, get := array_offset(g, n.args[2])
		init := fmt.tprintf("vec3 P = (%s).xyz; vec3 N = (%s).xyz; float sky = 1.0;", args[0], args[1])
		shape := fmt.tprintf(
			"vec4 s0 = %s4(%d + i * %d); vec4 s1 = %s4(%d + i * %d + 4); vec3 ba = s1.xyz - s0.xyz; " +
			"vec3 to = s0.xyz + ba * clamp(dot(P - s0.xyz, ba) / max(dot(ba, ba), 1e-12), 0.0, 1.0) - P; float d2 = dot(to, to); " +
			"if (d2 > 36.0 * s0.w * s0.w) continue; sky *= 1.0 - clamp(max(dot(N, to), 0.0) * inversesqrt(d2) * s0.w * s0.w / d2, 0.0, 1.0);",
			get,
			offset,
			CAPSULE3_STRIDE,
			get,
			offset,
			CAPSULE3_STRIDE,
		)
		bins: ^Node = n.args[6] if n.nargs > 6 else nil
		emit_shape_loop(g, sb, n, args[5], args[3], args[4], n.args[2].count[0] / CAPSULE3_STRIDE, init, shape, bins)
		body = "sky"
	case .HazeLights:
		offset, get := array_offset(g, n.args[3])
		entries := n.args[3].count[0] / LIGHT_STRIDE
		fmt.sbprintf(
			sb,
			"vec3 O = (%s).xyz; vec3 dir = (%s).xyz; float far = %s; float core = %s; int count = int(%s); int last = count < 0 ? %d : min(count, %d); vec3 sum = vec3(0.0); " +
			"for (int i = 0; i < last; i++) {{ vec4 lp = %s4(%d + i * %d); vec4 lc = %s4(%d + i * %d + 4); sum += lc.rgb * lc.w * light_haze(O, dir, far, lp.xyz, core); }} ",
			args[0],
			args[1],
			args[2],
			args[5],
			args[4],
			entries,
			entries,
			get,
			offset,
			LIGHT_STRIDE,
			get,
			offset,
			LIGHT_STRIDE,
		)
		body = "vec4(sum, 0.0)"
	case .MarchSolid:
		body = fmt.tprintf("march_solid(int(%s), (%s).xyz, (%s).xyz, %s, %s, %s, %d)", args[0], args[1], args[2], args[3], args[4], args[5], n.count[0])
	case .SolidNormal:
		body = fmt.tprintf("vec4(solid_normal(int(%s), (%s).xyz, %s), 0.0)", args[0], args[1], args[2])
	}
	return
}

// First slot of a param_array or data_array, and the GLSL function that reads its values by
// index (pget: the instance record, dget: the data texture), as walk assigned it.
@(private)
array_offset :: proc(g: ^Gen, n: ^Node) -> (offset: int, get: string) {
	return array_slot(g.w, n), "dget" if n.count[1] != 0 else "pget"
}

// Emits `init`, then `body` (which reads the position q and the shape index i) for the
// shapes first ..< first + count of an array of `entries` shapes (count < 0: all the rest).
// With `bins` (a data_array, see engine.bin_shapes; nil = none) only the shapes listed in the grid cell under q
// are visited: the lists are ascending, so a binary search finds `first` and the loop stops
// at `last`.
@(private)
emit_shape_loop :: proc(g: ^Gen, sb: ^strings.Builder, n: ^Node, p, first, count: string, entries: int, init, body: string, bins: ^Node) {
	fmt.sbprintf(
		sb,
		"vec2 q = %s; int first = max(int(%s), 0); int count = int(%s); int last = count < 0 ? %d : min(first + count, %d); %s ",
		p,
		first,
		count,
		entries,
		entries,
		init,
	)
	if bins == nil {
		fmt.sbprintf(sb, "for (int i = first; i < last; i++) {{ %s }} ", body)
		return
	}
	at, _ := array_offset(g, bins)
	fmt.sbprintf(
		sb,
		"vec4 bh = dget4(%d); vec4 bh2 = dget4(%d); ivec2 cell = ivec2(floor((q - bh.xy) / bh.z)); " +
		"if (cell.x >= 0 && cell.y >= 0 && cell.x < int(bh.w) && cell.y < int(bh2.x)) {{ " +
		"int ci = %d + 8 + 2 * (cell.y * int(bh.w) + cell.x); int at = %d + int(bh2.y) + int(dget(ci)); int end = at + int(dget(ci + 1)); " +
		"int hi = end; while (at < hi) {{ int mid = (at + hi) >> 1; if (int(dget(mid)) < first) at = mid + 1; else hi = mid; }} " +
		"for (; at < end; at++) {{ int i = int(dget(at)); if (i >= last) break; %s }} }} ",
		at,
		at + 4,
		at,
		at,
		body,
	)
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
