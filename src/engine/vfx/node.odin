// Package vfx describes visuals as trees of composable mathematical functions.
//
// A "look" is an expression tree built from the constructors in this file. Every node is
// a pure function of the local coordinate `p` (object space, centered, in virtual units,
// y pointing down). The tree is compiled into a GLSL fragment shader by `compile`; every
// numeric leaf becomes a uniform slot, so looks that share a structure share a shader and
// differ only in their parameter values (seeds, colors, densities...).
//
// Trees are transient: nodes are allocated with context.temp_allocator and only live until
// the engine has compiled them into a material.
package vfx

import "base:builtin"
import rl "vendor:raylib"

Type :: enum u8 {
	Float,
	Vec2,
	Vec4,
}

Op :: enum u8 {
	// Leaves
	Const,
	Param,
	Coord,
	World,
	Uv,
	Size,
	Time,
	Age,
	Px,
	// Arithmetic
	Add,
	Sub,
	Mul,
	Div,
	Min,
	Max,
	Mix,
	Smoothstep,
	Step,
	Saturate,
	Abs,
	Neg,
	Sin,
	Cos,
	Exp,
	Pow,
	Floor,
	Fract,
	Length,
	Dot,
	Swizzle,
	MakeVec2,
	MakeRgba,
	// Coordinates
	Rotate,
	Tile,
	CellId,
	BrickLocal,
	BrickId,
	At,
	// Patterns
	Hash,
	Noise,
	Fbm,
	Voronoi,
	VoronoiEdge,
	// Shapes
	SdBox,
	SdCircle,
	SdSegment,
	Fill,
	Stroke,
	Glow,
	// Color
	Palette,
	Over,
	Shade,
	Mask,
	Lit,
	// Effects
	Shatter,
	Sparks,
}

MAX_ARGS :: 10

Node :: struct {
	op:    Op,
	type:  Type,
	args:  [MAX_ARGS]^Node,
	nargs: int,
	value: [4]f32, // Const value / Param default
	name:  string, // Param name, Swizzle mask
	count: [2]int, // compile-time integers: octaves, shard grid, particle count
}

// Anything that can stand in for a node: plain numbers, vectors and colors become
// parameter slots.
Expr :: union {
	f32,
	[2]f32,
	[4]f32,
	rl.Color,
	^Node,
}

@(private)
new_node :: proc(op: Op, type: Type, args: ..Expr) -> ^Node {
	assert(len(args) <= MAX_ARGS)
	n := new(Node, context.temp_allocator)
	n.op = op
	n.type = type
	n.nargs = len(args)
	for a, i in args {
		n.args[i] = to_node(a)
	}
	return n
}

to_node :: proc(e: Expr) -> ^Node {
	n: ^Node
	switch v in e {
	case ^Node:
		return v
	case f32:
		n = new(Node, context.temp_allocator)
		n.type = .Float
		n.value = {v, 0, 0, 0}
	case [2]f32:
		n = new(Node, context.temp_allocator)
		n.type = .Vec2
		n.value = {v.x, v.y, 0, 0}
	case [4]f32:
		n = new(Node, context.temp_allocator)
		n.type = .Vec4
		n.value = v
	case rl.Color:
		n = new(Node, context.temp_allocator)
		n.type = .Vec4
		n.value = {f32(v.r), f32(v.g), f32(v.b), f32(v.a)} / 255
	case:
		panic("vfx: nil expression")
	}
	n.op = .Const
	return n
}

@(private)
type_of_expr :: proc(e: Expr) -> Type {
	return to_node(e).type
}

// Result type of a component-wise binary op: scalars broadcast to the other operand.
@(private)
wider :: proc(a, b: Type) -> Type {
	if a == .Float {return b}
	if b == .Float {return a}
	assert(a == b, "vfx: cannot combine vec2 and vec4")
	return a
}

@(private)
binary :: proc(op: Op, a, b: Expr) -> ^Node {
	na, nb := to_node(a), to_node(b)
	return new_node(op, wider(na.type, nb.type), na, nb)
}

@(private)
unary :: proc(op: Op, a: Expr) -> ^Node {
	na := to_node(a)
	return new_node(op, na.type, na)
}

@(private)
or_else_expr :: proc(e: Expr, default: Expr) -> Expr {
	return e if e != nil else default
}

// ---------------------------------------------------------------------------------------
// Inputs

// Local coordinate: object space, origin at the object's center, virtual units.
coord :: proc() -> ^Node {return new_node(.Coord, .Vec2)}
// World coordinate in virtual units; use it for patterns that must line up across objects.
world :: proc() -> ^Node {return new_node(.World, .Vec2)}
// Normalized coordinate: (0,0) top-left .. (1,1) bottom-right of the object's logical size.
uv :: proc() -> ^Node {return new_node(.Uv, .Vec2)}
// Logical size of the object (without padding).
size :: proc() -> ^Node {return new_node(.Size, .Vec2)}
// Scene time in seconds.
time :: proc() -> ^Node {return new_node(.Time, .Float)}
// Seconds since the object was spawned.
age :: proc() -> ^Node {return new_node(.Age, .Float)}
// Size of one screen pixel in virtual units (for custom anti-aliasing).
px :: proc() -> ^Node {return new_node(.Px, .Float)}

// A named parameter that game code can change at runtime with engine.set_param.
// Parameters with the same name share a slot.
param :: proc(name: string, default: Expr) -> ^Node {
	d := to_node(default)
	assert(d.op == .Const, "vfx: param default must be a constant")
	n := new_node(.Param, d.type)
	n.value = d.value
	n.name = name
	return n
}

// ---------------------------------------------------------------------------------------
// Arithmetic (component-wise, scalars broadcast)

add :: proc(a, b: Expr) -> ^Node {return binary(.Add, a, b)}
sub :: proc(a, b: Expr) -> ^Node {return binary(.Sub, a, b)}
mul :: proc(a, b: Expr) -> ^Node {return binary(.Mul, a, b)}
div :: proc(a, b: Expr) -> ^Node {return binary(.Div, a, b)}
min :: proc(a, b: Expr) -> ^Node {return binary(.Min, a, b)}
max :: proc(a, b: Expr) -> ^Node {return binary(.Max, a, b)}
pow :: proc(a, b: Expr) -> ^Node {return new_node(.Pow, type_of_expr(a), a, b)}

// Sum of any number of operands.
sum :: proc(terms: ..Expr) -> ^Node {
	assert(len(terms) > 0)
	acc := to_node(terms[0])
	for t in terms[1:] {
		acc = add(acc, t)
	}
	return acc
}

mix :: proc(a, b, t: Expr) -> ^Node {
	na, nb := to_node(a), to_node(b)
	return new_node(.Mix, wider(na.type, nb.type), na, nb, t)
}
smoothstep :: proc(e0, e1, x: Expr) -> ^Node {return new_node(.Smoothstep, type_of_expr(x), e0, e1, x)}
step :: proc(edge, x: Expr) -> ^Node {return new_node(.Step, type_of_expr(x), edge, x)}
saturate :: proc(a: Expr) -> ^Node {return unary(.Saturate, a)}
abs :: proc(a: Expr) -> ^Node {return unary(.Abs, a)}
neg :: proc(a: Expr) -> ^Node {return unary(.Neg, a)}
sin :: proc(a: Expr) -> ^Node {return unary(.Sin, a)}
cos :: proc(a: Expr) -> ^Node {return unary(.Cos, a)}
exp :: proc(a: Expr) -> ^Node {return unary(.Exp, a)}
floor :: proc(a: Expr) -> ^Node {return unary(.Floor, a)}
fract :: proc(a: Expr) -> ^Node {return unary(.Fract, a)}
length :: proc(a: Expr) -> ^Node {return new_node(.Length, .Float, a)}
dot :: proc(a, b: Expr) -> ^Node {return new_node(.Dot, .Float, a, b)}

// GLSL-style component selection: swizzle(v, "y"), swizzle(c, "a"), swizzle(v, "yx").
swizzle :: proc(v: Expr, mask: string) -> ^Node {
	types := [?]Type{.Float, .Vec2, .Vec4, .Vec4}
	assert(len(mask) == 1 || len(mask) == 2 || len(mask) == 4, "vfx: swizzle to 1, 2 or 4 components")
	n := new_node(.Swizzle, types[len(mask) - 1], v)
	n.name = mask
	return n
}

vec2 :: proc(x, y: Expr) -> ^Node {return new_node(.MakeVec2, .Vec2, x, y)}
rgba :: proc(r, g, b: Expr, a: Expr = f32(1)) -> ^Node {return new_node(.MakeRgba, .Vec4, r, g, b, a)}

// ---------------------------------------------------------------------------------------
// Coordinates

// Rotates a vector by `angle` radians (clockwise on screen).
rotate :: proc(v, angle: Expr) -> ^Node {return new_node(.Rotate, .Vec2, v, angle)}
// Infinite grid repetition: coordinates local to the cell, centered.
tile :: proc(p, cell: Expr) -> ^Node {return new_node(.Tile, .Vec2, p, cell)}
// Integer id of the grid cell containing `p`.
cell_id :: proc(p, cell: Expr) -> ^Node {return new_node(.CellId, .Vec2, p, cell)}
// Running-bond (brick wall) layout: every other row is shifted by `shift` cells.
brick_local :: proc(p, cell: Expr, shift: Expr = f32(0.5)) -> ^Node {return new_node(.BrickLocal, .Vec2, p, cell, shift)}
brick_id :: proc(p, cell: Expr, shift: Expr = f32(0.5)) -> ^Node {return new_node(.BrickId, .Vec2, p, cell, shift)}

// Evaluates `e` with its local coordinate replaced by `p` (domain transform). Every
// coord()/world()/uv() inside `e` sees the transformed position.
at :: proc(e, p: Expr) -> ^Node {
	ne := to_node(e)
	return new_node(.At, ne.type, ne, p)
}

// ---------------------------------------------------------------------------------------
// Patterns (all return values in [0, 1] unless noted)

// Pseudo-random value from a float or vec2 seed.
hash :: proc(v: Expr) -> ^Node {return new_node(.Hash, .Float, v)}
// Smooth value noise, one feature per unit.
noise :: proc(p: Expr) -> ^Node {return new_node(.Noise, .Float, p)}
// Fractal Brownian motion: `octaves` layers of noise, each `lacunarity` times denser
// and `gain` times weaker than the previous one.
fbm :: proc(p: Expr, octaves := 5, lacunarity: Expr = f32(2), gain: Expr = f32(0.5)) -> ^Node {
	n := new_node(.Fbm, .Float, p, lacunarity, gain)
	n.count = {octaves, 0}
	return n
}
// Cellular noise: distance to the nearest feature point (cells are one unit wide).
voronoi :: proc(p: Expr) -> ^Node {return new_node(.Voronoi, .Float, p)}
// Distance to the nearest cell border of the cellular pattern.
voronoi_edge :: proc(p: Expr) -> ^Node {return new_node(.VoronoiEdge, .Float, p)}

// ---------------------------------------------------------------------------------------
// Shapes: signed distance fields (negative inside) and their coverage

sd_box :: proc(p, half_size: Expr, radius: Expr = f32(0)) -> ^Node {return new_node(.SdBox, .Float, p, half_size, radius)}
sd_circle :: proc(p, radius: Expr) -> ^Node {return new_node(.SdCircle, .Float, p, radius)}
sd_segment :: proc(p, a, b: Expr) -> ^Node {return new_node(.SdSegment, .Float, p, a, b)}
// Anti-aliased coverage of the inside of a distance field.
fill :: proc(d: Expr) -> ^Node {return new_node(.Fill, .Float, d)}
// Anti-aliased coverage of a band of `width` around the zero contour.
stroke :: proc(d, width: Expr) -> ^Node {return new_node(.Stroke, .Float, d, width)}
// Exponential falloff outside the shape, 1 inside.
glow :: proc(d, radius: Expr) -> ^Node {return new_node(.Glow, .Float, d, radius)}

// ---------------------------------------------------------------------------------------
// Color

// Cosine palette: a + b * cos(2π(c·t + d)), see iquilezles.org/articles/palettes.
palette :: proc(t, a, b, c, d: Expr) -> ^Node {return new_node(.Palette, .Vec4, t, a, b, c, d)}
gradient :: proc(t, from, to: Expr) -> ^Node {return mix(from, to, t)}
// Alpha-composites `top` over `bottom`.
over :: proc(top, bottom: Expr) -> ^Node {return new_node(.Over, .Vec4, top, bottom)}
// Composites layers in painter's order: the first layer is at the bottom.
stack :: proc(layers: ..Expr) -> ^Node {
	assert(len(layers) > 0)
	acc := to_node(layers[0])
	for l in layers[1:] {
		acc = over(l, acc)
	}
	return acc
}
// Multiplies the color channels, keeping alpha.
shade :: proc(color, k: Expr) -> ^Node {return new_node(.Shade, .Vec4, color, k)}
// Multiplies alpha by a coverage value.
mask :: proc(color, coverage: Expr) -> ^Node {return new_node(.Mask, .Vec4, color, coverage)}

Light :: struct {
	strength: Expr, // how strongly height changes bend the surface normal
	specular: Expr, // intensity of the highlight
	shininess: Expr, // highlight exponent
	direction: Expr, // vec2 pointing towards the light, in screen space
	step:     Expr, // finite difference distance in virtual units
}

// Lights `color` as if it were a surface whose relief is given by `height`.
lit :: proc(color, height: Expr, light := Light{}) -> ^Node {
	return new_node(
		.Lit,
		.Vec4,
		color,
		height,
		or_else_expr(light.strength, f32(1)),
		or_else_expr(light.specular, f32(0)),
		or_else_expr(light.shininess, f32(24)),
		or_else_expr(light.direction, [2]f32{-0.6, -0.8}),
		or_else_expr(light.step, f32(1)),
	)
}

// ---------------------------------------------------------------------------------------
// Effects

Shatter :: struct {
	progress: Expr, // seconds since the break, usually age()
	impact:   Expr, // vec2, point (object space) the shards fly away from
	seed:     Expr,
	speed:    Expr, // initial shard speed, units/s
	gravity:  Expr, // units/s²
	spin:     Expr, // max angular velocity, rad/s
	cols:     int,
	rows:     int,
}

// Breaks `child` into a grid of jittered Voronoi shards that fly apart over time. The object
// needs enough padding for the shards to travel into.
shatter :: proc(child: Expr, o: Shatter) -> ^Node {
	n := new_node(
		.Shatter,
		.Vec4,
		child,
		or_else_expr(o.progress, age()),
		or_else_expr(o.impact, [2]f32{0, 0}),
		or_else_expr(o.seed, f32(0)),
		or_else_expr(o.speed, f32(220)),
		or_else_expr(o.gravity, f32(600)),
		or_else_expr(o.spin, f32(8)),
	)
	n.count = {builtin.max(o.cols, 1), builtin.max(o.rows, 1)}
	return n
}

Sparks :: struct {
	progress:  Expr, // seconds since emission, usually age()
	origin:    Expr, // vec2 emission point (object space)
	direction: Expr, // mean emission angle in radians (0 = right, -π/2 = up)
	spread:    Expr, // half-angle of the emission cone in radians (π = all around)
	speed:     Expr, // max initial speed, units/s
	gravity:   Expr, // units/s²
	radius:    Expr, // spark thickness
	life:      Expr, // max spark lifetime in seconds
	seed:      Expr,
	color:     Expr,
	count:     int,
}

// A burst of glowing streaks following ballistic trajectories.
sparks :: proc(o: Sparks) -> ^Node {
	n := new_node(
		.Sparks,
		.Vec4,
		or_else_expr(o.progress, age()),
		or_else_expr(o.origin, [2]f32{0, 0}),
		or_else_expr(o.direction, f32(-1.5707963)),
		or_else_expr(o.spread, f32(3.1415926)),
		or_else_expr(o.speed, f32(300)),
		or_else_expr(o.gravity, f32(500)),
		or_else_expr(o.radius, f32(1.5)),
		or_else_expr(o.life, f32(0.8)),
		or_else_expr(o.seed, f32(0)),
		or_else_expr(o.color, [4]f32{1, 0.7, 0.3, 1}),
	)
	n.count = {builtin.max(o.count, 1), 0}
	return n
}
