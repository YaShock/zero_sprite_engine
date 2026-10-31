package main

import "core:math/linalg"
import "core:math/rand"
import "core:slice"

BOT_THINK_INTERVAL :: [2]f32{1.5, 3}
BOT_SAFETY_MARGIN :: 1.15 // sends this much more than the expected defense
BOT_MAX_SEND :: 0.75 // never empties a planet completely

Bot :: struct {
	player: int,
	timer:  f32,
}

update_bots :: proc(dt: f32) {
	for b in 0 ..< game.bot_count {
		bot := &game.bots[b]
		bot.timer -= dt
		if bot.timer <= 0 {
			bot.timer = rand.float32_range(BOT_THINK_INTERVAL[0], BOT_THINK_INTERVAL[1])
			bot_think(bot.player)
		}
	}
}

// Ships of `player` already flying to planet `target`.
incoming :: proc(target, player: int) -> f32 {
	total: f32
	for s in game.ships {
		if s.target == target && s.owner == player {
			total += f32(s.value)
		}
	}
	return total
}

// Ships the defender is expected to have when an attack from `distance` away lands.
expected_defense :: proc(target, player: int, distance: f32) -> f32 {
	p := game.planets[target]
	growth := p.production * distance / SHIP_SPEED if p.owner != NEUTRAL else 0
	return p.ships + growth - incoming(target, player)
}

// Picks the most valuable planet relative to its defense and distance, then attacks it from
// the nearest own planets once they can muster enough ships.
bot_think :: proc(player: int) {
	Source :: struct {
		index:    int,
		distance: f32,
	}
	best, best_need, best_score := -1, f32(0), f32(0)
	for p, i in game.planets {
		if p.owner == player {
			continue
		}
		nearest := f32(-1)
		for q in game.planets {
			if q.owner == player {
				d := linalg.length(q.pos - p.pos)
				nearest = d if nearest < 0 else min(nearest, d)
			}
		}
		if nearest < 0 {
			return // no planets left to send from
		}
		defense := expected_defense(i, player, nearest)
		if defense < 0 {
			continue // already taken care of
		}
		value := p.production * (1 if p.owner == NEUTRAL else 1.5)
		score := value / (defense + 8) / (1 + nearest / 250)
		if score > best_score {
			best, best_need, best_score = i, defense * BOT_SAFETY_MARGIN + 3, score
		}
	}
	if best < 0 {
		return
	}

	sources := make([dynamic]Source, context.temp_allocator)
	available: f32
	for q, i in game.planets {
		if q.owner == player {
			append(&sources, Source{i, linalg.length(q.pos - game.planets[best].pos)})
			available += q.ships * BOT_MAX_SEND
		}
	}
	if available < best_need {
		return // build up first
	}
	slice.sort_by(sources[:], proc(a, b: Source) -> bool {return a.distance < b.distance})
	need := best_need
	for s in sources {
		ships := game.planets[s.index].ships
		if need <= 0 || ships < 2 {
			continue
		}
		fraction := clamp(need / ships, 0.2, BOT_MAX_SEND)
		need -= ships * fraction
		send_fleet(s.index, best, fraction)
	}
}
