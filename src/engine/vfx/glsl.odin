package vfx

// Formatted with the number of parameter slots; must not contain braces (fmt escapes).
@(private)
FRAGMENT_HEADER :: `#version 330
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
uniform float u_p[%d];  // per-object parameter slots
`

@(private)
PRELUDE :: `
vec2 rot2(vec2 v, float a) {
	float c = cos(a), s = sin(a);
	return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
}

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
	           mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p, int octaves, float lacunarity, float gain) {
	float v = 0.0, amp = 1.0, total = 0.0;
	mat2 r = mat2(0.8, 0.6, -0.6, 0.8);
	for (int i = 0; i < octaves; i++) {
		v += amp * vnoise(p);
		total += amp;
		p = r * p * lacunarity + 17.13;
		amp *= gain;
	}
	return v / total;
}

float voronoi(vec2 x) {
	vec2 n = floor(x), f = fract(x);
	float md = 8.0;
	for (int j = -1; j <= 1; j++)
	for (int i = -1; i <= 1; i++) {
		vec2 g = vec2(i, j);
		vec2 r = g + hash22(n + g) - f;
		md = min(md, dot(r, r));
	}
	return sqrt(md);
}

// Exact distance to the cell borders (two-pass, iquilezles.org/articles/voronoilines).
float voronoi_edge(vec2 x) {
	vec2 n = floor(x), f = fract(x);
	vec2 mg, mr;
	float md = 8.0;
	for (int j = -1; j <= 1; j++)
	for (int i = -1; i <= 1; i++) {
		vec2 g = vec2(i, j);
		vec2 r = g + hash22(n + g) - f;
		float d = dot(r, r);
		if (d < md) { md = d; mr = r; mg = g; }
	}
	md = 8.0;
	for (int j = -2; j <= 2; j++)
	for (int i = -2; i <= 2; i++) {
		vec2 g = mg + vec2(i, j);
		vec2 r = g + hash22(n + g) - f;
		if (dot(mr - r, mr - r) > 1e-5)
			md = min(md, dot(0.5 * (mr + r), normalize(r - mr)));
	}
	return md;
}

vec2 tile2(vec2 p, vec2 cell) {
	return (fract(p / cell) - 0.5) * cell;
}

vec2 brick_shifted(vec2 p, vec2 cell, float shift) {
	float row = floor(p.y / cell.y);
	p.x += mod(row, 2.0) * shift * cell.x;
	return p;
}

vec2 brick_local(vec2 p, vec2 cell, float shift) {
	return tile2(brick_shifted(p, cell, shift), cell);
}

vec2 brick_id(vec2 p, vec2 cell, float shift) {
	return floor(brick_shifted(p, cell, shift) / cell);
}

float sd_box(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float sd_segment(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a, ba = b - a;
	float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
	return length(pa - ba * h);
}

// One screen pixel of anti-aliasing regardless of window scale.
float fill_aa(float d) {
	return clamp(0.5 - d / u_px, 0.0, 1.0);
}

vec4 over(vec4 top, vec4 bottom) {
	float a = top.a + bottom.a * (1.0 - top.a);
	vec3 c = (top.rgb * top.a + bottom.rgb * bottom.a * (1.0 - top.a)) / max(a, 1e-5);
	return vec4(c, a);
}

// Lambert + Blinn-Phong for a height-field normal; a flat surface keeps its color.
vec4 light(vec4 color, vec2 slope, float specular, float shininess, vec2 dir) {
	vec3 n = normalize(vec3(-slope, 1.0));
	vec3 l = normalize(vec3(dir, 0.9));
	float flat_term = l.z;
	float diffuse = max(dot(n, l), 0.0) / flat_term;
	vec3 hv = normalize(l + vec3(0.0, 0.0, 1.0));
	float spec = specular * pow(max(dot(n, hv), 0.0), shininess);
	return vec4(color.rgb * (0.25 + 0.75 * diffuse) + spec, color.a);
}

`
