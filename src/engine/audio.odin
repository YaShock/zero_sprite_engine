package engine

import "core:strings"
import ma "vendor:miniaudio"

@(private)
audio_engine: ma.engine

// Heap-allocated sounds for controllable playback (stop, volume, looping).
@(private)
sound_cache: map[int]^ma.sound

// Paths stored alongside sounds so play_sound can use engine_play_sound
// for true fire-and-forget, overlapping instances.
@(private)
sound_paths: map[int]string

init_audio :: proc() {
	config := ma.engine_config_init()
	result := ma.engine_init(&config, &audio_engine)
	assert(result == .SUCCESS, "Failed to initialize audio engine")
	sound_cache = make(map[int]^ma.sound)
	sound_paths = make(map[int]string)
}

deinit_audio :: proc() {
	for _, s in sound_cache {
		ma.sound_uninit(s)
		free(s)
	}
	delete(sound_cache)
	for _, path in sound_paths {
		delete(path)
	}
	delete(sound_paths)
	ma.engine_uninit(&audio_engine)
}

load_sound :: proc(id: int, path: string) -> bool {
	if _, found := sound_paths[id]; found {
		return true
	}
	s := new(ma.sound)
	// DECODE: decode into memory upfront. WAIT_INIT: block until fully ready.
	result := ma.sound_init_from_file(
		&audio_engine,
		strings.clone_to_cstring(path, context.temp_allocator),
		{.DECODE, .WAIT_INIT},
		nil,
		nil,
		s,
	)
	if result != .SUCCESS {
		free(s)
		return false
	}
	sound_cache[id] = s
	sound_paths[id] = strings.clone(path)
	return true
}

unload_sound :: proc(id: int) {
	if s, found := sound_cache[id]; found {
		ma.sound_uninit(s)
		free(s)
		delete_key(&sound_cache, id)
	}
	if path, found := sound_paths[id]; found {
		delete(path)
		delete_key(&sound_paths, id)
	}
}

// Fire-and-forget: spawns a new sound instance each call, allowing overlapping.
// ma.sound_start is a no-op when the sound is already playing, so this avoids
// that limitation by going through the engine's inlined-sound mechanism.
play_sound :: proc(id: int) {
	if path, found := sound_paths[id]; found {
		ma.engine_play_sound(
			&audio_engine,
			strings.clone_to_cstring(path, context.temp_allocator),
			nil,
		)
	}
}

// Stop, change volume, or loop the persistent ma.sound instance.
// Pair with play_sound_controlled, not play_sound.
stop_sound :: proc(id: int) {
	if s, found := sound_cache[id]; found {
		ma.sound_stop(s)
	}
}

set_sound_volume :: proc(id: int, volume: f32) {
	if s, found := sound_cache[id]; found {
		ma.sound_set_volume(s, volume)
	}
}

set_sound_looping :: proc(id: int, looping: bool) {
	if s, found := sound_cache[id]; found {
		ma.sound_set_looping(s, b32(looping))
	}
}

// Plays the single persistent sound instance — use for music or looping sounds
// where stop_sound / set_sound_volume / set_sound_looping need to apply.
play_sound_controlled :: proc(id: int) {
	if s, found := sound_cache[id]; found {
		ma.sound_stop(s)
		ma.sound_seek_to_pcm_frame(s, 0)
		ma.sound_start(s)
	}
}

// Fire-and-forget by file path, no cache entry needed.
play_sound_once :: proc(path: string) {
	ma.engine_play_sound(
		&audio_engine,
		strings.clone_to_cstring(path, context.temp_allocator),
		nil,
	)
}
