package engine

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import gl "vendor:OpenGL"
import rl "vendor:raylib"
import "vfx"

BlendMode :: enum {
	Alpha,
	Additive,
	// The look returns premultiplied color: rgb already multiplied by its alpha, plus any
	// light to add. It covers what is behind by its alpha and adds the rest, so one look can
	// draw solid shapes and the glow around them.
	Premultiplied,
	// Each channel keeps the larger of the look's and what is there: where shapes overlap,
	// the strongest wins instead of adding up (e.g. the glow of the nearest of many pieces).
	// Meant for an out-of-focus layer's image (set_layer_resolution), which starts empty.
	Max,
}

TextAlign :: enum {
	Left,
	Center,
	Right,
}

Text :: struct {
	text:      string, // owned
	font_size: f32,
	color:     Color,
	align:     TextAlign,
}

Drawable :: union {
	Material,
	Text,
}

Entity :: struct {
	id:         int,
	pos:        Vector2, // center
	size:       Vector2, // logical size; the look's coord() spans ±size/2
	pad:        f32, // extra drawn margin around size, for glows and flying debris
	rotation:   f32, // degrees, around the center
	z_index:    int,
	layer_idx:  int,
	visible:    bool,
	blend:      BlendMode,
	drawable:   Drawable,
	collider:   Collider,
	spawn_time: f64,
	lifetime:   f32, // seconds of scene time until auto-removal; 0 = forever
	sort_key:   f32, // in a sorted layer (set_layer_sorted), higher keys draw first
	cache:      LookCache,
}

// A still look rendered once into a texture and redrawn from it (SpawnOptions.cache).
LookCache :: struct {
	enabled: bool,
	texture: rl.RenderTexture2D,
	scale:   f32, // viewport scale it was rendered at
	dirty:   bool, // a param changed since
}

@(private)
Layer :: struct {
	entity_ids: [dynamic]int,
	y_sorted:   bool,
	sorted:     bool, // by Entity.sort_key, highest first (set_layer_sorted)
	divisor:    int, // > 1: drawn into an image this many times smaller, then stretched (see set_layer_resolution)
	opacity:    f32,
	image:      rl.RenderTexture2D,
	soften:     f32, // Gaussian blur of the small image before stretching, its sigma in small-image pixels
	scratch:    rl.RenderTexture2D, // the blur's first pass
	empty:      bool, // nothing visible this frame: the image is neither drawn nor laid over the screen
	buffer:     bool, // drawn into `image` for looks to read (set_layer_buffer), never shown
	cleared:    bool, // a buffer's image holds nothing (it was empty and has been cleared)
	precise:    bool, // half-float image (set_layer_resolution)
	bloom:      bool, // the screen so far, its bright parts blurred and added back (set_layer_bloom)
	threshold:  f32, // the bloom's: how bright a part must be
	capture:    rl.RenderTexture2D, // the bloom's copy of the screen
}

@(private)
Scene :: struct {
	entities: map[int]Entity,
	layers:   [dynamic]Layer,
	next_id:  int,
}

@(private)
scene: Scene

@(private)
init_scene :: proc(num_layers: int) {
	scene.layers = make([dynamic]Layer, max(num_layers, 1))
}

// Draws the layer's entities ordered by the bottom edge of their logical size, so that in
// top-down / three-quarter views whatever stands further down the screen is in front.
set_layer_y_sorted :: proc(z_index: int, y_sorted: bool) {
	scene.layers[z_index].y_sorted = y_sorted
}

// Draws the layer's entities by their sort key (set_sort_key), highest first: e.g. the
// distance from a 3D camera, so that nearer things cover farther ones.
set_layer_sorted :: proc(z_index: int, sorted: bool) {
	scene.layers[z_index].sorted = sorted
}

set_sort_key :: proc(id: int, key: f32) {
	get_entity(id).sort_key = key
}

// Draws the layer out of focus: its entities go into an image `divisor` times smaller than
// the screen, which is then stretched over it (the stretching blurs it, like a lens focused
// elsewhere; shading the small image also costs divisor² times less). The image starts
// transparent and is laid over the scene with premultiplied blending at `opacity`, so
// light (premultiplied looks with zero alpha) adds and solid shapes cover. divisor <= 1
// draws the layer normally. `soften` > 0 first blurs the small image (a Gaussian of that
// sigma, in its pixels), which keeps thin lines from showing as stretched stair steps.
// The image is 8-bit, so each draw into it clips at 1 like the screen; `precise` makes it
// half-float, for many faint overlapping draws (e.g. light splats) that would otherwise
// each round to 1/255 (nothing is clipped then until it is laid over the screen).
set_layer_resolution :: proc(z_index: int, divisor: int, opacity: f32 = 1, soften: f32 = 0, precise := false) {
	layer := &scene.layers[z_index]
	layer.divisor, layer.opacity, layer.soften, layer.precise = divisor, opacity, soften, precise
}

// A layer's image (or the blur's scratch image) of w × h pixels
@(private)
load_layer_target :: proc(layer: ^Layer, w, h: i32) -> rl.RenderTexture2D {
	if layer.buffer || layer.precise {
		return load_float_target(w, h)
	}
	target := rl.LoadRenderTexture(w, h)
	rl.SetTextureFilter(target.texture, .BILINEAR)
	return target
}

// Makes a layer a buffer: its entities are drawn into an image (`divisor` times smaller than
// the screen, half-float color, starting at 0) that is never shown; looks read it with
// vfx.layer_sample. For values that many draws add up before a look uses them, e.g. a
// metaball field splatted blob by blob (premultiplied looks with zero alpha add).
set_layer_buffer :: proc(z_index: int, divisor := 1) {
	layer := &scene.layers[z_index]
	layer.divisor, layer.buffer = math.max(divisor, 1), true
}

// Makes a layer a bloom: where it comes in the drawing order, the screen as drawn so far is
// copied, the parts brighter than `threshold` (0..1, the screen's own values) are kept,
// shrunk `divisor` times and blurred (`soften`, sigma in small pixels), and the result is
// added back over the screen at `strength`, so bright lights and highlights bleed a soft
// glow. The layer's own entities are not drawn. strength <= 0 turns it off.
set_layer_bloom :: proc(z_index: int, threshold: f32 = 0.75, strength: f32 = 0.6, divisor := 4, soften: f32 = 2) {
	layer := &scene.layers[z_index]
	layer.bloom, layer.threshold, layer.opacity = strength > 0, threshold, strength
	layer.divisor, layer.soften, layer.precise = math.max(divisor, 1) if layer.bloom else 1, soften, true
}

// The image a buffer layer was drawn into this frame (see vfx.layer_sample)
@(private)
layer_texture :: proc(z_index: int) -> rl.Texture2D {
	return scene.layers[z_index].image.texture
}

// Renders the out-of-focus and buffer layers into their images. Runs before the frame is
// drawn, as render textures can't be used inside the scene's camera mode.
@(private)
render_layer_images :: proc(camera: rl.Camera2D) {
	for &layer, z in scene.layers {
		if (layer.divisor <= 1 && !layer.buffer) || layer.bloom {
			continue
		}
		// A layer with nothing visible would only add a cleared image
		layer.empty = true
		for id in layer.entity_ids {
			if scene.entities[id].visible {
				layer.empty = false
				break
			}
		}
		if layer.empty && (!layer.buffer || layer.cleared) {
			continue // a buffer that is read must at least be cleared
		}
		div := f32(layer.divisor)
		w := i32(math.ceil(engine.width * engine.viewport.scale / div))
		h := i32(math.ceil(engine.height * engine.viewport.scale / div))
		if layer.image.id == 0 || layer.image.texture.width != w || layer.image.texture.height != h {
			if layer.image.id != 0 {
				rl.UnloadRenderTexture(layer.image)
			}
			layer.image = load_layer_target(&layer, w, h)
		}
		rl.BeginTextureMode(layer.image)
		rl.ClearBackground({0, 0, 0, 0})
		layer.cleared = layer.empty
		if layer.empty {
			rl.EndTextureMode()
			continue
		}
		// The scene's camera, shrunk to the image (the image covers the virtual screen)
		small := rl.Camera2D {
			offset = (camera.offset - engine.viewport.offset) / div,
			zoom   = camera.zoom / div,
		}
		rl.BeginMode2D(small)
		engine.px_factor = div
		begin_batching(&scene_batcher)
		batch_layer(&scene_batcher, z)
		flush_batches()
		engine.px_factor = 1
		rl.EndMode2D()
		rl.EndTextureMode()
		if layer.soften > 0 {
			soften_image(&layer)
		}
	}
}

// A separable Gaussian blur of a texture along u_step (one texel across or down) over ±4
// texels, its weights (u_weights, worked out once per pass in soften_image) by sigma. The image holds premultiplied color, so it is
// averaged as it is.
@(private)
SOFTEN_SHADER :: `#version 330
in vec2 fragTexCoord;
out vec4 finalColor;
uniform sampler2D texture0;
uniform vec2 u_step;
uniform float u_weights[5]; // for offsets 0..4 (the same on both sides), adding up to 1
void main() {
	vec4 sum = texture(texture0, fragTexCoord) * u_weights[0];
	for (int i = 1; i <= 4; i++) {
		sum += (texture(texture0, fragTexCoord + u_step * float(i)) + texture(texture0, fragTexCoord - u_step * float(i))) * u_weights[i];
	}
	finalColor = sum;
}
`

// Blurs a layer's small image: across into its scratch image, then down back into it
@(private)
soften_image :: proc(layer: ^Layer) {
	@(static) shader: rl.Shader
	if shader.id == 0 {
		shader = rl.LoadShaderFromMemory(nil, SOFTEN_SHADER)
	}
	w, h := layer.image.texture.width, layer.image.texture.height
	if layer.scratch.id == 0 || layer.scratch.texture.width != w || layer.scratch.texture.height != h {
		if layer.scratch.id != 0 {
			rl.UnloadRenderTexture(layer.scratch)
		}
		layer.scratch = load_layer_target(layer, w, h)
	}
	loc_step, loc_weights := rl.GetShaderLocation(shader, "u_step"), rl.GetShaderLocation(shader, "u_weights")
	// The Gaussian's weights at 0..4 texels, normalized over -4..4
	weights: [5]f32
	total: f32
	for &w, i in weights {
		w = math.exp(-f32(i * i) / (2 * layer.soften * layer.soften))
		total += w if i == 0 else 2 * w
	}
	for &w in weights {
		w /= total
	}
	pass :: proc(shader: rl.Shader, from, to: rl.RenderTexture2D, step: [2]f32, loc_step, loc_weights: i32, weights: [5]f32) {
		step, weights := step, weights
		rl.BeginTextureMode(to)
		rl.ClearBackground({0, 0, 0, 0})
		rlDisableColorBlend() // replace, not blend over the cleared image
		rl.BeginShaderMode(shader)
		rl.SetShaderValue(shader, loc_step, &step, .VEC2)
		rl.SetShaderValueV(shader, loc_weights, &weights[0], .FLOAT, len(weights))
		texture := from.texture
		// Render textures are upside down: the flipped source keeps the image the right way up
		rl.DrawTextureRec(texture, {0, 0, f32(texture.width), -f32(texture.height)}, {}, rl.WHITE)
		rl.EndShaderMode()
		rlEnableColorBlend()
		rl.EndTextureMode()
	}
	pass(shader, layer.image, layer.scratch, {1 / f32(w), 0}, loc_step, loc_weights, weights)
	pass(shader, layer.scratch, layer.image, {0, 1 / f32(h)}, loc_step, loc_weights, weights)
}

// Keeps what is brighter than u_threshold of a copy of the screen, shrinking it: four
// bilinear reads u_step apart (half the small pixel each way) each average 2 × 2 screen
// pixels, together the 4 × 4 under a small pixel at divisor 4
@(private)
BLOOM_SHADER :: `#version 330
in vec2 fragTexCoord;
out vec4 finalColor;
uniform sampler2D texture0;
uniform vec2 u_step;
uniform float u_threshold;
void main() {
	vec3 sum = vec3(0.0);
	for (int i = 0; i < 4; i++) {
		vec2 o = vec2(float(i & 1), float(i >> 1)) * 2.0 - 1.0;
		sum += max(texture(texture0, fragTexCoord + o * u_step).rgb - u_threshold, 0.0);
	}
	finalColor = vec4(sum / (4.0 * (1.0 - u_threshold)), 1.0);
}
`

// A bloom layer (set_layer_bloom), drawn in the scene's camera mode: leaves it to copy the
// screen and make the small blurred image, then adds that over the screen
@(private)
draw_bloom :: proc(layer: ^Layer, camera: rl.Camera2D) {
	@(static) shader: rl.Shader
	if shader.id == 0 {
		shader = rl.LoadShaderFromMemory(nil, BLOOM_SHADER)
	}
	vp := engine.viewport
	w, h := i32(engine.width * vp.scale), i32(engine.height * vp.scale)
	if layer.capture.id == 0 || layer.capture.texture.width != w || layer.capture.texture.height != h {
		if layer.capture.id != 0 {
			rl.UnloadRenderTexture(layer.capture)
		}
		layer.capture = rl.LoadRenderTexture(w, h)
		rl.SetTextureFilter(layer.capture.texture, .BILINEAR)
	}
	div := f32(layer.divisor)
	sw, sh := i32(math.ceil(f32(w) / div)), i32(math.ceil(f32(h) / div))
	if layer.image.id == 0 || layer.image.texture.width != sw || layer.image.texture.height != sh {
		if layer.image.id != 0 {
			rl.UnloadRenderTexture(layer.image)
		}
		layer.image = load_layer_target(layer, sw, sh)
	}
	rl.EndMode2D()
	rl.EndScissorMode()
	rlDrawRenderBatchActive()
	// The screen so far: the window's framebuffer is bottom-up, as render textures are
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, layer.capture.id)
	x0, y0 := i32(vp.offset.x), rl.GetRenderHeight() - i32(vp.offset.y) - h
	gl.BlitFramebuffer(x0, y0, x0 + w, y0 + h, 0, 0, w, h, gl.COLOR_BUFFER_BIT, gl.NEAREST)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	// Its bright parts, shrunk, then blurred
	rl.BeginTextureMode(layer.image)
	rlDisableColorBlend() // replace
	rl.BeginShaderMode(shader)
	step := [2]f32{div / 4 / f32(w), div / 4 / f32(h)}
	threshold := layer.threshold
	rl.SetShaderValue(shader, rl.GetShaderLocation(shader, "u_step"), &step, .VEC2)
	rl.SetShaderValue(shader, rl.GetShaderLocation(shader, "u_threshold"), &threshold, .FLOAT)
	source := rl.Rectangle{0, 0, f32(w), -f32(h)} // render textures are upside down
	rl.DrawTexturePro(layer.capture.texture, source, {0, 0, f32(sw), f32(sh)}, {}, 0, rl.WHITE)
	rl.EndShaderMode()
	rlEnableColorBlend()
	rl.EndTextureMode()
	if layer.soften > 0 {
		soften_image(layer)
	}
	// Back to the scene, and added over it
	rl.BeginScissorMode(x0, i32(vp.offset.y), w, h)
	rl.BeginMode2D(camera)
	k := u8(clamp(layer.opacity, 0, 1) * 255)
	rl.BeginBlendMode(.ADDITIVE)
	texture := layer.image.texture
	rl.DrawTexturePro(texture, {0, 0, f32(texture.width), -f32(texture.height)}, {0, 0, engine.width, engine.height}, {}, 0, {255, 255, 255, k})
	rl.EndBlendMode()
	gpu_timer.dirty = true
}

// Lays an out-of-focus layer's image over the virtual screen
@(private)
draw_layer_image :: proc(layer: ^Layer) {
	texture := layer.image.texture
	source := rl.Rectangle{0, 0, f32(texture.width), -f32(texture.height)} // render textures are upside down
	k := u8(clamp(layer.opacity, 0, 1) * 255)
	rl.BeginBlendMode(.ALPHA_PREMULTIPLY)
	rl.DrawTexturePro(texture, source, {0, 0, engine.width, engine.height}, {}, 0, {k, k, k, k})
	rl.EndBlendMode()
	gpu_timer.dirty = true
}

SpawnOptions :: struct {
	z_index:  int,
	pad:      f32,
	lifetime: f32,
	blend:    BlendMode,
	rotation: f32,
	// Render the look once into a texture and redraw that, re-rendering when the window
	// scale or a param changes. For still, expensive looks; ignored if the look reads time()
	// or age().
	cache:    bool,
}

// Adds an entity whose appearance is the shader compiled from `look`.
add_entity :: proc(look: vfx.Expr, pos, size: Vector2, opts := SpawnOptions{}, loc := #caller_location) -> int {
	id := add_drawable(make_material(look, loc), pos, size, opts.z_index)
	e := get_entity(id)
	e.pad = opts.pad
	e.lifetime = opts.lifetime
	e.blend = opts.blend
	e.rotation = opts.rotation
	e.cache.enabled = opts.cache && !shader_cache.entries[e.drawable.(Material).shader].program.animated
	return id
}

add_text :: proc(text: string, pos: Vector2, font_size: f32, color: Color, z_index := 0, align := TextAlign.Left) -> int {
	t := Text {
		text      = strings.clone(text),
		font_size = font_size,
		color     = color,
		align     = align,
	}
	return add_drawable(t, pos, {}, z_index)
}

set_text :: proc(id: int, text: string) {
	t := &get_entity(id).drawable.(Text)
	if t.text != text {
		delete(t.text)
		t.text = strings.clone(text)
	}
}

set_text_color :: proc(id: int, color: Color) {
	(&get_entity(id).drawable.(Text)).color = color
}

@(private)
add_drawable :: proc(drawable: Drawable, pos, size: Vector2, z_index: int) -> int {
	assert(z_index >= 0 && z_index < len(scene.layers), fmt.tprintf("Invalid layer index: %d", z_index))
	id := scene.next_id
	scene.next_id += 1
	layer := &scene.layers[z_index]
	scene.entities[id] = Entity {
		id         = id,
		pos        = pos,
		size       = size,
		z_index    = z_index,
		layer_idx  = len(layer.entity_ids),
		visible    = true,
		drawable   = drawable,
		spawn_time = engine.time,
	}
	append(&layer.entity_ids, id)
	return id
}

get_entity :: proc(id: int) -> ^Entity {
	e, ok := &scene.entities[id]
	assert(ok, fmt.tprintf("Unknown entity: %d", id))
	return e
}

entity_exists :: proc(id: int) -> bool {
	return id in scene.entities
}

set_collider :: proc(id: int, collider: Collider) {
	get_entity(id).collider = collider
}

remove_entity :: proc(id: int) {
	e, ok := scene.entities[id]
	if !ok {
		return
	}
	// Swap-remove from the layer, fixing up the moved entity's index.
	layer := &scene.layers[e.z_index]
	last_id := layer.entity_ids[len(layer.entity_ids) - 1]
	layer.entity_ids[e.layer_idx] = last_id
	(&scene.entities[last_id]).layer_idx = e.layer_idx
	pop(&layer.entity_ids)

	switch d in e.drawable {
	case Material:
		delete_material(d)
	case Text:
		delete(d.text)
	}
	if e.cache.texture.id != 0 {
		rl.UnloadRenderTexture(e.cache.texture)
	}
	delete_key(&scene.entities, id)
}

clear_scene :: proc() {
	for &layer in scene.layers {
		for len(layer.entity_ids) > 0 {
			remove_entity(layer.entity_ids[0])
		}
	}
}

@(private)
remove_expired_entities :: proc() {
	expired := make([dynamic]int, context.temp_allocator)
	for id, e in scene.entities {
		if e.lifetime > 0 && engine.time - e.spawn_time >= f64(e.lifetime) {
			append(&expired, id)
		}
	}
	for id in expired {
		remove_entity(id)
	}
}

@(private)
render_entities :: proc(camera: rl.Camera2D) {
	begin_batching(&scene_batcher)
	for &layer, z in scene.layers {
		switch {
		case layer.buffer:
		// Only read by looks
		case layer.bloom:
			// Works on the screen as drawn so far
			flush_batches()
			draw_bloom(&layer, camera)
			begin_batching(&scene_batcher)
		case layer.divisor > 1:
			// Drawn before the frame (render_layer_images); it covers the whole screen, so
			// nothing drawn after it could join a group before it anyway
			if layer.image.id != 0 && !layer.empty {
				flush_batches()
				draw_layer_image(&layer)
				begin_batching(&scene_batcher)
			}
		case:
			batch_layer(&scene_batcher, z)
		}
	}
	flush_batches()
}

// Draws what was batched since begin_batching.
@(private)
flush_batches :: proc() {
	{
		profile_scope("batch")
		emit_batches(&scene_batcher, &scene_draws)
	}
	submit_draws(&scene_draws)
}

// Adds a layer's visible entities to the batcher, in the layer's order.
@(private)
batch_layer :: proc(b: ^Batcher, z: int) {
	profile_scope("batch")
	layer := &scene.layers[z]
	ids := layer.entity_ids[:]
	if layer.y_sorted {
		ids = slice.clone(ids, context.temp_allocator)
		slice.sort_by(ids, proc(a, b: int) -> bool {
			ea, eb := &scene.entities[a], &scene.entities[b]
			return ea.pos.y + ea.size.y / 2 < eb.pos.y + eb.size.y / 2
		})
	} else if layer.sorted {
		ids = slice.clone(ids, context.temp_allocator)
		slice.stable_sort_by(ids, proc(a, b: int) -> bool {return scene.entities[a].sort_key > scene.entities[b].sort_key})
	}
	for id in ids {
		e := &scene.entities[id]
		if !e.visible {
			continue
		}
		assert(e.drawable != nil, "Entity drawable cannot be nil!")
		batch_entity(b, e)
	}
}

@(private)
draw_text :: proc(e: ^Entity, t: Text) {
	pos, _ := text_rect(e, t)
	text := strings.clone_to_cstring(t.text, context.temp_allocator)
	rl.DrawTextEx(rl.GetFontDefault(), text, pos, t.font_size, t.font_size / 10, t.color)
	gpu_timer.dirty = true
}

// Where raylib draws a text entity: its top left corner and size.
@(private)
text_rect :: proc(e: ^Entity, t: Text) -> (pos, dims: Vector2) {
	text := strings.clone_to_cstring(t.text, context.temp_allocator)
	dims = rl.MeasureTextEx(rl.GetFontDefault(), text, t.font_size, t.font_size / 10)
	pos = e.pos - {0, dims.y / 2}
	switch t.align {
	case .Left:
	case .Center:
		pos.x -= dims.x / 2
	case .Right:
		pos.x -= dims.x
	}
	return
}
