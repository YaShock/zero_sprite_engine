package main

// Goo on both walls, ported from index-pixi.html ("metaballs", GOO PHYSICS, DROPLETS): blobs
// whose fields add up, gathered in patches. Blobs near the ship become clusters of
// particles held together by springs; the hull pushes and drags them, springs snap, and
// small cut-off pieces are carried away by the cave's current as scoring droplets.

import "core:math"
import "core:slice"

METABALL_SPACING :: 3.2
GOO_PATCH_SCALE :: 28.0
GOO_PATCH_COVERAGE :: 0.35
GOO_PATCH_DENSITY :: 0.95
GOO_SPARSE_DENSITY :: 0.1
METABALL_MAX_PER_ROOT :: 3
METABALL_RADIUS_MIN :: 0.9
METABALL_RADIUS_MAX :: 1.8
METABALL_RISE :: 2.2
METABALL_DRIFT :: 0.8
METABALL_THRESHOLD :: 0.35
METABALL_WALL_REACH :: 0.8
METABALL_PERIOD :: 4.0

GOO_PARTICLES :: 8
GOO_RING_FRACTION :: 0.3
GOO_ACTIVATE_MARGIN :: 1.5
GOO_SPRING_STIFFNESS :: 40.0
GOO_SPRING_DAMPING :: 4.0
GOO_BREAK_STRETCH :: 1.5
GOO_REJOIN_DISTANCE :: 0.75
GOO_VISCOSITY :: 3.0
GOO_TETHER :: 30.0
GOO_HULL_FRICTION :: 6.0
GOO_COLLISION_RADIUS :: 0.5
GOO_REGROUP :: 6.0
GOO_SHOVE_STIFFNESS :: 6.0
GOO_SHOVE_REACH :: 0.9

DROPLET_MAX_PARTICLES :: 2
DROPLET_POINTS :: 10
DROPLET_FLIGHT_TIME :: 1.1
DROPLET_ARC :: 2.5
DROPLET_COLOR_TIME :: 0.4

Blob :: struct {
	key:       i64, // its own seed; 0 for a particle of a cluster
	x, y:      f64,
	radius:    f64,
}

Particle :: struct {
	x, y, vx, vy: f64,
}

Spring :: struct {
	i, j: int, // i < j
	rest: f64,
}

Cluster :: struct {
	key:       i64,
	side:      f64,
	particles: [dynamic]Particle,
	radius:    f64,
	springs:   [dynamic]Spring,
	bonded:    [dynamic]bool, // n × n, [i * n + j] for i < j
}

Droplet :: struct {
	t, radius:   f64,
	points:      int,
	start_x:     f64, // screen-fixed world units: the flight is a fixed path on screen
	start_y:     f64,
	offsets:     [DROPLET_MAX_PARTICLES][2]f64,
	n:           int,
}

// Noise value above which a wall is inside a goo patch, found by sampling the patch noise so
// that GOO_PATCH_COVERAGE of the wall ends up covered
goo_patch_threshold: f64
// Particle size relative to the blob's radius at which a cluster looks like its blob
goo_particle_scale: f64

init_goo :: proc() {
	samples := make([]f64, 20000, context.temp_allocator)
	for &s, i in samples {
		s = fractal_noise(12345, f64(i) * 0.137, 2)
	}
	slice.sort(samples)
	goo_patch_threshold = samples[math.min(len(samples) - 1, int(math.floor((1 - GOO_PATCH_COVERAGE) * f64(len(samples)))))]
	goo_particle_scale = compute_goo_particle_scale()
}

// The size at which the cluster's goo outline has the same average radius as the blob's
// (toward a ring particle and toward the gap between two), so switching is invisible
compute_goo_particle_scale :: proc() -> f64 {
	n, ring, T := GOO_PARTICLES, GOO_RING_FRACTION, METABALL_THRESHOLD
	visible := math.sqrt(1 - math.sqrt(T)) // a lone blob's outline radius
	points: [GOO_PARTICLES][2]f64
	for i in 0 ..< n - 1 {
		a := (2 * math.PI * f64(i)) / f64(n - 1)
		points[i + 1] = {math.cos(a) * ring, math.sin(a) * ring}
	}
	field :: proc(points: []([2]f64), k, x, y: f64) -> f64 {
		sum := 0.0
		for p in points {
			q := 1 - ((x - p.x) * (x - p.x) + (y - p.y) * (y - p.y)) / (k * k)
			if q > 0 {
				sum += q * q
			}
		}
		return sum
	}
	outline :: proc(points: []([2]f64), k, angle, T: f64) -> f64 {
		lo, hi := 0.0, 3.0
		for _ in 0 ..< 40 {
			m := (lo + hi) / 2
			if field(points, k, math.cos(angle) * m, math.sin(angle) * m) >= T {
				lo = m
			} else {
				hi = m
			}
		}
		return lo
	}
	lo, hi := 0.2, 1.5
	for _ in 0 ..< 40 {
		k := (lo + hi) / 2
		average := (outline(points[:], k, 0, T) + outline(points[:], k, math.PI / f64(n - 1), T)) / 2
		if average < visible {
			lo = k
		} else {
			hi = k
		}
	}
	return (lo + hi) / 2
}

// How much a spot on a wall is inside a goo patch: 0 between patches, 1 inside
goo_patch :: proc(seed: i64, side, x: f64) -> f64 {
	n := fractal_noise(seed + (8801 if side > 0 else 9901), x / GOO_PATCH_SCALE, 2)
	e, t := 0.04, goo_patch_threshold
	k := math.min(1, math.max(0, (n - (t - e)) / (2 * e)))
	return k * k * (3 - 2 * k)
}

// Goo blobs on one wall: each root carries 1..3 blobs that rise from the wall, sink back
// and drift sideways on slow noise; dense inside patches, sparse between them
metaballs_in_range :: proc(seed: i64, side, x0, x1, t: f64, out: ^[dynamic]Blob) {
	time := t / METABALL_PERIOD
	deco := seed + (808 if side > 0 else 909)
	reach := METABALL_DRIFT + METABALL_RADIUS_MAX
	roots := make([dynamic]Root, context.temp_allocator)
	roots_in_range(deco, x0 - reach, x1 + reach, METABALL_SPACING, 1, &roots)
	for root in roots {
		patch := goo_patch(seed, side, root.x)
		density := GOO_SPARSE_DENSITY + (GOO_PATCH_DENSITY - GOO_SPARSE_DENSITY) * patch
		if hash(deco + 5, root.id) >= density {
			continue
		}
		count := 1 + int(math.floor(hash(deco + 1, root.id) * METABALL_MAX_PER_ROOT * patch))
		for b in 0 ..< count {
			own := deco + imul(root.id * 8 + i64(b), 0x9e3779b1)
			speed := 0.6 + 0.8 * hash(own, 1) // each blob has its own tempo
			x := root.x + (value_noise2(own, 0, time * speed) * 2 - 1) * METABALL_DRIFT
			height := value_noise2(own + 1, 0, time * speed) * METABALL_RISE
			cave := cave_at(seed, x)
			edge := cave.top if side > 0 else cave.bottom
			radius := METABALL_RADIUS_MIN + hash(own, 2) * (METABALL_RADIUS_MAX - METABALL_RADIUS_MIN)
			append(out, Blob{own, x, edge + side * height, radius})
		}
	}
}

// Turns a blob into a cluster: particles packed inside it (the ring turned by a seeded
// angle), neighbors joined by springs at their current length
make_cluster :: proc(blob: Blob, side: f64) -> ^Cluster {
	n, R := GOO_PARTICLES, blob.radius
	turn := hash(i64(math.floor(blob.x * 1000 + 0.5)), 7) * 2 * math.PI
	c := new(Cluster)
	c.key, c.side, c.radius = blob.key, side, R * goo_particle_scale
	append(&c.particles, Particle{blob.x, blob.y, 0, 0})
	for i in 0 ..< n - 1 {
		a := turn + (2 * math.PI * f64(i)) / f64(n - 1)
		append(&c.particles, Particle{blob.x + math.cos(a) * R * GOO_RING_FRACTION, blob.y + math.sin(a) * R * GOO_RING_FRACTION, 0, 0})
	}
	resize(&c.bonded, n * n)
	for i in 0 ..< n {
		for j in i + 1 ..< n {
			rest := math.hypot(c.particles[i].x - c.particles[j].x, c.particles[i].y - c.particles[j].y)
			if rest < c.radius * 1.6 {
				append(&c.springs, Spring{i, j, rest})
				c.bonded[i * n + j] = true
			}
		}
	}
	return c
}

free_cluster :: proc(c: ^Cluster) {
	delete(c.particles)
	delete(c.springs)
	delete(c.bonded)
	free(c)
}

// Closest point on the hull to (px, py), whether the point is inside, and the outward
// normal of the closest edge
HullContact :: struct {
	d, qx, qy, nx, ny: f64,
	at_nose, inside:   bool,
}

hull_contact :: proc(hull: [3][2]f64, px, py: f64) -> HullContact {
	best: HullContact
	found := false
	inside := true
	for k in 0 ..< 3 {
		a, b := hull[k], hull[(k + 1) % 3]
		ex, ey := b.x - a.x, b.y - a.y
		l := math.hypot(ex, ey)
		nx, ny := -ey / l, ex / l // outward normal of this edge
		if (px - a.x) * nx + (py - a.y) * ny > 0 {
			inside = false
		}
		t := math.max(0, math.min(1, ((px - a.x) * ex + (py - a.y) * ey) / (l * l)))
		qx, qy := a.x + ex * t, a.y + ey * t
		d := math.hypot(px - qx, py - qy)
		if !found || d < best.d {
			best = {d, qx, qy, nx, ny, k == 0 && t == 0, false}
			found = true
		}
	}
	best.inside = inside
	return best
}

// Groups of particles still joined by springs (directly or through others), biggest first
cluster_pieces :: proc(c: ^Cluster) -> [][dynamic]int {
	n := len(c.particles)
	parent := make([]int, n, context.temp_allocator)
	for i in 0 ..< n {
		parent[i] = i
	}
	find :: proc(parent: []int, i: int) -> int {
		if parent[i] == i {
			return i
		}
		parent[i] = find(parent, parent[i])
		return parent[i]
	}
	for sp in c.springs {
		parent[find(parent, sp.i)] = find(parent, sp.j)
	}
	groups := make([dynamic][dynamic]int, context.temp_allocator)
	root_group := make(map[int]int, context.temp_allocator)
	for i in 0 ..< n {
		root := find(parent, i)
		g, ok := root_group[root]
		if !ok {
			g = len(groups)
			root_group[root] = g
			append(&groups, make([dynamic]int, context.temp_allocator))
		}
		append(&groups[g], i)
	}
	slice.stable_sort_by(groups[:], proc(a, b: [dynamic]int) -> bool {return len(a) > len(b)})
	return groups[:]
}

// Keeps only the listed particles and the springs between them, renumbered from 0
keep_particles :: proc(c: ^Cluster, indices: []int) {
	renumber := make(map[int]int, context.temp_allocator)
	kept := make([dynamic]Particle, 0, len(indices))
	for i, k in indices {
		renumber[i] = k
		append(&kept, c.particles[i])
	}
	springs := make([dynamic]Spring)
	for sp in c.springs {
		a, ok_a := renumber[sp.i]
		b, ok_b := renumber[sp.j]
		if ok_a && ok_b {
			append(&springs, Spring{math.min(a, b), math.max(a, b), sp.rest}) // springs keep i < j
		}
	}
	delete(c.particles)
	delete(c.springs)
	c.particles, c.springs = kept, springs
	n := len(kept)
	clear(&c.bonded)
	resize(&c.bonded, n * n)
	for sp in springs {
		c.bonded[sp.i * n + sp.j] = true
	}
}

// Splits every small enough piece off the cluster into a droplet and scores it. Returns the
// cluster's remaining pieces (particle indices), biggest first.
detach_droplets :: proc(state: ^State, c: ^Cluster) -> [][dynamic]int {
	pieces := cluster_pieces(c)
	if len(pieces) < 2 {
		return pieces
	}
	leaving := make([dynamic]bool, len(pieces), context.temp_allocator)
	any := false
	for piece, k in pieces[1:] {
		leaving[k + 1] = len(piece) <= DROPLET_MAX_PARTICLES
		any ||= leaving[k + 1]
	}
	if !any {
		return pieces
	}
	for piece, k in pieces {
		if !leaving[k] {
			continue
		}
		sx, sy: f64
		for i in piece {
			sx += c.particles[i].x
			sy += c.particles[i].y
		}
		cx, cy := sx / f64(len(piece)), sy / f64(len(piece))
		state.score += DROPLET_POINTS
		drop := Droplet {
			t       = state.time,
			radius  = c.radius,
			points  = DROPLET_POINTS,
			start_x = cx - state.distance,
			start_y = cy,
			n       = len(piece),
		}
		for i, j in piece {
			drop.offsets[j] = {c.particles[i].x - cx, c.particles[i].y - cy}
		}
		append(&state.droplets, drop)
	}
	staying := make([dynamic]int, context.temp_allocator)
	for piece, k in pieces {
		if !leaving[k] {
			append(&staying, ..piece[:])
		}
	}
	keep_particles(c, staying[:])
	return cluster_pieces(c)
}

// The droplet's flight: a quadratic Bézier in screen space from where it was cut, swinging
// forward and toward the cave's middle, then to the middle of the left screen edge,
// speeding up as it goes. Its center in screen-fixed world units, or false once it has left.
droplet_position :: proc(state: ^State, drop: ^Droplet, time, distance: f64) -> (x, y: f64, ok: bool) {
	k := (time - drop.t) / DROPLET_FLIGHT_TIME
	if k >= 1 {
		return
	}
	s := math.pow(math.max(0, k), 1.6)
	middle_at :: proc(state: ^State, distance, screen_x: f64) -> f64 {
		cave := cave_at(state.seed, distance + screen_x)
		return (cave.top + cave.bottom) / 2
	}
	end_x, end_y := -drop.radius, middle_at(state, distance, 0) // just past the left edge
	mid_x, mid_y := drop.start_x + DROPLET_ARC, middle_at(state, distance, drop.start_x)
	u := 1 - s
	return u * u * drop.start_x + 2 * u * s * mid_x + s * s * end_x, u * u * drop.start_y + 2 * u * s * mid_y + s * s * end_y, true
}

step_droplets :: proc(state: ^State) {
	kept := 0
	for drop in state.droplets {
		if state.time - drop.t < DROPLET_FLIGHT_TIME {
			state.droplets[kept] = drop
			kept += 1
		}
	}
	resize(&state.droplets, kept)
}

BlobHome :: struct {
	x, y, px, py:  f64,
	now, previous: bool,
}

step_goo :: proc(state: ^State, dt: f64) {
	ship := &state.ship
	hull := ship_hull(state)
	ship_x := state.distance + SHIP_X
	svx, svy := state.ship_vx, ship.vy
	axis_x, axis_y := math.cos(ship.angle), math.sin(ship.angle)

	// Blobs close to the ship become clusters
	blobs := make([dynamic]Blob, context.temp_allocator)
	for side in ([2]f64{1, -1}) {
		clear(&blobs)
		metaballs_in_range(state.seed, side, ship_x - 3, ship_x + 4, state.time, &blobs)
		for blob in blobs {
			if blob.key in state.clusters {
				continue
			}
			if math.hypot(blob.x - ship_x, blob.y - ship.y) < blob.radius + GOO_ACTIVATE_MARGIN {
				state.clusters[blob.key] = make_cluster(blob, side)
			}
		}
	}
	if len(state.clusters) == 0 {
		return // nothing to move (most of the flight)
	}

	// Where each clustered blob would be now, and a step ago
	homes := make(map[i64]BlobHome, context.temp_allocator)
	for side in ([2]f64{1, -1}) {
		for t, k in ([2]f64{state.time - dt, state.time}) {
			clear(&blobs)
			metaballs_in_range(state.seed, side, state.distance - 12, ship_x + 6, t, &blobs)
			for blob in blobs {
				if blob.key not_in state.clusters {
					continue
				}
				home := homes[blob.key]
				if k == 1 {
					home.x, home.y, home.now = blob.x, blob.y, true
				} else {
					home.px, home.py, home.previous = blob.x, blob.y, true
				}
				homes[blob.key] = home
			}
		}
	}

	keys := make([dynamic]i64, context.temp_allocator)
	for key in state.clusters {
		append(&keys, key)
	}
	for key in keys {
		cluster := state.clusters[key]
		home, found := homes[key]
		if !found || !home.now { 	// scrolled away
			delete_key(&state.clusters, key)
			free_cluster(cluster)
			continue
		}
		bvx := 0.0 if !home.previous else (home.x - home.px) / dt
		bvy := 0.0 if !home.previous else (home.y - home.py) / dt

		// Cut-off pieces: small enough ones leave as droplets (and score); the rest stay
		pieces := detach_droplets(state, cluster)
		n, p, r := len(cluster.particles), cluster.particles[:], cluster.radius

		// Tether: the whole cluster is pulled along with where the blob would be, acting on
		// its center only, so it moves the goo without undoing its shape
		mx, my: f64
		for q in p {
			mx += q.x
			my += q.y
		}
		mx /= f64(n)
		my /= f64(n)
		tx, ty := (home.x - mx) * GOO_TETHER, (home.y - my) * GOO_TETHER
		ax := make([]f64, n, context.temp_allocator)
		ay := make([]f64, n, context.temp_allocator)
		for i in 0 ..< n {
			// Viscosity: motion relative to the blob's own drift dies out
			ax[i] = tx - (p[i].vx - bvx) * GOO_VISCOSITY
			ay[i] = ty - (p[i].vy - bvy) * GOO_VISCOSITY
		}

		// Pieces too big to be carried away are drawn back to the main body
		if len(pieces) > 1 {
			center_of :: proc(p: []Particle, piece: []int) -> (f64, f64) {
				sx, sy: f64
				for i in piece {
					sx += p[i].x / f64(len(piece))
					sy += p[i].y / f64(len(piece))
				}
				return sx, sy
			}
			cx, cy := center_of(p, pieces[0][:])
			for piece in pieces[1:] {
				px, py := center_of(p, piece[:])
				for i in piece {
					ax[i] += (cx - px) * GOO_REGROUP
					ay[i] += (cy - py) * GOO_REGROUP
				}
			}
		}

		// Surface tension: springs pull bonded neighbors back to their rest length and snap
		// when stretched too far. While the ship is slowed it can't cut: springs don't snap
		// and are much stiffer, so the blob is shoved aside as a whole.
		stiffness := GOO_SPRING_STIFFNESS * (1 if state.can_cut else GOO_SHOVE_STIFFNESS)
		kept := 0
		for sp in cluster.springs {
			a, b := p[sp.i], p[sp.j]
			dx, dy := b.x - a.x, b.y - a.y
			l := math.hypot(dx, dy)
			if l == 0 {
				l = 1e-6
			}
			if state.can_cut && l > sp.rest * GOO_BREAK_STRETCH {
				cluster.bonded[sp.i * n + sp.j] = false
				continue
			}
			ux, uy := dx / l, dy / l
			relative := (b.vx - a.vx) * ux + (b.vy - a.vy) * uy
			f := (l - sp.rest) * stiffness + relative * GOO_SPRING_DAMPING
			ax[sp.i] += ux * f
			ay[sp.i] += uy * f
			ax[sp.j] -= ux * f
			ay[sp.j] -= uy * f
			cluster.springs[kept] = sp
			kept += 1
		}
		resize(&cluster.springs, kept)

		// Particles that touch again bond again
		for i in 0 ..< n {
			for j in i + 1 ..< n {
				if cluster.bonded[i * n + j] {
					continue
				}
				l := math.hypot(p[j].x - p[i].x, p[j].y - p[i].y)
				if l < r * GOO_REJOIN_DISTANCE {
					append(&cluster.springs, Spring{i, j, l})
					cluster.bonded[i * n + j] = true
				}
			}
		}

		for i in 0 ..< n {
			p[i].vx += ax[i] * dt
			p[i].vy += ay[i] * dt
			p[i].x += p[i].vx * dt
			p[i].y += p[i].vy * dt
		}

		// The direction to push a particle out of the hull: away from the closest point, and
		// at the nose tip also sideways, so goo splits instead of piling up in front
		push_normal :: proc(hit: HullContact, q: Particle, ship_x, ship_y, axis_x, axis_y: f64) -> (nx, ny: f64) {
			if hit.inside || hit.d < 1e-6 {
				nx, ny = hit.nx, hit.ny
			} else {
				nx, ny = (q.x - hit.qx) / hit.d, (q.y - hit.qy) / hit.d
			}
			if hit.at_nose {
				side_sign := 1.0 if (q.x - ship_x) * -axis_y + (q.y - ship_y) * axis_x >= 0 else -1.0
				nx += -axis_y * side_sign
				ny += axis_x * side_sign
				l := math.hypot(nx, ny)
				nx /= l
				ny /= l
			}
			return
		}

		// Slowed ship: the blob is shoved aside as one piece by the deepest contact
		if !state.can_cut {
			for _ in 0 ..< 2 {
				best_depth, best_nx, best_ny: f64
				found := false
				for q in p {
					reach := r * GOO_SHOVE_REACH
					hit := hull_contact(hull, q.x, q.y)
					if !hit.inside && hit.d >= reach {
						continue
					}
					nx, ny := push_normal(hit, q, ship_x, ship.y, axis_x, axis_y)
					depth := reach + hit.d if hit.inside else reach - hit.d
					if !found || depth > best_depth {
						best_depth, best_nx, best_ny = depth, nx, ny
						found = true
					}
				}
				if !found {
					break
				}
				for &q in p {
					q.x += best_nx * best_depth
					q.y += best_ny * best_depth
					into := (q.vx - svx) * best_nx + (q.vy - svy) * best_ny
					if into < 0 {
						q.vx -= best_nx * into
						q.vy -= best_ny * into
					}
				}
			}
			continue
		}

		for &q in p {
			// Hull: push the particle out to its collision radius
			reach := r * GOO_COLLISION_RADIUS
			hit := hull_contact(hull, q.x, q.y)
			if !hit.inside && hit.d >= reach {
				continue
			}
			nx, ny := push_normal(hit, q, ship_x, ship.y, axis_x, axis_y)
			q.x, q.y = hit.qx + nx * reach, hit.qy + ny * reach
			// Relative to the hull: no moving into it, and friction drags it along
			rvx, rvy := q.vx - svx, q.vy - svy
			into := rvx * nx + rvy * ny
			if into < 0 {
				rvx -= nx * into
				rvy -= ny * into
			}
			along := rvx * nx + rvy * ny
			grip := 1 - math.exp(-GOO_HULL_FRICTION * dt)
			rvx -= (rvx - nx * along) * grip
			rvy -= (rvy - ny * along) * grip
			q.vx, q.vy = svx + rvx, svy + rvy
		}
	}
}

// The goo blobs as they are now: seeded blobs, except those turned into clusters, which
// are their particles instead
goo_blobs :: proc(state: ^State, side, x0, x1, t: f64, out: ^[dynamic]Blob) {
	blobs := make([dynamic]Blob, context.temp_allocator)
	metaballs_in_range(state.seed, side, x0, x1, t, &blobs)
	for blob in blobs {
		if blob.key not_in state.clusters {
			append(out, blob)
		}
	}
	for _, c in state.clusters {
		if c.side != side {
			continue
		}
		for q in c.particles {
			if q.x > x0 - c.radius && q.x < x1 + c.radius {
				append(out, Blob{0, q.x, q.y, c.radius})
			}
		}
	}
}
