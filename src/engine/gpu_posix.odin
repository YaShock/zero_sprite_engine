#+build !windows
package engine

import gl "vendor:OpenGL"
import "vendor:glfw"
import rl "vendor:raylib"

// vendor:raylib/rlgl links its own bundled static library, which distro/Nix builds of raylib
// don't ship; the few rlgl symbols needed here are exported by the system raylib anyway.
foreign import raylib_lib "system:raylib"

@(private, default_calling_convention = "c")
foreign raylib_lib {
	rlGetShaderIdDefault :: proc() -> u32 ---
	rlDrawRenderBatchActive :: proc() ---
	rlEnableColorBlend :: proc() ---
	rlDisableColorBlend :: proc() ---
	rlGetMatrixModelview :: proc() -> rl.Matrix ---
	rlGetMatrixProjection :: proc() -> rl.Matrix ---
}

// raylib creates its window through the system GLFW, so GLFW's loader sees its context.
@(private)
load_gl :: proc() {
	set_proc_address :: proc(p: rawptr, name: cstring) {
		(^rawptr)(p)^ = glfw.GetProcAddress(name)
	}
	gl.load_up_to(3, 3, set_proc_address)
	gl.load_4_1(set_proc_address) // for program binaries, where the driver has them (see init_program_cache)
}

@(private)
set_swap_interval :: proc(on: bool) {
	glfw.SwapInterval(1 if on else 0)
}

// Wayland has no window positions, so raylib's borderless mode can't be steered to a monitor
// (see fill_monitor): the window is made full screen on it directly, as raylib does on the
// monitor it picks. False elsewhere.
@(private)
fill_monitor_wayland :: proc(monitor: int) -> bool {
	if glfw.GetPlatform() != glfw.PLATFORM_WAYLAND {
		return false
	}
	window := glfw.GetCurrentContext() // raylib's
	monitors := glfw.GetMonitors()
	mode := glfw.GetVideoMode(monitors[monitor])
	if window == nil || mode == nil {
		return false
	}
	glfw.SetWindowAttrib(window, glfw.DECORATED, 0)
	glfw.SetWindowMonitor(window, monitors[monitor], 0, 0, mode.width, mode.height, mode.refresh_rate)
	glfw.FocusWindow(window)
	return true
}
