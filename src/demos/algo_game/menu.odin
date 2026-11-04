package main

// The quit menu: Escape opens it over the game, which stands still behind it. Yes quits,
// No plays on; Enter or Y quits, Escape or N closes it, the arrow keys or Tab change the
// highlighted button, and the mouse works too.

import eng "../../engine"
import fx "../../engine/vfx"
import "core:math"
import rl "vendor:raylib"

MENU_YES :: 0
MENU_NO :: 1

Menu :: struct {
	open:    bool,
	choice:  int, // MENU_YES or MENU_NO: the highlighted button
	dim:     int, // darkens the game
	panel:   int,
	buttons: [2]int, // Yes, No
	labels:  [2]int,
	title:   int,
	keys:    int, // the key hint under the buttons
	mouse:   eng.Vector2, // where the mouse was last frame: only moving it highlights a button
}

menu: Menu

menu_dim_look :: proc() -> ^fx.Node {
	return fx.mask(MENU_DIM, f32(1))
}

menu_panel_look :: proc() -> ^fx.Node {
	d := fx.sd_box(fx.coord(), fx.sub(fx.mul(fx.size(), 0.5), 2), fx.param("radius", f32(12)))
	return fx.stack(fx.mask(MENU_PANEL, fx.fill(d)), fx.mask(MENU_BORDER, fx.stroke(d, 1.5)))
}

// A rounded button, lit up while `hover` is 1; its glow fades out within the margin around the box
menu_button_look :: proc() -> ^fx.Node {
	hover := fx.param("hover", f32(0))
	d := fx.sd_box(fx.coord(), fx.sub(fx.mul(fx.size(), 0.5), 12), fx.param("radius", f32(8)))
	halo := fx.mask(MENU_BUTTON_GLOW, fx.mul(fx.glow(d, 2.5), fx.mul(hover, 0.35)))
	body := fx.mask(fx.mix(MENU_BUTTON, MENU_BUTTON_HOVER, hover), fx.fill(d))
	border := fx.mask(fx.mix(MENU_BORDER, MENU_BUTTON_GLOW, hover), fx.stroke(d, 1.5))
	return fx.stack(halo, body, border)
}

// Makes the menu's entities, hidden (its shaders compile now, not when Escape is pressed)
init_menu :: proc() {
	menu.dim = eng.add_entity(menu_dim_look(), {}, {1, 1}, {z_index = LAYER_MENU})
	menu.panel = eng.add_entity(menu_panel_look(), {}, {1, 1}, {z_index = LAYER_MENU})
	for i in 0 ..< 2 {
		menu.buttons[i] = eng.add_entity(menu_button_look(), {}, {1, 1}, {z_index = LAYER_MENU})
		menu.labels[i] = eng.add_text("Yes" if i == MENU_YES else "No", {}, 20, SCORE, LAYER_MENU_TEXT, .Center)
	}
	menu.title = eng.add_text("Quit the game?", {}, 20, SCORE, LAYER_MENU_TEXT, .Center)
	menu.keys = eng.add_text("Enter: choose     Esc: back to the game", {}, 14, TEXT, LAYER_MENU_TEXT, .Center)
	show_menu(false)
}

// Opens or closes the menu, pausing or resuming the game
show_menu :: proc(open: bool) {
	menu.open = open
	for id in ([?]int{menu.dim, menu.panel, menu.buttons[0], menu.buttons[1], menu.labels[0], menu.labels[1], menu.title, menu.keys}) {
		eng.get_entity(id).visible = open
	}
	eng.set_time_scale(0 if open else 1)
}

// Handles the menu's keys and mouse. Returns whether the menu was open this frame, including
// the frame it closes, so the key or click that closed it isn't taken as thrust.
update_menu :: proc() -> bool {
	if !menu.open {
		if !rl.IsKeyPressed(.ESCAPE) {
			return false
		}
		show_menu(true)
		menu.choice = MENU_NO
		menu.mouse = eng.mouse_position()
		place_menu()
		return true
	}
	mouse := eng.mouse_position()
	hovered := -1
	for id, i in menu.buttons {
		e := eng.get_entity(id)
		if abs(mouse.x - e.pos.x) <= e.size.x / 2 && abs(mouse.y - e.pos.y) <= e.size.y / 2 {
			hovered = i
		}
	}
	if hovered >= 0 && mouse != menu.mouse {
		menu.choice = hovered
	}
	menu.mouse = mouse
	for key in ([?]rl.KeyboardKey{.LEFT, .RIGHT, .UP, .DOWN, .TAB, .A, .D}) {
		if rl.IsKeyPressed(key) {
			menu.choice = 1 - menu.choice
		}
	}
	chosen := -1
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) || rl.IsKeyPressed(.SPACE) {
		chosen = menu.choice
	}
	if rl.IsMouseButtonPressed(.LEFT) && hovered >= 0 {
		chosen = hovered
	}
	if rl.IsKeyPressed(.Y) {
		chosen = MENU_YES
	}
	if rl.IsKeyPressed(.N) || rl.IsKeyPressed(.ESCAPE) {
		chosen = MENU_NO
	}
	switch chosen {
	case MENU_YES:
		eng.quit()
	case MENU_NO:
		show_menu(false)
		return true
	}
	place_menu()
	return true
}

// Lays the menu out in the middle of the screen, sized like the game's text
place_menu :: proc() {
	screen := eng.screen_size()
	s := screen.y / VIEW_HEIGHT // pixels per world unit
	center := screen / 2
	dim := eng.get_entity(menu.dim)
	dim.pos, dim.size = center, screen
	panel := eng.get_entity(menu.panel)
	panel.pos, panel.size = center, {8 * s, 4.4 * s}
	eng.set_param(menu.panel, "radius", 0.3 * s)
	place_text(menu.title, center - {0, 1.6 * s}, 0.7 * s)
	for id, i in menu.buttons {
		e := eng.get_entity(id)
		at := center + {(-1.5 if i == MENU_YES else 1.5) * s, 0.35 * s}
		e.pos, e.size = at, {2.6 * s + 24, 1.1 * s + 24} // 12 pixels of glow margin around the box
		eng.set_param(id, "radius", 0.2 * s)
		eng.set_param(id, "hover", f32(1) if i == menu.choice else f32(0))
		place_text(menu.labels[i], at - {0, 0.26 * s}, 0.52 * s)
	}
	place_text(menu.keys, center + {0, 1.35 * s}, math.max(0.32 * s, 12))
}
