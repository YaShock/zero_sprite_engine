package vfx

import "core:strings"

// The GLSL library behind generated look shaders, embedded at compile time.

// Inputs every look shader reads; codegen appends the per-look parameter array after it.
@(private)
FRAGMENT_HEADER :: #load("glsl/header.glsl", string)

// Vertex shader of every look: one quad per instance, from the instance records.
VERTEX_SHADER :: #load("glsl/vertex.glsl", string)

// Helper functions that generated code calls by name.
@(private)
PRELUDE :: #load("glsl/prelude.glsl", string)

// A complete shader that only declares the inputs and helpers, for checking the library on
// its own (see engine.check_glsl_library).
library_test_source :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({FRAGMENT_HEADER, PRELUDE, "\nvoid main() { finalColor = vec4(0.0); }\n"}, allocator)
}
