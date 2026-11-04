package engine

import win "core:sys/windows"
import gl "vendor:OpenGL"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// On Windows raylib statically bundles GLFW, so the separate vendor:glfw library would be a
// second, uninitialized GLFW; GL is loaded through WGL instead and vsync goes through raylib.
rlGetShaderIdDefault :: rlgl.GetShaderIdDefault
rlDrawRenderBatchActive :: rlgl.DrawRenderBatchActive
rlEnableColorBlend :: rlgl.EnableColorBlend
rlDisableColorBlend :: rlgl.DisableColorBlend
rlGetMatrixModelview :: rlgl.GetMatrixModelview
rlGetMatrixProjection :: rlgl.GetMatrixProjection

@(private)
load_gl :: proc() {
	gl.load_up_to(3, 3, win.gl_set_proc_address)
	gl.load_4_1(win.gl_set_proc_address) // for program binaries, where the driver has them (see init_program_cache)
}

@(private)
set_swap_interval :: proc(on: bool) {
	if on {
		rl.SetWindowState({.VSYNC_HINT})
	} else {
		rl.ClearWindowState({.VSYNC_HINT})
	}
}

// Windows reports window positions, so raylib's own borderless mode finds the monitor.
@(private)
fill_monitor_wayland :: proc(monitor: int) -> bool {
	return false
}
