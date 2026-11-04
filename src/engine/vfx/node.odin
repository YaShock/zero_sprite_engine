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
import "base:runtime"
import "core:math"
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
	Sqrt,
	Asin,
	Pow,
	Floor,
	Fract,
	Length,
	Dot,
	Angle,
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
	LitScene,
	// Effects
	Shatter,
	Sparks,
	// Lists of values set by game code
	ParamArray,
	Curve,
	SdCapsules,
	GlowPoints,
	Metaballs,
	IntFbm,
	Gate,
	Instance,
	Falloff,
	SdCapsuleGroups,
	LayerSample,
	InstanceOf,
	InstanceIndex,
	Instanced,
	// 3D: positions and directions as vec4s whose w is 0
	PointLights,
	CapsuleShadows,
	CapsuleOcclusion,
	HazeLights,
	MarchSolid,
	SolidNormal,
}

MAX_ARGS :: 10

Node :: struct {
	op:    Op,
	type:  Type,
	args:  [MAX_ARGS]^Node,
	nargs: int,
	value: [4]f32, // Const value / Param default
	name:  string, // Param name, Swizzle mask
	count:  [2]int, // compile-time integers: octaves, shard grid, particle count
	origin: string, // procedure that built this node, e.g. the look function for a root
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

// Tags a node with the procedure that called the constructor that made it, so a look's
// root node names the function that built the look.
@(private)
origin :: proc(n: ^Node, loc: runtime.Source_Code_Location) -> ^Node {
	n.origin = loc.procedure
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
coord :: proc(loc := #caller_location) -> ^Node {return origin(new_node(.Coord, .Vec2), loc)}
// World coordinate in virtual units; use it for patterns that must line up across objects.
world :: proc(loc := #caller_location) -> ^Node {return origin(new_node(.World, .Vec2), loc)}
// Normalized coordinate: (0,0) top-left .. (1,1) bottom-right of the object's logical size.
uv :: proc(loc := #caller_location) -> ^Node {return origin(new_node(.Uv, .Vec2), loc)}
// Logical size of the object (without padding).
size :: proc(loc := #caller_location) -> ^Node {return origin(new_node(.Size, .Vec2), loc)}
// Scene time in seconds.
time :: proc(loc := #caller_location) -> ^Node {return origin(new_node(.Time, .Float), loc)}
// Seconds since the object was spawned.
age :: proc(loc := #caller_location) -> ^Node {return origin(new_node(.Age, .Float), loc)}
// Size of one screen pixel in virtual units (for custom anti-aliasing).
px :: proc(loc := #caller_location) -> ^Node {return origin(new_node(.Px, .Float), loc)}

// A named parameter that game code can change at runtime with engine.set_param.
// Parameters with the same name share a slot.
param :: proc(name: string, default: Expr, loc := #caller_location) -> ^Node {
	d := to_node(default)
	assert(d.op == .Const, "vfx: param default must be a constant")
	n := new_node(.Param, d.type)
	n.value = d.value
	n.name = name
	return origin(n, loc)
}

// A named list of `count` numbers that game code replaces at once with
// engine.set_param_array, e.g. sampled positions updated every frame. It is not a value
// on its own: nodes such as curve and sd_capsules read it. Arrays with the same name share
// their slots. They take uniform space (4 numbers per register), so keep them to a few
// hundred numbers per look.
param_array :: proc(name: string, count: int, loc := #caller_location) -> ^Node {
	assert(count > 0, "vfx: param_array needs at least one value")
	n := new_node(.ParamArray, .Float)
	n.name = name
	n.count = {count, 0}
	return origin(n, loc)
}

// Like param_array, for long lists (thousands of values): kept in a float texture that the
// entity owns and uploads when it changes, instead of in uniforms. Reading a value costs a
// texture fetch instead of a register read.
data_array :: proc(name: string, count: int, loc := #caller_location) -> ^Node {
	assert(count > 0, "vfx: data_array needs at least one value")
	n := new_node(.ParamArray, .Float)
	n.name = name
	n.count = {count, 1}
	return origin(n, loc)
}

// The records of an instanced look: the entity draws one quad per record in a single draw
// call (eng.set_instances sets the records and how many there are). A record is `stride`
// values (a multiple of 4, at most `max_count` records); its first INSTANCE_QUAD values are
// the quad: center x, y and half width, height in the entity's frame (its virtual units
// around its position, turned with it); the rest is the look's, read with instance() and
// instance4(). In an instanced look coord() is the position from the instance's center and
// world() the world position; size() and uv() stay the entity's. A look is instanced when
// it reads instance values, from one records array. Kept in the data texture, like a
// data_array.
instances :: proc(name: string, stride, max_count: int, loc := #caller_location) -> ^Node {
	assert(stride >= INSTANCE_QUAD && stride % 4 == 0, "vfx: an instance record is a multiple of 4 values, starting with its quad")
	assert(max_count > 0, "vfx: instances needs at least one record")
	n := new_node(.ParamArray, .Float)
	n.name = name
	n.count = {stride * max_count, INSTANCE_ARRAY}
	n.value[0] = f32(stride)
	return origin(n, loc)
}

// Values at the start of an instance record that place its quad: center x, y, half width,
// half height.
INSTANCE_QUAD :: 4

// count[1] of an instances array (a data_array has 1): in the data texture, as records of
// value[0] values each
@(private)
INSTANCE_ARRAY :: 2

// Value k of this pixel's instance record
instance :: proc(records: ^Node, k: int, loc := #caller_location) -> ^Node {
	assert(records.op == .ParamArray && records.count[1] == INSTANCE_ARRAY, "vfx: instance reads an instances array")
	assert(k >= 0 && k < int(records.value[0]), "vfx: instance value outside the record")
	n := new_node(.Instance, .Float, records)
	n.count = {k, 0}
	return origin(n, loc)
}

// Values k ..< k + 4 of this pixel's instance record (k a multiple of 4)
instance4 :: proc(records: ^Node, k: int, loc := #caller_location) -> ^Node {
	assert(records.op == .ParamArray && records.count[1] == INSTANCE_ARRAY, "vfx: instance4 reads an instances array")
	assert(k >= 0 && k % 4 == 0 && k + 4 <= int(records.value[0]), "vfx: instance4 reads an aligned group of four of the record")
	n := new_node(.Instance, .Vec4, records)
	n.count = {k, 0}
	return origin(n, loc)
}

// Values k ..< k + 4 of another record of the instances array: number `index` (0-based; a
// float rounded down), so an instance can look at its neighbors (e.g. which of two
// overlapping shapes draws a pixel)
instance4_of :: proc(records: ^Node, index: Expr, k: int, loc := #caller_location) -> ^Node {
	assert(records.op == .ParamArray && records.count[1] == INSTANCE_ARRAY, "vfx: instance4_of reads an instances array")
	assert(k >= 0 && k % 4 == 0 && k + 4 <= int(records.value[0]), "vfx: instance4_of reads an aligned group of four of the record")
	n := new_node(.InstanceOf, .Vec4, records, index)
	n.count = {k, 0}
	return origin(n, loc)
}

// The number of this pixel's instance record (0 for the first), as a float
instance_index :: proc(loc := #caller_location) -> ^Node {
	return origin(new_node(.InstanceIndex, .Float), loc)
}

// `look`, drawn once per record of `records`, for looks that need nothing from a record but
// its quad (e.g. one big shape cut into pieces that each cover only what it needs)
instanced :: proc(look: Expr, records: ^Node, loc := #caller_location) -> ^Node {
	assert(records.op == .ParamArray && records.count[1] == INSTANCE_ARRAY, "vfx: instanced draws the records of an instances array")
	l := to_node(look)
	return origin(new_node(.Instanced, l.type, l, records), loc)
}

// ---------------------------------------------------------------------------------------
// Arithmetic (component-wise, scalars broadcast)

add :: proc(a, b: Expr, loc := #caller_location) -> ^Node {return origin(binary(.Add, a, b), loc)}
sub :: proc(a, b: Expr, loc := #caller_location) -> ^Node {return origin(binary(.Sub, a, b), loc)}
mul :: proc(a, b: Expr, loc := #caller_location) -> ^Node {return origin(binary(.Mul, a, b), loc)}
div :: proc(a, b: Expr, loc := #caller_location) -> ^Node {return origin(binary(.Div, a, b), loc)}
min :: proc(a, b: Expr, loc := #caller_location) -> ^Node {return origin(binary(.Min, a, b), loc)}
max :: proc(a, b: Expr, loc := #caller_location) -> ^Node {return origin(binary(.Max, a, b), loc)}
pow :: proc(a, b: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Pow, type_of_expr(a), a, b), loc)}

// Sum of any number of operands.
sum :: proc(terms: ..Expr, loc := #caller_location) -> ^Node {
	assert(len(terms) > 0)
	acc := to_node(terms[0])
	for t in terms[1:] {
		acc = add(acc, t)
	}
	return origin(acc, loc)
}

mix :: proc(a, b, t: Expr, loc := #caller_location) -> ^Node {
	na, nb := to_node(a), to_node(b)
	return origin(new_node(.Mix, wider(na.type, nb.type), na, nb, t), loc)
}
smoothstep :: proc(e0, e1, x: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Smoothstep, type_of_expr(x), e0, e1, x), loc)}
step :: proc(edge, x: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Step, type_of_expr(x), edge, x), loc)}
saturate :: proc(a: Expr, loc := #caller_location) -> ^Node {return origin(unary(.Saturate, a), loc)}
abs :: proc(a: Expr, loc := #caller_location) -> ^Node {return origin(unary(.Abs, a), loc)}
neg :: proc(a: Expr, loc := #caller_location) -> ^Node {return origin(unary(.Neg, a), loc)}
sin :: proc(a: Expr, loc := #caller_location) -> ^Node {return origin(unary(.Sin, a), loc)}
cos :: proc(a: Expr, loc := #caller_location) -> ^Node {return origin(unary(.Cos, a), loc)}
exp :: proc(a: Expr, loc := #caller_location) -> ^Node {return origin(unary(.Exp, a), loc)}
// Square root of max(a, 0).
sqrt :: proc(a: Expr, loc := #caller_location) -> ^Node {return origin(unary(.Sqrt, a), loc)}
// Arc sine of a clamped to [-1, 1].
asin :: proc(a: Expr, loc := #caller_location) -> ^Node {return origin(unary(.Asin, a), loc)}
floor :: proc(a: Expr, loc := #caller_location) -> ^Node {return origin(unary(.Floor, a), loc)}
fract :: proc(a: Expr, loc := #caller_location) -> ^Node {return origin(unary(.Fract, a), loc)}
length :: proc(a: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Length, .Float, a), loc)}
dot :: proc(a, b: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Dot, .Float, a, b), loc)}
// Polar angle of a vector in radians, in [-π, π] (0 = right, π/2 = down).
angle :: proc(v: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Angle, .Float, v), loc)}

// GLSL-style component selection: swizzle(v, "y"), swizzle(c, "a"), swizzle(v, "yx").
swizzle :: proc(v: Expr, mask: string, loc := #caller_location) -> ^Node {
	types := [?]Type{.Float, .Vec2, .Vec4, .Vec4}
	assert(len(mask) == 1 || len(mask) == 2 || len(mask) == 4, "vfx: swizzle to 1, 2 or 4 components")
	n := new_node(.Swizzle, types[len(mask) - 1], v)
	n.name = mask
	return origin(n, loc)
}

vec2 :: proc(x, y: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.MakeVec2, .Vec2, x, y), loc)}
rgba :: proc(r, g, b: Expr, a: Expr = f32(1), loc := #caller_location) -> ^Node {return origin(new_node(.MakeRgba, .Vec4, r, g, b, a), loc)}

// ---------------------------------------------------------------------------------------
// Coordinates

// Rotates a vector by `angle` radians (clockwise on screen).
rotate :: proc(v, angle: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Rotate, .Vec2, v, angle), loc)}
// Infinite grid repetition: coordinates local to the cell, centered.
tile :: proc(p, cell: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Tile, .Vec2, p, cell), loc)}
// Integer id of the grid cell containing `p`.
cell_id :: proc(p, cell: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.CellId, .Vec2, p, cell), loc)}
// Running-bond (brick wall) layout: every other row is shifted by `shift` cells.
brick_local :: proc(p, cell: Expr, shift: Expr = f32(0.5), loc := #caller_location) -> ^Node {return origin(new_node(.BrickLocal, .Vec2, p, cell, shift), loc)}
brick_id :: proc(p, cell: Expr, shift: Expr = f32(0.5), loc := #caller_location) -> ^Node {return origin(new_node(.BrickId, .Vec2, p, cell, shift), loc)}

// Evaluates `e` with its local coordinate replaced by `p` (domain transform). Every
// coord()/world()/uv() inside `e` sees the transformed position.
at :: proc(e, p: Expr, loc := #caller_location) -> ^Node {
	ne := to_node(e)
	return origin(new_node(.At, ne.type, ne, p), loc)
}

// ---------------------------------------------------------------------------------------
// Patterns (all return values in [0, 1] unless noted)

// Pseudo-random value from a float or vec2 seed.
hash :: proc(v: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Hash, .Float, v), loc)}
// Smooth value noise, one feature per unit.
noise :: proc(p: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Noise, .Float, p), loc)}
// Fractal Brownian motion: `octaves` layers of noise, each `lacunarity` times denser
// and `gain` times weaker than the previous one.
fbm :: proc(p: Expr, octaves := 5, lacunarity: Expr = f32(2), gain: Expr = f32(0.5), loc := #caller_location) -> ^Node {
	n := new_node(.Fbm, .Float, p, lacunarity, gain)
	n.count = {octaves, 0}
	return origin(n, loc)
}
// Cellular noise: distance to the nearest feature point (cells are one unit wide).
voronoi :: proc(p: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Voronoi, .Float, p), loc)}
// Distance to the nearest cell border of the cellular pattern.
voronoi_edge :: proc(p: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.VoronoiEdge, .Float, p), loc)}

// ---------------------------------------------------------------------------------------
// Shapes: signed distance fields (negative inside) and their coverage

sd_box :: proc(p, half_size: Expr, radius: Expr = f32(0), loc := #caller_location) -> ^Node {return origin(new_node(.SdBox, .Float, p, half_size, radius), loc)}
sd_circle :: proc(p, radius: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.SdCircle, .Float, p, radius), loc)}
sd_segment :: proc(p, a, b: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.SdSegment, .Float, p, a, b), loc)}
// Signed distance to a convex polygon, as the largest distance to any of its edge lines
// (exact inside, slightly rounded-off outside the corners). Vertices may wind either way.
sd_convex_polygon :: proc(p: Expr, points: [][2]f32, loc := #caller_location) -> ^Node {
	assert(len(points) >= 3)
	centroid: [2]f32
	for v in points {
		centroid += v / f32(len(points))
	}
	pn := to_node(p)
	d: ^Node
	for a, i in points {
		b := points[(i + 1) % len(points)]
		edge := b - a
		normal := [2]f32{edge.y, -edge.x} / math.sqrt(edge.x * edge.x + edge.y * edge.y)
		if (centroid.x - a.x) * normal.x + (centroid.y - a.y) * normal.y > 0 {
			normal = -normal
		}
		side := dot(sub(pn, a), normal)
		d = side if d == nil else max(d, side)
	}
	return origin(d, loc)
}

// Distance to an open polyline: the union of its segments.
sd_polyline :: proc(p: Expr, points: [][2]f32, loc := #caller_location) -> ^Node {
	assert(len(points) >= 2)
	pn := to_node(p)
	d := sd_segment(pn, points[0], points[1])
	for i in 1 ..< len(points) - 1 {
		d = min(d, sd_segment(pn, points[i], points[i + 1]))
	}
	return origin(d, loc)
}
// Linear interpolation through the values of a param_array at the fractional index `t`
// (0 = first value), clamped to the first and last value: a polyline y(x) or any other
// sampled function whose samples game code updates.
curve :: proc(values: ^Node, t: Expr, loc := #caller_location) -> ^Node {
	assert(values.op == .ParamArray && values.count[0] >= 2, "vfx: curve reads a param_array of at least 2 values")
	return origin(new_node(.Curve, .Float, values, t), loc)
}

// Values per capsule in the array read by sd_capsules: ax, ay, bx, by, ra, rb and two
// unused, so that a capsule is two aligned groups of four (two reads in the shader).
CAPSULE_STRIDE :: 8

// Signed distance to the nearest of a list of tapered capsules: segments from a to b whose
// radius goes from ra to rb, CAPSULE_STRIDE values each in an array (param_array or
// data_array). Only capsules first ..< first + count are used, so one array can hold
// several groups (e.g. drawing layers); count < 0 means all the rest. With `bins` (a
// data_array filled by engine.bin_shapes) each pixel visits only the capsules near it,
// which is what makes lists of hundreds of capsules cheap.
sd_capsules :: proc(p: Expr, values: ^Node, first: Expr = f32(0), count: Expr = f32(-1), bins: ^Node = nil, loc := #caller_location) -> ^Node {
	assert(values.op == .ParamArray && values.count[0] % CAPSULE_STRIDE == 0, "vfx: sd_capsules reads an array of CAPSULE_STRIDE values per capsule")
	if bins != nil {
		assert(bins.op == .ParamArray && bins.count[1] != 0, "vfx: bins are a data_array (see engine.bin_shapes)")
		return origin(new_node(.SdCapsules, .Float, p, values, first, count, bins), loc)
	}
	return origin(new_node(.SdCapsules, .Float, p, values, first, count), loc)
}

// Values per light in the array read by glow_points: x, y, radius, strength.
GLOW_STRIDE :: 4

// How a light of glow_points fades from its center (0) to its radius (1)
GlowFalloff :: enum {
	Soft, // a radial gradient through 1, 2/3, 1/5 and 0 at 0, 0.2, 0.5 and 1
	Dot, // brighter core: 1, 0.53 and 0 at 0, 0.25 and 1
	Quadratic, // (1 − r)²
}

// Sum of soft round lights: each is full strength at its center and fades out at its
// radius (see GlowFalloff). Overlapping lights add up. Four values each in an array (see
// GLOW_STRIDE); only lights first ..< first + count are used (count < 0: all the rest).
// `bins` as for sd_capsules.
glow_points :: proc(p: Expr, values: ^Node, first: Expr = f32(0), count: Expr = f32(-1), bins: ^Node = nil, falloff := GlowFalloff.Soft, loc := #caller_location) -> ^Node {
	assert(values.op == .ParamArray && values.count[0] % GLOW_STRIDE == 0, "vfx: glow_points reads an array of 4 values per light")
	n: ^Node
	if bins != nil {
		assert(bins.op == .ParamArray && bins.count[1] != 0, "vfx: bins are a data_array (see engine.bin_shapes)")
		n = new_node(.GlowPoints, .Float, p, values, first, count, bins)
	} else {
		n = new_node(.GlowPoints, .Float, p, values, first, count)
	}
	n.count = {int(falloff), 0}
	return origin(n, loc)
}

// One light's brightness at distance r from its center, in radii (1 at 0, 0 from 1 on), as
// glow_points fades each light; for drawing lights one quad each (instanced looks).
falloff :: proc(r: Expr, kind := GlowFalloff.Soft, loc := #caller_location) -> ^Node {
	n := new_node(.Falloff, .Float, r)
	n.count = {int(kind), 0}
	return origin(n, loc)
}

// The distances to the nearest capsule of four consecutive groups of an array (as
// sd_capsules reads it), in one pass over the list: group k is the `counts[k]` capsules
// after group k - 1, the first starting at `first`. x..w = groups 0..3 (1e9 for an empty
// group). The same as four sd_capsules calls, for a quarter of the list walks; `bins` as for
// sd_capsules, covering all four groups.
sd_capsule_groups :: proc(p: Expr, values: ^Node, first: Expr, counts: [4]Expr, bins: ^Node = nil, loc := #caller_location) -> ^Node {
	assert(values.op == .ParamArray && values.count[0] % CAPSULE_STRIDE == 0, "vfx: sd_capsule_groups reads an array of CAPSULE_STRIDE values per capsule")
	if bins != nil {
		assert(bins.op == .ParamArray && bins.count[1] != 0, "vfx: bins are a data_array (see engine.bin_shapes)")
		return origin(new_node(.SdCapsuleGroups, .Vec4, p, values, first, counts[0], counts[1], counts[2], counts[3], bins), loc)
	}
	return origin(new_node(.SdCapsuleGroups, .Vec4, p, values, first, counts[0], counts[1], counts[2], counts[3]), loc)
}

// The image of buffer layer `z_index` (engine.set_layer_buffer) at world position `at`
// (virtual units, as world() gives; the camera must not move). Bilinear between the image's
// pixels; at full resolution a pixel reads exactly what was drawn there. Two layers per
// look at most.
layer_sample :: proc(z_index: int, at: Expr, loc := #caller_location) -> ^Node {
	n := new_node(.LayerSample, .Vec4, at)
	n.count = {z_index, 0}
	return origin(n, loc)
}

// Fractal value noise with integer hashing (the same algorithm as a game's own CPU code
// can run, so both get the very same pattern): `octaves` layers, each twice as dense and
// half as strong, normalized to [0, 1). The seed is a 32-bit integer given as its high and
// low 16 bits (a float can't hold all 32), plus a compile-time `offset` added to it. Per
// layer and cell: h = hash(seed + 1013·octave ^ row·0x632be5ab, column) as in prelude.glsl.
int_fbm :: proc(p: Expr, seed_hi, seed_lo: Expr, octaves: int, offset := 0, loc := #caller_location) -> ^Node {
	n := new_node(.IntFbm, .Float, p, seed_hi, seed_lo)
	n.count = {octaves, offset}
	return origin(n, loc)
}

// Anti-aliased coverage of the inside of a distance field.
fill :: proc(d: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Fill, .Float, d), loc)}
// Anti-aliased coverage of a band of `width` around the zero contour.
stroke :: proc(d, width: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Stroke, .Float, d, width), loc)}
// Exponential falloff outside the shape, 1 inside.
glow :: proc(d, radius: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Glow, .Float, d, radius), loc)}

// ---------------------------------------------------------------------------------------
// Color

// Cosine palette: a + b * cos(2π(c·t + d)), see iquilezles.org/articles/palettes.
palette :: proc(t, a, b, c, d: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Palette, .Vec4, t, a, b, c, d), loc)}
gradient :: proc(t, from, to: Expr, loc := #caller_location) -> ^Node {return origin(mix(from, to, t), loc)}
// Piecewise-linear gradient through evenly spaced stops as `t` goes from 0 to 1.
ramp :: proc(t: Expr, stops: ..Expr, loc := #caller_location) -> ^Node {
	assert(len(stops) >= 2)
	tn := to_node(t)
	acc := to_node(stops[0])
	for i in 1 ..< len(stops) {
		acc = mix(acc, stops[i], saturate(sub(mul(tn, f32(len(stops) - 1)), f32(i - 1))))
	}
	return origin(acc, loc)
}
// Alpha-composites `top` over `bottom`.
over :: proc(top, bottom: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Over, .Vec4, top, bottom), loc)}
// Composites layers in painter's order: the first layer is at the bottom.
stack :: proc(layers: ..Expr, loc := #caller_location) -> ^Node {
	assert(len(layers) > 0)
	acc := to_node(layers[0])
	for l in layers[1:] {
		acc = over(l, acc)
	}
	return origin(acc, loc)
}
// Multiplies the color channels, keeping alpha.
shade :: proc(color, k: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Shade, .Vec4, color, k), loc)}
// Multiplies alpha by a coverage value.
mask :: proc(color, coverage: Expr, loc := #caller_location) -> ^Node {return origin(new_node(.Mask, .Vec4, color, coverage), loc)}

Light :: struct {
	strength: Expr, // how strongly height changes bend the surface normal
	specular: Expr, // intensity of the highlight
	shininess: Expr, // highlight exponent
	direction: Expr, // vec2 pointing towards the light, in screen space
	step:     Expr, // finite difference distance in virtual units
}

// Lights `color` as if it were a surface whose relief is given by `height`.
// Lights `color` as a surface with relief `height` under the scene's lights (engine.add_light)
// rather than one fixed direction: point lights fall off with distance and shade the relief
// from where they are. `light.direction` is ignored. Counts as animated, since lights move.
lit_scene :: proc(color, height: Expr, light := Light{}, loc := #caller_location) -> ^Node {
	n := new_node(
		.LitScene,
		.Vec4,
		color,
		height,
		or_else_expr(light.strength, f32(1)),
		or_else_expr(light.specular, f32(0)),
		or_else_expr(light.shininess, f32(24)),
		or_else_expr(light.step, f32(1)),
	)
	return origin(n, loc)
}

lit :: proc(color, height: Expr, light := Light{}, loc := #caller_location) -> ^Node {
	n := new_node(
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
	return origin(n, loc)
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
shatter :: proc(child: Expr, o: Shatter, loc := #caller_location) -> ^Node {
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
	return origin(n, loc)
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
sparks :: proc(o: Sparks, loc := #caller_location) -> ^Node {
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
	return origin(n, loc)
}

// The field of a list of metaballs and its slope: vec4(field, d/dx, d/dy, 0). Each ball adds
// strength · (1 − d²/r²)², a smooth bump that is exactly zero beyond its radius r, so balls
// near each other merge. Four values each, like glow_points (x, y, radius, strength); the
// iso-line field = threshold is the surface, and (field − threshold) / |slope| the signed
// distance to it in the units of p. `first`, `count` and `bins` as for glow_points.
metaballs :: proc(p: Expr, values: ^Node, first: Expr = f32(0), count: Expr = f32(-1), bins: ^Node = nil, loc := #caller_location) -> ^Node {
	assert(values.op == .ParamArray && values.count[0] % GLOW_STRIDE == 0, "vfx: metaballs reads an array of 4 values per ball")
	if bins != nil {
		assert(bins.op == .ParamArray && bins.count[1] != 0, "vfx: bins are a data_array (see engine.bin_shapes)")
		return origin(new_node(.Metaballs, .Vec4, p, values, first, count, bins), loc)
	}
	return origin(new_node(.Metaballs, .Vec4, p, values, first, count), loc)
}

// `value` where `condition` > 0, zero elsewhere, without computing `value` there: the GPU
// skips the work for whole groups of pixels that fail the condition together. For looks
// whose expensive part matters only in some places (e.g. inside a shape, near a light).
gate :: proc(condition, value: Expr, loc := #caller_location) -> ^Node {
	v := to_node(value)
	return origin(new_node(.Gate, v.type, condition, v), loc)
}

// ---------------------------------------------------------------------------------------
// 3D: looks that cast a ray through each pixel and light what it hits (see the light_room
// demo). Positions and directions are vec4s whose w is 0, so that dot, length and the
// arithmetic work as in 3D; units are the scene's (meters, say).

// Values per light in the array read by point_lights, capsule_shadows and haze_lights: x, y,
// z, range (its light fades to nothing there), r, g, b (linear), intensity.
LIGHT_STRIDE :: 8
// Values per capsule in the array read by capsule_shadows and capsule_occlusion: ax, ay, az,
// radius, bx, by, bz, unused. A sphere is a capsule whose ends coincide.
CAPSULE3_STRIDE :: 8

// The light reflected towards the viewer from a surface point by the lights of an array
// (LIGHT_STRIDE values each; the first `count`, all if < 0): Lambert diffuse plus a
// Blinn-Phong highlight, falling off with the inverse square of the distance and windowed
// to 0 at each light's range. pos, normal, view (towards the viewer, unit) are 3D vec4s,
// albedo linear rgb, material = (specular, shininess, _, _). shadow scales lights 0..3 (what
// reaches the point past what stands between, e.g. capsule_shadows); `mask` (>= 0) is a bit
// set of the lights to use, so each object can skip the lights out of its reach. Returns
// linear rgb, w 0.
point_lights :: proc(
	pos, normal, view, albedo, material: Expr,
	lights: ^Node,
	count: Expr = f32(-1),
	shadow: Expr = [4]f32{1, 1, 1, 1},
	mask: Expr = f32(-1),
	loc := #caller_location,
) -> ^Node {
	assert(lights.op == .ParamArray && lights.count[0] % LIGHT_STRIDE == 0, "vfx: point_lights reads an array of LIGHT_STRIDE values per light")
	return origin(new_node(.PointLights, .Vec4, pos, normal, view, albedo, material, lights, count, shadow, mask), loc)
}

// How much of each of the first four lights of an array (vec4: lights 0..3) reaches pos past
// the capsules first ..< first + count of `occluders` (count < 0: all the rest), each a soft
// occluder: the share of the light's disc (`light_size` across) that it leaves uncovered.
// With `bins` (a data_array from engine.bin_shapes over the capsules' reach on screen, looked
// up at `at`, world() if nil) each pixel visits only the capsules listed in its cell.
capsule_shadows :: proc(
	pos: Expr,
	lights, occluders: ^Node,
	first: Expr = f32(0),
	count: Expr = f32(-1),
	light_size: Expr = f32(0.3),
	bins: ^Node = nil,
	at: Expr = nil,
	loc := #caller_location,
) -> ^Node {
	assert(lights.op == .ParamArray && lights.count[0] % LIGHT_STRIDE == 0, "vfx: capsule_shadows reads an array of LIGHT_STRIDE values per light")
	assert(occluders.op == .ParamArray && occluders.count[0] % CAPSULE3_STRIDE == 0, "vfx: capsule_shadows reads an array of CAPSULE3_STRIDE values per capsule")
	at_pos := at if at != nil else Expr(world())
	if bins != nil {
		assert(bins.op == .ParamArray && bins.count[1] != 0, "vfx: bins are a data_array (see engine.bin_shapes)")
		return origin(new_node(.CapsuleShadows, .Vec4, pos, lights, occluders, first, count, light_size, at_pos, bins), loc)
	}
	return origin(new_node(.CapsuleShadows, .Vec4, pos, lights, occluders, first, count, light_size, at_pos), loc)
}

// The share of the sky that the capsules first ..< first + count of `occluders` leave to a
// surface point (pos, unit normal): each hides r²·cos / d² of it, as a sphere at its nearest
// point would. Capsules more than 6 radii away are skipped. `bins` and `at` as for
// capsule_shadows.
capsule_occlusion :: proc(
	pos, normal: Expr,
	occluders: ^Node,
	first: Expr = f32(0),
	count: Expr = f32(-1),
	bins: ^Node = nil,
	at: Expr = nil,
	loc := #caller_location,
) -> ^Node {
	assert(occluders.op == .ParamArray && occluders.count[0] % CAPSULE3_STRIDE == 0, "vfx: capsule_occlusion reads an array of CAPSULE3_STRIDE values per capsule")
	at_pos := at if at != nil else Expr(world())
	if bins != nil {
		assert(bins.op == .ParamArray && bins.count[1] != 0, "vfx: bins are a data_array (see engine.bin_shapes)")
		return origin(new_node(.CapsuleOcclusion, .Float, pos, normal, occluders, first, count, at_pos, bins), loc)
	}
	return origin(new_node(.CapsuleOcclusion, .Float, pos, normal, occluders, first, count, at_pos), loc)
}

// Light that air scatters towards the viewer along a ray (origin, unit dir) up to distance
// `far`, around each of the first `count` lights of an array (all if < 0): their color times
// intensity times the closed-form integral of 1 / distance² along the ray, the distance
// taken as at least `core`. Scale it by the air's density. Linear rgb, w 0.
haze_lights :: proc(ray_origin, dir, far: Expr, lights: ^Node, count: Expr = f32(-1), core: Expr = f32(0.05), loc := #caller_location) -> ^Node {
	assert(lights.op == .ParamArray && lights.count[0] % LIGHT_STRIDE == 0, "vfx: haze_lights reads an array of LIGHT_STRIDE values per light")
	return origin(new_node(.HazeLights, .Vec4, ray_origin, dir, far, lights, count, core), loc)
}

// Kinds of solid for march_solid and solid_normal, centered at the origin of their own space;
// `size` means: Sphere (radius), Box (half sizes xyz, edge rounding w), Cylinder along y
// (radius x, half height y, edge rounding w), Ellipsoid (radii xyz), Torus around y (radius
// x, tube y), Capsule along y (radius x, half length y), Blob (four spheres melted together:
// scale x, seed y; within 1.7 x of its center), Twisted (a Box twisted around y by 1.2
// radians from its middle to each end; at least 1.5 times as tall as wide), Carved (a Box
// with three round tunnels through it).
Solid :: enum {
	Sphere,
	Box,
	Cylinder,
	Ellipsoid,
	Torus,
	Capsule,
	Blob,
	Twisted,
	Carved,
}

// Sphere tracing of a solid (kind: a Solid as a float, so it can come from a param or an
// instance record) along a ray (origin and unit dir in the solid's space), within its
// bounding sphere of radius `bound`, in at most `steps` steps. Returns x = distance to the
// hit (on a miss, to where the ray passed closest), y = coverage of the pixel (1 on a hit;
// near the outline, from the closest pass and `pix`, the angle of one pixel), z = 1 on a hit.
march_solid :: proc(kind, ray_origin, dir, size, bound, pix: Expr, steps := 40, loc := #caller_location) -> ^Node {
	n := new_node(.MarchSolid, .Vec4, kind, ray_origin, dir, size, bound, pix)
	n.count = {steps, 0}
	return origin(n, loc)
}

// The outward unit normal of a solid (as for march_solid) at p, in its space; w 0.
solid_normal :: proc(kind, p, size: Expr, loc := #caller_location) -> ^Node {
	return origin(new_node(.SolidNormal, .Vec4, kind, p, size), loc)
}
