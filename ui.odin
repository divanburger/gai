package main

import "core:fmt"

BUTTON_BORDER      :: f32(12)
WINDOW_BORDER      :: f32(34)   // top row height in screen pixels (matches WINDOW_SPLITS_Y[0])
WINDOW_PAD         :: f32(12)   // content padding inside window (all sides below header)
BUTTON_PAD_X       :: f32(32)
BUTTON_PAD_Y       :: f32(14)
BUTTON_SPACING     :: f32(16)

BUTTON_SELECT_TINT :: Color{0.68, 0.88, 1.0, 1.0}   // light-blue tint applied to selected button
BUTTON_DEPTH_PX    :: f32(8)                         // shadow rows unique to depth texture (y=56-63)

// Explicit nine-patch split points for button_square_depth.png (64×64).
// Screw circles at all four corners: x=8-11 / x=52-55, y=8-11 / y=48-51.
// Fixed zones (0-15 and 48-63 on each axis) capture all screws; only the 32px middles stretch.
// Bottom zone (y=44-63) also captures the shadow rows (y=56-63).
BUTTON_SEL_SPLITS_X :: [2]f32{16, 48}
BUTTON_SEL_SPLITS_Y :: [2]f32{16, 44}

// Explicit nine-patch split points for button_square_header_blade_square_screws.png (64×64).
// Left col 0-13px (13px) stretches only the 7px middle strip; right col 20-64px (44px) is
// fixed to preserve the blade shape. Top row 0-34px captures the full blue header; bottom
// row 50-64px (14px) holds the screw decorations.
WINDOW_SPLITS_X :: [2]f32{13, 20}
WINDOW_SPLITS_Y :: [2]f32{34, 50}

UIInput :: struct {
	mouse_pos:      vec2,
	mouse_clicked:  bool,
	left_pressed:   bool,
	right_pressed:  bool,
}

UI :: struct {
	button_tex:     Texture,
	button_sel_tex: Texture,
	window_tex:     Texture,
	input:          UIInput,
	cursor:         vec2,
	line_height:    f32,
	indent:         f32,
	_row_saved_y:    f32,
	_row_max_height: f32,
}

ui_load :: proc() -> (ui: UI, ok: bool) {
	ui.button_tex     = texture_load("assets/ui/button_square.png") or_return
	ui.button_sel_tex = texture_load("assets/ui/button_square_depth.png") or_return
	ui.window_tex     = texture_load("assets/ui/button_square_header_blade_square_screws.png") or_return
	return ui, true
}

ui_destroy :: proc(ui: ^UI) {
	texture_destroy(&ui.button_tex)
	texture_destroy(&ui.button_sel_tex)
	texture_destroy(&ui.window_tex)
}

ui_begin :: proc(ui: ^UI, input: UIInput) {
	ui.input       = input
	ui.cursor      = {ui.indent, 0}
	ui.line_height = 0
}

ui_button :: proc(r: ^Renderer, ui: ^UI, label: string, selected: bool = false) -> bool {
	text_h := r.ui_font.size
	btn_w  := text_width(r.ui_font, label) + BUTTON_PAD_X * 2
	btn_h  := text_h + BUTTON_PAD_Y * 2
	rect   := Rect{
		min = ui.cursor,
		max = ui.cursor + {btn_w, btn_h},
	}
	ui_button_render(r, ui^, rect, label, selected)
	clicked := ui.input.mouse_clicked && point_inside_rect(ui.input.mouse_pos, rect)
	ui.cursor.y    += btn_h + BUTTON_SPACING
	ui.line_height  = max(ui.line_height, btn_h)
	return clicked
}

ui_label :: proc(r: ^Renderer, ui: ^UI, text: string, color: Color = BLACK) {
	text_h := r.ui_font.size
	draw_text(r, r.ui_font, text, ui.cursor, color)
	ui.cursor.y    += text_h + BUTTON_SPACING
	ui.line_height  = max(ui.line_height, text_h)
}

ui_spacing :: proc(ui: ^UI, amount: f32) {
	ui.cursor.y += amount
}

// Low-level primitives — used by the stateful API above, and directly from draw_* procs.

// ui_button_render draws a button nine-patch + centred label.
// selected=true tints the normal button texture with BUTTON_SELECT_TINT (light blue).
// button_sel_tex and BUTTON_SEL_SPLITS_* are loaded/defined for future use.
ui_button_render :: proc(r: ^Renderer, ui: UI, rect: Rect, label: string, selected: bool = false) {
	tint := BUTTON_SELECT_TINT if selected else WHITE
	draw_nine_patch(r, rect, ui.button_tex, BUTTON_BORDER, tint)
	draw_text_rect(r, r.ui_font, label, rect, BLACK)
}

// ui_window_render draws a window using draw_nine_patch_splits so the blade header texture
// renders with its asymmetric fixed zones:
//   • only the 7px middle column (13–20px) stretches horizontally
//   • the full right column (20–64px, 44px) is fixed, preserving the blade shape
//   • the 34px top row is fixed, capturing the entire blue header
//   • the 14px bottom row is fixed, preserving the screw decorations
// Returns the usable content rect (header and padding subtracted).
ui_window_render :: proc(r: ^Renderer, ui: UI, rect: Rect, label: string) -> Rect {
	draw_nine_patch_splits(r, rect, ui.window_tex, WINDOW_SPLITS_X, WINDOW_SPLITS_Y)
	content := rect
	header := cut_top(&content, WINDOW_BORDER)
	content = shrink_rect(content, WINDOW_PAD)
	// Align title left edge with content area left edge
	title_rect := Rect{min = {content.min.x, header.min.y}, max = {header.max.x, header.max.y}}
	draw_text_rect(r, r.ui_font, label, title_rect, WHITE, .Left, .Middle)
	return content
}

// ---------------------------------------------------------------------------
// New generic widgets
// ---------------------------------------------------------------------------

// ui_selector renders a labelled left/right arrow selector.
// Returns -1 for left press, +1 for right press, 0 for no change.
// Keyboard input (Left/Right) is consumed only when selected=true.
ui_selector :: proc(r: ^Renderer, ui: ^UI, label: string, value: string, selected: bool = false) -> (changed: int) {
	text_h := r.ui_font.size
	btn_h  := text_h + BUTTON_PAD_Y * 2

	// Build display string "< value >" into a stack buffer.
	dbuf: [256]u8
	display_str := fmt.bprintf(dbuf[:], "< %s >", value)

	label_w   := text_width(r.ui_font, label)
	display_w := text_width(r.ui_font, display_str)
	total_w   := label_w + BUTTON_PAD_X + display_w + BUTTON_PAD_X * 2

	rect := Rect{
		min = ui.cursor,
		max = ui.cursor + {total_w, btn_h},
	}

	tint := BUTTON_SELECT_TINT if selected else WHITE
	draw_nine_patch(r, rect, ui.button_tex, BUTTON_BORDER, tint)

	text_y := rect.min.y + (btn_h - text_h) / 2
	draw_text(r, r.ui_font, label,       {rect.min.x + BUTTON_PAD_X, text_y}, BLACK, .Left)
	draw_text(r, r.ui_font, display_str, {rect.max.x - BUTTON_PAD_X, text_y}, BLACK, .Right)

	// Click zones: left half of display area = left arrow, right half = right arrow.
	mid_x     := rect.max.x - display_w/2 - BUTTON_PAD_X
	left_zone  := Rect{min = {rect.max.x - display_w - BUTTON_PAD_X*2, rect.min.y}, max = {mid_x, rect.max.y}}
	right_zone := Rect{min = {mid_x, rect.min.y}, max = rect.max}

	if ui.input.mouse_clicked {
		if point_inside_rect(ui.input.mouse_pos, left_zone)  { changed = -1 }
		if point_inside_rect(ui.input.mouse_pos, right_zone) { changed =  1 }
	}
	if selected {
		if ui.input.left_pressed  { changed = -1 }
		if ui.input.right_pressed { changed =  1 }
	}

	ui.cursor.y    += btn_h + BUTTON_SPACING
	ui.line_height  = max(ui.line_height, btn_h)
	return changed
}

// ui_progress_bar draws a background rect then a filled rect proportional to ratio (0–1).
ui_progress_bar :: proc(r: ^Renderer, ui: ^UI, ratio: f32, width: f32, height: f32 = 20, fg: Color = WHITE, bg: Color = GREY) {
	rect := Rect{
		min = ui.cursor,
		max = ui.cursor + {width, height},
	}
	draw_rect(r, rect, bg)
	filled_w := clamp(ratio, 0, 1) * width
	if filled_w > 0 {
		draw_rect(r, Rect{min = rect.min, max = {rect.min.x + filled_w, rect.max.y}}, fg)
	}
	ui.cursor.y    += height + BUTTON_SPACING
	ui.line_height  = max(ui.line_height, height)
}

// ui_indicator draws a small colored circle at the cursor and advances cursor horizontally.
ui_indicator :: proc(r: ^Renderer, ui: ^UI, color: Color, size: f32 = 12) {
	radius := size / 2
	center := ui.cursor + {radius, radius}
	draw_circle(r, Circle{pos = center, radius = radius}, color)
	ui.cursor.x    += size + BUTTON_SPACING
	ui.line_height  = max(ui.line_height, size)
}

// ui_slider draws a track with a draggable handle. Returns true if value changed.
// value must be in [0, 1]; it is clamped on read.
ui_slider :: proc(r: ^Renderer, ui: ^UI, value: ^f32, width: f32, height: f32 = 20) -> bool {
	track := Rect{
		min = ui.cursor,
		max = ui.cursor + {width, height},
	}
	draw_rect(r, track, GREY)

	v      := clamp(value^, 0, 1)
	handle_w  := height             // square handle
	handle_x  := track.min.x + v * (width - handle_w)
	handle := Rect{
		min = {handle_x, track.min.y},
		max = {handle_x + handle_w, track.max.y},
	}
	draw_rect(r, handle, WHITE)

	changed := false
	if ui.input.mouse_clicked && point_inside_rect(ui.input.mouse_pos, track) {
		new_v := (ui.input.mouse_pos.x - track.min.x - handle_w / 2) / (width - handle_w)
		new_v  = clamp(new_v, 0, 1)
		if new_v != value^ {
			value^  = new_v
			changed = true
		}
	}

	ui.cursor.y    += height + BUTTON_SPACING
	ui.line_height  = max(ui.line_height, height)
	return changed
}

// ui_dialog renders a centered modal window with title, message, and a row of buttons.
// Returns the index of the clicked/selected button, or -1 if none.
// Does NOT advance cursor (overlay widget).
ui_dialog :: proc(r: ^Renderer, ui: ^UI, title: string, message: string, buttons: []string, selected: int = 0) -> int {
	text_h    := r.ui_font.size
	btn_h     := text_h + BUTTON_PAD_Y * 2

	// Measure total button row width
	btn_row_w := f32(0)
	for b, i in buttons {
		btn_row_w += text_width(r.ui_font, b) + BUTTON_PAD_X * 2
		if i < len(buttons) - 1 { btn_row_w += BUTTON_SPACING }
	}

	msg_w     := text_width(r.ui_font, message)
	inner_w   := max(msg_w, btn_row_w) + WINDOW_PAD * 2
	inner_h   := WINDOW_BORDER + WINDOW_PAD + text_h + WINDOW_PAD + btn_h + WINDOW_PAD
	win_w     := inner_w
	win_h     := inner_h

	// Center in game space
	game_center := GAME_SIZE / 2
	win_rect := Rect{
		min = vec2{f32(game_center.x), f32(game_center.y)} - {win_w, win_h} / 2,
		max = vec2{f32(game_center.x), f32(game_center.y)} + {win_w, win_h} / 2,
	}

	content := ui_window_render(r, ui^, win_rect, title)

	// Message
	draw_text(r, r.ui_font, message, content.min, BLACK, .Left)

	// Button row
	buttons_y := content.max.y - btn_h
	btn_x     := content.min.x + (content.max.x - content.min.x - btn_row_w) / 2
	result    := -1
	for b, i in buttons {
		bw     := text_width(r.ui_font, b) + BUTTON_PAD_X * 2
		brect  := Rect{min = {btn_x, buttons_y}, max = {btn_x + bw, buttons_y + btn_h}}
		is_sel := i == selected
		ui_button_render(r, ui^, brect, b, is_sel)
		if ui.input.mouse_clicked && point_inside_rect(ui.input.mouse_pos, brect) {
			result = i
		}
		btn_x += bw + BUTTON_SPACING
	}
	return result
}

// ---------------------------------------------------------------------------
// Layout helpers — row mode
// ---------------------------------------------------------------------------

// ui_row_begin saves the current cursor Y. While in row mode, widgets advance X instead of Y.
// Call ui_row_end when all row widgets have been emitted.
// NOTE: stores state in ui; callers must not nest rows.
ui_row_begin :: proc(ui: ^UI) {
	ui._row_saved_y    = ui.cursor.y
	ui._row_max_height = 0
}

// ui_row_end restores saved Y and advances by the tallest widget height.
ui_row_end :: proc(ui: ^UI) {
	ui.cursor.x     = ui.indent
	ui.cursor.y     = ui._row_saved_y + ui._row_max_height + BUTTON_SPACING
	ui.line_height  = ui._row_max_height
}
