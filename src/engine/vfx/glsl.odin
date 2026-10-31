package vfx

import "core:strings"

// The GLSL library behind generated look shaders, embedded at compile time.

// Inputs every look shader reads; codegen appends the per-look parameter array after it.
@(private)
FRAGMENT_HEADER :: #load("glsl/header.glsl", string)

// Helper functions that generated code calls by name.
@(private)
PRELUDE :: #load("glsl/prelude.glsl", string)

// A complete shader that only declares the inputs and helpers, for checking the library on
// its own (see engine.check_glsl_library).
library_test_source :: proc(allocator := context.temp_allocator) -> string {
	return strings.concatenate({FRAGMENT_HEADER, "uniform vec4 u_p[1];\n", PRELUDE, "\nvoid main() { finalColor = vec4(0.0); }\n"}, allocator)
}
