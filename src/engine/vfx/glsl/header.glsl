#version 330
// Inputs shared by every generated look shader. The compiler appends the per-look
// parameter array after this: uniform vec4 u_p[N], parameter slots packed by 4.

in vec2 fragTexCoord;
in vec4 fragColor;
out vec4 finalColor;

uniform float u_time;   // scene time
uniform float u_age;    // seconds since the object spawned
uniform float u_px;     // virtual units per screen pixel
uniform float u_rot;    // object rotation, radians
uniform vec2 u_size;    // logical object size
uniform vec2 u_extent;  // drawn quad size (size + padding)
uniform vec2 u_origin;  // object center in world space

// Scene lights (engine.add_light). Position: xy in the world and z the height above the
// scene, w = 1 for point lights; or a direction towards the light with w = 0 for directional
// ones. Color: rgb scaled by intensity, a = the radius where a point light fades out.
const int MAX_LIGHTS = 8;
uniform int u_light_count;
uniform vec4 u_light_pos[MAX_LIGHTS];
uniform vec4 u_light_color[MAX_LIGHTS];
uniform vec3 u_ambient;
