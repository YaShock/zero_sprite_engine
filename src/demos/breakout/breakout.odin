package main

import eng "../../engine"
import "core:math"
import "core:math/rand"
import rl "vendor:raylib"

SCREEN_WIDTH :: 800
SCREEN_HEIGHT :: 600

BRICK_HEIGHT :: 20
BALL_RADIUS :: 8

BRICK_ROWS :: 4
BRICK_COLS :: 15

// fBm color pairs per row: [dark, light]
BRICK_ROW_COLORS := [BRICK_ROWS][2]rl.Color {
	{{90, 90, 95, 255}, {200, 200, 210, 255}}, // stone gray
	{{130, 100, 65, 255}, {215, 185, 135, 255}}, // warm sandstone
	{{65, 95, 70, 255}, {135, 175, 125, 255}}, // mossy green
	{{120, 55, 45, 255}, {205, 115, 95, 255}}, // rusty red
}
BRICK_OUTLINE_COLORS := [BRICK_ROWS]rl.Color {
	{40, 40, 45, 255},
	{80, 55, 30, 255},
	{35, 55, 40, 255},
	{70, 25, 20, 255},
}

MARGIN :: 10

MOVESPEED :: 300
BALL_MOVESPEED :: 400

PARTICLE_GRAVITY :: f32(320)
PARTICLE_COLS :: 4
PARTICLE_ROWS :: 2

Particle :: struct {
	id:           int,
	vel:          rl.Vector2,
	rot_vel:      f32, // degrees/sec
	lifetime:     f32,
	max_lifetime: f32,
}

GameState :: enum {
	Playing,
	Won,
	Lost,
	Pause,
}

Game :: struct {
	player_id:     int,
	ball_id:       int,
	ball_velocity: rl.Vector2,
	brick_ids:     [dynamic]int,
	game_state:    GameState,
}

player_collider: eng.Collider
ball_collider: eng.Collider
brick_colliders: map[int]eng.Collider

game: Game
particles: [dynamic]Particle

create_level := proc() {
	game.game_state = .Playing
	game.brick_ids = make([dynamic]int)
	reserve(&game.brick_ids, BRICK_ROWS * BRICK_COLS)
	particles = make([dynamic]Particle)

	brick_width := (SCREEN_WIDTH - MARGIN) / BRICK_COLS
	for i in 0 ..< BRICK_ROWS {
		for j in 0 ..< BRICK_COLS {
			brick_id := eng.add_rect_shape(
				{MARGIN + f32(brick_width * j), MARGIN + f32(BRICK_HEIGHT * i)},
				{f32(brick_width), BRICK_HEIGHT},
				.FillOutline,
				rl.BROWN,
				BRICK_OUTLINE_COLORS[i],
				1,
				1,
			)
			eng.get_drawable(brick_id, eng.RectShape).fbm = eng.FbmParams {
				octaves    = 4,
				frequency  = 0.07,
				lacunarity = 2.0,
				gain       = 0.5,
				color_a    = BRICK_ROW_COLORS[i][0],
				color_b    = BRICK_ROW_COLORS[i][1],
				cell_size  = 2,
				seed       = f32(i) * 17.3 + f32(j) * 3.1,
			}
			append(&game.brick_ids, brick_id)

			brick_colliders[brick_id] = eng.make_rect_collider(
				{0, 0},
				{f32(brick_width), BRICK_HEIGHT},
			)
			eng.set_collider(brick_id, brick_colliders[brick_id])
		}
	}

	center_bot := rl.Vector2 {
		f32(SCREEN_WIDTH / 2 - brick_width / 2),
		SCREEN_HEIGHT - BRICK_HEIGHT - MARGIN,
	}
	center := rl.Vector2{f32(SCREEN_WIDTH / 2), f32(SCREEN_HEIGHT / 2)}

	game.player_id = eng.add_rect_shape(
		center_bot,
		{f32(brick_width), BRICK_HEIGHT},
		.FillOutline,
		rl.RED,
		rl.BROWN,
		1,
		1,
	)

	game.ball_id = eng.add_circle_shape(center, BALL_RADIUS, .Fill, rl.GREEN, rl.GREEN, 1, 1)
	game.ball_velocity.y = f32(BALL_MOVESPEED)

	player_collider = eng.make_rect_collider({0, 0}, {f32(brick_width), BRICK_HEIGHT})
	eng.set_collider(game.player_id, player_collider)

	ball_collider = eng.make_circle_collider({0, 0}, BALL_RADIUS)
	eng.set_collider(game.ball_id, ball_collider)
}

spawn_particles :: proc(pos, size: rl.Vector2, color: rl.Color) {
	cell_w := size.x / PARTICLE_COLS
	cell_h := size.y / PARTICLE_ROWS
	brick_center := rl.Vector2{pos.x + size.x * 0.5, pos.y + size.y * 0.5}

	for row in 0 ..< PARTICLE_ROWS {
		for col in 0 ..< PARTICLE_COLS {
			pw := cell_w * rand.float32_range(0.5, 0.85)
			ph := cell_h * rand.float32_range(0.5, 0.85)
			px := pos.x + f32(col) * cell_w + rand.float32_range(0, cell_w - pw)
			py := pos.y + f32(row) * cell_h + rand.float32_range(0, cell_h - ph)

			cell_center := rl.Vector2 {
				pos.x + (f32(col) + 0.5) * cell_w,
				pos.y + (f32(row) + 0.5) * cell_h,
			}
			dir := rl.Vector2Normalize(cell_center - brick_center)
			speed := rand.float32_range(80, 220)
			vel := rl.Vector2 {
				dir.x * speed + rand.float32_range(-25, 25),
				dir.y * speed + rand.float32_range(-25, 25),
			}

			lifetime := rand.float32_range(0.4, 0.7)
			id := eng.add_rect_shape({px, py}, {pw, ph}, .Fill, color, rl.BLACK, 1, 1)
			append(
				&particles,
				Particle {
					id = id,
					vel = vel,
					rot_vel = rand.float32_range(-240, 240),
					lifetime = lifetime,
					max_lifetime = lifetime,
				},
			)
		}
	}
}

update_particles :: proc(dt: f32) {
	i := 0
	for i < len(particles) {
		p := &particles[i]
		p.lifetime -= dt
		if p.lifetime <= 0 {
			eng.remove_scene_object(p.id)
			unordered_remove(&particles, i)
			continue
		}

		obj := eng.get_render_object(p.id)
		obj.pos.x += p.vel.x * dt
		obj.pos.y += p.vel.y * dt
		obj.rotation += p.rot_vel * dt
		p.vel.y += PARTICLE_GRAVITY * dt

		t := p.lifetime / p.max_lifetime
		eng.get_drawable(p.id, eng.RectShape).fill_color.a = u8(t * 255)

		i += 1
	}
}

do_brick_collision := proc(
	brick_obj, ball_obj: ^eng.RenderObject,
	delta_time: f32,
	is_player: bool,
) {
	player_center_x := brick_obj.pos.x + brick_obj.size.x / 2
	ball_center_x := ball_obj.pos.x + (ball_obj.size.x / 2)
	offset := (ball_center_x - player_center_x) / (brick_obj.size.x / 2)
	max_angle := math.PI / 3
	angle := f64(offset) * max_angle
	vx := f64(BALL_MOVESPEED) * math.sin(angle)
	vy := -f64(BALL_MOVESPEED) * math.cos(angle)

	game.ball_velocity.x = f32(vx) * delta_time
	game.ball_velocity.y = f32(vy) * delta_time
	game.ball_velocity = rl.Vector2Normalize(game.ball_velocity)
	game.ball_velocity.x *= f32(BALL_MOVESPEED)
	game.ball_velocity.y *= f32(BALL_MOVESPEED)

	if !is_player {
		game.ball_velocity.y = -game.ball_velocity.y
	}
}

check_collision := proc(player_obj, ball_obj: ^eng.RenderObject, delta_time: f32) {
	if eng.check_collision(player_obj, ball_obj) {
		do_brick_collision(player_obj, ball_obj, delta_time, true)
	} else if ball_obj.pos.y + BALL_RADIUS <= MARGIN {
		game.ball_velocity.y = -game.ball_velocity.y
	} else if ball_obj.pos.x + BALL_RADIUS <= MARGIN {
		game.ball_velocity.x = -game.ball_velocity.x
	} else if ball_obj.pos.x - BALL_RADIUS >= SCREEN_WIDTH - MARGIN {
		game.ball_velocity.x = -game.ball_velocity.x
	}

	to_remove_id := -1
	to_remove_idx := -1

	for brick_id, idx in game.brick_ids {
		brick_obj := eng.get_render_object(brick_id)
		if eng.check_collision(brick_obj, ball_obj) {
			do_brick_collision(brick_obj, ball_obj, delta_time, false)
			to_remove_id = brick_id
			to_remove_idx = idx
			break
		}
	}
	if to_remove_id != -1 {
		brick_obj := eng.get_render_object(to_remove_id)
		d := eng.get_drawable(to_remove_id, eng.RectShape)
		brick_color: rl.Color
		if fbm_p, ok := d.fbm.?; ok {
			brick_color = eng.lerp_color(fbm_p.color_a, fbm_p.color_b, 0.6)
		} else {
			brick_color = d.fill_color
		}
		spawn_particles(brick_obj.pos, brick_obj.size, brick_color)
		eng.remove_scene_object(to_remove_id)
		unordered_remove(&game.brick_ids, to_remove_idx)
	}
}

on_update := proc(delta_time: f32) {
	if rl.IsKeyPressed(.SPACE) {
		if game.game_state == .Playing {
			game.game_state = .Pause
		}
		else if game.game_state == .Pause {
			game.game_state = .Playing
		}
	}

	if game.game_state != .Playing {
		return
	}

	velocity := eng.Vector2{0, 0}
	if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT) {
		velocity.x -= 1
	}
	if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) {
		velocity.x += 1
	}

	player_obj := eng.get_render_object(game.player_id)
	player_obj.pos.x += velocity.x * delta_time * f32(MOVESPEED)

	if player_obj.pos.x + velocity.x < MARGIN {
		player_obj.pos.x = MARGIN
	}
	if player_obj.pos.x + player_obj.size.x > SCREEN_WIDTH - MARGIN {
		player_obj.pos.x = SCREEN_WIDTH - player_obj.size.x - MARGIN
	}

	ball_obj := eng.get_render_object(game.ball_id)
	ball_obj.pos.x += game.ball_velocity.x * delta_time
	ball_obj.pos.y += game.ball_velocity.y * delta_time

	check_collision(player_obj, ball_obj, delta_time)
	update_particles(delta_time)

	if len(game.brick_ids) == 0 {
		game.game_state = .Won
		eng.add_text_object_align(
			"VICTORY!",
			{SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2},
			30,
			rl.GREEN,
			1,
			.Center,
		)
	}

	if ball_obj.pos.y - BALL_RADIUS > SCREEN_HEIGHT {
		game.game_state = .Lost
		eng.add_text_object_align(
			"DEFEAT!",
			{SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2},
			30,
			rl.RED,
			1,
			.Center,
		)
	}
}

main :: proc() {
	eng.init_context(
		eng.InitOptions {
			width = SCREEN_WIDTH,
			height = SCREEN_HEIGHT,
			fps = 60,
			title = "Breakout",
			resize_strategy = eng.ResizeStrategy.STATIC,
			num_layers = 2,
			bg_color = rl.BLACK,
		},
	)

	create_level()

	eng.run(on_update)
}
