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
