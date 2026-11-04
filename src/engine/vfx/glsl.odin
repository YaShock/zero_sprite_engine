package vfx

import "core:strings"

// The GLSL library behind generated look shaders, embedded at compile time.

// Inputs every look shader reads.
@(private)
FRAGMENT_HEADER :: #load("glsl/header.glsl", string)

// Vertex shader of every look: one quad per instance, from the instance records.
VERTEX_SHADER :: #load("glsl/vertex.glsl", string)

// Vertex shader of instanced looks (Program.instances): one quad per record of the look's
// instances array.
VERTEX_INSTANCED_SHADER :: #load("glsl/vertex_instanced.glsl", string)

// Helper functions that generated code calls by name.
@(private)
PRELUDE :: #load("glsl/prelude.glsl", string)

// The first line of an instanced look's fragment shader after the header, so that the right
// vertex shader can be told from the source alone (see vertex_shader_of).
@(private)
INSTANCED_MARKER :: "// instanced look\n"

// The vertex shader a generated fragment shader is linked with.
vertex_shader_of :: proc(fragment_source: string) -> string {
	if len(fragment_source) > len(FRAGMENT_HEADER) && strings.has_prefix(fragment_source[len(FRAGMENT_HEADER):], INSTANCED_MARKER) {
		return VERTEX_INSTANCED_SHADER
	}
	return VERTEX_SHADER
}

// How header.glsl reads parameter slots: at constant indices (one instance per draw call),
// or from the instance's record (the batched variant).
@(private)
PARAMS_SINGLE :: "#define u_p(i) u_inst[3 + (i)]\n"
@(private)
PARAMS_BATCHED :: "#define u_p(i) u_inst[v_params + (i)]\n"

// The variant of a generated fragment shader for draw calls of several instances. Reading
// parameters at an offset only known per instance makes some drivers load each one from
// memory (on Intel, Light Room's letters took 75% longer), so a look gets this variant only
// once it's drawn batched. Instanced looks never are, so it's always linked with
// VERTEX_SHADER.
batched_source :: proc(source: string, allocator := context.allocator) -> string {
	i := strings.index(source, PARAMS_SINGLE)
	assert(i >= 0, "vfx: header.glsl lost its u_p definition")
	return strings.concatenate({source[:i], PARAMS_BATCHED, source[i + len(PARAMS_SINGLE):]}, allocator)
}

// A complete shader that only declares the inputs and helpers, for checking the library on
// its own (see engine.check_glsl_library).
library_test_source :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({FRAGMENT_HEADER, PRELUDE, "\nvoid main() { finalColor = vec4(0.0); }\n"}, allocator)
}
