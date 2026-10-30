package main

// Balance tables: towers, enemies and wave composition.

TowerKind :: enum {
	Fire,
	Ice,
	Lightning,
}

TOWER_LEVELS :: 3

TowerLevel :: struct {
	cost:     int, // price of buying (level 1) or upgrading to this level
	range:    f32,
	cooldown: f32, // seconds between shots
	damage:   f32, // on impact
	effect:   f32, // Fire: burn damage/s, Ice: slow fraction, Lightning: bounces
	duration: f32, // seconds the burn / slow lasts
	speed:    f32, // projectile speed
}

TowerInfo :: struct {
	name:        string,
	description: string,
	levels:      [TOWER_LEVELS]TowerLevel,
}

TOWERS := [TowerKind]TowerInfo {
	.Fire = {
		name = "Fire",
		description = "burns over time",
		levels = {
			{cost = 60, range = 110, cooldown = 1.0, damage = 8, effect = 6, duration = 3, speed = 320},
			{cost = 55, range = 125, cooldown = 0.85, damage = 12, effect = 11, duration = 3.5, speed = 340},
			{cost = 95, range = 140, cooldown = 0.7, damage = 18, effect = 18, duration = 4, speed = 360},
		},
	},
	.Ice = {
		name = "Ice",
		description = "slows enemies",
		levels = {
			{cost = 50, range = 120, cooldown = 0.9, damage = 5, effect = 0.35, duration = 2, speed = 420},
			{cost = 45, range = 135, cooldown = 0.8, damage = 8, effect = 0.45, duration = 2.5, speed = 440},
			{cost = 80, range = 150, cooldown = 0.7, damage = 12, effect = 0.55, duration = 3, speed = 460},
		},
	},
	.Lightning = {
		name = "Lightning",
		description = "jumps between foes",
		levels = {
			{cost = 80, range = 130, cooldown = 1.4, damage = 16, effect = 2, speed = 620},
			{cost = 70, range = 145, cooldown = 1.2, damage = 22, effect = 3, speed = 660},
			{cost = 120, range = 160, cooldown = 1.0, damage = 30, effect = 4, speed = 700},
		},
	},
}

BOUNCE_RANGE :: 140
BOUNCE_FALLOFF :: 0.8 // damage multiplier per lightning bounce
SELL_REFUND :: 0.6

EnemyKind :: enum {
	Mud,
	Stone,
	Crystal,
	Iron,
	Magma,
}

EnemyInfo :: struct {
	size:   [2]f32,
	hp:     f32,
	speed:  f32, // units/s along the road
	reward: int,
}

ENEMIES := [EnemyKind]EnemyInfo {
	.Mud     = {size = {30, 38}, hp = 40, speed = 46, reward = 6},
	.Stone   = {size = {34, 42}, hp = 95, speed = 38, reward = 10},
	.Crystal = {size = {28, 36}, hp = 70, speed = 72, reward = 12},
	.Iron    = {size = {38, 46}, hp = 200, speed = 32, reward = 16},
	.Magma   = {size = {56, 66}, hp = 900, speed = 26, reward = 80},
}

WAVE_COUNT :: 15
WAVE_BREAK :: 12 // seconds between waves, skippable

Wave :: struct {
	enemies:        [dynamic]EnemyKind, // in spawn order
	interval:       f32,
	health_scale:   f32,
	clear_bonus:    int,
}

// Waves get longer, mix in tougher golems and scale everyone's health; every fifth wave
// ends with magma bosses.
make_wave :: proc(n: int, allocator := context.allocator) -> Wave {
	w := Wave {
		enemies      = make([dynamic]EnemyKind, allocator),
		interval     = max(0.45, 1.05 - f32(n) * 0.035),
		health_scale = 1 + 0.16 * f32(n - 1) + 0.02 * f32((n - 1) * (n - 1)),
		clear_bonus  = 20 + 5 * n,
	}
	count := min(6 + 2 * n, 32)
	for i in 0 ..< count {
		kind := EnemyKind.Mud
		switch {
		case n >= 6 && i % 4 == 3:
			kind = .Iron
		case n >= 4 && i % 5 == 1:
			kind = .Crystal
		case n >= 3 && i % 2 == 1:
			kind = .Stone
		case n >= 10:
			kind = .Stone
		}
		append(&w.enemies, kind)
	}
	if n % 5 == 0 {
		for _ in 0 ..< n / 5 {
			append(&w.enemies, EnemyKind.Magma)
		}
	}
	return w
}
