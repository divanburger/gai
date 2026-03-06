package main

import "core:fmt"
import "core:flags"
import "core:os"
import SDL "vendor:sdl3"
import GL "vendor:OpenGL"
import ef "vendor:stb/easy_font"

WINDOW_TITLE   :: "Bouncing Ball"
WINDOW_WIDTH   :: 800
WINDOW_HEIGHT  :: 600
WINDOW_SIZE    :: ivec2{WINDOW_WIDTH, WINDOW_HEIGHT}
BALL_RADIUS    :: 30.0
BALL_SPEED     :: vec2{250.0, 180.0}
SEGMENTS       :: 64
VERTEX_COUNT   :: SEGMENTS + 2

PADDLE_SIZE  :: vec2{120.0, 15.0}
PADDLE_SPEED :: 500.0
PADDLE_Y     :: f32(WINDOW_HEIGHT) - 60.0

BLOCK_COLS   :: 20
BLOCK_ROWS   :: 5
BLOCK_SIZE   :: vec2{36.0, 14.0}
BLOCK_GAP    :: vec2{3.0, 5.0}
BLOCK_AREA_Y :: 40.0

GAME_NAME      :: "gai"
TEXT_SCALE     :: f32(3)
STARTING_LIVES :: 3

block_rect :: proc(col, row: int) -> Rect {
	area_x := (f32(WINDOW_WIDTH) - (BLOCK_COLS * (BLOCK_SIZE.x + BLOCK_GAP.x) - BLOCK_GAP.x)) / 2
	bmin := vec2{
		area_x + f32(col) * (BLOCK_SIZE.x + BLOCK_GAP.x),
		BLOCK_AREA_Y + f32(row) * (BLOCK_SIZE.y + BLOCK_GAP.y),
	}
	return {min = bmin, max = bmin + BLOCK_SIZE}
}

Options :: struct {
	screenshot_at:         f32  `usage:"Take a screenshot this many seconds after startup."`,
	quit_after_screenshot: bool `usage:"Quit the game after the timed screenshot is taken."`,
}

update :: proc(
	prev_counter:       ^u64,
	freq:                u64,
	running:            ^bool,
	paused:             ^bool,
	opts:               ^Options,
	left_held:          ^bool,
	right_held:         ^bool,
	state:              ^LevelState,
	elapsed:            ^f32,
	screenshot_counter: ^int,
	should_screenshot:  ^bool,
	r:                  ^Renderer,
) {
	now := SDL.GetPerformanceCounter()
	dt  := f32(now - prev_counter^) / f32(freq)
	prev_counter^ = now

	event: SDL.Event
	for SDL.PollEvent(&event) {
		#partial switch event.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			running^ = false
		case .KEY_DOWN:
			#partial switch event.key.scancode {
			case .ESCAPE:      running^ = false
			case .PAUSE, .P:   paused^ = !paused^
			case .PRINTSCREEN: should_screenshot^ = true
			case .LEFT:        left_held^  = true
			case .RIGHT:       right_held^ = true
			}
		case .KEY_UP:
			#partial switch event.key.scancode {
			case .LEFT:  left_held^  = false
			case .RIGHT: right_held^ = false
			}
		}
	}

	elapsed^ += dt

	if opts.screenshot_at >= 0 && elapsed^ >= opts.screenshot_at {
		should_screenshot^ = true
		opts.screenshot_at = -1  // trigger only once
		if opts.quit_after_screenshot {
			running^ = false
		}
	}

	if !paused^ {
		if left_held^  { state.paddle.pos.x -= PADDLE_SPEED * dt }
		if right_held^ { state.paddle.pos.x += PADDLE_SPEED * dt }
		state.paddle.pos.x = clamp(state.paddle.pos.x, PADDLE_SIZE.x / 2, f32(WINDOW_WIDTH) - PADDLE_SIZE.x / 2)

		state.ball.pos += state.ball.vel * dt

		// Block collision
		block_loop: for row in 0..<BLOCK_ROWS {
			for col in 0..<BLOCK_COLS {
				idx := row * BLOCK_COLS + col
				if !state.blocks[idx] { continue }
				rect := block_rect(col, row)
				if rect_circle_dist(rect, state.ball.circle) <= 0 {
					state.blocks[idx] = false
					state.score += 100
					if state.ball.pos.x >= rect.min.x && state.ball.pos.x <= rect.max.x {
						state.ball.vel.y = -state.ball.vel.y
					} else {
						state.ball.vel.x = -state.ball.vel.x
					}
					break block_loop
				}
			}
		}

		// Paddle collision: ball bottom hits paddle top
		half_paddle := PADDLE_SIZE / 2
		paddle_rect := Rect{min = state.paddle.pos - half_paddle, max = state.paddle.pos + half_paddle}
		if state.ball.vel.y > 0 && rect_circle_dist(paddle_rect, state.ball.circle) <= 0 {
			state.ball.pos.y = paddle_rect.min.y - state.ball.radius
			state.ball.vel.y = -abs(state.ball.vel.y)
		}

		if state.ball.pos.x - state.ball.radius < 0            { state.ball.pos.x = state.ball.radius;                state.ball.vel.x =  abs(state.ball.vel.x) }
		if state.ball.pos.x + state.ball.radius > WINDOW_WIDTH { state.ball.pos.x = WINDOW_WIDTH - state.ball.radius; state.ball.vel.x = -abs(state.ball.vel.x) }
		if state.ball.pos.y - state.ball.radius < 0            { state.ball.pos.y = state.ball.radius;                state.ball.vel.y =  abs(state.ball.vel.y) }
		if state.ball.pos.y - state.ball.radius > WINDOW_HEIGHT {
			state.lives -= 1
			if state.lives <= 0 {
				running^ = false
			} else {
				state.ball.pos = {state.paddle.pos.x, state.paddle.pos.y - PADDLE_SIZE.y/2 - state.ball.radius - 5}
				state.ball.vel = {BALL_SPEED.x, -abs(BALL_SPEED.y)}
			}
		}
	} // end !paused

	// Draw calls
	text_w    := f32(ef.width(GAME_NAME)) * TEXT_SCALE
	title_pos := vec2{(f32(WINDOW_WIDTH) - text_w) / 2, 10}
	draw_text(r, GAME_NAME, title_pos, TEXT_SCALE, WHITE)

	score_str := fmt.tprintf("Score: %d", state.score)
	score_w   := f32(ef.width(score_str)) * TEXT_SCALE
	score_pos := vec2{f32(WINDOW_WIDTH) - score_w - 10, 10}
	draw_text(r, score_str, score_pos, TEXT_SCALE, WHITE)

	draw_text(r, fmt.tprintf("Lives: %d", state.lives), {10, 10}, TEXT_SCALE, WHITE)

	draw_circle(r, state.ball.circle, WHITE)

	half := PADDLE_SIZE / 2
	draw_rect(r, Rect{min = state.paddle.pos - half, max = state.paddle.pos + half}, WHITE)

	for row in 0..<BLOCK_ROWS {
		for col in 0..<BLOCK_COLS {
			if state.blocks[row * BLOCK_COLS + col] {
				draw_rect(r, block_rect(col, row), WHITE)
			}
		}
	}

	if paused^ {
		draw_rect(r, Rect{min = {0, 0}, max = {WINDOW_WIDTH, WINDOW_HEIGHT}}, Color{0, 0, 0, 0.6})
		paused_text := "PAUSED"
		paused_w    := f32(ef.width(paused_text)) * TEXT_SCALE
		paused_pos  := vec2{(f32(WINDOW_WIDTH) - paused_w) / 2, (f32(WINDOW_HEIGHT) - 8 * TEXT_SCALE) / 2}
		draw_text(r, paused_text, paused_pos, TEXT_SCALE, WHITE)
	}
}

main :: proc() {
	opts := Options{screenshot_at = -1}
	flags.parse_or_exit(&opts, os.args, .Unix)

	if infos, err := os.read_directory_by_path("screenshots", 0, context.allocator); err == nil {
		for fi in infos {
			os.remove(fi.fullpath)
		}
		os.file_info_slice_delete(infos, context.allocator)
	}
	os.make_directory("screenshots")

	if !SDL.Init(SDL.InitFlags{.VIDEO}) {
		fmt.eprintln("SDL_Init failed:", SDL.GetError())
		return
	}
	defer SDL.Quit()

	SDL.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	SDL.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	SDL.GL_SetAttribute(.CONTEXT_PROFILE_MASK, 1)
	SDL.GL_SetAttribute(.DOUBLEBUFFER, 1)

	window := SDL.CreateWindow(WINDOW_TITLE, WINDOW_WIDTH, WINDOW_HEIGHT, SDL.WindowFlags{.OPENGL})
	if window == nil {
		fmt.eprintln("CreateWindow failed:", SDL.GetError())
		return
	}
	defer SDL.DestroyWindow(window)

	gl_ctx := SDL.GL_CreateContext(window)
	if gl_ctx == nil {
		fmt.eprintln("GL_CreateContext failed:", SDL.GetError())
		return
	}
	defer SDL.GL_DestroyContext(gl_ctx)
	SDL.GL_MakeCurrent(window, gl_ctx)

	GL.load_up_to(3, 3, SDL.gl_set_proc_address)

	r, ok := renderer_init()
	if !ok { return }
	defer renderer_destroy(&r)

	left_held, right_held := false, false

	state := LevelState{
		ball   = {circle = {pos = {WINDOW_WIDTH / 2.0, WINDOW_HEIGHT / 2.0}, radius = BALL_RADIUS}, vel = BALL_SPEED},
		paddle = {pos = {f32(WINDOW_WIDTH) / 2.0, PADDLE_Y}},
		lives  = STARTING_LIVES,
	}
	for &b in state.blocks { b = true }

	paused             := false
	prev_counter       := SDL.GetPerformanceCounter()
	freq               := SDL.GetPerformanceFrequency()
	screenshot_counter := 0
	should_screenshot  := false
	elapsed            : f32

	running := true
	for running {
		free_all(context.temp_allocator)
		renderer_start_frame(&r)
		update(
			&prev_counter, freq,
			&running, &paused,
			&opts,
			&left_held, &right_held,
			&state,
			&elapsed,
			&screenshot_counter, &should_screenshot,
			&r,
		)
		renderer_end_frame(&r, &screenshot_counter, &should_screenshot, window)
	}
}
