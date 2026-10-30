package main

import eng "../../engine"
import fx "../../engine/vfx"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import rl "vendor:raylib"

SCREEN_WIDTH :: 960
SCREEN_HEIGHT :: 720

HUD_HEIGHT :: 48
WALL :: 16
FIELD_LEFT :: WALL
FIELD_RIGHT :: SCREEN_WIDTH - WALL
FIELD_TOP :: HUD_HEIGHT + WALL

BRICK_ROWS :: 6
BRICK_COLS :: 12
BRICK_MARGIN :: 20
BRICK_WIDTH :: f32(FIELD_RIGHT - FIELD_LEFT - 2 * BRICK_MARGIN) / BRICK_COLS
BRICK_HEIGHT :: 26
BRICKS_TOP :: FIELD_TOP + 50

PADDLE_SIZE :: eng.Vector2{130, 18}
PADDLE_Y :: SCREEN_HEIGHT - 50
PADDLE_SPEED :: 520

BALL_RADIUS :: 9
BALL_SPEED :: 430
BALL_MAX_SPEED :: 760
BALL_SPEEDUP :: 6 // per brick hit
MAX_BOUNCE_ANGLE :: math.PI / 3
PHYSICS_SUBSTEPS :: 4

LIVES :: 3

// Layers, back to front.
Z_BACKGROUND :: 0
Z_FRAME :: 1
Z_BRICKS :: 2
Z_EFFECTS :: 3
Z_BALL :: 4
Z_TEXT :: 5

ROW_KINDS := [BRICK_ROWS]BrickKind{.Crystal, .Metal, .Lava, .Moss, .Sandstone, .Clay}
BRICK_HP := [BrickKind]int {
	.Crystal   = 2,
	.Metal     = 2,
	.Lava      = 1,
	.Moss      = 1,
	.Sandstone = 1,
	.Clay      = 1,
}
BRICK_SCORE := [BrickKind]int {
	.Crystal   = 60,
	.Metal     = 50,
	.Lava      = 40,
	.Moss      = 30,
	.Sandstone = 20,
	.Clay      = 10,
}

GameState :: enum {
	Serve, // ball rests on the paddle until launched
	Playing,
	Paused,
	Won,
	Lost,
}

Brick :: struct {
	id:   int,
	kind: BrickKind,
	hp:   int,
	seed: f32,
}

Game :: struct {
	state:       GameState,
	background:  int,
	paddle:      int,
	ball:        int,
	score_text:  int,
	message:     int,
	life_orbs:   [dynamic]int,
	bricks:      [dynamic]Brick,
	ball_vel:    eng.Vector2,
	ball_speed:  f32,
	score:       int,
	last_mouse:  eng.Vector2,
}

game: Game

create_level :: proc() {
	eng.clear_scene()
	clear(&game.bricks)
	clear(&game.life_orbs)
	game.score = 0
	game.ball_speed = BALL_SPEED
	game.last_mouse = eng.mouse_position()

	game.background = eng.add_entity(
		wall_background_look(),
		{SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2},
		{SCREEN_WIDTH, SCREEN_HEIGHT},
		{z_index = Z_BACKGROUND},
	)
	eng.add_entity(hud_band_look(), {SCREEN_WIDTH / 2, HUD_HEIGHT / 2}, {SCREEN_WIDTH, HUD_HEIGHT}, {z_index = Z_FRAME})

	side_height := f32(SCREEN_HEIGHT - HUD_HEIGHT)
	side_y := f32(HUD_HEIGHT) + side_height / 2
	eng.add_entity(pipe_look(true), {WALL / 2, side_y}, {WALL, side_height}, {z_index = Z_FRAME})
	eng.add_entity(pipe_look(true), {SCREEN_WIDTH - WALL / 2, side_y}, {WALL, side_height}, {z_index = Z_FRAME})
	eng.add_entity(pipe_look(false), {SCREEN_WIDTH / 2, HUD_HEIGHT + WALL / 2}, {SCREEN_WIDTH, WALL}, {z_index = Z_FRAME})

	for row in 0 ..< BRICK_ROWS {
		kind := ROW_KINDS[row]
		for col in 0 ..< BRICK_COLS {
			seed := f32(row * BRICK_COLS + col) * 1.618
			pos := eng.Vector2 {
				FIELD_LEFT + BRICK_MARGIN + BRICK_WIDTH * (f32(col) + 0.5),
				BRICKS_TOP + BRICK_HEIGHT * (f32(row) + 0.5),
			}
			look := brick_look(kind, seed, fx.param("damage", f32(0)), fx.param("hit_time", f32(-100)))
			id := eng.add_entity(look, pos, {BRICK_WIDTH, BRICK_HEIGHT}, {z_index = Z_BRICKS})
			eng.set_collider(id, eng.RectCollider{})
			append(&game.bricks, Brick{id = id, kind = kind, hp = BRICK_HP[kind], seed = seed})
		}
	}

	game.paddle = eng.add_entity(paddle_look(), {SCREEN_WIDTH / 2, PADDLE_Y}, PADDLE_SIZE, {z_index = Z_BRICKS, pad = 14})
	eng.set_collider(game.paddle, eng.RectCollider{})

	game.ball = eng.add_entity(ball_look(BALL_RADIUS), {}, {BALL_RADIUS * 2, BALL_RADIUS * 2}, {z_index = Z_BALL, pad = 48})
	eng.set_collider(game.ball, eng.CircleCollider{radius = BALL_RADIUS})

	for i in 0 ..< LIVES {
		orb := eng.add_entity(
			ball_look(7),
			{SCREEN_WIDTH - 30 - f32(i) * 26, HUD_HEIGHT / 2},
			{14, 14},
			{z_index = Z_FRAME, pad = 24},
		)
		append(&game.life_orbs, orb)
	}

	game.score_text = eng.add_text("", {24, HUD_HEIGHT / 2}, 24, TEXT_CREAM, Z_TEXT)
	game.message = eng.add_text("", {SCREEN_WIDTH / 2, SCREEN_HEIGHT * 0.62}, 28, TEXT_LIGHT, Z_TEXT, .Center)
	update_score(0)
	set_state(.Serve)
}

set_state :: proc(state: GameState) {
	game.state = state
	eng.set_time_scale(0 if state == .Paused else 1)
	messages := [GameState]string {
		.Serve   = "SPACE to launch  -  A/D, arrows or mouse to move",
		.Playing = "",
		.Paused  = "PAUSED  -  SPACE to resume",
		.Won     = "VICTORY!  -  R to play again",
		.Lost    = "DEFEAT!  -  R to try again",
	}
	eng.set_text(game.message, messages[state])
}

update_score :: proc(delta: int) {
	game.score += delta
	eng.set_text(game.score_text, fmt.tprintf("SCORE %05d", game.score))
}

move_paddle :: proc(dt: f32) {
	paddle := eng.get_entity(game.paddle)
	dir: f32
	if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT) {
		dir -= 1
	}
	if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) {
		dir += 1
	}
	paddle.pos.x += dir * PADDLE_SPEED * dt

	mouse := eng.mouse_position()
	if mouse != game.last_mouse {
		paddle.pos.x = mouse.x
		game.last_mouse = mouse
	}
	half := PADDLE_SIZE.x / 2
	paddle.pos.x = clamp(paddle.pos.x, FIELD_LEFT + half, FIELD_RIGHT - half)
}

launch_ball :: proc() {
	angle := rand.float32_range(-0.4, 0.4)
	game.ball_vel = {math.sin(angle), -math.cos(angle)} * game.ball_speed
	set_state(.Playing)
}

// Keeps the ball from settling into near-horizontal paths.
set_ball_direction :: proc(dir: eng.Vector2) {
	d := linalg.normalize(dir)
	min_vertical: f32 : 0.3
	if abs(d.y) < min_vertical {
		d.y = math.copy_sign(min_vertical, d.y if d.y != 0 else -1)
		d.x = math.copy_sign(math.sqrt(1 - min_vertical * min_vertical), d.x)
	}
	game.ball_vel = d * game.ball_speed
}

step_ball :: proc(dt: f32) {
	ball := eng.get_entity(game.ball)
	ball.pos += game.ball_vel * dt

	if ball.pos.x - BALL_RADIUS < FIELD_LEFT {
		ball.pos.x = FIELD_LEFT + BALL_RADIUS
		game.ball_vel.x = abs(game.ball_vel.x)
	} else if ball.pos.x + BALL_RADIUS > FIELD_RIGHT {
		ball.pos.x = FIELD_RIGHT - BALL_RADIUS
		game.ball_vel.x = -abs(game.ball_vel.x)
	}
	if ball.pos.y - BALL_RADIUS < FIELD_TOP {
		ball.pos.y = FIELD_TOP + BALL_RADIUS
		game.ball_vel.y = abs(game.ball_vel.y)
	}
	if ball.pos.y - BALL_RADIUS > SCREEN_HEIGHT {
		lose_ball(ball.pos)
		return
	}

	paddle := eng.get_entity(game.paddle)
	if contact, hit := eng.collide(ball, paddle); hit && game.ball_vel.y > 0 {
		if contact.normal.y < -0.5 {
			// Top face: the further from the center, the steeper the bounce.
			offset := clamp((ball.pos.x - paddle.pos.x) / (PADDLE_SIZE.x / 2), -1, 1)
			angle := offset * MAX_BOUNCE_ANGLE
			set_ball_direction({math.sin(angle), -math.cos(angle)})
			ball.pos.y = paddle.pos.y - PADDLE_SIZE.y / 2 - BALL_RADIUS
		} else {
			ball.pos += contact.normal * contact.depth
			game.ball_vel = linalg.reflect(game.ball_vel, contact.normal)
		}
		eng.set_param(game.paddle, "hit_time", eng.time())
		contact_point := eng.Vector2{ball.pos.x, paddle.pos.y - PADDLE_SIZE.y / 2}
		eng.add_entity(
			spark_burst_look(SPARK_BLUE, -math.PI / 2, 1.0, rand.float32() * 100, 14),
			contact_point,
			{0, 0},
			{z_index = Z_EFFECTS, pad = 90, lifetime = 0.6, blend = .Additive},
		)
	}

	for brick, i in game.bricks {
		brick_entity := eng.get_entity(brick.id)
		contact, hit := eng.collide(ball, brick_entity)
		if !hit {
			continue
		}
		ball.pos += contact.normal * contact.depth
		if linalg.dot(game.ball_vel, contact.normal) < 0 {
			game.ball_vel = linalg.reflect(game.ball_vel, contact.normal)
		}
		hit_brick(i, ball.pos - contact.normal * BALL_RADIUS)
		game.ball_speed = min(game.ball_speed + BALL_SPEEDUP, BALL_MAX_SPEED)
		set_ball_direction(game.ball_vel)
		break
	}
}

hit_brick :: proc(index: int, impact: eng.Vector2) {
	brick := &game.bricks[index]
	brick.hp -= 1
	if brick.hp > 0 {
		eng.set_param(brick.id, "damage", 1 - f32(brick.hp) / f32(BRICK_HP[brick.kind]))
		eng.set_param(brick.id, "hit_time", eng.time())
		eng.add_shake(1.5)
		update_score(5)
		return
	}

	e := eng.get_entity(brick.id)
	eng.add_entity(
		explosion_look(brick.kind, brick.seed, impact - e.pos),
		e.pos,
		e.size,
		{z_index = Z_EFFECTS, pad = 170, lifetime = 1.2},
	)
	eng.add_shake(3)
	update_score(BRICK_SCORE[brick.kind])
	eng.remove_entity(brick.id)
	unordered_remove(&game.bricks, index)

	if len(game.bricks) == 0 {
		eng.get_entity(game.ball).visible = false
		set_state(.Won)
	}
}

lose_ball :: proc(pos: eng.Vector2) {
	eng.add_entity(
		shockwave_look(ALARM_RED, 500),
		{pos.x, SCREEN_HEIGHT},
		{0, 0},
		{z_index = Z_EFFECTS, pad = 400, lifetime = 1.2, blend = .Additive},
	)
	eng.add_shake(9)

	orb := pop(&game.life_orbs)
	eng.remove_entity(orb)
	if len(game.life_orbs) == 0 {
		eng.get_entity(game.ball).visible = false
		set_state(.Lost)
	} else {
		game.ball_speed = BALL_SPEED
		set_state(.Serve)
	}
}

on_update :: proc(dt: f32) {
	switch game.state {
	case .Serve:
		if rl.IsKeyPressed(.SPACE) || rl.IsMouseButtonPressed(.LEFT) {
			launch_ball()
		}
	case .Playing:
		if rl.IsKeyPressed(.SPACE) {
			set_state(.Paused)
			return
		}
	case .Paused:
		if rl.IsKeyPressed(.SPACE) {
			set_state(.Playing)
		}
		return
	case .Won, .Lost:
		if rl.IsKeyPressed(.R) {
			create_level()
		}
		return
	}

	move_paddle(dt)

	ball := eng.get_entity(game.ball)
	if game.state == .Serve {
		paddle := eng.get_entity(game.paddle)
		ball.pos = {paddle.pos.x, paddle.pos.y - PADDLE_SIZE.y / 2 - BALL_RADIUS - 1}
		game.ball_vel = {}
	} else {
		for _ in 0 ..< PHYSICS_SUBSTEPS {
			if game.state != .Playing {
				break
			}
			step_ball(dt / PHYSICS_SUBSTEPS)
		}
	}

	eng.set_param(game.ball, "velocity", game.ball_vel)
	eng.set_param(game.background, "light", ball.pos)
}

main :: proc() {
	eng.init_context(
		eng.InitOptions {
			width = SCREEN_WIDTH,
			height = SCREEN_HEIGHT,
			fps = 60,
			title = "Breakout",
			num_layers = 6,
			bg_color = rl.BLACK,
			resizable = true,
		},
	)
	create_level()
	eng.run(on_update)
}
