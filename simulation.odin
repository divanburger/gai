package main

import "core:fmt"
import glsl "core:math/linalg/glsl"
import "core:math"
import "core:math/rand"

// Y position of the paddle's curved top surface at normalized position t in [-1, 1].
paddle_surface_y :: proc(paddle_y: f32, paddle_half_h: f32, t: f32) -> f32 {
	return paddle_y - paddle_half_h - PADDLE_BOW_HEIGHT * (1.0 - t * t)
}

release_locked_balls :: proc(state: ^LevelState) {
	pw := effective_paddle_width(state)
	for &ball in state.balls {
		if !ball.locked { continue }
		ball.locked = false
		ball.dir = paddle_bounce_normal(ball.pos.x, state.paddle.pos.x, pw / 2)
	}
}

effective_ball_speed :: proc(state: ^LevelState) -> f32 {
	s := glsl.length(BALL_SPEED)
	if has_effect(state, .FastBall) { s *= BALL_FAST_MULT }
	if has_effect(state, .SlowBall) { s *= BALL_SLOW_MULT }
	return s
}

// split_balls doubles all existing balls. Each ball spawns a twin at opposite angle offsets.
// Newly spawned balls start with a ghost timer (transparent, no ball-ball collision).
split_balls :: proc(state: ^LevelState) {
	count := len(state.balls)
	if count == 0 { return }
	angle_rad := BALL_SPLIT_ANGLE * math.PI / 180.0
	for i in 0..<count {
		if len(state.balls) >= MAX_BALLS { break }
		orig := state.balls[i]
		// Rotate original slightly one way, clone the other way
		cos_a := math.cos(angle_rad)
		sin_a := math.sin(angle_rad)
		// Rotate original direction by +angle
		state.balls[i].dir = glsl.normalize(vec2{
			orig.dir.x * cos_a - orig.dir.y * sin_a,
			orig.dir.x * sin_a + orig.dir.y * cos_a,
		})
		// New ball gets -angle
		new_ball := orig
		new_ball.dir = glsl.normalize(vec2{
			orig.dir.x * cos_a + orig.dir.y * sin_a,
			-orig.dir.x * sin_a + orig.dir.y * cos_a,
		})
		new_ball.ghost_timer = BALL_GHOST_TIME
		append(&state.balls, new_ball)
	}
}

paddle_bounce_normal :: proc(hit_x: f32, paddle_center_x: f32, paddle_half_width: f32) -> vec2 {
	t := clamp((hit_x - paddle_center_x) / paddle_half_width, -1, 1)
	max_angle :: f32(67.5 * math.PI / 180.0)
	angle := t * max_angle
	return glsl.normalize(vec2{math.sin(angle), -math.cos(angle)})
}

apply_item_effect :: proc(run: ^RunState, state: ^LevelState, kind: ItemKind) {
	switch kind {
	case .ExtraLife:
		run.lives += 1
	case .ExtraBall:
		split_balls(state)
	case .WidePaddle:
		add_effect(state, kind)
	case .NarrowPaddle:
		add_effect(state, kind)
	case .StickyPaddle:
		add_effect(state, kind)
	case .FastBall:
		add_effect(state, kind)
	case .SlowBall:
		add_effect(state, kind)
	}
}

simulate_step :: proc(gs: ^GameState, run: ^RunState, state: ^LevelState, ps: ^ParticleSystem, types: []BlockType, input: ^Input) {
	dt := SIM_DT
	state.sim_steps += 1
	state.sim_time  += dt

	// Paddle movement
	if input.keys[.LEFT].down  { state.paddle.pos.x -= PADDLE_SPEED * dt }
	if input.keys[.RIGHT].down { state.paddle.pos.x += PADDLE_SPEED * dt }
	state.paddle.pos.x = clamp(state.paddle.pos.x, state.playing_area.min.x + effective_paddle_width(state) / 2, state.playing_area.max.x - effective_paddle_width(state) / 2)

	// Update active effects
	for kind in ItemKind {
		if state.effect_timers[kind] <= 0 { continue }
		state.effect_timers[kind] -= dt
		if state.effect_timers[kind] <= 0 {
			state.effect_timers[kind] = 0
			game_log(state, fmt.tprintf("effect_expired kind=%v", kind))
			if kind == .StickyPaddle {
				release_locked_balls(state)
			}
		}
	}

	pa := state.playing_area
	pw := effective_paddle_width(state)
	paddle_half := vec2{pw, PADDLE_SIZE.y} / 2
	paddle_rect := Rect{min = state.paddle.pos - paddle_half, max = state.paddle.pos + paddle_half}

	// Update each ball (iterate backwards for correct unordered_remove)
	for bi := len(state.balls) - 1; bi >= 0; bi -= 1 {
		ball := &state.balls[bi]

		// Locked balls follow paddle
		if ball.locked {
			ball.pos = state.paddle.pos + ball.lock_offset
			continue
		}

		// Tick ghost timer
		if ball.ghost_timer > 0 {
			ball.ghost_timer -= dt
			if ball.ghost_timer < 0 { ball.ghost_timer = 0 }
		}

		speed := effective_ball_speed(state)
		ball.pos += ball.dir * speed * dt

			// Block collision (one block per ball per step)
			block_loop: for row in 0..<BLOCK_ROWS {
				for col in 0..<BLOCK_COLS {
					idx := row * BLOCK_COLS + col
					if state.blocks[idx].lives <= 0 { continue }
					rect := block_rect(col, row)
					sep, normal := rect_circle_contact(rect, ball.circle)
					if sep <= 0 {
						state.blocks[idx].lives -= 1
						state.score += SCORE_PER_BLOCK
						ball.pos -= sep * normal
						ball.dir = glsl.normalize(glsl.reflect(ball.dir, normal))
						game_log(state, fmt.tprintf("block_hit col=%d row=%d lives_left=%d", col, row, state.blocks[idx].lives))
						emit_color := block_color(state.blocks[idx], types)
						center := (rect.min + rect.max) / 2
						if state.blocks[idx].lives <= 0 {
							game_log(state, fmt.tprintf("block_destroyed col=%d row=%d", col, row))
							// Destroy particles: impactful burst
							destroy_cfg := BLOCK_DESTROY_EMIT
							destroy_cfg.color = emit_color
							particles_emit(ps, center, BLOCK_DESTROY_COUNT, destroy_cfg)
							if rand.float32() < ITEM_DROP_CHANCE && state.drop_count < MAX_DROPS {
								kind := ItemKind(rand.int31_max(i32(len(ItemKind))))
								state.drops[state.drop_count] = ItemDrop{pos = center, kind = kind, active = true}
								state.drop_count += 1
								game_log(state, fmt.tprintf("item_spawned kind=%v pos=[%.1f,%.1f]", kind, center.x, center.y))
							}
						} else {
							// Hit particles: subtle feedback
							hit_cfg := BLOCK_HIT_EMIT
							hit_cfg.color = emit_color
							particles_emit(ps, center, BLOCK_HIT_COUNT, hit_cfg)
						}
						break block_loop
					}
				}
			}

			// Paddle collision — curved top surface matching visual bow
			// First check broad rect, then refine with curve
			sep, _ := rect_circle_contact(paddle_rect, ball.circle)
			if sep <= 0 && ball.dir.y > 0 {
				// Compute the curved surface Y at the ball's x position
				t := clamp((ball.pos.x - state.paddle.pos.x) / (pw / 2), -1, 1)
				surface_y := paddle_surface_y(state.paddle.pos.y, paddle_half.y, t)

				if ball.pos.y + ball.radius >= surface_y {
					ball.pos.y = surface_y - ball.radius
					n := paddle_bounce_normal(ball.pos.x, state.paddle.pos.x, pw / 2)
					reflected := glsl.reflect(ball.dir, n)
					reflected.y = -abs(reflected.y) // always bounce upward
					ball.dir = glsl.normalize(reflected)
					game_log(state, fmt.tprintf("paddle_hit ball=%d pos=[%.1f,%.1f]", bi, ball.pos.x, ball.pos.y))
					if has_effect(state, .StickyPaddle) {
						ball.locked = true
						ball.lock_offset = ball.pos - state.paddle.pos
						game_log(state, fmt.tprintf("sticky_catch ball=%d", bi))
					}
				}
			}

			// Wall collision
			wall_sep, wall_normal := rect_circle_contact(pa, ball.circle)
			if wall_sep + 2*ball.radius >= 0 && wall_normal.y != 1 {
				ball.pos -= (wall_sep + 2*ball.radius) * wall_normal
				ball.dir  = glsl.normalize(glsl.reflect(ball.dir, -wall_normal))
			}

			// Ball fell below playing area — remove it
			if ball.pos.y - ball.radius > pa.max.y {
				game_log(state, fmt.tprintf("ball_lost ball=%d remaining=%d", bi, len(state.balls) - 1))
				unordered_remove(&state.balls, bi)
				continue
			}

			// Prevent near-horizontal travel
			min_dy := f32(0.15)
			if abs(ball.dir.y) < min_dy {
				ball.dir.y = min_dy if ball.dir.y > 0 else -min_dy
				ball.dir = glsl.normalize(ball.dir)
			}
	}

	// Ball-to-ball collision (skip ghost balls)
	for ai in 0..<len(state.balls) {
		a := &state.balls[ai]
		if a.locked { continue }
		for bi in ai+1..<len(state.balls) {
			b := &state.balls[bi]
			if b.locked { continue }
			// Ghost balls don't collide with other balls
			if a.ghost_timer > 0 || b.ghost_timer > 0 { continue }
			delta := a.pos - b.pos
			dist  := glsl.length(delta)
			min_dist := a.radius + b.radius
			if dist < min_dist && dist > 0 {
				// Push apart
				normal := delta / dist
				overlap := min_dist - dist
				a.pos += normal * (overlap / 2)
				b.pos -= normal * (overlap / 2)
				// Reflect velocities along collision normal
				a_speed := effective_ball_speed(state)
				b_speed := a_speed
				a_vel := a.dir * a_speed
				b_vel := b.dir * b_speed
				rel_vel := a_vel - b_vel
				rel_n   := glsl.dot(rel_vel, normal)
				if rel_n < 0 {
					a_vel -= rel_n * normal
					b_vel += rel_n * normal
					a.dir = glsl.normalize(a_vel)
					b.dir = glsl.normalize(b_vel)
				}
			}
		}
	}

	// Update item drops
	for di := state.drop_count - 1; di >= 0; di -= 1 {
		if !state.drops[di].active { continue }
		state.drops[di].pos.y += ITEM_FALL_SPEED * dt

		// Check paddle catch
		if point_inside_rect(state.drops[di].pos, paddle_rect) {
			game_log(state, fmt.tprintf("item_caught kind=%v", state.drops[di].kind))
			apply_item_effect(run, state, state.drops[di].kind)
			state.drop_count -= 1
			state.drops[di] = state.drops[state.drop_count]
			continue
		}

		// Remove if below screen
		if state.drops[di].pos.y > pa.max.y + ITEM_SIZE.y {
			state.drop_count -= 1
			state.drops[di] = state.drops[state.drop_count]
		}
	}

	// Lose a life only when all balls are gone (no locked balls remaining)
	if len(state.balls) == 0 {
		run.lives -= 1
		game_log(state, fmt.tprintf("life_lost lives_remaining=%d", run.lives))
		if run.lives <= 0 {
			game_log(state, fmt.tprintf("game_over score=%d", state.score))
			gs.screen = .GameOver
			if gs.quit_on_gameover { gs.running = false }
		} else {
			spawn_locked_ball(state, pw)
			gs.playing_state = .WaitingToStart
		}
	}

	// Level complete check
	all_cleared := true
	for b in state.blocks {
		if b.lives > 0 { all_cleared = false; break }
	}
	if all_cleared {
		game_log(state, fmt.tprintf("level_complete score=%d", state.score))
		gs.screen = .LevelComplete
		if gs.quit_on_complete { gs.running = false }
	}
}
