package main

import glsl "core:math/linalg/glsl"

vec2  :: glsl.vec2
ivec2 :: glsl.ivec2
vec4  :: glsl.vec4
Color :: glsl.vec4

Rect :: struct {
	min, max: vec2,
}

Circle :: struct {
	pos:    vec2,
	radius: f32,
}


// Signed distance between two rects.
// Negative = penetrating, zero = touching, positive = gap.
rect_rect_dist :: proc(a, b: Rect) -> f32 {
	gap_x := max(a.min.x - b.max.x, b.min.x - a.max.x)
	gap_y := max(a.min.y - b.max.y, b.min.y - a.max.y)
	return max(gap_x, gap_y)
}

// Signed distance between a rect and a circle.
// Negative = penetrating, zero = touching, positive = gap.
rect_circle_dist :: proc(rect: Rect, circle: Circle) -> f32 {
	closest := clamp2(circle.pos, rect.min, rect.max)
	return glsl.length(circle.pos - closest) - circle.radius
}

point_inside_rect :: proc(point: vec2, r: Rect) -> bool {
	return point.x >= r.min.x && point.x <= r.max.x &&
	       point.y >= r.min.y && point.y <= r.max.y
}

clamp2 :: proc(v, lo, hi: $T/[2]$E) -> T {
	return {clamp(v.x, lo.x, hi.x), clamp(v.y, lo.y, hi.y)}
}
