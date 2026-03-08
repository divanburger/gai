package main

import "core:math"
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

Line :: struct {
	start, end: vec2,
}


// Contact info between two rects.
// separation: negative = penetrating, zero = touching, positive = gap.
// normal: unit vector pointing from b toward a (push a in this direction to resolve).
rect_rect_contact :: proc(a, b: Rect) -> (separation: f32, normal: vec2) {
	gap_x_pos := a.min.x - b.max.x  // positive: a is right of b
	gap_x_neg := b.min.x - a.max.x  // positive: a is left of b
	gap_x := max(gap_x_pos, gap_x_neg)

	gap_y_pos := a.min.y - b.max.y  // positive: a is below b
	gap_y_neg := b.min.y - a.max.y  // positive: a is above b
	gap_y := max(gap_y_pos, gap_y_neg)

	separation = max(gap_x, gap_y)
	if gap_x >= gap_y {
		normal = {1 if gap_x_pos >= gap_x_neg else -1, 0}
	} else {
		normal = {0, 1 if gap_y_pos >= gap_y_neg else -1}
	}
	return
}

// Contact info between a rect and a circle.
// separation: negative = penetrating, zero = touching, positive = gap.
// normal: unit vector pointing from rect toward circle center (push circle in this direction to resolve).
rect_circle_contact :: proc(rect: Rect, circle: Circle) -> (separation: f32, normal: vec2) {
	closest   := clamp2(circle.pos, rect.min, rect.max)
	delta     := circle.pos - closest
	delta_len := glsl.length(delta)
	separation = delta_len - circle.radius
	if delta_len > 0 {
		normal = delta / delta_len
	} else {
		// Circle center inside rect: normal from nearest face outward
		pen_left   := circle.pos.x - rect.min.x
		pen_right  := rect.max.x   - circle.pos.x
		pen_top    := circle.pos.y - rect.min.y
		pen_bottom := rect.max.y   - circle.pos.y
		min_pen    := min(pen_left, pen_right, pen_top, pen_bottom)
		separation = -(min_pen + circle.radius)
		switch min_pen {
		case pen_left:   normal = {-1,  0}
		case pen_right:  normal = { 1,  0}
		case pen_top:    normal = { 0, -1}
		case pen_bottom: normal = { 0,  1}
		}
	}
	return
}

point_inside_rect :: proc(point: vec2, r: Rect) -> bool {
	return point.x >= r.min.x && point.x <= r.max.x &&
	       point.y >= r.min.y && point.y <= r.max.y
}

clamp2 :: proc(v, lo, hi: $T/[2]$E) -> T {
	return {clamp(v.x, lo.x, hi.x), clamp(v.y, lo.y, hi.y)}
}

// Frame-rate independent exponential decay: smoothly moves `current` toward `target`.
// `speed` controls how fast (higher = snappier). Uses exp(-speed * dt) for proper integration.
// Works for f32 and vectors of any dimension.
move_toward_scalar :: proc(current, target: f32, speed, dt: f32) -> f32 {
	return target + (current - target) * math.exp(-speed * dt)
}

move_toward_vector :: proc(current, target: $T/[$N]f32, speed, dt: f32) -> T {
	decay := math.exp(-speed * dt)
	return target + (current - target) * decay
}

move_toward :: proc { move_toward_scalar, move_toward_vector }

// Cut functions: slice off a strip from one side of a rect.
// The input rect is shrunk in-place; the sliced-off strip is returned.

cut_left :: proc(r: ^Rect, amount: f32) -> Rect {
	result := Rect{r.min, {r.min.x + amount, r.max.y}}
	r.min.x += amount
	return result
}

cut_right :: proc(r: ^Rect, amount: f32) -> Rect {
	result := Rect{{r.max.x - amount, r.min.y}, r.max}
	r.max.x -= amount
	return result
}

cut_top :: proc(r: ^Rect, amount: f32) -> Rect {
	result := Rect{r.min, {r.max.x, r.min.y + amount}}
	r.min.y += amount
	return result
}

cut_bottom :: proc(r: ^Rect, amount: f32) -> Rect {
	result := Rect{{r.min.x, r.max.y - amount}, r.max}
	r.max.y -= amount
	return result
}

// Shrink/grow a rect by `amount` on all sides (grow uses negative shrink).
shrink_rect :: proc(r: Rect, amount: f32) -> Rect {
	return {{r.min.x + amount, r.min.y + amount}, {r.max.x - amount, r.max.y - amount}}
}

grow_rect :: proc(r: Rect, amount: f32) -> Rect {
	return shrink_rect(r, -amount)
}

// Return the center point of a rect.
center_of_rect :: proc(r: Rect) -> vec2 {
	return (r.min + r.max) * 0.5
}

// Center a rect of `size` within `bounds`.
center_rect :: proc(bounds: Rect, size: vec2) -> Rect {
	center := (bounds.min + bounds.max) * 0.5
	half   := size * 0.5
	return {center - half, center + half}
}


// Returns black or white, whichever is more readable on the given background color.
// Uses relative luminance (ITU-R BT.709).
color_readable :: proc(bg: Color) -> Color {
	luminance := 0.2126 * bg[0] + 0.7152 * bg[1] + 0.0722 * bg[2]
	return BLACK if luminance > 0.5 else WHITE
}

// Test if a moving circle (from `pos` to `pos + vel*dt`) intersects a line segment.
// Returns the time of first intersection in [0, 1] (relative to dt), or -1 if no hit.
line_circle_sweep :: proc(seg: Line, circle_pos, circle_vel: vec2, radius, dt: f32) -> f32 {
	d   := seg.end - seg.start           // segment direction
	f   := circle_pos - seg.start        // vector from seg start to circle center
	vel := circle_vel * dt               // displacement this frame

	// Solve quadratic: |f + t*vel - proj_along_d|^2 = radius^2 projected onto segment normal
	// Full sweep: treat as capsule vs point.
	// Quadratic coefficients for ray-expanded-segment test:
	// a*t^2 + b*t + c = 0  where t is in [0,1]
	a := glsl.dot(vel, vel)
	b := 2 * glsl.dot(f, vel)
	c := glsl.dot(f, f) - radius * radius

	// Also need to clamp to segment endpoints — check distance from infinite line first,
	// then verify the closest point on segment is within [seg.start, seg.end].
	seg_len_sq := glsl.dot(d, d)
	if seg_len_sq == 0 {
		// Degenerate segment: treat as point
		if a == 0 { return -1 }
		disc := b * b - 4 * a * c
		if disc < 0 { return -1 }
		t := (-b - math.sqrt_f32(disc)) / (2 * a)
		if t >= 0 && t <= 1 { return t }
		return -1
	}

	// Project sweep onto segment's perpendicular and parallel axes
	seg_dir  := d / math.sqrt_f32(seg_len_sq)
	seg_norm := vec2{-seg_dir.y, seg_dir.x}

	// Distance from circle center to segment line along normal
	dist_n := glsl.dot(f, seg_norm)
	// Rate of change of that distance
	vel_n  := glsl.dot(vel, seg_norm)

	// Solve for when |dist_n + t*vel_n| = radius
	if vel_n == 0 {
		if math.abs(dist_n) > radius { return -1 }
		// Already alongside — check parallel extent
	} else {
		t1 := (-radius - dist_n) / vel_n
		t2 := ( radius - dist_n) / vel_n
		if t1 > t2 { t1, t2 = t2, t1 }
		if t2 < 0 || t1 > 1 { return -1 }
		t_enter := max(t1, f32(0))
		// At t_enter, check if contact point falls within segment extent
		contact_pos := circle_pos + circle_vel * dt * t_enter
		proj := glsl.dot(contact_pos - seg.start, seg_dir)
		seg_len := math.sqrt_f32(seg_len_sq)
		if proj >= 0 && proj <= seg_len {
			return t_enter
		}
		// Check endpoint capsule circles
	}

	// Fallback: sweep against endpoint circles
	best := f32(-1)
	endpoints := [2]vec2{seg.start, seg.end}
	for i in 0..<2 {
		ep  := endpoints[i]
		g   := circle_pos - ep
		qa  := glsl.dot(vel, vel)
		qb  := 2 * glsl.dot(g, vel)
		qc  := glsl.dot(g, g) - radius * radius
		if qa == 0 { continue }
		disc := qb * qb - 4 * qa * qc
		if disc < 0 { continue }
		t := (-qb - math.sqrt_f32(disc)) / (2 * qa)
		if t >= 0 && t <= 1 {
			if best < 0 || t < best { best = t }
		}
	}
	return best
}

// Test if a moving circle sweeps into an axis-aligned rectangle.
// Returns the time of first intersection in [0, 1] (relative to dt), or -1 if no hit.
// Treats the rect as four line segments and returns the earliest hit.
line_rect_sweep :: proc(rect: Rect, circle_pos, circle_vel: vec2, radius, dt: f32) -> (t: f32, normal: vec2) {
	edges := [4]Line{
		{start = {rect.min.x, rect.min.y}, end = {rect.max.x, rect.min.y}}, // top
		{start = {rect.max.x, rect.min.y}, end = {rect.max.x, rect.max.y}}, // right
		{start = {rect.max.x, rect.max.y}, end = {rect.min.x, rect.max.y}}, // bottom
		{start = {rect.min.x, rect.max.y}, end = {rect.min.x, rect.min.y}}, // left
	}
	normals := [4]vec2{
		{0, -1}, // top
		{1,  0}, // right
		{0,  1}, // bottom
		{-1, 0}, // left
	}
	best := f32(-1)
	best_normal := vec2{}
	for edge, i in edges {
		hit := line_circle_sweep(edge, circle_pos, circle_vel, radius, dt)
		if hit >= 0 && (best < 0 || hit < best) {
			best = hit
			best_normal = normals[i]
		}
	}
	return best, best_normal
}
