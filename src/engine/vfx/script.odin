package vfx

// Look scripts: a small text language for composing looks from the same functions that
// game code calls, so looks can be written, tweaked and stored as data (see the editor in
// src/tools/editor).
//
//     // A pulsing orb
//     size 120 120
//     param radius = 40 in [10, 60] animate 2
//     let d = sd_circle(coord, radius)
//     stack(mask(#ff8a3c, glow(d, 12)), mask(#fff3c4, fill(d)))
//
// One statement per line; a line continues while parentheses or brackets are open.
//   size W [H]       logical size of the entity (default 160 x 160)
//   pad N            extra drawn margin around it
//   lifetime N       seconds after which age() restarts in previews (0 = never)
//   param NAME = VALUE [in [MIN, MAX]] [animate PERIOD [sine|saw|pingpong]]
//                    a vfx.param: tweakable at runtime, optionally animated between bounds
//   let NAME = EXPR  names a value for reuse
//   EXPR             the look itself (the last expression statement wins)
//
// Expressions: numbers, #rrggbb or #rrggbbaa colors, [x, y] vectors, + - * / with the
// usual precedence, unary minus, swizzles (.x .y .xy .rgba ...), `pi`, `tau`, and calls to
// the functions in BUILTINS with positional or `name: value` arguments. Constant arithmetic
// is folded, so it costs nothing in the shader.

import "base:builtin"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

Wave :: enum {
	Sine,
	Saw,
	PingPong,
}

ScriptParam :: struct {
	name:     string, // slice of the script source
	type:     Type,
	default:  [4]f32,
	min, max: f32,
	animate:  f32, // period in seconds; 0 = not animated
	wave:     Wave,
}

Script :: struct {
	look:     ^Node,
	size:     [2]f32,
	pad:      f32,
	lifetime: f32,
	params:   []ScriptParam,
	nodes:    int, // expression nodes created, a rough measure of complexity
}

ScriptError :: struct {
	line, col: int, // 1-based
	message:   string,
}

// Parses a look script. Everything is allocated with the temp allocator; names in the result
// point into `source`.
parse_script :: proc(source: string) -> (script: Script, err: ScriptError, ok: bool) {
	context.allocator = context.temp_allocator
	tokens, token_err, tokens_ok := tokenize(source)
	if !tokens_ok {
		return {}, token_err, false
	}
	p := Parser {
		tokens = tokens,
		script = {size = {160, 160}},
	}
	p.vars = make(map[string]Value)
	p.params = make([dynamic]ScriptParam)
	for !p.failed && peek(&p).kind != .EOF {
		statement(&p)
	}
	_ = err
	if !p.failed && p.script.look == nil {
		fail(&p, peek(&p), "the script has no look: end it with an expression, e.g. fill(sd_circle(coord, 40))")
	}
	if p.failed {
		return {}, p.err, false
	}
	p.script.params = p.params[:]
	return p.script, {}, true
}

// Where an animated parameter is in its swing, 0 (at min) .. 1 (at max), `seconds` into the
// animation.
animation_phase :: proc(param: ScriptParam, seconds: f64) -> f32 {
	if param.animate <= 0 {
		return 0
	}
	phase := f32(math.mod(seconds / f64(param.animate), 1))
	k: f32
	switch param.wave {
	case .Sine:
		k = 0.5 - 0.5 * math.cos(phase * math.TAU)
	case .Saw:
		k = phase
	case .PingPong:
		k = 1 - builtin.abs(2 * phase - 1)
	}
	return k
}

// ---------------------------------------------------------------------------------------
// Tokens

@(private)
TokenKind :: enum {
	EOF,
	Newline,
	Ident,
	Number,
	Color,
	LParen,
	RParen,
	LBracket,
	RBracket,
	Comma,
	Colon,
	Dot,
	Plus,
	Minus,
	Star,
	Slash,
	Equals,
}

@(private)
Token :: struct {
	kind:      TokenKind,
	text:      string,
	number:    f32,
	color:     [4]f32,
	line, col: int,
}

@(private)
tokenize :: proc(source: string) -> (tokens: []Token, err: ScriptError, ok: bool) {
	out := make([dynamic]Token)
	line, col := 1, 1
	depth := 0 // open parentheses/brackets: newlines inside them don't end a statement
	i := 0
	is_ident :: proc(c: u8) -> bool {return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')}
	is_digit :: proc(c: u8) -> bool {return c >= '0' && c <= '9'}
	for i < len(source) {
		c := source[i]
		start, start_col := i, col
		tok := Token {
			line = line,
			col  = col,
		}
		switch {
		case c == '\n':
			i += 1
			line, col = line + 1, 1
			if depth == 0 && len(out) > 0 && out[len(out) - 1].kind != .Newline {
				append(&out, Token{kind = .Newline, text = "\n", line = tok.line, col = tok.col})
			}
			continue
		case c == ' ' || c == '\t' || c == '\r':
			i += 1
			col += 1
			continue
		case c == '/' && i + 1 < len(source) && source[i + 1] == '/':
			for i < len(source) && source[i] != '\n' {
				i += 1
			}
			continue
		case is_digit(c) || (c == '.' && i + 1 < len(source) && is_digit(source[i + 1]) && !follows_value(out[:])):
			for i < len(source) && (is_digit(source[i]) || source[i] == '.') {
				i += 1
			}
			tok.kind = .Number
			value, parsed := strconv.parse_f32(source[start:i])
			if !parsed {
				return nil, {line, start_col, fmt.tprintf("bad number '%s'", source[start:i])}, false
			}
			tok.number = value
		case c == '#':
			i += 1
			for i < len(source) && is_ident(source[i]) {
				i += 1
			}
			hex := source[start + 1:i]
			value, parsed := strconv.parse_u64_of_base(hex, 16)
			if !parsed || (len(hex) != 6 && len(hex) != 8) {
				return nil, {line, start_col, fmt.tprintf("colors are #rrggbb or #rrggbbaa, not '%s'", source[start:i])}, false
			}
			if len(hex) == 6 {
				value = value << 8 | 0xff
			}
			tok.kind = .Color
			tok.color = {f32((value >> 24) & 0xff), f32((value >> 16) & 0xff), f32((value >> 8) & 0xff), f32(value & 0xff)} / 255
		case is_ident(c):
			for i < len(source) && is_ident(source[i]) {
				i += 1
			}
			tok.kind = .Ident
		case:
			switch c {
			case '(':
				tok.kind = .LParen
			case ')':
				tok.kind = .RParen
			case '[':
				tok.kind = .LBracket
			case ']':
				tok.kind = .RBracket
			case ',':
				tok.kind = .Comma
			case ':':
				tok.kind = .Colon
			case '.':
				tok.kind = .Dot
			case '+':
				tok.kind = .Plus
			case '-':
				tok.kind = .Minus
			case '*':
				tok.kind = .Star
			case '/':
				tok.kind = .Slash
			case '=':
				tok.kind = .Equals
			case:
				return nil, {line, col, fmt.tprintf("unexpected character '%c'", c)}, false
			}
			i += 1
			#partial switch tok.kind {
			case .LParen, .LBracket:
				depth += 1
			case .RParen, .RBracket:
				depth = builtin.max(depth - 1, 0)
			}
		}
		tok.text = source[start:i]
		col += i - start
		append(&out, tok)
	}
	append(&out, Token{kind = .EOF, line = line, col = col})
	return out[:], {}, true

	// A '.' right after a value is a swizzle, not the start of a number like .5
	follows_value :: proc(tokens: []Token) -> bool {
		if len(tokens) == 0 {
			return false
		}
		#partial switch tokens[len(tokens) - 1].kind {
		case .Ident, .Number, .RParen, .RBracket:
			return true
		}
		return false
	}
}

// ---------------------------------------------------------------------------------------
// Parser

// Script values: constants stay constants until they meet a node, so constant arithmetic
// folds away. Lists hold point lists for sd_polyline / sd_polygon.
@(private)
Value :: union {
	f32,
	[2]f32,
	[4]f32,
	^Node,
	[]Value,
}

@(private)
Parser :: struct {
	tokens: []Token,
	pos:    int,
	vars:   map[string]Value,
	params: [dynamic]ScriptParam,
	script: Script,
	err:    ScriptError,
	failed: bool,
}

@(private)
peek :: proc(p: ^Parser, ahead := 0) -> Token {
	return p.tokens[builtin.min(p.pos + ahead, len(p.tokens) - 1)]
}

@(private)
next :: proc(p: ^Parser) -> Token {
	t := peek(p)
	if p.pos < len(p.tokens) - 1 {
		p.pos += 1
	}
	return t
}

@(private)
fail :: proc(p: ^Parser, at: Token, message: string) {
	if !p.failed {
		p.failed = true
		p.err = {at.line, at.col, message}
	}
}

@(private)
expect :: proc(p: ^Parser, kind: TokenKind, what: string) -> (Token, bool) {
	t := peek(p)
	if t.kind != kind {
		fail(p, t, fmt.tprintf("expected %s, found '%s'", what, describe(t)))
		return t, false
	}
	return next(p), true
}

@(private)
describe :: proc(t: Token) -> string {
	#partial switch t.kind {
	case .EOF:
		return "end of script"
	case .Newline:
		return "end of line"
	}
	return t.text
}

@(private)
end_of_statement :: proc(p: ^Parser) {
	t := peek(p)
	if t.kind == .Newline {
		next(p)
	} else if t.kind != .EOF {
		fail(p, t, fmt.tprintf("unexpected '%s' after the end of the statement", describe(t)))
	}
}

@(private)
statement :: proc(p: ^Parser) -> bool {
	t := peek(p)
	if t.kind == .Newline {
		next(p)
		return true
	}
	if t.kind == .Ident {
		switch t.text {
		case "let":
			next(p)
			name := expect(p, .Ident, "a name after 'let'") or_return
			expect(p, .Equals, "'='") or_return
			p.vars[name.text] = expression(p) or_return
			end_of_statement(p)
			return !p.failed
		case "param":
			param_statement(p) or_return
			end_of_statement(p)
			return !p.failed
		case "size", "pad", "lifetime":
			if peek(p, 1).kind == .Number || peek(p, 1).kind == .Minus {
				next(p)
				a := constant_number(p) or_return
				switch t.text {
				case "size":
					p.script.size = {a, a}
					if peek(p).kind != .Newline && peek(p).kind != .EOF {
						p.script.size.y = constant_number(p) or_return
					}
				case "pad":
					p.script.pad = a
				case "lifetime":
					p.script.lifetime = a
				}
				end_of_statement(p)
				return !p.failed
			}
		}
	}
	value := expression(p) or_return
	look, is_node := to_look(value)
	if !is_node {
		fail(p, t, "the look must be an expression, not a list")
		return false
	}
	p.script.look = look
	end_of_statement(p)
	return !p.failed

	to_look :: proc(v: Value) -> (^Node, bool) {
		if _, is_list := v.([]Value); is_list {
			return nil, false
		}
		return to_node(to_expr(v)), true
	}
}

@(private)
constant_number :: proc(p: ^Parser) -> (number: f32, ok: bool) {
	t := peek(p)
	v := expression(p) or_return
	n, is_number := v.(f32)
	if !is_number {
		fail(p, t, "expected a constant number")
		return 0, false
	}
	return n, true
}

// param NAME = VALUE [in [MIN, MAX]] [animate PERIOD [sine|saw|pingpong]]
@(private)
param_statement :: proc(p: ^Parser) -> bool {
	next(p)
	name := expect(p, .Ident, "a parameter name") or_return
	for existing in p.params {
		if existing.name == name.text {
			fail(p, name, fmt.tprintf("parameter '%s' is declared twice", name.text))
			return false
		}
	}
	expect(p, .Equals, "'='") or_return
	value_tok := peek(p)
	value := expression(p) or_return
	sp := ScriptParam {
		name = name.text,
	}
	switch v in value {
	case f32:
		sp.type, sp.default = .Float, {v, 0, 0, 0}
		sp.min, sp.max = builtin.min(0, 2 * v), builtin.max(1, 2 * v)
	case [2]f32:
		sp.type, sp.default = .Vec2, {v.x, v.y, 0, 0}
		m := builtin.max(builtin.abs(v.x), builtin.abs(v.y), 1)
		sp.min, sp.max = -2 * m, 2 * m
	case [4]f32:
		sp.type, sp.default = .Vec4, v
		sp.min, sp.max = 0, 1
	case ^Node, []Value:
		fail(p, value_tok, "a parameter's default must be a constant number, vector or color")
		return false
	}
	if peek(p).kind == .Ident && peek(p).text == "in" {
		next(p)
		expect(p, .LBracket, "'[' after 'in'") or_return
		sp.min = constant_number(p) or_return
		expect(p, .Comma, "','") or_return
		sp.max = constant_number(p) or_return
		expect(p, .RBracket, "']'") or_return
	}
	if peek(p).kind == .Ident && peek(p).text == "animate" {
		next(p)
		sp.animate = constant_number(p) or_return
		if peek(p).kind == .Ident {
			mode := next(p)
			switch mode.text {
			case "sine":
				sp.wave = .Sine
			case "saw":
				sp.wave = .Saw
			case "pingpong":
				sp.wave = .PingPong
			case:
				fail(p, mode, "animation is 'sine', 'saw' or 'pingpong'")
				return false
			}
		}
	}
	append(&p.params, sp)
	p.vars[name.text] = param(name.text, to_expr(value))
	return true
}

@(private)
to_expr :: proc(v: Value) -> Expr {
	switch x in v {
	case f32:
		return x
	case [2]f32:
		return x
	case [4]f32:
		return x
	case ^Node:
		return x
	case []Value:
	}
	return nil
}

@(private)
value_type :: proc(v: Value) -> (Type, bool) {
	switch x in v {
	case f32:
		return .Float, true
	case [2]f32:
		return .Vec2, true
	case [4]f32:
		return .Vec4, true
	case ^Node:
		return x.type, true
	case []Value:
	}
	return .Float, false
}

@(private)
TYPE_NAME := [Type]string {
	.Float = "a number",
	.Vec2  = "a vec2",
	.Vec4  = "a color/vec4",
}

@(private)
expression :: proc(p: ^Parser) -> (result: Value, ok: bool) {
	left := term(p) or_return
	for peek(p).kind == .Plus || peek(p).kind == .Minus {
		op := next(p)
		right := term(p) or_return
		left = arithmetic(p, op, left, right) or_return
	}
	return left, true
}

@(private)
term :: proc(p: ^Parser) -> (result: Value, ok: bool) {
	left := unary_expr(p) or_return
	for peek(p).kind == .Star || peek(p).kind == .Slash {
		op := next(p)
		right := unary_expr(p) or_return
		left = arithmetic(p, op, left, right) or_return
	}
	return left, true
}

@(private)
unary_expr :: proc(p: ^Parser) -> (result: Value, ok: bool) {
	if peek(p).kind == .Minus {
		op := next(p)
		v := unary_expr(p) or_return
		return arithmetic(p, op, f32(0), v)
	}
	return postfix(p)
}

@(private)
postfix :: proc(p: ^Parser) -> (v: Value, ok: bool) {
	v = primary(p) or_return
	for peek(p).kind == .Dot {
		next(p)
		field := expect(p, .Ident, "a swizzle like .x or .rgb after '.'") or_return
		v = swizzle_value(p, field, v) or_return
	}
	return v, true
}

@(private)
swizzle_value :: proc(p: ^Parser, field: Token, v: Value) -> (result: Value, ok: bool) {
	t, is_value := value_type(v)
	width := [Type]int {
		.Float = 1,
		.Vec2  = 2,
		.Vec4  = 4,
	}
	n := len(field.text)
	if !is_value || (n != 1 && n != 2 && n != 4) {
		fail(p, field, "swizzles pick 1, 2 or 4 components, e.g. .x, .yx, .rgba")
		return nil, false
	}
	xyzw := "xyzw"
	picks := make([]u8, n)
	for i in 0 ..< n {
		index := strings.index_byte(xyzw, field.text[i])
		if index < 0 {
			index = strings.index_byte("rgba", field.text[i])
		}
		if index < 0 || index >= width[t] {
			fail(p, field, fmt.tprintf("'.%s' doesn't fit %s", field.text, TYPE_NAME[t]))
			return nil, false
		}
		picks[i] = xyzw[index]
	}
	// Fold constants.
	components: [4]f32
	switch x in v {
	case f32:
		components = {x, 0, 0, 0}
	case [2]f32:
		components = {x.x, x.y, 0, 0}
	case [4]f32:
		components = x
	case ^Node:
		return swizzle(x, string(picks)), true
	case []Value:
	}
	picked: [4]f32
	for c, i in picks {
		picked[i] = components[strings.index_byte(xyzw, c)]
	}
	switch n {
	case 1:
		return picked[0], true
	case 2:
		return [2]f32{picked[0], picked[1]}, true
	}
	return picked, true
}

// + - * / with constant folding and the same broadcasting rules as GLSL.
@(private)
arithmetic :: proc(p: ^Parser, op: Token, a, b: Value) -> (result: Value, ok: bool) {
	ta, a_ok := value_type(a)
	tb, b_ok := value_type(b)
	if !a_ok || !b_ok {
		fail(p, op, "lists can't be used in arithmetic")
		return nil, false
	}
	if ta != .Float && tb != .Float && ta != tb {
		fail(p, op, fmt.tprintf("can't combine %s and %s with '%s'", TYPE_NAME[ta], TYPE_NAME[tb], op.text))
		return nil, false
	}
	_, a_node := a.(^Node)
	_, b_node := b.(^Node)
	if !a_node && !b_node {
		return fold(op.kind, a, b), true
	}
	#partial switch op.kind {
	case .Plus:
		return add(to_expr(a), to_expr(b)), true
	case .Minus:
		if n, is_zero := a.(f32); is_zero && n == 0 {
			return neg(to_expr(b)), true
		}
		return sub(to_expr(a), to_expr(b)), true
	case .Star:
		return mul(to_expr(a), to_expr(b)), true
	}
	return div(to_expr(a), to_expr(b)), true

	fold :: proc(op: TokenKind, a, b: Value) -> Value {
		widen :: proc(v: Value) -> (c: [4]f32, width: int) {
			#partial switch x in v {
			case f32:
				return {x, x, x, x}, 1
			case [2]f32:
				return {x.x, x.y, 0, 0}, 2
			case [4]f32:
				return x, 4
			}
			return
		}
		ca, wa := widen(a)
		cb, wb := widen(b)
		r: [4]f32
		#partial switch op {
		case .Plus:
			r = ca + cb
		case .Minus:
			r = ca - cb
		case .Star:
			r = ca * cb
		case:
			r = ca / cb
		}
		switch builtin.max(wa, wb) {
		case 1:
			return r[0]
		case 2:
			return [2]f32{r[0], r[1]}
		}
		return r
	}
}

@(private)
primary :: proc(p: ^Parser) -> (result: Value, ok: bool) {
	t := next(p)
	#partial switch t.kind {
	case .Number:
		return t.number, true
	case .Color:
		return t.color, true
	case .LParen:
		v := expression(p) or_return
		expect(p, .RParen, "')'") or_return
		return v, true
	case .LBracket:
		return list(p, t)
	case .Ident:
		if peek(p).kind == .LParen {
			return call(p, t)
		}
		if v, found := p.vars[t.text]; found {
			return v, true
		}
		switch t.text {
		case "pi":
			return f32(math.PI), true
		case "tau":
			return f32(math.TAU), true
		}
		if b, found := find_builtin(t.text); found && b.required == 0 {
			return call(p, t) // inputs like coord or time can be used without parentheses
		}
		fail(p, t, fmt.tprintf("unknown name '%s'", t.text))
		return nil, false
	}
	fail(p, t, fmt.tprintf("expected a value, found '%s'", describe(t)))
	return nil, false
}

// [a, b] and [a, b, c, d] are vectors (folded when constant); [[x, y], ...] is a point list.
@(private)
list :: proc(p: ^Parser, open: Token) -> (result: Value, ok: bool) {
	items := make([dynamic]Value)
	for peek(p).kind != .RBracket {
		v := expression(p) or_return
		append(&items, v)
		if peek(p).kind != .Comma {
			break
		}
		next(p)
	}
	expect(p, .RBracket, "']'") or_return
	all_numbers, any_vector := true, false
	for v in items {
		_, is_number := v.(f32)
		_, is_point := v.([2]f32)
		all_numbers &&= is_number
		any_vector ||= is_point
	}
	if any_vector {
		for v in items {
			if _, is_point := v.([2]f32); !is_point {
				fail(p, open, "a point list must contain only constant [x, y] points")
				return nil, false
			}
		}
		return items[:], true
	}
	switch len(items) {
	case 2:
		if all_numbers {
			return [2]f32{items[0].(f32), items[1].(f32)}, true
		}
		return vec2(to_expr(items[0]), to_expr(items[1])), true
	case 4:
		if all_numbers {
			return [4]f32{items[0].(f32), items[1].(f32), items[2].(f32), items[3].(f32)}, true
		}
		return rgba(to_expr(items[0]), to_expr(items[1]), to_expr(items[2]), to_expr(items[3])), true
	}
	fail(p, open, "vectors have 2 or 4 components")
	return nil, false
}

// ---------------------------------------------------------------------------------------
// Function calls

@(private)
Call :: struct {
	p:    ^Parser,
	at:   Token,
	name: string,
}

// A script function. Arguments bind to `params` by position or by name; arguments past the
// declared ones are allowed for variadic functions.
Builtin :: struct {
	name:      string,
	params:    []string,
	required:  int, // leading params that must be given
	variadic:  bool,
	help:      string,
	call:      proc(c: ^Call, a: []Value) -> (Value, bool),
}

find_builtin :: proc(name: string) -> (Builtin, bool) {
	for b in BUILTINS {
		if b.name == name {
			return b, true
		}
	}
	return {}, false
}

// "name(a, b, c = default)" for help texts.
builtin_signature :: proc(b: Builtin, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	fmt.sbprintf(&sb, "%s(", b.name)
	for name, i in b.params {
		if i > 0 {
			strings.write_string(&sb, ", ")
		}
		if i >= b.required {
			strings.write_string(&sb, "[")
		}
		strings.write_string(&sb, name)
		if i >= b.required {
			strings.write_string(&sb, "]")
		}
	}
	if b.variadic {
		strings.write_string(&sb, ", ...")
	}
	strings.write_string(&sb, ")")
	return strings.to_string(sb)
}

@(private)
call :: proc(p: ^Parser, name: Token) -> (result: Value, ok: bool) {
	b, found := find_builtin(name.text)
	if !found {
		fail(p, name, fmt.tprintf("unknown function '%s'", name.text))
		return nil, false
	}
	args := make([dynamic]Value, len(b.params))
	given := make([]bool, len(b.params))
	if peek(p).kind == .LParen {
		next(p)
		positional := 0
		for peek(p).kind != .RParen {
			at := peek(p)
			if at.kind == .Ident && peek(p, 1).kind == .Colon {
				next(p)
				next(p)
				index := -1
				for param_name, i in b.params {
					if param_name == at.text {
						index = i
					}
				}
				if index < 0 {
					fail(p, at, fmt.tprintf("%s has no argument '%s'", builtin_signature(b), at.text))
					return nil, false
				}
				args[index] = expression(p) or_return
				given[index] = true
			} else {
				v := expression(p) or_return
				switch {
				case positional < len(b.params):
					args[positional] = v
					given[positional] = true
				case b.variadic:
					append(&args, v)
				case:
					fail(p, at, fmt.tprintf("too many arguments: %s", builtin_signature(b)))
					return nil, false
				}
				positional += 1
			}
			if peek(p).kind != .Comma {
				break
			}
			next(p)
		}
		expect(p, .RParen, "')'") or_return
	}
	for i in 0 ..< b.required {
		if !given[i] {
			fail(p, name, fmt.tprintf("missing argument '%s': %s", b.params[i], builtin_signature(b)))
			return nil, false
		}
	}
	c := Call{p, name, b.name}
	p.script.nodes += 1
	return b.call(&c, args[:])
}

// Checks an argument's type; `what` names it in the error.
@(private)
need :: proc(c: ^Call, v: Value, what: string, types: bit_set[Type]) -> bool {
	if v == nil {
		return true // optional and not given
	}
	t, is_value := value_type(v)
	if is_value && t in types {
		return true
	}
	wanted := make([dynamic]string)
	for k in types {
		append(&wanted, TYPE_NAME[k])
	}
	got := TYPE_NAME[t] if is_value else "a list"
	fail(c.p, c.at, fmt.tprintf("%s: '%s' must be %s, got %s", c.name, what, strings.join(wanted[:], " or "), got))
	return false
}

// Arguments that become compile-time integers (octaves, grid sizes, counts) must be constant.
@(private)
need_int :: proc(c: ^Call, v: Value, what: string, default: int) -> (int, bool) {
	return need_whole(c, v, what, default, 1, 64)
}

@(private)
need_whole :: proc(c: ^Call, v: Value, what: string, default, lo, hi: int) -> (int, bool) {
	if v == nil {
		return default, true
	}
	n, is_number := v.(f32)
	if !is_number || n < f32(lo) || n > f32(hi) || n != math.floor(n) {
		fail(c.p, c.at, fmt.tprintf("%s: '%s' must be a constant whole number between %d and %d", c.name, what, lo, hi))
		return 0, false
	}
	return int(n), true
}

@(private)
need_points :: proc(c: ^Call, v: Value, at_least: int) -> ([][2]f32, bool) {
	items, is_list := v.([]Value)
	if !is_list || len(items) < at_least {
		fail(c.p, c.at, fmt.tprintf("%s: expected a list of at least %d [x, y] points", c.name, at_least))
		return nil, false
	}
	points := make([][2]f32, len(items))
	for item, i in items {
		points[i] = item.([2]f32)
	}
	return points, true
}

// Two values combined component-wise must have matching widths (scalars broadcast).
@(private)
compatible :: proc(c: ^Call, a, b: Value) -> bool {
	ta, _ := value_type(a)
	tb, _ := value_type(b)
	if ta != .Float && tb != .Float && ta != tb {
		fail(c.p, c.at, fmt.tprintf("%s: can't combine %s and %s", c.name, TYPE_NAME[ta], TYPE_NAME[tb]))
		return false
	}
	return true
}

@(private)
ANY :: bit_set[Type]{.Float, .Vec2, .Vec4}
@(private)
NUM :: bit_set[Type]{.Float}
@(private)
V2 :: bit_set[Type]{.Vec2}
@(private)
COLOR :: bit_set[Type]{.Vec4}

@(private)
unary_builtin :: proc(c: ^Call, a: []Value, f: proc(a: Expr, loc := #caller_location) -> ^Node) -> (result: Value, ok: bool) {
	need(c, a[0], "x", ANY) or_return
	return f(to_expr(a[0])), true
}

@(private)
binary_builtin :: proc(c: ^Call, a: []Value, f: proc(a, b: Expr, loc := #caller_location) -> ^Node) -> (result: Value, ok: bool) {
	need(c, a[0], "a", ANY) or_return
	need(c, a[1], "b", ANY) or_return
	compatible(c, a[0], a[1]) or_return
	return f(to_expr(a[0]), to_expr(a[1])), true
}

// Every function a look script can call.
BUILTINS := [?]Builtin {
	// Inputs
	{"coord", {}, 0, false, "local position: origin at the center, in units", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return coord(), true}},
	{"world", {}, 0, false, "world position in units", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return world(), true}},
	{"uv", {}, 0, false, "(0,0) top-left .. (1,1) bottom-right of the size", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return uv(), true}},
	{"size", {}, 0, false, "logical size of the entity", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return size(), true}},
	{"time", {}, 0, false, "scene time in seconds", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return time(), true}},
	{"age", {}, 0, false, "seconds since the entity spawned", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return age(), true}},
	{"px", {}, 0, false, "one screen pixel in units", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return px(), true}},
	// Arithmetic
	{"add", {"a", "b"}, 2, false, "a + b", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return binary_builtin(c, a, add)}},
	{"sub", {"a", "b"}, 2, false, "a - b", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return binary_builtin(c, a, sub)}},
	{"mul", {"a", "b"}, 2, false, "a * b", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return binary_builtin(c, a, mul)}},
	{"div", {"a", "b"}, 2, false, "a / b", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return binary_builtin(c, a, div)}},
	{"min", {"a", "b"}, 2, false, "smaller of a and b", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return binary_builtin(c, a, min)}},
	{"max", {"a", "b"}, 2, false, "larger of a and b", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return binary_builtin(c, a, max)}},
	{"pow", {"x", "exponent"}, 2, false, "x to the power", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return binary_builtin(c, a, pow)}},
	{"dot", {"a", "b"}, 2, false, "dot product", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return binary_builtin(c, a, dot)}},
	{"step", {"edge", "x"}, 2, false, "0 below edge, 1 above", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return binary_builtin(c, a, step)}},
	{"saturate", {"x"}, 1, false, "clamp to 0..1", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return unary_builtin(c, a, saturate)}},
	{"abs", {"x"}, 1, false, "absolute value", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return unary_builtin(c, a, abs)}},
	{"neg", {"x"}, 1, false, "-x", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return unary_builtin(c, a, neg)}},
	{"sin", {"x"}, 1, false, "sine", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return unary_builtin(c, a, sin)}},
	{"cos", {"x"}, 1, false, "cosine", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return unary_builtin(c, a, cos)}},
	{"exp", {"x"}, 1, false, "e to the x", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return unary_builtin(c, a, exp)}},
	{"sqrt", {"x"}, 1, false, "square root", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return unary_builtin(c, a, sqrt)}},
	{"asin", {"x"}, 1, false, "arc sine", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return unary_builtin(c, a, asin)}},
	{"floor", {"x"}, 1, false, "round down", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return unary_builtin(c, a, floor)}},
	{"fract", {"x"}, 1, false, "fractional part", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return unary_builtin(c, a, fract)}},
	{"length", {"v"}, 1, false, "vector length", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {return unary_builtin(c, a, length)}},
	{"angle", {"v"}, 1, false, "polar angle of a vec2", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "v", V2) or_return
			return angle(to_expr(a[0])), true
		}},
	{"sum", {"a"}, 1, true, "a + b + ...", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			terms := make([]Expr, len(a))
			for x, i in a {
				need(c, x, "term", ANY) or_return
				compatible(c, a[0], x) or_return
				terms[i] = to_expr(x)
			}
			return sum(..terms), true
		}},
	{"mix", {"a", "b", "t"}, 3, false, "blend from a to b by t", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			compatible(c, a[0], a[1]) or_return
			need(c, a[2], "t", ANY) or_return
			return mix(to_expr(a[0]), to_expr(a[1]), to_expr(a[2])), true
		}},
	{"smoothstep", {"edge0", "edge1", "x"}, 3, false, "smooth 0..1 ramp between the edges", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "edge0", NUM) or_return
			need(c, a[1], "edge1", NUM) or_return
			return smoothstep(to_expr(a[0]), to_expr(a[1]), to_expr(a[2])), true
		}},
	{"vec2", {"x", "y"}, 2, false, "build a vec2", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "x", NUM) or_return
			need(c, a[1], "y", NUM) or_return
			return vec2(to_expr(a[0]), to_expr(a[1])), true
		}},
	{"rgba", {"r", "g", "b", "a"}, 3, false, "build a color", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			names := [4]string{"r", "g", "b", "a"}
			for x, i in a {
				need(c, x, names[i], NUM) or_return
			}
			return rgba(to_expr(a[0]), to_expr(a[1]), to_expr(a[2]), to_expr(a[3]) if a[3] != nil else f32(1)), true
		}},
	// Coordinates
	{"rotate", {"v", "angle"}, 2, false, "rotate a vec2 by radians", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "v", V2) or_return
			need(c, a[1], "angle", NUM) or_return
			return rotate(to_expr(a[0]), to_expr(a[1])), true
		}},
	{"tile", {"p", "cell"}, 2, false, "repeat space in cells; local centered position", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "p", V2) or_return
			return tile(to_expr(a[0]), to_expr(a[1])), true
		}},
	{"cell_id", {"p", "cell"}, 2, false, "integer cell of p", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "p", V2) or_return
			return cell_id(to_expr(a[0]), to_expr(a[1])), true
		}},
	{"brick_local", {"p", "cell", "shift"}, 2, false, "running-bond bricks: local position", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "p", V2) or_return
			return brick_local(to_expr(a[0]), to_expr(a[1]), to_expr(a[2]) if a[2] != nil else f32(0.5)), true
		}},
	{"brick_id", {"p", "cell", "shift"}, 2, false, "running-bond bricks: brick id", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "p", V2) or_return
			return brick_id(to_expr(a[0]), to_expr(a[1]), to_expr(a[2]) if a[2] != nil else f32(0.5)), true
		}},
	{"at", {"look", "p"}, 2, false, "evaluate a look at another position", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[1], "p", V2) or_return
			return at(to_expr(a[0]), to_expr(a[1])), true
		}},
	// Patterns
	{"hash", {"v"}, 1, false, "random 0..1 from a number or vec2", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "v", NUM | V2) or_return
			return hash(to_expr(a[0])), true
		}},
	{"noise", {"p"}, 1, false, "smooth value noise, one feature per unit", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "p", V2) or_return
			return noise(to_expr(a[0])), true
		}},
	{"fbm", {"p", "octaves", "lacunarity", "gain"}, 1, false, "fractal noise", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "p", V2) or_return
			octaves := need_int(c, a[1], "octaves", 5) or_return
			return fbm(to_expr(a[0]), octaves, to_expr(a[2]) if a[2] != nil else f32(2), to_expr(a[3]) if a[3] != nil else f32(0.5)), true
		}},
	{"voronoi", {"p"}, 1, false, "distance to the nearest cell point", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "p", V2) or_return
			return voronoi(to_expr(a[0])), true
		}},
	{"voronoi_edge", {"p"}, 1, false, "distance to the nearest cell border", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "p", V2) or_return
			return voronoi_edge(to_expr(a[0])), true
		}},
	{"int_fbm", {"p", "seed_hi", "seed_lo", "octaves", "offset"}, 3, false, "fractal noise with integer hashing (AlgoGame's fog); offset varies the seed", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "p", V2) or_return
			need(c, a[1], "seed_hi", NUM) or_return
			need(c, a[2], "seed_lo", NUM) or_return
			octaves := need_int(c, a[3], "octaves", 3) or_return
			offset := need_whole(c, a[4], "offset", 0, 0, 1000) or_return
			return int_fbm(to_expr(a[0]), to_expr(a[1]), to_expr(a[2]), octaves, offset), true
		}},
	// Shapes
	{"sd_box", {"p", "half_size", "radius"}, 2, false, "rounded box distance", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "p", V2) or_return
			need(c, a[1], "half_size", NUM | V2) or_return
			return sd_box(to_expr(a[0]), to_expr(a[1]), to_expr(a[2]) if a[2] != nil else f32(0)), true
		}},
	{"sd_circle", {"p", "radius"}, 2, false, "circle distance", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "p", V2) or_return
			need(c, a[1], "radius", NUM) or_return
			return sd_circle(to_expr(a[0]), to_expr(a[1])), true
		}},
	{"sd_segment", {"p", "a", "b"}, 3, false, "distance to a line segment", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			names := [3]string{"p", "a", "b"}
			for x, i in a {
				need(c, x, names[i], V2) or_return
			}
			return sd_segment(to_expr(a[0]), to_expr(a[1]), to_expr(a[2])), true
		}},
	{"sd_polyline", {"p", "points"}, 2, false, "distance to a path, points: [[x, y], ...]", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "p", V2) or_return
			points := need_points(c, a[1], 2) or_return
			return sd_polyline(to_expr(a[0]), points), true
		}},
	{"sd_polygon", {"p", "points"}, 2, false, "convex polygon distance, points: [[x, y], ...]", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "p", V2) or_return
			points := need_points(c, a[1], 3) or_return
			return sd_convex_polygon(to_expr(a[0]), points), true
		}},
	{"fill", {"d"}, 1, false, "anti-aliased inside of a distance", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "d", NUM) or_return
			return fill(to_expr(a[0])), true
		}},
	{"stroke", {"d", "width"}, 2, false, "anti-aliased outline of a distance", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "d", NUM) or_return
			need(c, a[1], "width", NUM) or_return
			return stroke(to_expr(a[0]), to_expr(a[1])), true
		}},
	{"glow", {"d", "radius"}, 2, false, "exponential falloff outside a distance", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "d", NUM) or_return
			need(c, a[1], "radius", NUM) or_return
			return glow(to_expr(a[0]), to_expr(a[1])), true
		}},
	{"falloff", {"r", "kind"}, 1, false, "round light from 1 at r = 0 to 0 at r = 1; kind 0 soft, 1 dot, 2 quadratic", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "r", NUM) or_return
			kind := need_whole(c, a[1], "kind", 0, 0, len(GlowFalloff) - 1) or_return
			return falloff(to_expr(a[0]), GlowFalloff(kind)), true
		}},
	{"gate", {"condition", "value"}, 2, false, "value where condition > 0, else 0 (value is computed only there)", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "condition", NUM) or_return
			need(c, a[1], "value", ANY) or_return
			return gate(to_expr(a[0]), to_expr(a[1])), true
		}},
	// Color
	{"palette", {"t", "a", "b", "c", "d"}, 5, false, "cosine palette a + b*cos(2pi(c*t + d))", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "t", NUM) or_return
			return palette(to_expr(a[0]), to_expr(a[1]), to_expr(a[2]), to_expr(a[3]), to_expr(a[4])), true
		}},
	{"gradient", {"t", "from", "to"}, 3, false, "blend between two colors", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			compatible(c, a[1], a[2]) or_return
			return gradient(to_expr(a[0]), to_expr(a[1]), to_expr(a[2])), true
		}},
	{"ramp", {"t", "c0", "c1"}, 3, true, "gradient through evenly spaced stops", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "t", NUM) or_return
			stops := make([]Expr, len(a) - 1)
			for x, i in a[1:] {
				need(c, x, "stop", COLOR) or_return
				stops[i] = to_expr(x)
			}
			return ramp(to_expr(a[0]), ..stops), true
		}},
	{"over", {"top", "bottom"}, 2, false, "alpha-composite top over bottom", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "top", COLOR) or_return
			need(c, a[1], "bottom", COLOR) or_return
			return over(to_expr(a[0]), to_expr(a[1])), true
		}},
	{"stack", {"bottom"}, 1, true, "composite layers, first at the bottom", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			layers := make([]Expr, len(a))
			for x, i in a {
				need(c, x, "layer", COLOR) or_return
				layers[i] = to_expr(x)
			}
			return stack(..layers), true
		}},
	{"shade", {"color", "k"}, 2, false, "multiply color channels, keep alpha", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "color", COLOR) or_return
			return shade(to_expr(a[0]), to_expr(a[1])), true
		}},
	{"mask", {"color", "coverage"}, 2, false, "multiply alpha by a coverage", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "color", COLOR) or_return
			need(c, a[1], "coverage", NUM) or_return
			return mask(to_expr(a[0]), to_expr(a[1])), true
		}},
	{"lit", {"color", "height", "strength", "specular", "shininess", "direction", "step"}, 2, false, "light a color as a surface with relief", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "color", COLOR) or_return
			need(c, a[1], "height", NUM) or_return
			need(c, a[5], "direction", V2) or_return
			return lit(to_expr(a[0]), to_expr(a[1]), {strength = to_expr(a[2]), specular = to_expr(a[3]), shininess = to_expr(a[4]), direction = to_expr(a[5]), step = to_expr(a[6])}), true
		}},
	{"lit_scene", {"color", "height", "strength", "specular", "shininess", "step"}, 2, false, "light a color as a surface with relief, by the scene's lights", proc(c: ^Call, a: []Value) -> (result: Value, ok: bool) {
			need(c, a[0], "color", COLOR) or_return
			need(c, a[1], "height", NUM) or_return
			return lit_scene(to_expr(a[0]), to_expr(a[1]), {strength = to_expr(a[2]), specular = to_expr(a[3]), shininess = to_expr(a[4]), step = to_expr(a[5])}), true
		}},
	// Effects
	{"shatter", {"look", "progress", "impact", "seed", "speed", "gravity", "spin", "cols", "rows"}, 1, false, "break a look into flying shards", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[0], "look", COLOR) or_return
			need(c, a[2], "impact", V2) or_return
			cols := need_int(c, a[7], "cols", 4) or_return
			rows := need_int(c, a[8], "rows", 2) or_return
			return shatter(to_expr(a[0]), {progress = to_expr(a[1]), impact = to_expr(a[2]), seed = to_expr(a[3]), speed = to_expr(a[4]), gravity = to_expr(a[5]), spin = to_expr(a[6]), cols = cols, rows = rows}), true
		}},
	{"sparks", {"progress", "origin", "direction", "spread", "speed", "gravity", "radius", "life", "seed", "color", "count"}, 0, false, "burst of glowing streaks", proc(c: ^Call, a: []Value) -> (v: Value, ok: bool) {
			need(c, a[1], "origin", V2) or_return
			need(c, a[9], "color", COLOR) or_return
			count := need_int(c, a[10], "count", 16) or_return
			return sparks({progress = to_expr(a[0]), origin = to_expr(a[1]), direction = to_expr(a[2]), spread = to_expr(a[3]), speed = to_expr(a[4]), gravity = to_expr(a[5]), radius = to_expr(a[6]), life = to_expr(a[7]), seed = to_expr(a[8]), color = to_expr(a[9]), count = count}), true
		}},
}
