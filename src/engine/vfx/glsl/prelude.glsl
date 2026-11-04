// Helper functions available to every generated look shader (see codegen.odin, which
// calls them by name). Relies on the uniforms declared in header.glsl.

vec2 rot2(vec2 v, float a) {
	float c = cos(a), s = sin(a);
	return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
}

float angle2(vec2 v) {
	return atan(v.y, v.x);
}

// The k-th parameter slot (param_array values are read by index), and the four slots from
// k on (k a multiple of 4).
float pget(int k) {
	return u_p(k >> 2)[k & 3];
}

vec4 pget4(int k) {
	return u_p(k >> 2);
}

// The k-th value of the look's data texture (data_array values, read by index; 1024
// texels of 4 values per row).
float dget(int k) {
	return texelFetch(u_data, ivec2((k >> 2) & 1023, k >> 12), 0)[k & 3];
}

vec4 dget4(int k) {
	return texelFetch(u_data, ivec2((k >> 2) & 1023, k >> 12), 0);
}

// A soft round light at distance r (in radii): 1, 2/3, 1/5 and 0 at 0, 0.2, 0.5 and 1.
float glow_falloff(float r) {
	return r < 0.2 ? mix(1.0, 0.6667, r / 0.2) : r < 0.5 ? mix(0.6667, 0.2, (r - 0.2) / 0.3) : mix(0.2, 0.0, min(1.0, (r - 0.5) / 0.5));
}

// A light with a brighter core (1, 0.53 and 0 at 0, 0.25 and 1 of its radius), and one
// fading as (1 − r)².
float dot_falloff(float r) {
	return r < 0.25 ? mix(1.0, 0.5333, r / 0.25) : mix(0.5333, 0.0, min(1.0, (r - 0.25) / 0.75));
}

float quadratic_falloff(float r) {
	float k = max(1.0 - r, 0.0);
	return k * k;
}

// Integer hashing for value noise that matches a CPU implementation bit for bit (the
// usual 32-bit multiply-xorshift mix), in [0, 1).
float int_hash(uint seed, int i) {
	uint h = (seed ^ (uint(i) * 0x27d4eb2du)) * 0x165667b1u;
	h ^= h >> 15u;
	h *= 0x85ebca6bu;
	h ^= h >> 13u;
	h *= 0xc2b2ae35u;
	h ^= h >> 16u;
	return float(h) / 4294967296.0;
}

float int_value_noise(uint seed, vec2 p) {
	vec2 fi = floor(p), f = p - fi;
	int i = int(fi.x), j = int(fi.y);
	vec2 t = f * f * (3.0 - 2.0 * f);
	uint row0 = seed ^ (uint(j) * 0x632be5abu), row1 = seed ^ (uint(j + 1) * 0x632be5abu);
	float a = int_hash(row0, i), b = int_hash(row0, i + 1), c = int_hash(row1, i), d = int_hash(row1, i + 1);
	float top = a + (b - a) * t.x, bottom = c + (d - c) * t.x;
	return top + (bottom - top) * t.y;
}

float int_fbm(vec2 p, uint seed, int octaves) {
	float sum = 0.0, amp = 1.0, freq = 1.0, norm = 0.0;
	for (int o = 0; o < octaves; o++) {
		sum += int_value_noise(seed + uint(o) * 1013u, p * freq) * amp;
		norm += amp;
		amp *= 0.5;
		freq *= 2.0;
	}
	return sum / norm;
}

// Distance to a segment whose radius goes from ra at a to rb at b.
float sd_capsule(vec2 p, vec2 a, vec2 b, float ra, float rb) {
	vec2 pa = p - a, ba = b - a;
	float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
	return length(pa - ba * h) - mix(ra, rb, h);
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

// ---------------------------------------------------------------------------------------
// 3D, for looks that cast a ray through each pixel (point_lights, capsule_shadows,
// capsule_occlusion, haze_lights, march_solid). Positions in meters, directions unit length.

// Where a ray (unit d) comes closest to the segment a-b: x = how far along the ray (0 if the
// closest point is behind its origin), y = how far apart they are there
vec2 ray_segment_approach(vec3 o, vec3 d, vec3 a, vec3 b) {
	vec3 ba = b - a;
	vec3 oa = o - a;
	float bard = dot(ba, d);
	float rdoa = dot(d, oa);
	float s = clamp((dot(ba, oa) - bard * rdoa) / max(dot(ba, ba) - bard * bard, 1e-6), 0.0, 1.0);
	float t = max(bard * s - rdoa, 0.0);
	return vec2(t, length(oa + d * t - ba * s));
}

// How much of a light (direction l, `dist` away, a disc `size` across) reaches p past the
// capsule a-b of radius r: the share of the disc that the capsule's edge leaves uncovered,
// the edge being (gap - r) / t off the light's direction at t along it
float capsule_light(vec3 p, vec3 l, float dist, vec3 a, vec3 b, float r, float size) {
	vec2 near = ray_segment_approach(p, l, a, b);
	if (near.x < 1e-3 || near.x > dist) return 1.0;
	return smoothstep(-1.0, 1.0, (near.y - r) * dist / (near.x * size));
}

// Light scattered towards the eye by air around a point light at l, along a ray (unit d)
// from o up to `far`: the integral of 1 / distance², (atan((far - b) / h) + atan(b / h)) / h,
// b being how far along the ray the light is closest and h (at least `core`) how close
float light_haze(vec3 o, vec3 d, float far, vec3 l, float core) {
	vec3 to = l - o;
	float b = dot(to, d);
	float h = max(sqrt(max(dot(to, to) - b * b, 0.0)), core);
	return (atan((far - b) / h) + atan(b / h)) / h;
}

// Signed distance to a solid centered at the origin. kind: 0 sphere (radius s.x), 1 box
// (half sizes s.xyz, edges rounded by s.w), 2 cylinder along y (radius s.x, half height s.y,
// edges rounded by s.w), 3 ellipsoid (radii s.xyz; approximate), 4 torus around y (radius
// s.x, tube s.y), 5 capsule along y (radius s.x, half length s.y), 6 blob (scale s.x, seed
// s.y), 7 twisted box (as 1), 8 carved box (as 1); the last three are not exact distances
float sd_solid(int kind, vec3 p, vec4 s) {
	if (kind == 1) {
		vec3 q = abs(p) - s.xyz + s.w;
		return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - s.w;
	}
	if (kind == 2) {
		vec2 q = vec2(length(p.xz), abs(p.y)) - s.xy + s.w;
		return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - s.w;
	}
	if (kind == 3) {
		float k0 = length(p / s.xyz);
		return k0 * (k0 - 1.0) / max(length(p / (s.xyz * s.xyz)), 1e-6);
	}
	if (kind == 4) return length(vec2(length(p.xz) - s.x, p.y)) - s.y;
	if (kind == 5) {
		p.y -= clamp(p.y, -s.y, s.y);
		return length(p) - s.x;
	}
	if (kind == 6) {
		// Blob: four spheres placed by the seed s.y within s.x, melted together (polynomial
		// smooth minimum); it stays within 1.7 s.x of its center
		float d = 1e9;
		float k = 0.35 * s.x;
		for (int i = 0; i < 4; i++) {
			float n = s.y + float(i) * 7.13;
			vec3 c = (fract(sin(vec3(1.0, 1.7, 2.3) * n) * 43758.5453) - 0.5) * 1.1 * s.x;
			float di = length(p - c) - s.x * (0.42 + 0.2 * fract(sin(n * 3.1) * 9631.7));
			float h = clamp(0.5 + 0.5 * (di - d) / k, 0.0, 1.0);
			d = mix(di, d, h) - k * h * (1.0 - h);
		}
		return d;
	}
	if (kind == 7) {
		// Twisted: a rounded box (half sizes s.xyz, rounding s.w) turned around y by 1.2
		// radians from its middle to each end. Twisting stretches distances, so the step is
		// shortened (enough for boxes at least 1.5 times as tall as wide).
		float a = p.y * 1.2 / s.y;
		p.xz = mat2(cos(a), -sin(a), sin(a), cos(a)) * p.xz;
		vec3 q = abs(p) - s.xyz + s.w;
		return 0.6 * (length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - s.w);
	}
	if (kind == 8) {
		// Carved: a rounded box with three round tunnels through its middle, along x, y and
		// z, their rims rounded (smooth subtraction)
		vec3 q = abs(p) - s.xyz + s.w;
		float box = length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - s.w;
		float holes = min(min(length(p.xy), length(p.yz)), length(p.xz)) - 0.55 * min(s.x, min(s.y, s.z));
		float h = clamp(0.5 - 0.5 * (box + holes) / 0.04, 0.0, 1.0);
		return mix(box, -holes, h) + 0.04 * h * (1.0 - h);
	}
	return length(p) - s.x;
}

// Sphere tracing of a solid (sd_solid) along a ray (unit d) from o, within its bounding
// sphere of radius `bound`, at most `steps` steps. x = distance to the hit, or to the
// closest pass on a miss; y = coverage of the pixel: 1 on a hit, else from how close the ray
// passed relative to the pixel's angle `pix` (anti-aliasing at the outline); z = 1 on a hit
vec4 march_solid(int kind, vec3 o, vec3 d, vec4 s, float bound, float pix, int steps) {
	float b = dot(o, d);
	float h = b * b - dot(o, o) + bound * bound;
	if (h <= 0.0) return vec4(0.0);
	h = sqrt(h);
	float t = max(-b - h, 0.0);
	float t_end = -b + h;
	float best = 1e9;
	float best_t = t;
	for (int i = 0; i < steps; i++) {
		float dist = sd_solid(kind, o + d * t, s);
		if (dist < 0.25 * pix * t) return vec4(t, 1.0, 1.0, 0.0);
		float ratio = dist / max(t, 1e-3);
		if (ratio < best) {
			best = ratio;
			best_t = t;
		}
		t += dist;
		if (t > t_end) break;
	}
	return vec4(best_t, clamp(0.5 - best / pix, 0.0, 1.0), 0.0, 0.0);
}

// The outward normal of a solid at p (its distance's gradient, tetrahedral differences)
vec3 solid_normal(int kind, vec3 p, vec4 s) {
	const vec2 k = vec2(1.0, -1.0);
	const float e = 5e-4;
	return normalize(
		k.xyy * sd_solid(kind, p + k.xyy * e, s) + k.yyx * sd_solid(kind, p + k.yyx * e, s) +
		k.yxy * sd_solid(kind, p + k.yxy * e, s) + k.xxx * sd_solid(kind, p + k.xxx * e, s)
	);
}
