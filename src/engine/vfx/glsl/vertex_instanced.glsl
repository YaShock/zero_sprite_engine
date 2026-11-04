#version 330
// Vertex shader of instanced looks (vfx.instances): one entity draws a quad per instance
// record, all in one draw call. The entity's own record (laid out as in vertex.glsl) is the
// first in the Instances block; each instance record starts with its quad (center x, y,
// half width, height, in the entity's frame: virtual units around its position, turned with
// it), read from the material's data texture like the fragment shader's dget4.

uniform mat4 u_modelview;
uniform mat4 u_projection;
uniform sampler2D u_data;
uniform ivec2 u_instances; // first value and values per record of the instance records in u_data
layout(std140) uniform Instances {
	vec4 u_inst[4096];
};

out vec2 fragTexCoord;
flat out vec4 v_shape;
flat out vec4 v_frame;
flat out int v_params;
flat out int v_instance;
out vec2 v_local;  // position from the instance's center (coord())
out vec2 v_center; // the instance's center in the entity's frame

void main() {
	vec4 entity = u_inst[0]; // center in the drawing space, drawn extent there
	v_shape = u_inst[1];
	v_frame = u_inst[2];
	v_params = 3;
	// Drawing units per virtual unit
	float scale = v_frame.x > 0.0 ? entity.z / v_frame.x : 1.0;

	int k = u_instances.x + gl_InstanceID * u_instances.y;
	vec4 quad = texelFetch(u_data, ivec2((k >> 2) & 1023, k >> 12), 0);
	// Corners in the order of vertex.glsl: top-left, bottom-left, top-right, bottom-right
	vec2 corner = vec2(gl_VertexID >> 1, gl_VertexID & 1);
	fragTexCoord = corner;
	v_instance = gl_InstanceID;
	v_local = (corner * 2.0 - 1.0) * quad.zw;
	v_center = quad.xy;
	vec2 l = (quad.xy + v_local) * scale;
	float c = cos(v_shape.z), s = sin(v_shape.z);
	vec2 pos = entity.xy + vec2(c * l.x - s * l.y, s * l.x + c * l.y);
	gl_Position = u_projection * u_modelview * vec4(pos, 0.0, 1.0);
}
