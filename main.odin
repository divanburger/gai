package main

import "core:fmt"
import "core:flags"
import "core:os"
import fp "core:path/filepath"
import glsl "core:math/linalg/glsl"
import SDL "vendor:sdl3"
import GL "vendor:OpenGL"

WINDOW_TITLE   :: "Shardbreak"
GAME_WIDTH     :: 1280
GAME_HEIGHT    :: 720
GAME_SIZE      :: vec2{GAME_WIDTH, GAME_HEIGHT}
WINDOW_SIZE    :: ivec2{GAME_WIDTH, GAME_HEIGHT}
SEGMENTS       :: 64
VERTEX_COUNT   :: SEGMENTS + 2

MenuItem    :: enum { Continue, StartGame, Options, Quit }
MENU_LABELS :: [MenuItem]string{ .Continue = "Continue", .StartGame = "Start game", .Options = "Options", .Quit = "Quit" }

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
	should_screenshot:  bool,
	dt:                 f32,
	elapsed:            f32,
	sim_paused:         bool,
	sim_steps_requested: int,
	quit_on_complete:   bool,
	quit_on_gameover:   bool,
	has_save:           bool,
}

Game :: struct {
	window:             ^SDL.Window,
	gl_ctx:             SDL.GLContext,
	r:                  Renderer,
	assets:             AssetSystem,
	ps:                 ParticleSystem,
	ui:                 UI,
	input:              Input,
	block_types:        []BlockType,
	levels:             []Level,
	state:              LevelState,
	run:                RunState,
	gs:                 GameState,
	stdin_reader:       StdinReader,
	settings:           Settings,
	test_script:        TestScript,
	screenshot_dir:     string,
	screenshot_counter: int,
	prev_counter:       u64,
	freq:               u64,
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
	renderer_apply_display(r, window, s.display_mode, resolutions[s.resolution_idx])
}

Options :: struct {
	test_script:      string `usage:"Path to a test script JSON file to replay."`,
	pause_sim:        bool   `usage:"Start with the simulation paused."`,
	quit_on_complete: bool   `usage:"Quit when a level is completed."`,
	quit_on_gameover: bool   `usage:"Quit on game over."`,
}

menu_next :: proc(gs: ^GameState, delta: int) {
	count := len(MenuItem)
	cur   := int(gs.menu_selected)
	for {
		cur = (cur + delta + count) % count
		item := MenuItem(cur)
		// Skip Continue when no save file exists
		if item == .Continue && !gs.has_save { continue }
		gs.menu_selected = item
		return
	}
}

handle_main_menu :: proc(event: SDL.Event, gs: ^GameState, run: ^RunState, state: ^LevelState, levels: []Level) {
	#partial switch event.key.scancode {
	case .UP:   menu_next(gs, -1)
	case .DOWN: menu_next(gs, 1)
	case .RETURN, .KP_ENTER:
		switch gs.menu_selected {
		case .Continue:
			if load_game(run, state, levels) {
				save_delete()
				gs.has_save = false
				gs.screen = .Playing
				gs.playing_state = .WaitingToStart
			}
		case .StartGame: gs.screen = .Playing; gs.playing_state = .WaitingToStart
		case .Options:   gs.screen = .Options; gs.options_focused = .DisplayMode
		case .Quit:      gs.running = false
		}
	case .ESCAPE: gs.running = false
	}
}

handle_options :: proc(event: SDL.Event, gs: ^GameState, settings: ^Settings) {
	options_next :: proc(gs: ^GameState, settings: ^Settings, delta: int) {
		count := len(OptionsItem)
		cur   := int(gs.options_focused)
		for {
			cur = (cur + delta + count) % count
			item := OptionsItem(cur)
			if item == .Resolution && settings.display_mode == .Fullscreen { continue }
			gs.options_focused = item
			return
		}
	}
	#partial switch event.key.scancode {
	case .ESCAPE:
		gs.screen = .MainMenu
	case .UP:
		options_next(gs, settings, -1)
	case .DOWN:
		options_next(gs, settings, 1)
	case .RETURN, .KP_ENTER:
		if gs.options_focused == .Back { gs.screen = .MainMenu }
	}
}

handle_game_over :: proc(event: SDL.Event, gs: ^GameState, run: ^RunState, state: ^LevelState, levels: []Level) {
	#partial switch event.key.scancode {
	case .RETURN, .KP_ENTER, .ESCAPE:
		save_delete()
		gs.has_save = false
		gs.screen = .MainMenu
		gs.menu_selected = .StartGame
		run_state_init(run, state, levels)
		gs.playing_state = .Active
	}
}

handle_level_complete :: proc(event: SDL.Event, gs: ^GameState, run: ^RunState, state: ^LevelState, levels: []Level) {
	#partial switch event.key.scancode {
	case .SPACE, .RETURN, .KP_ENTER:
		run.run_score += state.score
		run.level_idx += 1
		if run.level_idx >= len(levels) {
			save_delete()
			gs.has_save = false
			gs.menu_selected = .StartGame
			gs.screen = .MainMenu
			run_state_init(run, state, levels)
		} else {
			level_state_init(state, levels[run.level_idx])
			save_game(run, state)
			gs.has_save = save_exists()
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
			save_game(run, state)
			gs.has_save = save_exists()
			gs.menu_selected = .Continue if gs.has_save else .StartGame
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
	}
}

MENU_BG_SCROLL_SPEED :: vec2{0.03, 0.02} // UV units per second (diagonal)
MENU_BG_A            :: Color{0.12, 0.12, 0.12, 1}
MENU_BG_B            :: Color{0.08, 0.08, 0.08, 1}

draw_menu_background :: proc(r: ^Renderer, assets: ^AssetSystem, elapsed: f32) {
	bg := asset_get_texture(assets, "bg_pattern")
	if bg.id != 0 {
		offset := MENU_BG_SCROLL_SPEED * elapsed
		draw_two_tone_tiled(r, Rect{min = {}, max = GAME_SIZE}, bg, 64, MENU_BG_A, MENU_BG_B, offset)
	}
}

draw_main_menu :: proc(r: ^Renderer, gs: ^GameState, ui: UI, assets: ^AssetSystem, elapsed: f32) {
	draw_menu_background(r, assets, elapsed)
	menu_labels := MENU_LABELS
	btn_h   := r.ui_font.size + BUTTON_PAD_Y * 2

	// Count visible items and measure widths
	visible_count := 0
	max_label_w   := f32(0)
	for item in MenuItem {
		if item == .Continue && !gs.has_save { continue }
		visible_count += 1
		max_label_w = max(max_label_w, text_width(r.ui_font, menu_labels[item]))
	}
	btn_w := max_label_w + BUTTON_PAD_X * 2

	title       := WINDOW_TITLE
	title_w     := text_width(r.ui_font, title) + WINDOW_PAD * 2
	btns_h      := f32(visible_count) * btn_h + f32(visible_count - 1) * BUTTON_SPACING
	win_w       := max(btn_w, title_w) + WINDOW_PAD * 2
	win_h       := WINDOW_BORDER + WINDOW_PAD + btns_h + WINDOW_PAD
	win_rect    := Rect{
		min = {GAME_SIZE.x/2 - win_w/2, GAME_SIZE.y/2 - win_h/2},
		max = {GAME_SIZE.x/2 + win_w/2, GAME_SIZE.y/2 + win_h/2},
	}
	content := ui_window_render(r, ui, win_rect, title)

	row := 0
	for item in MenuItem {
		if item == .Continue && !gs.has_save { continue }
		item_y   := content.min.y + f32(row) * (btn_h + BUTTON_SPACING)
		btn_rect := Rect{
			min = {content.min.x, item_y},
			max = {content.max.x, item_y + btn_h},
		}
		ui_button_render(r, ui, btn_rect, menu_labels[item], item == gs.menu_selected)
		row += 1
	}
}

draw_options :: proc(r: ^Renderer, gs: ^GameState, settings: ^Settings, assets: ^AssetSystem, elapsed: f32, ui: ^UI, window: ^SDL.Window) {
	draw_menu_background(r, assets, elapsed)

	resolutions := RESOLUTIONS
	res: ivec2
	if settings.display_mode == .Fullscreen {
		res = r.window_size
	} else {
		res = resolutions[settings.resolution_idx]
	}
	values := [OptionsItem]string{
		.DisplayMode = display_mode_name(settings.display_mode),
		.Resolution  = fmt.tprintf("%dx%d", res.x, res.y),
		.Back        = "",
	}

	option_labels := OPTION_LABELS
	text_h := r.ui_font.size
	btn_h  := text_h + BUTTON_PAD_Y * 2

	// Measure widest selector row to size the window
	// Each selector: label + padding + [<] + gap + [inlay] + gap + [>]
	// We need to ensure the inlay fits the widest value text
	max_label_w := f32(0)
	max_value_w := f32(0)
	for item in OptionsItem.DisplayMode..=OptionsItem.Resolution {
		max_label_w = max(max_label_w, text_width(r.ui_font, option_labels[item]))
		max_value_w = max(max_value_w, text_width(r.ui_font, values[item]))
	}
	// inlay needs padding around the value text
	inlay_w    := max_value_w + BUTTON_PAD_X * 2
	sel_row_w  := max_label_w + BUTTON_PAD_X + SELECTOR_ARROW_W + SELECTOR_GAP + inlay_w + SELECTOR_GAP + SELECTOR_ARROW_W
	back_w     := text_width(r.ui_font, option_labels[.Back]) + BUTTON_PAD_X * 2
	title      := "OPTIONS"
	title_w    := text_width(r.ui_font, title) + WINDOW_PAD * 2

	item_count := len(OptionsItem)
	btns_h   := f32(item_count) * btn_h + f32(item_count - 1) * BUTTON_SPACING
	win_w    := max(sel_row_w, back_w, title_w) + WINDOW_PAD * 2
	win_h    := WINDOW_BORDER + WINDOW_PAD + btns_h + WINDOW_PAD
	win_rect := Rect{
		min = {GAME_SIZE.x/2 - win_w/2, GAME_SIZE.y/2 - win_h/2},
		max = {GAME_SIZE.x/2 + win_w/2, GAME_SIZE.y/2 + win_h/2},
	}
	content := ui_window_render(r, ui^, win_rect, title)
	ui.cursor = content.min

	content_w := content.max.x - content.min.x
	changed := false

	dm_delta := ui_selector(r, ui, option_labels[.DisplayMode], values[.DisplayMode], content_w, gs.options_focused == .DisplayMode, max_label_w)
	if dm_delta != 0 {
		settings.display_mode = DisplayMode((int(settings.display_mode) + dm_delta + len(DisplayMode)) % len(DisplayMode))
		changed = true
	}

	res_disabled := settings.display_mode == .Fullscreen
	res_delta := ui_selector(r, ui, option_labels[.Resolution], values[.Resolution], content_w, gs.options_focused == .Resolution, max_label_w, res_disabled)
	if res_delta != 0 {
		settings.resolution_idx = (settings.resolution_idx + res_delta + len(RESOLUTIONS)) % len(RESOLUTIONS)
		changed = true
	}

	if changed {
		apply_display_settings(window, r, settings^)
		settings_save(settings^)
	}

	// Back button (full width)
	back_rect := Rect{
		min = ui.cursor,
		max = {content.max.x, ui.cursor.y + btn_h},
	}
	ui_button_render(r, ui^, back_rect, option_labels[.Back], gs.options_focused == .Back)
}

OVERLAY_DIM :: Color{0, 0, 0, 0.85}

draw_game_over :: proc(r: ^Renderer, run: ^RunState, state: ^LevelState) {
	draw_rect(r, Rect{min = {}, max = GAME_SIZE}, OVERLAY_DIM)
	draw_text(r, r.font, "GAME OVER", {GAME_SIZE.x / 2, GAME_SIZE.y / 2 - 60}, WHITE, .Center)
	draw_text(r, r.font, fmt.tprintf("Score: %d", run.run_score + state.score), GAME_SIZE / 2, WHITE, .Center)
	draw_text(r, r.font, "Press Enter to return to menu", {GAME_SIZE.x / 2, GAME_SIZE.y / 2 + 60}, WHITE, .Center)
}

draw_level_complete :: proc(r: ^Renderer, run: ^RunState, state: ^LevelState) {
	draw_rect(r, Rect{min = {}, max = GAME_SIZE}, OVERLAY_DIM)
	draw_text(r, r.font, "LEVEL COMPLETE!", {GAME_SIZE.x / 2, GAME_SIZE.y / 2 - 60}, YELLOW, .Center)
	draw_text(r, r.font, fmt.tprintf("Level Score: %d", state.score), {GAME_SIZE.x / 2, GAME_SIZE.y / 2 - 10}, WHITE, .Center)
	draw_text(r, r.font, fmt.tprintf("Total Score: %d", run.run_score + state.score), {GAME_SIZE.x / 2, GAME_SIZE.y / 2 + 30}, WHITE, .Center)
	draw_text(r, r.font, "Press Space to continue", {GAME_SIZE.x / 2, GAME_SIZE.y / 2 + 80}, WHITE, .Center)
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

PLAY_AREA_BORDER_COLOR :: Color{0.25, 0.25, 0.25, 1}
PLAY_AREA_BORDER_WIDTH :: f32(2)
PLAY_AREA_BG_A         :: Color{0.06, 0.06, 0.06, 1}
PLAY_AREA_BG_B         :: Color{0.03, 0.03, 0.03, 1}

draw_balls :: proc(r: ^Renderer, gs: ^GameState, state: ^LevelState) {
	for &ball in state.balls {
		ball_color := WHITE
		if ball.ghost { ball_color.a = 0.4 }
		draw_circle(r, ball.circle, ball_color)

		// Draw a transparent dotted line showing launch direction for locked balls
		if ball.locked || gs.playing_state == .WaitingToStart {
			dir: vec2
			if ball.locked {
				pw := effective_paddle_width(state)
				dir = paddle_bounce_normal(ball.pos.x, state.paddle.pos.x, pw / 2)
			} else {
				dir = ball.dir
			}
			if glsl.length(dir) > 0 {
				arrow_color := Color{1, 1, 1, 0.15}
				dot_spacing :: f32(8)
				dot_count   :: 6
				dot_radius  :: f32(1.5)
				start_dist  := ball.radius + 4
				for i in 0..<dot_count {
					d := start_dist + f32(i) * dot_spacing
					dot_pos := ball.pos + dir * d
					draw_circle(r, Circle{pos = dot_pos, radius = dot_radius}, arrow_color)
				}
			}
		}
	}
}

draw_paddle :: proc(r: ^Renderer, state: ^LevelState) {
	epw_render  := effective_paddle_width(state)
	paddle_half := vec2{epw_render, PADDLE_SIZE.y} / 2
	paddle_pts: [PADDLE_SLICES * 2 + 2]vec2
	for i in 0..=PADDLE_SLICES {
		t := f32(i) / f32(PADDLE_SLICES) * 2.0 - 1.0
		x := state.paddle.pos.x - paddle_half.x + f32(i) / f32(PADDLE_SLICES) * epw_render
		y := paddle_surface_y(state.paddle.pos.y, paddle_half.y, t)
		paddle_pts[i] = {x, y}
	}
	for i in 0..=PADDLE_SLICES {
		x := state.paddle.pos.x + paddle_half.x - f32(i) / f32(PADDLE_SLICES) * epw_render
		y := state.paddle.pos.y + paddle_half.y
		paddle_pts[PADDLE_SLICES + 1 + i] = {x, y}
	}
	draw_polygon(r, paddle_pts[:], state.paddle_tint)
}

draw_blocks :: proc(r: ^Renderer, state: ^LevelState, types: []BlockType) {
	for row in 0..<BLOCK_ROWS {
		for col in 0..<BLOCK_COLS {
			b := state.blocks[row * BLOCK_COLS + col]
			if b.lives <= 0 { continue }
			br := block_rect(col, row)
			draw_rect(r, br, block_color(b, types))
			if b.type_idx >= 0 && b.type_idx < len(types) {
				max_lives := types[b.type_idx].hit_points
				if b.lives < max_lives {
					draw_block_damage(r, br, max_lives - b.lives)
				}
			}
		}
	}
}

// draw_item_icon draws a colored circle with an icon overlay at the given position and size.
draw_item_icon :: proc(r: ^Renderer, kind: ItemKind, pos: vec2, size: f32) {
	colors := ITEM_COLORS
	icons  := ITEM_ICONS
	draw_circle(r, Circle{pos = pos, radius = size / 2}, colors[kind])
	tex := r.icons[icons[kind]]
	if tex.id != 0 {
		half := vec2{size, size} * 0.5
		draw_image(r, Rect{min = pos - half, max = pos + half}, tex, color_readable(colors[kind]))
	}
}

draw_item_drops :: proc(r: ^Renderer, state: ^LevelState) {
	for di in 0..<state.drop_count {
		d := state.drops[di]
		draw_item_icon(r, d.kind, d.pos, ITEM_SIZE.x)
	}
}

draw_effects_hud :: proc(r: ^Renderer, state: ^LevelState, ui: ^UI) {
	effect_labels := [ItemKind]string{
		.ExtraLife    = "LIFE",
		.ExtraBall    = "BALL",
		.WidePaddle   = "WIDE",
		.NarrowPaddle = "NARROW",
		.StickyPaddle = "STICKY",
		.FastBall     = "FAST",
		.SlowBall     = "SLOW",
		.Punch        = "PUNCH",
	}
	has_any := false
	for kind in ItemKind {
		if state.effect_timers[kind] > 0 { has_any = true; break }
	}
	if !has_any { return }
	colors := ITEM_COLORS
	icon_size := ITEM_SIZE.x
	ui.cursor = {10, GAME_SIZE.y - ITEM_SIZE.x - 10}
	ui_row_begin(ui)
	for kind in ItemKind {
		t := state.effect_timers[kind]
		if t <= 0 { continue }
		icon_center := ui.cursor + {icon_size / 2, icon_size / 2}
		draw_item_icon(r, kind, icon_center, icon_size)
		ui.cursor.x += icon_size + BUTTON_SPACING
		ui.line_height = max(ui.line_height, icon_size)
		label := fmt.tprintf("%s %.0fs", effect_labels[kind], t)
		draw_text(r, r.ui_font, label, ui.cursor, colors[kind], .Left)
		ui.cursor.x += text_width(r.ui_font, label) + 12
	}
	ui_row_end(ui)
}

draw_playing :: proc(r: ^Renderer, gs: ^GameState, run: ^RunState, state: ^LevelState, ps: ^ParticleSystem, types: []BlockType, ui: ^UI, assets: ^AssetSystem) {
	bg := asset_get_texture(assets, "bg_pattern")
	if bg.id != 0 {
		draw_two_tone_tiled(r, Rect{min = {}, max = GAME_SIZE}, bg, 64, Color{0.14, 0.14, 0.14, 1}, Color{0.10, 0.10, 0.10, 1})
	}

	pa := state.playing_area
	border_rect := grow_rect(pa, PLAY_AREA_BORDER_WIDTH)
	draw_rect(r, border_rect, PLAY_AREA_BORDER_COLOR)
	if bg.id != 0 {
		draw_two_tone_tiled(r, pa, bg, 64, PLAY_AREA_BG_A, PLAY_AREA_BG_B)
	} else {
		draw_rect(r, pa, BLACK)
	}

	draw_text(r, r.font, fmt.tprintf("Score: %d", state.score), {GAME_SIZE.x - 10, 10}, WHITE, .Right)
	draw_text(r, r.font, fmt.tprintf("Lives: %d", run.lives), {10, 10}, WHITE, .Left)
	draw_text(r, r.font, fmt.tprintf("Level: %d", run.level_idx + 1), {GAME_SIZE.x / 2, 10}, WHITE, .Center)

	draw_balls(r, gs, state)
	draw_paddle(r, state)
	draw_blocks(r, state, types)
	draw_item_drops(r, state)
	particles_draw(ps, r)
	draw_effects_hud(r, state, ui)

	switch gs.playing_state {
	case .WaitingToStart: draw_waiting_to_start(r)
	case .Paused:         draw_paused(r, gs, ui^)
	case .Active:
	}
}

handle_event :: proc(event: SDL.Event, gs: ^GameState, run: ^RunState, state: ^LevelState, levels: []Level, r: ^Renderer, window: ^SDL.Window, settings: ^Settings, input: ^Input) {
	input_process_event(input, event)

	#partial switch event.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		gs.running = false
	case .WINDOW_RESIZED:
		renderer_set_window_size(r, {event.window.data1, event.window.data2})
	case .KEY_DOWN:
		switch gs.screen {
		case .MainMenu:      handle_main_menu(event, gs, run, state, levels)
		case .Options:       handle_options(event, gs, settings)
		case .GameOver:      handle_game_over(event, gs, run, state, levels)
		case .LevelComplete: handle_level_complete(event, gs, run, state, levels)
		case .Playing:
			switch gs.playing_state {
			case .WaitingToStart: handle_waiting_to_start(event, gs, state)
			case .Paused:         handle_paused(event, gs, run, state, levels)
			case .Active:         handle_playing(event, gs, state)
			}
		}
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
	assets:   ^AssetSystem,
	input:    ^Input,
) {
	input_update(input)
	event: SDL.Event
	for SDL.PollEvent(&event) {
		handle_event(event, gs, run, state, levels, r, window, settings, input)
	}

	// Fixed-step simulation
	if gs.screen == .Playing && gs.playing_state == .Active {
		if gs.sim_paused {
			for gs.sim_steps_requested > 0 {
				simulate_step(gs, run, state, ps, types, input)
				gs.sim_steps_requested -= 1
				if gs.screen != .Playing || gs.playing_state != .Active { break }
			}
		} else {
			state.sim_accumulator += gs.dt
			for state.sim_accumulator >= SIM_DT {
				simulate_step(gs, run, state, ps, types, input)
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
	r.clear_color = DARK_GREY if gs.screen == .Playing || gs.screen == .GameOver || gs.screen == .LevelComplete else BLACK

	switch gs.screen {
	case .MainMenu:      draw_main_menu(r, gs, ui^, assets, gs.elapsed)
	case .Options:       draw_options(r, gs, settings, assets, gs.elapsed, ui, window)
	case .GameOver:
		draw_playing(r, gs, run, state, ps, types, ui, assets)
		draw_game_over(r, run, state)
	case .LevelComplete:
		draw_playing(r, gs, run, state, ps, types, ui, assets)
		draw_level_complete(r, run, state)
	case .Playing:       draw_playing(r, gs, run, state, ps, types, ui, assets)
	}
}

game_init :: proc(g: ^Game, opts: Options) -> bool {
	// Screenshot directory
	g.screenshot_dir = "screenshots"
	if opts.test_script != "" {
		g.screenshot_dir = fmt.aprintf("%s/%s", fp.dir(opts.test_script, context.temp_allocator), fp.stem(opts.test_script))
		save_set_dir(g.screenshot_dir)
	}
	if infos, err := os.read_directory_by_path(g.screenshot_dir, 0, context.allocator); err == nil {
		for fi in infos { os.remove(fi.fullpath) }
		os.file_info_slice_delete(infos, context.allocator)
	}
	os.make_directory(g.screenshot_dir)

	// SDL
	if !SDL.Init(SDL.InitFlags{.VIDEO}) {
		fmt.eprintln("SDL_Init failed:", SDL.GetError())
		return false
	}

	SDL.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	SDL.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	SDL.GL_SetAttribute(.CONTEXT_PROFILE_MASK, 1)
	SDL.GL_SetAttribute(.DOUBLEBUFFER, 1)

	g.window = SDL.CreateWindow(WINDOW_TITLE, GAME_WIDTH, GAME_HEIGHT, SDL.WindowFlags{.OPENGL})
	if g.window == nil {
		fmt.eprintln("CreateWindow failed:", SDL.GetError())
		return false
	}
	SDL.SetWindowPosition(g.window, SDL.WINDOWPOS_CENTERED, SDL.WINDOWPOS_CENTERED)

	g.gl_ctx = SDL.GL_CreateContext(g.window)
	if g.gl_ctx == nil {
		fmt.eprintln("GL_CreateContext failed:", SDL.GetError())
		return false
	}
	SDL.GL_MakeCurrent(g.window, g.gl_ctx)
	GL.load_up_to(3, 3, SDL.gl_set_proc_address)

	// Subsystems
	if !renderer_init(&g.r) {
		fmt.eprintln("renderer_init failed")
		return false
	}
	if !asset_system_init(&g.assets) {
		fmt.eprintln("asset_system_init failed")
		return false
	}
	asset_setup_bg_pattern(&g.assets)

	if !particles_init(&g.ps) {
		fmt.eprintln("particles_init failed")
		return false
	}
	if !ui_init(&g.ui, &g.assets) {
		fmt.eprintln("ui_init failed")
		return false
	}
	g.ui.input = &g.input

	// Settings and test script
	g.settings = settings_load()
	if opts.test_script != "" {
		g.test_script, _ = test_script_load(opts.test_script)
		if s, ok := g.test_script.settings.?; ok {
			g.settings = s
		}
	}
	apply_display_settings(g.window, &g.r, g.settings)

	// Game data
	g.block_types, _ = block_types_load()
	levels_ok: bool
	g.levels, levels_ok = levels_load(g.block_types)
	if !levels_ok {
		fmt.eprintln("levels_load failed: no levels found")
		return false
	}

	run_state_init(&g.run, &g.state, g.levels)
	if idx, ok := g.test_script.level_idx.?; ok && idx < len(g.levels) {
		g.run.level_idx = idx
		level_state_init(&g.state, g.levels[idx])
	}

	if !stdin_reader_init(&g.stdin_reader) {
		fmt.eprintln("stdin_reader_init failed")
		return false
	}

	// Game state
	g.gs.running          = true
	g.gs.screen           = .MainMenu
	g.gs.pause_selected   = .Resume
	g.gs.sim_paused       = opts.pause_sim || g.test_script.pause_sim
	g.gs.quit_on_complete = opts.quit_on_complete
	g.gs.quit_on_gameover = opts.quit_on_gameover
	g.gs.options_focused  = .DisplayMode
	g.gs.has_save         = save_exists()
	g.gs.menu_selected    = .Continue if g.gs.has_save else .StartGame

	// Timing
	g.prev_counter = SDL.GetPerformanceCounter()
	g.freq         = SDL.GetPerformanceFrequency()

	return true
}

game_deinit :: proc(g: ^Game) {
	stdin_reader_destroy(&g.stdin_reader)
	delete(g.state.balls)
	delete(g.levels)
	delete(g.block_types)
	particles_destroy(&g.ps)
	asset_system_destroy(&g.assets)
	renderer_destroy(&g.r)
	if g.gl_ctx != nil { SDL.GL_DestroyContext(g.gl_ctx) }
	if g.window != nil { SDL.DestroyWindow(g.window) }
	SDL.Quit()
}

main :: proc() {
	opts: Options
	flags.parse_or_exit(&opts, os.args, .Unix)

	g: Game
	if !game_init(&g, opts) {
		game_deinit(&g)
		os.exit(1)
	}
	defer game_deinit(&g)

	for g.gs.running {
		now          := SDL.GetPerformanceCounter()
		g.gs.dt       = f32(now - g.prev_counter) / f32(g.freq)
		g.prev_counter = now
		g.gs.elapsed  += g.gs.dt

		free_all(context.temp_allocator)
		test_script_pump(&g.test_script, g.gs.elapsed, &g.gs.should_screenshot, &g.gs.running, &g.gs.sim_steps_requested)
		stdin_reader_pump(&g.stdin_reader, &g.gs.should_screenshot, &g.gs.running, &g.gs.sim_steps_requested, &g.gs, &g.run, &g.state)
		renderer_start_frame(&g.r)
		update(&g.gs, &g.run, &g.state, g.levels, &g.r, g.window, &g.settings, &g.ui, &g.ps, g.block_types, &g.assets, &g.input)
		renderer_end_frame(&g.r, &g.gs.should_screenshot, &g.screenshot_counter, &g.state, g.window, g.screenshot_dir)
	}
}
