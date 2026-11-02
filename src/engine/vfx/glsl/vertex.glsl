#version 330
// Vertex shader shared by every look: draws one quad per instance, as a triangle strip of
// four vertices without attributes. Each instance's record is a run of vec4s in the
// Instances block (written by the engine's draw batches):
//   0: quad center (drawing space), quad size on screen (drawing space)
//   1: logical size, rotation (radians), age
//   2: drawn extent (size + padding, virtual units), world origin
//   3...: the look's parameter slots, read by the fragment shader

uniform mat4 u_modelview;
uniform mat4 u_projection;
uniform int u_stride; // vec4s per record: 3 + the look's parameter vec4s
layout(std140) uniform Instances {
	vec4 u_inst[4096];
};

out vec2 fragTexCoord;
flat out vec4 v_shape;
flat out vec4 v_frame;
flat out int v_params;

void main() {
	int base = gl_InstanceID * u_stride;
	vec4 quad = u_inst[base];
	v_shape = u_inst[base + 1];
	v_frame = u_inst[base + 2];
	v_params = base + 3;

	// Top left, bottom left, top right, bottom right: counter-clockwise on screen like
	// raylib's own quads, so back-face culling keeps them.
	vec2 corner = vec2(gl_VertexID >> 1, gl_VertexID & 1);
	fragTexCoord = corner;
	vec2 offset = (corner - 0.5) * quad.zw;
	float c = cos(v_shape.z), s = sin(v_shape.z);
	vec2 pos = quad.xy + vec2(c * offset.x - s * offset.y, s * offset.x + c * offset.y);
	gl_Position = u_projection * u_modelview * vec4(pos, 0.0, 1.0);
}
