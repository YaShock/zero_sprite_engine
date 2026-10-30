package engine

import "core:math/linalg"

RectCollider :: struct {
	offset: Vector2, // from the entity's center
	size:   Vector2, // zero = use the entity's size
}

CircleCollider :: struct {
	offset: Vector2, // from the entity's center
	radius: f32,
}

Collider :: union {
	RectCollider,
	CircleCollider,
}

// Separation info for an overlapping pair: moving `a` by normal * depth resolves it.
Contact :: struct {
	normal: Vector2, // unit vector pointing from b towards a
	depth:  f32,
}

// collider_aabb returns the axis-aligned bounding rectangle of an entity's collider.
// Returns false if the entity has no collider.
collider_aabb :: proc(e: ^Entity) -> (rect: Rectangle, ok: bool) {
	switch c in e.collider {
	case RectCollider:
		return rect_of(e, c), true
	case CircleCollider:
		center := e.pos + c.offset
		return {center.x - c.radius, center.y - c.radius, c.radius * 2, c.radius * 2}, true
	}
	return {}, false
}

check_collision :: proc(a, b: ^Entity) -> bool {
	_, hit := collide(a, b)
	return hit
}

// collide tests two entities' colliders and returns how to push `a` out of `b`.
// Returns false if they do not overlap or either has no collider.
collide :: proc(a, b: ^Entity) -> (contact: Contact, hit: bool) {
	switch ca in a.collider {
	case RectCollider:
		switch cb in b.collider {
		case RectCollider:
			return rect_rect(rect_of(a, ca), rect_of(b, cb))
		case CircleCollider:
			contact, hit = circle_rect(b.pos + cb.offset, cb.radius, rect_of(a, ca))
			contact.normal = -contact.normal
			return
		}
	case CircleCollider:
		center := a.pos + ca.offset
		switch cb in b.collider {
		case RectCollider:
			return circle_rect(center, ca.radius, rect_of(b, cb))
		case CircleCollider:
			return circle_circle(center, ca.radius, b.pos + cb.offset, cb.radius)
		}
	}
	return {}, false
}

@(private)
rect_of :: proc(e: ^Entity, c: RectCollider) -> Rectangle {
	size := c.size if c.size != {} else e.size
	center := e.pos + c.offset
	return {center.x - size.x / 2, center.y - size.y / 2, size.x, size.y}
}

@(private)
rect_rect :: proc(a, b: Rectangle) -> (Contact, bool) {
	dx := min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
	dy := min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
	if dx <= 0 || dy <= 0 {
		return {}, false
	}
	ca := Vector2{a.x + a.width / 2, a.y + a.height / 2}
	cb := Vector2{b.x + b.width / 2, b.y + b.height / 2}
	if dx < dy {
		return {{1 if ca.x > cb.x else -1, 0}, dx}, true
	}
	return {{0, 1 if ca.y > cb.y else -1}, dy}, true
}

@(private)
circle_circle :: proc(c1: Vector2, r1: f32, c2: Vector2, r2: f32) -> (Contact, bool) {
	delta := c1 - c2
	dist := linalg.length(delta)
	if dist >= r1 + r2 {
		return {}, false
	}
	normal := delta / dist if dist > 1e-6 else Vector2{0, -1}
	return {normal, r1 + r2 - dist}, true
}

@(private)
circle_rect :: proc(center: Vector2, radius: f32, r: Rectangle) -> (Contact, bool) {
	closest := Vector2{clamp(center.x, r.x, r.x + r.width), clamp(center.y, r.y, r.y + r.height)}
	delta := center - closest
	dist2 := linalg.dot(delta, delta)
	if dist2 >= radius * radius {
		return {}, false
	}
	if dist2 > 1e-8 {
		dist := linalg.sqrt(dist2)
		return {delta / dist, radius - dist}, true
	}
	// Center inside the rectangle: push out through the nearest side.
	left := center.x - r.x
	right := r.x + r.width - center.x
	top := center.y - r.y
	bottom := r.y + r.height - center.y
	m := min(left, right, top, bottom)
	if m == left {
		return {{-1, 0}, left + radius}, true
	} else if m == right {
		return {{1, 0}, right + radius}, true
	} else if m == top {
		return {{0, -1}, top + radius}, true
	}
	return {{0, 1}, bottom + radius}, true
}
