#version 330
// Inputs shared by every generated look shader, drawn by vertex.glsl.

in vec2 fragTexCoord;
flat in vec4 v_shape;  // logical size, rotation, age
flat in vec4 v_frame;  // drawn extent, world origin
flat in int v_params;  // index of the instance's first parameter vec4 in u_inst
out vec4 finalColor;

// This draw call's instance records (see vertex.glsl). Generated code reads parameter slots
// (packed four per vec4) from the instance's record with u_p(i).
layout(std140) uniform Instances {
	vec4 u_inst[4096];
};
#define u_p(i) u_inst[v_params + (i)]

uniform float u_time;   // scene time
uniform float u_px;     // virtual units per screen pixel

// Per-instance values, set at the start of main() from the inputs above.
float u_age;     // seconds since the object spawned
float u_rot;     // object rotation, radians
vec2 u_size;     // logical object size
vec2 u_extent;   // drawn quad size (size + padding)
vec2 u_origin;   // object center in world space

// Scene lights (engine.add_light). Position: xy in the world and z the height above the
// scene, w = 1 for point lights; or a direction towards the light with w = 0 for directional
// ones. Color: rgb scaled by intensity, a = the radius where a point light fades out.
const int MAX_LIGHTS = 8;
uniform int u_light_count;
uniform vec4 u_light_pos[MAX_LIGHTS];
uniform vec4 u_light_color[MAX_LIGHTS];
uniform vec3 u_ambient;
