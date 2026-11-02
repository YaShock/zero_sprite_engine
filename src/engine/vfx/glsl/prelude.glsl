// Helper functions available to every generated look shader (see codegen.odin, which
// calls them by name). Relies on the uniforms declared in header.glsl.

vec2 rot2(vec2 v, float a) {
	float c = cos(a), s = sin(a);
	return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
}

float angle2(vec2 v) {
	return atan(v.y, v.x);
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

// Lambert + Blinn-Phong under the scene lights plus ambient. `slope` is the height field's
// gradient in the object's own frame (rotated into the world here) and `world` the pixel's
// world position.
vec4 scene_light(vec4 color, vec2 slope, float specular, float shininess, vec2 world) {
	vec3 n = normalize(vec3(-rot2(slope, u_rot), 1.0));
	vec3 total = u_ambient * color.rgb;
	for (int i = 0; i < u_light_count; i++) {
		vec4 pos = u_light_pos[i];
		vec4 col = u_light_color[i];
		vec3 l = normalize(pos.xyz);
		float falloff = 1.0;
		if (pos.w > 0.5) {
			vec3 to_light = vec3(pos.xy - world, pos.z);
			l = normalize(to_light);
			float k = clamp(1.0 - dot(to_light.xy, to_light.xy) / (col.a * col.a), 0.0, 1.0);
			falloff = k * k;
		}
		float diffuse = max(dot(n, l), 0.0);
		vec3 hv = normalize(l + vec3(0.0, 0.0, 1.0));
		float spec = specular * pow(max(dot(n, hv), 0.0), shininess);
		total += (color.rgb * diffuse + spec) * col.rgb * falloff;
	}
	return vec4(total, color.a);
}

// A burst of glowing streaks on ballistic paths, `t` seconds after emission from `origin`.
// Each particle gets its own direction within `spread` of `dir`, speed and lifetime.
vec4 sparks(vec2 p, float t, vec2 origin, float dir, float spread, float speed, float grav,
            float radius, float life, float seed, vec4 color, int count) {
	float acc = 0.0;
	for (int i = 0; i < count; i++) {
		vec2 h = hash22(vec2(float(i) * 1.37, seed));
		float l = life * (0.4 + 0.6 * hash11(float(i) * 5.11 + seed));
		float k = t / l;
		if (k >= 1.0) continue;
		float ang = dir + (h.x * 2.0 - 1.0) * spread;
		vec2 v = vec2(cos(ang), sin(ang)) * speed * (0.25 + 0.75 * h.y);
		vec2 pos = origin + v * t + vec2(0.0, 0.5 * grav * t * t);
		vec2 vnow = v + vec2(0.0, grav * t);
		float d = sd_segment(p, pos, pos - vnow * 0.02);
		acc += (1.0 - k) * exp(-d * d / (radius * radius));
	}
	acc = clamp(acc, 0.0, 1.5);
	return vec4(mix(color.rgb, vec3(1.0), clamp(acc - 0.5, 0.0, 1.0) * 0.7), min(acc, 1.0) * color.a);
}
