package engine

import rl "vendor:raylib"

RectCollider :: struct {
	offset: rl.Vector2,
	size:   rl.Vector2, // zero = use obj.size
}

CircleCollider :: struct {
	offset: rl.Vector2, // from obj.pos (top-left)
	radius: f32,
}

Collider :: union {
	RectCollider,
	CircleCollider,
}

make_rect_collider :: proc(offset, size: rl.Vector2) -> Collider {
	return RectCollider{offset = offset, size = size}
}

make_circle_collider :: proc(offset: rl.Vector2, radius: f32) -> Collider {
	return CircleCollider{offset = offset, radius = radius}
}

// collider_aabb returns the axis-aligned bounding rectangle of an object's collider.
// Returns false if the object has no collider.
collider_aabb :: proc(obj: ^RenderObject) -> (rect: rl.Rectangle, ok: bool) {
	switch c in obj.collider {
	case RectCollider:
		return _rect_aabb(obj, c), true
	case CircleCollider:
		center := _circle_center(obj, c)
		return rl.Rectangle {
				x = center.x - c.radius,
				y = center.y - c.radius,
				width = c.radius * 2,
				height = c.radius * 2,
			},
			true
	}
	return {}, false
}

// check_collision tests whether two RenderObjects overlap using their assigned colliders.
// Returns false if either object has no collider set.
check_collision :: proc(a, b: ^RenderObject) -> bool {
	if a.collider == nil || b.collider == nil {
		return false
	}
	switch ca in a.collider {
	case RectCollider:
		ra := _rect_aabb(a, ca)
		switch cb in b.collider {
		case RectCollider:
			return _rect_rect(ra, _rect_aabb(b, cb))
		case CircleCollider:
			return _circle_rect(_circle_center(b, cb), cb.radius, ra)
		}
	case CircleCollider:
		ca_center := _circle_center(a, ca)
		switch cb in b.collider {
		case RectCollider:
			return _circle_rect(ca_center, ca.radius, _rect_aabb(b, cb))
		case CircleCollider:
			return _circle_circle(ca_center, ca.radius, _circle_center(b, cb), cb.radius)
		}
	}
	return false
}

@(private)
_rect_aabb :: proc(obj: ^RenderObject, col: RectCollider) -> rl.Rectangle {
	size: rl.Vector2
	if col.size.x != 0 || col.size.y != 0 {
		size = col.size
	} else {
		size = obj.size
	}
	return rl.Rectangle {
		x = obj.pos.x + col.offset.x,
		y = obj.pos.y + col.offset.y,
		width = size.x,
		height = size.y,
	}
}

@(private)
_circle_center :: proc(obj: ^RenderObject, col: CircleCollider) -> rl.Vector2 {
	return {obj.pos.x + col.offset.x, obj.pos.y + col.offset.y}
}

@(private)
_rect_rect :: proc(r1, r2: rl.Rectangle) -> bool {
	return(
		r1.x < r2.x + r2.width &&
		r1.x + r1.width > r2.x &&
		r1.y < r2.y + r2.height &&
		r1.y + r1.height > r2.y \
	)
}

@(private)
_circle_circle :: proc(c1: rl.Vector2, r1: f32, c2: rl.Vector2, r2: f32) -> bool {
	dx := c1.x - c2.x
	dy := c1.y - c2.y
	sum_r := r1 + r2
	return dx * dx + dy * dy < sum_r * sum_r
}

@(private)
_circle_rect :: proc(center: rl.Vector2, radius: f32, rect: rl.Rectangle) -> bool {
	closest_x := clamp(center.x, rect.x, rect.x + rect.width)
	closest_y := clamp(center.y, rect.y, rect.y + rect.height)
	dx := center.x - closest_x
	dy := center.y - closest_y
	return dx * dx + dy * dy < radius * radius
}

