package main

import "core:fmt"
import "core:flags"
import "core:os"
import fp "core:path/filepath"
import glsl "core:math/linalg/glsl"
import "core:math"
import "core:math/rand"
import SDL "vendor:sdl3"
import GL "vendor:OpenGL"

WINDOW_TITLE   :: "Shardbreak"
GAME_WIDTH     :: 1280
GAME_HEIGHT    :: 720
GAME_SIZE      :: vec2{GAME_WIDTH, GAME_HEIGHT}
WINDOW_SIZE    :: ivec2{GAME_WIDTH, GAME_HEIGHT}
BALL_RADIUS    :: 18.0
BALL_SPEED     :: vec2{450.0, 324.0}
SEGMENTS       :: 64
VERTEX_COUNT   :: SEGMENTS + 2

PADDLE_SIZE  :: vec2{144.0, 18.0}
PADDLE_SPEED      :: 600.0
PADDLE_Y          :: f32(GAME_HEIGHT) - 70.0
PADDLE_BOW_HEIGHT :: f32(4)
PADDLE_SLICES     :: 20

BLOCK_COLS   :: 20
BLOCK_ROWS   :: 15
BLOCK_SIZE   :: vec2{57.0, 17.0}
BLOCK_GAP    :: vec2{5.0, 6.0}
BLOCK_AREA_Y :: 50.0

GAME_NAME      :: "Shardbreak"
STARTING_LIVES :: 3

MenuItem    :: enum { StartGame, Options, Quit }
MENU_LABELS :: [MenuItem]string{ .StartGame = "Start game", .Options = "Options", .Quit = "Quit" }

GameScreen  :: enum { MainMenu, Options, Playing, LevelComplete, GameOver }

OptionsItem   :: enum { DisplayMode, Resolution, Back }
OPTION_LABELS :: [OptionsItem]string{ .DisplayMode = "Display Mode", .Resolution = "Resolution", .Back = "Back" }

PauseItem    :: enum { Resume, Quit }
PAUSE_LABELS :: [PauseItem]string{ .Resume = "Resume", .Quit = "Quit" }

PlayingState :: enum { Active, WaitingToStart, Paused }

SIM_DT :: f32(0.01) // 10ms fixed simulation step

GameState :: struct {
	running:          bool,
	screen:           GameScreen,
	menu_selected:    MenuItem,
	options_focused:  OptionsItem,
	playing_state:    PlayingState,
	pause_selected:   PauseItem,
	left_held:        bool,
	right_held:       bool,
	should_screenshot:  bool,
	dt:                 f32,
	elapsed:            f32,
	sim_paused:         bool,
	sim_steps_requested: int,
	quit_on_complete:   bool,
	quit_on_gameover:   bool,
}

block_rect :: proc(col, row: int) -> Rect {
	area_x := (GAME_SIZE.x - (BLOCK_COLS * (BLOCK_SIZE.x + BLOCK_GAP.x) - BLOCK_GAP.x)) / 2
	bmin := vec2{
		area_x + f32(col) * (BLOCK_SIZE.x + BLOCK_GAP.x),
		BLOCK_AREA_Y + f32(row) * (BLOCK_SIZE.y + BLOCK_GAP.y),
	}
	return {min = bmin, max = bmin + BLOCK_SIZE}
}

apply_display_settings :: proc(window: ^SDL.Window, r: ^Renderer, s: Settings) {
	resolutions := RESOLUTIONS
	res := resolutions[s.resolution_idx]
	switch s.display_mode {
	case .Windowed:
		SDL.SetWindowFullscreen(window, false)
		SDL.SetWindowBordered(window, true)
		SDL.SetWindowSize(window, res.x, res.y)
	case .Borderless:
		SDL.SetWindowFullscreen(window, false)
		SDL.SetWindowBordered(window, false)
		SDL.SetWindowSize(window, res.x, res.y)
	case .Fullscreen:
		SDL.SetWindowFullscreen(window, true)
		// Viewport is updated when SDL fires WINDOW_RESIZED
		return
	}
	renderer_set_window_size(r, res)
}

Options :: struct {
	test_script:      string `usage:"Path to a test script JSON file to replay."`,
	pause_sim:        bool   `usage:"Start with the simulation paused."`,
	quit_on_complete: bool   `usage:"Quit when a level is completed."`,
	quit_on_gameover: bool   `usage:"Quit on game over."`,
}

handle_main_menu :: proc(event: SDL.Event, gs: ^GameState) {
	#partial switch event.key.scancode {
	case .UP:   gs.menu_selected = MenuItem((int(gs.menu_selected) - 1 + len(MenuItem)) % len(MenuItem))
	case .DOWN: gs.menu_selected = MenuItem((int(gs.menu_selected) + 1) % len(MenuItem))
	case .RETURN, .KP_ENTER:
		switch gs.menu_selected {
		case .StartGame: gs.screen = .Playing; gs.playing_state = .WaitingToStart
		case .Options:   gs.screen = .Options; gs.options_focused = .DisplayMode
		case .Quit:      gs.running = false
		}
	case .ESCAPE: gs.running = false
	}
}

handle_options :: proc(event: SDL.Event, gs: ^GameState, settings: ^Settings, window: ^SDL.Window, r: ^Renderer) {
	#partial switch event.key.scancode {
	case .ESCAPE:
		gs.screen = .MainMenu
	case .UP:
		gs.options_focused = OptionsItem((int(gs.options_focused) - 1 + len(OptionsItem)) % len(OptionsItem))
	case .DOWN:
		gs.options_focused = OptionsItem((int(gs.options_focused) + 1) % len(OptionsItem))
	case .LEFT:
		#partial switch gs.options_focused {
		case .DisplayMode:
			settings.display_mode = DisplayMode((int(settings.display_mode) - 1 + len(DisplayMode)) % len(DisplayMode))
		case .Resolution:
			if settings.display_mode != .Fullscreen {
				settings.resolution_idx = (settings.resolution_idx - 1 + len(RESOLUTIONS)) % len(RESOLUTIONS)
			}
		}
		apply_display_settings(window, r, settings^)
		settings_save(settings^)
	case .RIGHT:
		#partial switch gs.options_focused {
		case .DisplayMode:
			settings.display_mode = DisplayMode((int(settings.display_mode) + 1) % len(DisplayMode))
		case .Resolution:
			if settings.display_mode != .Fullscreen {
				settings.resolution_idx = (settings.resolution_idx + 1) % len(RESOLUTIONS)
			}
		}
		apply_display_settings(window, r, settings^)
		settings_save(settings^)
	case .RETURN, .KP_ENTER:
		if gs.options_focused == .Back { gs.screen = .MainMenu }
	}
}

handle_game_over :: proc(event: SDL.Event, gs: ^GameState, run: ^RunState, state: ^LevelState, levels: []Level) {
	#partial switch event.key.scancode {
	case .RETURN, .KP_ENTER, .ESCAPE:
		gs.screen = .MainMenu
		run_state_init(run, state, levels)
		gs.playing_state = .Active
	}
}

handle_level_complete :: proc(event: SDL.Event, gs: ^GameState, run: ^RunState, state: ^LevelState, levels: []Level) {
	#partial switch event.key.scancode {
	case .SPACE, .RETURN, .KP_ENTER:
		run.level_idx += 1
		if run.level_idx >= len(levels) {
			gs.screen = .MainMenu
			run_state_init(run, state, levels)
		} else {
			level_state_init(state, levels[run.level_idx])
			gs.screen = .Playing
			gs.playing_state = .WaitingToStart
		}
	case .ESCAPE:
		gs.screen = .MainMenu
		run_state_init(run, state, levels)
	}
}

handle_waiting_to_start :: proc(event: SDL.Event, gs: ^GameState, state: ^LevelState) {
	#partial switch event.key.scancode {
	case .ESCAPE: gs.running = false
	case .SPACE:
		gs.playing_state = .Active
		release_locked_balls(state)
	case .LEFT:   gs.left_held  = true
	case .RIGHT:  gs.right_held = true
	}
}

handle_paused :: proc(event: SDL.Event, gs: ^GameState, run: ^RunState, state: ^LevelState, levels: []Level) {
	#partial switch event.key.scancode {
	case .ESCAPE, .PAUSE, .P: gs.playing_state = .Active
	case .UP:   gs.pause_selected = PauseItem((int(gs.pause_selected) - 1 + len(PauseItem)) % len(PauseItem))
	case .DOWN: gs.pause_selected = PauseItem((int(gs.pause_selected) + 1) % len(PauseItem))
	case .RETURN, .KP_ENTER:
		switch gs.pause_selected {
		case .Resume:
			gs.playing_state = .Active
		case .Quit:
			gs.screen = .MainMenu
			run_state_init(run, state, levels)
			gs.playing_state = .Active
		}
	}
}

handle_playing :: proc(event: SDL.Event, gs: ^GameState, state: ^LevelState) {
	#partial switch event.key.scancode {
	case .ESCAPE, .PAUSE, .P: gs.playing_state = .Paused; gs.pause_selected = .Resume
	case .PRINTSCREEN: gs.should_screenshot = true
	case .SPACE:       release_locked_balls(state)
	case .LEFT:        gs.left_held  = true
	case .RIGHT:       gs.right_held = true
	}
}

draw_main_menu :: proc(r: ^Renderer, gs: ^GameState, ui: UI) {
	menu_labels := MENU_LABELS
	btn_h   := r.ui_font.size + BUTTON_PAD_Y * 2

	max_label_w := f32(0)
	for item in MenuItem { max_label_w = max(max_label_w, text_width(r.ui_font, menu_labels[item])) }
	btn_w := max_label_w + BUTTON_PAD_X * 2

	title       := GAME_NAME
	title_w     := text_width(r.ui_font, title) + WINDOW_PAD * 2
	btns_h      := f32(len(MenuItem)) * btn_h + f32(len(MenuItem) - 1) * BUTTON_SPACING
	win_w       := max(btn_w, title_w) + WINDOW_PAD * 2
	win_h       := WINDOW_BORDER + WINDOW_PAD + btns_h + WINDOW_PAD
	win_rect    := Rect{
		min = {GAME_SIZE.x/2 - win_w/2, GAME_SIZE.y/2 - win_h/2},
		max = {GAME_SIZE.x/2 + win_w/2, GAME_SIZE.y/2 + win_h/2},
	}
	content := ui_window_render(r, ui, win_rect, title)

	for item in MenuItem {
		item_y   := content.min.y + f32(int(item)) * (btn_h + BUTTON_SPACING)
		btn_rect := Rect{
			min = {content.min.x, item_y},
			max = {content.max.x, item_y + btn_h},
		}
		ui_button_render(r, ui, btn_rect, menu_labels[item], item == gs.menu_selected)
	}
}

draw_options :: proc(r: ^Renderer, gs: ^GameState, settings: ^Settings) {
	draw_text(r, r.font, "OPTIONS", {GAME_SIZE.x / 2, 80}, WHITE, .Center)

	resolutions := RESOLUTIONS
	res         := resolutions[settings.resolution_idx]
	values  := [2]string{display_mode_name(settings.display_mode), fmt.tprintf("%dx%d", res.x, res.y)}
	item_h  := r.font.size
	spacing := f32(30)
	start_y := f32(150)

	option_labels := OPTION_LABELS
	for item in OptionsItem.DisplayMode..=OptionsItem.Resolution {
		fullscreen_res := item == .Resolution && settings.display_mode == .Fullscreen
		color := GREY if fullscreen_res else (YELLOW if item == gs.options_focused else WHITE)
		y     := start_y + f32(int(item)) * (item_h + spacing)
		draw_text(r, r.font, option_labels[item], {GAME_SIZE.x * 0.18, y}, color, .Left)
		draw_text(r, r.font, fmt.tprintf("< %s >", values[int(item)]), {GAME_SIZE.x * 0.52, y}, color, .Left)
	}

	back_color := YELLOW if gs.options_focused == .Back else WHITE
	back_y     := start_y + 2 * (item_h + spacing)
	draw_text(r, r.font, option_labels[.Back], {GAME_SIZE.x / 2, back_y}, back_color, .Center)
}

draw_game_over :: proc(r: ^Renderer, state: ^LevelState) {
	draw_text(r, r.font, "GAME OVER", {GAME_SIZE.x / 2, GAME_SIZE.y / 2 - 60}, WHITE, .Center)
	draw_text(r, r.font, fmt.tprintf("Score: %d", state.score), GAME_SIZE / 2, WHITE, .Center)
	draw_text(r, r.font, "Press Enter to return to menu", {GAME_SIZE.x / 2, GAME_SIZE.y / 2 + 60}, WHITE, .Center)
}

draw_level_complete :: proc(r: ^Renderer) {
	draw_text(r, r.font, "LEVEL COMPLETE!", {GAME_SIZE.x / 2, GAME_SIZE.y / 2 - 30}, YELLOW, .Center)
	draw_text(r, r.font, "Press Space to continue", {GAME_SIZE.x / 2, GAME_SIZE.y / 2 + 30}, WHITE, .Center)
}

draw_waiting_to_start :: proc(r: ^Renderer) {
	draw_rect(r, Rect{min = {}, max = GAME_SIZE}, Color{0, 0, 0, 0.6})
	draw_text(r, r.font, "Press space to start", {GAME_SIZE.x / 2, (GAME_SIZE.y - r.font.size) / 2}, WHITE, .Center)
}

draw_paused :: proc(r: ^Renderer, gs: ^GameState, ui: UI) {
	draw_rect(r, Rect{min = {}, max = GAME_SIZE}, Color{0, 0, 0, 0.6})

	pause_labels := PAUSE_LABELS
	btn_h   := r.ui_font.size + BUTTON_PAD_Y * 2

	max_label_w := f32(0)
	for item in PauseItem { max_label_w = max(max_label_w, text_width(r.ui_font, pause_labels[item])) }
	btn_w := max_label_w + BUTTON_PAD_X * 2

	title       := "PAUSED"
	title_w     := text_width(r.ui_font, title) + WINDOW_PAD * 2
	btns_h      := f32(len(PauseItem)) * btn_h + f32(len(PauseItem) - 1) * BUTTON_SPACING
	win_w       := max(btn_w, title_w) + WINDOW_PAD * 2
	win_h       := WINDOW_BORDER + WINDOW_PAD + btns_h + WINDOW_PAD
	win_rect    := Rect{
		min = {GAME_SIZE.x/2 - win_w/2, GAME_SIZE.y/2 - win_h/2},
		max = {GAME_SIZE.x/2 + win_w/2, GAME_SIZE.y/2 + win_h/2},
	}
	content := ui_window_render(r, ui, win_rect, title)

	for item in PauseItem {
		item_y   := content.min.y + f32(int(item)) * (btn_h + BUTTON_SPACING)
		btn_rect := Rect{
			min = {content.min.x, item_y},
			max = {content.max.x, item_y + btn_h},
		}
		ui_button_render(r, ui, btn_rect, pause_labels[item], item == gs.pause_selected)
	}
}

draw_playing :: proc(r: ^Renderer, gs: ^GameState, run: ^RunState, state: ^LevelState, ps: ^ParticleSystem, types: []BlockType, ui: ^UI) {
	// Tiled background pattern behind everything
	if r.bg_pattern.id != 0 {
		draw_two_tone_tiled(r, Rect{min = {}, max = GAME_SIZE}, r.bg_pattern, 64, Color{0.14, 0.14, 0.14, 1}, Color{0.10, 0.10, 0.10, 1})
	}
	draw_rect(r, state.playing_area, BLACK)

	draw_text(r, r.font, fmt.tprintf("Score: %d", state.score), {GAME_SIZE.x - 10, 10}, WHITE, .Right)
	draw_text(r, r.font, fmt.tprintf("Lives: %d", run.lives), {10, 10}, WHITE, .Left)
	draw_text(r, r.font, fmt.tprintf("Level: %d", run.level_idx + 1), {GAME_SIZE.x / 2, 10}, WHITE, .Center)

	for &ball in state.balls {
		draw_circle(r, ball.circle, WHITE)
	}

	epw_render  := effective_paddle_width(state)
	paddle_half := vec2{epw_render, PADDLE_SIZE.y} / 2
	paddle_pts: [PADDLE_SLICES * 2 + 2]vec2
	// Top curve: left to right
	for i in 0..=PADDLE_SLICES {
		t := f32(i) / f32(PADDLE_SLICES) * 2.0 - 1.0
		x := state.paddle.pos.x - paddle_half.x + f32(i) / f32(PADDLE_SLICES) * epw_render
		y := state.paddle.pos.y - paddle_half.y - PADDLE_BOW_HEIGHT * (1.0 - t * t)
		paddle_pts[i] = {x, y}
	}
	// Bottom edge: right to left
	for i in 0..=PADDLE_SLICES {
		x := state.paddle.pos.x + paddle_half.x - f32(i) / f32(PADDLE_SLICES) * epw_render
		y := state.paddle.pos.y + paddle_half.y
		paddle_pts[PADDLE_SLICES + 1 + i] = {x, y}
	}
	draw_polygon(r, paddle_pts[:], WHITE)

	for row in 0..<BLOCK_ROWS {
		for col in 0..<BLOCK_COLS {
			b := state.blocks[row * BLOCK_COLS + col]
			if b.lives <= 0 { continue }
			br := block_rect(col, row)
			draw_rect(r, br, block_color(b, types))
			// Draw crack overlay if block has taken damage
			if b.type_idx >= 0 && b.type_idx < len(types) {
				max_lives := types[b.type_idx].lives
				if b.lives < max_lives {
					draw_block_damage(r, br, max_lives - b.lives)
				}
			}
		}
	}

	// Draw item drops
	item_colors := ITEM_COLORS
	for di in 0..<state.drop_count {
		d    := state.drops[di]
		half := ITEM_SIZE / 2
		draw_rect(r, Rect{min = d.pos - half, max = d.pos + half}, item_colors[d.kind])
	}

	particles_draw(ps, r)

	// Draw active effects HUD using ui widgets
	{
		effect_labels := [ItemKind]string{
			.ExtraLife    = "LIFE",
			.ExtraBall    = "BALL",
			.WidePaddle   = "WIDE",
			.NarrowPaddle = "NARROW",
			.StickyPaddle = "STICKY",
			.FastBall     = "FAST",
			.SlowBall     = "SLOW",
		}
		item_colors := ITEM_COLORS
		has_any := false
		for kind in ItemKind {
			if state.effect_timers[kind] > 0 { has_any = true; break }
		}
		if has_any {
			ui.cursor = {10, GAME_SIZE.y - 30}
			ui_row_begin(ui)
			for kind in ItemKind {
				t := state.effect_timers[kind]
				if t <= 0 { continue }
				ui_indicator(r, ui, item_colors[kind], 10)
				label := fmt.tprintf("%s %.0fs", effect_labels[kind], t)
				draw_text(r, r.ui_font, label, ui.cursor, item_colors[kind], .Left)
				ui.cursor.x += text_width(r.ui_font, label) + 12
			}
			ui_row_end(ui)
		}
	}

	switch gs.playing_state {
	case .WaitingToStart: draw_waiting_to_start(r)
	case .Paused:         draw_paused(r, gs, ui^)
	case .Active:
	}
}

apply_item_effect :: proc(run: ^RunState, state: ^LevelState, kind: ItemKind) {
	switch kind {
	case .ExtraLife:
		run.lives += 1
	case .ExtraBall:
		if len(state.balls) < MAX_BALLS {
			new_ball := state.balls[0]
			new_ball.dir.x = -new_ball.dir.x
			append(&state.balls, new_ball)
		}
		add_effect(state, kind)
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

handle_event :: proc(event: SDL.Event, gs: ^GameState, run: ^RunState, state: ^LevelState, levels: []Level, r: ^Renderer, window: ^SDL.Window, settings: ^Settings) {
	#partial switch event.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		gs.running = false
	case .WINDOW_RESIZED:
		renderer_set_window_size(r, {event.window.data1, event.window.data2})
	case .KEY_DOWN:
		switch gs.screen {
		case .MainMenu:      handle_main_menu(event, gs)
		case .Options:       handle_options(event, gs, settings, window, r)
		case .GameOver:      handle_game_over(event, gs, run, state, levels)
		case .LevelComplete: handle_level_complete(event, gs, run, state, levels)
		case .Playing:
			switch gs.playing_state {
			case .WaitingToStart: handle_waiting_to_start(event, gs, state)
			case .Paused:         handle_paused(event, gs, run, state, levels)
			case .Active:         handle_playing(event, gs, state)
			}
		}
	case .KEY_UP:
		#partial switch event.key.scancode {
		case .LEFT:  gs.left_held  = false
		case .RIGHT: gs.right_held = false
		}
	}
}

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
	if has_effect(state, .FastBall) { s *= 1.5 }
	if has_effect(state, .SlowBall) { s *= 0.6 }
	return s
}

paddle_bounce_normal :: proc(hit_x: f32, paddle_center_x: f32, paddle_half_width: f32) -> vec2 {
	t := clamp((hit_x - paddle_center_x) / paddle_half_width, -1, 1)
	max_angle :: f32(67.5 * math.PI / 180.0)
	angle := t * max_angle
	return glsl.normalize(vec2{math.sin(angle), -math.cos(angle)})
}


simulate_step :: proc(gs: ^GameState, run: ^RunState, state: ^LevelState, ps: ^ParticleSystem, types: []BlockType) {
	dt := SIM_DT
	state.sim_steps += 1
	state.sim_time  += dt

	// Paddle movement
	if gs.left_held  { state.paddle.pos.x -= PADDLE_SPEED * dt }
	if gs.right_held { state.paddle.pos.x += PADDLE_SPEED * dt }
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
						state.score += 100
						ball.pos -= sep * normal
						ball.dir = glsl.normalize(glsl.reflect(ball.dir, normal))
						game_log(state, fmt.tprintf("block_hit col=%d row=%d lives_left=%d", col, row, state.blocks[idx].lives))
						if state.blocks[idx].lives <= 0 {
							game_log(state, fmt.tprintf("block_destroyed col=%d row=%d", col, row))
							emit_color := block_color(state.blocks[idx], types)
							center := (rect.min + rect.max) / 2
							particles_emit(ps, center, 17, EmitConfig{
								color        = emit_color,
								speed_min    = 50,
								speed_max    = 200,
								size_min     = 2,
								size_max     = 6,
								lifetime_min = 0.3,
								lifetime_max = 0.8,
								spread       = glsl.TAU,
								direction    = 0,
								fade         = true,
								shrink       = true,
							})
							if rand.float32() < ITEM_DROP_CHANCE && state.drop_count < MAX_DROPS {
								kind := ItemKind(rand.int31_max(i32(len(ItemKind))))
								state.drops[state.drop_count] = ItemDrop{pos = center, kind = kind, active = true}
								state.drop_count += 1
								game_log(state, fmt.tprintf("item_spawned kind=%v pos=[%.1f,%.1f]", kind, center.x, center.y))
							}
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

	// Update item drops
	for di := state.drop_count - 1; di >= 0; di -= 1 {
		if !state.drops[di].active { continue }
		state.drops[di].pos.y += ITEM_FALL_SPEED * dt

		// Check paddle catch
		drop_paddle_half := vec2{pw, PADDLE_SIZE.y} / 2
		paddle_rect2 := Rect{min = state.paddle.pos - drop_paddle_half, max = state.paddle.pos + drop_paddle_half}
		if point_inside_rect(state.drops[di].pos, paddle_rect2) {
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
			lock_x := f32(PADDLE_SIZE.x * 0.2)
			lock_t := lock_x / (pw / 2)
			lock_y := paddle_surface_y(0, PADDLE_SIZE.y / 2, lock_t) - BALL_RADIUS
			append(&state.balls, Ball{
				circle      = {pos = state.paddle.pos + {lock_x, lock_y}, radius = BALL_RADIUS},
				locked      = true,
				lock_offset = {lock_x, lock_y},
			})
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

update :: proc(
	gs:       ^GameState,
	run:      ^RunState,
	state:    ^LevelState,
	levels:   []Level,
	r:        ^Renderer,
	window:   ^SDL.Window,
	settings: ^Settings,
	ui:       ^UI,
	ps:       ^ParticleSystem,
	types:    []BlockType,
) {
	event: SDL.Event
	for SDL.PollEvent(&event) {
		handle_event(event, gs, run, state, levels, r, window, settings)
	}

	// Fixed-step simulation
	if gs.screen == .Playing && gs.playing_state == .Active {
		if gs.sim_paused {
			// Manual stepping: run exactly the requested number of steps
			for gs.sim_steps_requested > 0 {
				simulate_step(gs, run, state, ps, types)
				gs.sim_steps_requested -= 1
				if gs.screen != .Playing || gs.playing_state != .Active { break }
			}
		} else {
			state.sim_accumulator += gs.dt
			for state.sim_accumulator >= SIM_DT {
				simulate_step(gs, run, state, ps, types)
				state.sim_accumulator -= SIM_DT
				if gs.screen != .Playing || gs.playing_state != .Active { break }
			}
		}
	}

	// Particles are visual-only — update with frame dt
	if gs.screen == .Playing && gs.playing_state == .Active {
		particles_update(ps, gs.dt)
	}

	// Draw calls
	r.clear_color = DARK_GREY if gs.screen == .Playing else BLACK

	switch gs.screen {
	case .MainMenu:      draw_main_menu(r, gs, ui^)
	case .Options:       draw_options(r, gs, settings)
	case .GameOver:      draw_game_over(r, state)
	case .LevelComplete: draw_level_complete(r)
	case .Playing:       draw_playing(r, gs, run, state, ps, types, ui)
	}
}

main :: proc() {
	opts: Options
	flags.parse_or_exit(&opts, os.args, .Unix)

	screenshot_dir := "screenshots"
	if opts.test_script != "" {
		screenshot_dir = fmt.aprintf("%s/%s", fp.dir(opts.test_script, context.temp_allocator), fp.stem(opts.test_script))
	}

	if infos, err := os.read_directory_by_path(screenshot_dir, 0, context.allocator); err == nil {
		for fi in infos {
			os.remove(fi.fullpath)
		}
		os.file_info_slice_delete(infos, context.allocator)
	}
	os.make_directory(screenshot_dir)

	if !SDL.Init(SDL.InitFlags{.VIDEO}) {
		fmt.eprintln("SDL_Init failed:", SDL.GetError())
		return
	}
	defer SDL.Quit()

	SDL.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	SDL.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	SDL.GL_SetAttribute(.CONTEXT_PROFILE_MASK, 1)
	SDL.GL_SetAttribute(.DOUBLEBUFFER, 1)

	window := SDL.CreateWindow(WINDOW_TITLE, GAME_WIDTH, GAME_HEIGHT, SDL.WindowFlags{.OPENGL})
	if window == nil {
		fmt.eprintln("CreateWindow failed:", SDL.GetError())
		return
	}
	defer SDL.DestroyWindow(window)
	SDL.SetWindowPosition(window, SDL.WINDOWPOS_CENTERED, SDL.WINDOWPOS_CENTERED)

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

	ps := particles_init()
	defer particles_destroy(&ps)

	ui, _ := ui_load()
	defer ui_destroy(&ui)

	settings := settings_load()

	test_script: TestScript
	if opts.test_script != "" {
		test_script, _ = test_script_load(opts.test_script)
		if s, ok := test_script.settings.?; ok {
			settings = s
		}
	}

	apply_display_settings(window, &r, settings)

	block_types, _ := block_types_load()
	defer delete(block_types)

	levels, levels_ok := levels_load(block_types)
	if !levels_ok { return }
	defer delete(levels)

	state: LevelState
	run: RunState
	run_state_init(&run, &state, levels)

	if idx, ok := test_script.level_idx.?; ok && idx < len(levels) {
		run.level_idx = idx
		level_state_init(&state, levels[idx])
	}

	stdin_reader: StdinReader
	stdin_reader_init(&stdin_reader)

	gs: GameState
	gs.running        = true
	gs.screen         = .MainMenu
	gs.pause_selected = .Resume
	gs.sim_paused        = opts.pause_sim || test_script.pause_sim
	gs.quit_on_complete  = opts.quit_on_complete
	gs.quit_on_gameover  = opts.quit_on_gameover
	gs.options_focused = .DisplayMode

	screenshot_counter := 0
	prev_counter := SDL.GetPerformanceCounter()
	freq         := SDL.GetPerformanceFrequency()

	for gs.running {
		now          := SDL.GetPerformanceCounter()
		gs.dt         = f32(now - prev_counter) / f32(freq)
		prev_counter  = now
		gs.elapsed   += gs.dt

		free_all(context.temp_allocator)
		test_script_pump(&test_script, gs.elapsed, &gs.should_screenshot, &gs.running, &gs.sim_steps_requested)
		stdin_reader_pump(&stdin_reader, &gs.should_screenshot, &gs.running, &gs.sim_steps_requested, &gs, &run, &state)
		renderer_start_frame(&r)
		update(&gs, &run, &state, levels, &r, window, &settings, &ui, &ps, block_types)
		renderer_end_frame(&r, &gs.should_screenshot, &screenshot_counter, &state, window, screenshot_dir)
	}

	// Stdin reader thread may be blocked on os.read — close the fd to unblock it.
	stdin_reader_destroy(&stdin_reader)
}
