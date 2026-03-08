package main

import SDL "vendor:sdl3"

ButtonState :: struct {
	down:      bool,
	went_down: bool,
	went_up:   bool,
}

Input :: struct {
	keys:          #sparse [SDL.Scancode]ButtonState,
	mouse_pos:     vec2,
	mouse_clicked: bool,
}

input_update :: proc(input: ^Input) {
	for &key in input.keys {
		key.went_down = false
		key.went_up   = false
	}
	input.mouse_clicked = false
}

input_set_key :: proc(input: ^Input, scancode: SDL.Scancode, down: bool) {
	button := &input.keys[scancode]
	if button.down == down { return }
	button.down = down
	if down  { button.went_down = true }
	if !down { button.went_up   = true }
}

input_process_event :: proc(input: ^Input, event: SDL.Event) {
	#partial switch event.type {
	case .KEY_DOWN:
		input_set_key(input, event.key.scancode, true)
	case .KEY_UP:
		input_set_key(input, event.key.scancode, false)
	}
}
