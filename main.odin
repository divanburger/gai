package main

import "core:fmt"
import "core:flags"
import "core:os"
import glsl "core:math/linalg/glsl"
import SDL "vendor:sdl3"
import GL "vendor:OpenGL"
import stbi "vendor:stb/image"
import ef   "vendor:stb/easy_font"

WINDOW_TITLE  :: "Bouncing Ball"
WINDOW_WIDTH  :: 800
WINDOW_HEIGHT :: 600
BALL_RADIUS    :: 30.0
BALL_SPEED     :: glsl.vec2{250.0, 180.0}
SEGMENTS       :: 64
VERTEX_COUNT   :: SEGMENTS + 2

PADDLE_WIDTH   :: 120.0
PADDLE_HEIGHT  :: 15.0
PADDLE_SPEED   :: 500.0
PADDLE_Y       :: f32(WINDOW_HEIGHT) - 60.0

BLOCK_COLS   :: 20
BLOCK_ROWS   :: 5
BLOCK_W      :: 36.0
BLOCK_H      :: 14.0
BLOCK_GAP_X  :: 3.0
BLOCK_GAP_Y  :: 5.0
BLOCK_AREA_Y :: 40.0

GAME_NAME  :: "gai"
TEXT_SCALE :: f32(3)

VERT_SRC :: `#version 330 core
layout(location = 0) in vec2 a_offset;
uniform vec2 u_center;
uniform vec2 u_resolution;
void main() {
    vec2 screen_pos = u_center + a_offset;
    vec2 ndc = (screen_pos / u_resolution) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    gl_Position = vec4(ndc, 0.0, 1.0);
}`

FRAG_SRC :: `#version 330 core
out vec4 frag_color;
void main() {
    frag_color = vec4(1.0, 1.0, 1.0, 1.0);
}`

generate_circle_offsets :: proc() -> [VERTEX_COUNT]glsl.vec2 {
	v: [VERTEX_COUNT]glsl.vec2
	v[0] = {0, 0}
	for i in 0..<SEGMENTS {
		angle := f32(i) / f32(SEGMENTS) * glsl.TAU
		v[i+1] = {glsl.cos(angle), glsl.sin(angle)} * BALL_RADIUS
	}
	v[SEGMENTS+1] = v[1]
	return v
}

block_rect :: proc(col, row: int) -> (l, t, r, b: f32) {
	area_x :: (f32(WINDOW_WIDTH) - (BLOCK_COLS * (BLOCK_W + BLOCK_GAP_X) - BLOCK_GAP_X)) / 2
	l = area_x + f32(col) * (BLOCK_W + BLOCK_GAP_X)
	t = BLOCK_AREA_Y + f32(row) * (BLOCK_H + BLOCK_GAP_Y)
	r = l + BLOCK_W
	b = t + BLOCK_H
	return
}

rebuild_block_vbo :: proc(vbo: u32, blocks: ^[BLOCK_COLS * BLOCK_ROWS]bool) -> int {
	verts: [BLOCK_COLS * BLOCK_ROWS * 6]glsl.vec2
	count := 0
	for row in 0..<BLOCK_ROWS {
		for col in 0..<BLOCK_COLS {
			if !blocks[row * BLOCK_COLS + col] { continue }
			l, t, r, b := block_rect(col, row)
			verts[count+0] = {l, t}
			verts[count+1] = {r, t}
			verts[count+2] = {l, b}
			verts[count+3] = {r, t}
			verts[count+4] = {l, b}
			verts[count+5] = {r, b}
			count += 6
		}
	}
	GL.BindBuffer(GL.ARRAY_BUFFER, vbo)
	if count > 0 {
		GL.BufferSubData(GL.ARRAY_BUFFER, 0, count * size_of(glsl.vec2), &verts)
	}
	return count
}

compile_shader_program :: proc(vert_src, frag_src: string) -> (program: u32, ok: bool) {
	compile :: proc(src: string, kind: u32) -> (id: u32, ok: bool) {
		id = GL.CreateShader(kind)
		src_ptr := cstring(raw_data(src))
		src_len := i32(len(src))
		GL.ShaderSource(id, 1, &src_ptr, &src_len)
		GL.CompileShader(id)
		status: i32
		GL.GetShaderiv(id, GL.COMPILE_STATUS, &status)
		if status == 0 {
			n: i32
			GL.GetShaderiv(id, GL.INFO_LOG_LENGTH, &n)
			buf := make([]u8, n)
			defer delete(buf)
			GL.GetShaderInfoLog(id, n, nil, raw_data(buf))
			fmt.eprintln("shader compile error:", string(buf))
			GL.DeleteShader(id)
			return 0, false
		}
		return id, true
	}

	vert := compile(vert_src, GL.VERTEX_SHADER) or_return
	defer GL.DeleteShader(vert)
	frag := compile(frag_src, GL.FRAGMENT_SHADER) or_return
	defer GL.DeleteShader(frag)

	program = GL.CreateProgram()
	GL.AttachShader(program, vert)
	GL.AttachShader(program, frag)
	GL.LinkProgram(program)

	status: i32
	GL.GetProgramiv(program, GL.LINK_STATUS, &status)
	if status == 0 {
		n: i32
		GL.GetProgramiv(program, GL.INFO_LOG_LENGTH, &n)
		buf := make([]u8, n)
		defer delete(buf)
		GL.GetProgramInfoLog(program, n, nil, raw_data(buf))
		fmt.eprintln("program link error:", string(buf))
		GL.DeleteProgram(program)
		return 0, false
	}
	return program, true
}

take_screenshot :: proc(counter: ^int) {
	pixels := make([]u8, WINDOW_WIDTH * WINDOW_HEIGHT * 4)
	defer delete(pixels)

	GL.ReadPixels(0, 0, WINDOW_WIDTH, WINDOW_HEIGHT, GL.RGBA, GL.UNSIGNED_BYTE, raw_data(pixels))

	counter^ += 1

	buf: [256]u8
	filename := fmt.bprintf(buf[:], "screenshots/screenshot_%04d.png\x00", counter^)

	if stbi.write_png(cstring(raw_data(buf[:])), WINDOW_WIDTH, WINDOW_HEIGHT, 4, raw_data(pixels), WINDOW_WIDTH * 4) == 0 {
		fmt.eprintln("screenshot failed")
	} else {
		fmt.println("screenshot saved:", filename[:len(filename)-1])
	}
}

main :: proc() {
	Options :: struct {
		screenshot_at:          f32  `usage:"Take a screenshot this many seconds after startup."`,
		quit_after_screenshot:  bool `usage:"Quit the game after the timed screenshot is taken."`,
	}
	opts := Options{screenshot_at = -1}
	flags.parse_or_exit(&opts, os.args, .Unix)

	if infos, err := os.read_directory_by_path("screenshots", 0, context.allocator); err == nil {
		for fi in infos {
			os.remove(fi.fullpath)
		}
		os.file_info_slice_delete(infos, context.allocator)
	}
	os.make_directory("screenshots")
	stbi.flip_vertically_on_write(true)

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

	program, ok := compile_shader_program(VERT_SRC, FRAG_SRC)
	if !ok {
		return
	}
	defer GL.DeleteProgram(program)

	vertices := generate_circle_offsets()
	vao, vbo: u32
	GL.GenVertexArrays(1, &vao)
	GL.GenBuffers(1, &vbo)
	defer GL.DeleteVertexArrays(1, &vao)
	defer GL.DeleteBuffers(1, &vbo)

	GL.BindVertexArray(vao)
	GL.BindBuffer(GL.ARRAY_BUFFER, vbo)
	GL.BufferData(GL.ARRAY_BUFFER, size_of(vertices), &vertices, GL.STATIC_DRAW)
	GL.VertexAttribPointer(0, 2, GL.FLOAT, false, size_of(glsl.vec2), 0)
	GL.EnableVertexAttribArray(0)
	GL.BindVertexArray(0)

	paddle_vao, paddle_vbo: u32
	GL.GenVertexArrays(1, &paddle_vao)
	GL.GenBuffers(1, &paddle_vbo)
	defer GL.DeleteVertexArrays(1, &paddle_vao)
	defer GL.DeleteBuffers(1, &paddle_vbo)

	GL.BindVertexArray(paddle_vao)
	GL.BindBuffer(GL.ARRAY_BUFFER, paddle_vbo)
	GL.BufferData(GL.ARRAY_BUFFER, 4 * size_of(glsl.vec2), nil, GL.DYNAMIC_DRAW)
	GL.VertexAttribPointer(0, 2, GL.FLOAT, false, size_of(glsl.vec2), 0)
	GL.EnableVertexAttribArray(0)
	GL.BindVertexArray(0)

	block_vao, block_vbo: u32
	GL.GenVertexArrays(1, &block_vao)
	GL.GenBuffers(1, &block_vbo)
	defer GL.DeleteVertexArrays(1, &block_vao)
	defer GL.DeleteBuffers(1, &block_vbo)

	GL.BindVertexArray(block_vao)
	GL.BindBuffer(GL.ARRAY_BUFFER, block_vbo)
	GL.BufferData(GL.ARRAY_BUFFER, BLOCK_COLS * BLOCK_ROWS * 6 * size_of(glsl.vec2), nil, GL.DYNAMIC_DRAW)
	GL.VertexAttribPointer(0, 2, GL.FLOAT, false, size_of(glsl.vec2), 0)
	GL.EnableVertexAttribArray(0)
	GL.BindVertexArray(0)

	text_vao, text_vbo: u32
	GL.GenVertexArrays(1, &text_vao)
	GL.GenBuffers(1, &text_vbo)
	defer GL.DeleteVertexArrays(1, &text_vao)
	defer GL.DeleteBuffers(1, &text_vbo)

	text_vert_count: int
	{
		text_w := f32(ef.width(GAME_NAME)) * TEXT_SCALE
		text_x := (f32(WINDOW_WIDTH) - text_w) / 2
		text_y := f32(10)

		quads: [256]ef.Quad
		num_quads := ef.print(text_x, text_y, GAME_NAME, {255, 255, 255, 255}, quads[:], TEXT_SCALE)

		verts: [256 * 6]glsl.vec2
		for i in 0..<num_quads {
			q := quads[i]
			verts[text_vert_count+0] = {q.tl.v[0], q.tl.v[1]}
			verts[text_vert_count+1] = {q.tr.v[0], q.tr.v[1]}
			verts[text_vert_count+2] = {q.bl.v[0], q.bl.v[1]}
			verts[text_vert_count+3] = {q.tr.v[0], q.tr.v[1]}
			verts[text_vert_count+4] = {q.br.v[0], q.br.v[1]}
			verts[text_vert_count+5] = {q.bl.v[0], q.bl.v[1]}
			text_vert_count += 6
		}

		GL.BindVertexArray(text_vao)
		GL.BindBuffer(GL.ARRAY_BUFFER, text_vbo)
		GL.BufferData(GL.ARRAY_BUFFER, text_vert_count * size_of(glsl.vec2), &verts, GL.STATIC_DRAW)
		GL.VertexAttribPointer(0, 2, GL.FLOAT, false, size_of(glsl.vec2), 0)
		GL.EnableVertexAttribArray(0)
		GL.BindVertexArray(0)
	}

	GL.UseProgram(program)
	loc_center     := GL.GetUniformLocation(program, "u_center")
	loc_resolution := GL.GetUniformLocation(program, "u_resolution")
	GL.Uniform2f(loc_resolution, WINDOW_WIDTH, WINDOW_HEIGHT)

	ball_pos  := glsl.vec2{WINDOW_WIDTH / 2.0, WINDOW_HEIGHT / 2.0}
	ball_vel  := BALL_SPEED
	paddle_x  := f32(WINDOW_WIDTH) / 2.0
	left_held, right_held := false, false

	blocks: [BLOCK_COLS * BLOCK_ROWS]bool
	for &b in blocks { b = true }
	block_vert_count := rebuild_block_vbo(block_vbo, &blocks)

	prev_counter := SDL.GetPerformanceCounter()
	freq         := SDL.GetPerformanceFrequency()

	screenshot_counter := 0
	should_screenshot  := false
	elapsed            : f32

	running := true
	for running {
		now := SDL.GetPerformanceCounter()
		dt  := f32(now - prev_counter) / f32(freq)
		prev_counter = now

		event: SDL.Event
		for SDL.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				running = false
			case .KEY_DOWN:
			#partial switch event.key.scancode {
			case .ESCAPE:      running = false
			case .PRINTSCREEN: should_screenshot = true
			case .LEFT:        left_held  = true
			case .RIGHT:       right_held = true
			}
		case .KEY_UP:
			#partial switch event.key.scancode {
			case .LEFT:  left_held  = false
			case .RIGHT: right_held = false
			}
			}
		}

		elapsed += dt

		if opts.screenshot_at >= 0 && elapsed >= opts.screenshot_at {
			should_screenshot = true
			opts.screenshot_at = -1  // trigger only once
			if opts.quit_after_screenshot {
				running = false
			}
		}

		if left_held  { paddle_x -= PADDLE_SPEED * dt }
		if right_held { paddle_x += PADDLE_SPEED * dt }
		paddle_x = clamp(paddle_x, PADDLE_WIDTH / 2, f32(WINDOW_WIDTH) - PADDLE_WIDTH / 2)

		ball_pos += ball_vel * dt

		// Block collision
		block_loop: for row in 0..<BLOCK_ROWS {
			for col in 0..<BLOCK_COLS {
				idx := row * BLOCK_COLS + col
				if !blocks[idx] { continue }
				l, t, r, b := block_rect(col, row)
				cx := clamp(ball_pos.x, l, r)
				cy := clamp(ball_pos.y, t, b)
				dx := ball_pos.x - cx
				dy := ball_pos.y - cy
				if dx*dx + dy*dy < BALL_RADIUS * BALL_RADIUS {
					blocks[idx] = false
					block_vert_count = rebuild_block_vbo(block_vbo, &blocks)
					if ball_pos.x >= l && ball_pos.x <= r {
						ball_vel.y = -ball_vel.y
					} else {
						ball_vel.x = -ball_vel.x
					}
					break block_loop
				}
			}
		}

		// Paddle collision: ball bottom hits paddle top
		paddle_top := PADDLE_Y - PADDLE_HEIGHT / 2
		if ball_vel.y > 0 &&
		   ball_pos.y + BALL_RADIUS >= paddle_top &&
		   ball_pos.y - BALL_RADIUS <= PADDLE_Y + PADDLE_HEIGHT / 2 &&
		   ball_pos.x + BALL_RADIUS >= paddle_x - PADDLE_WIDTH / 2 &&
		   ball_pos.x - BALL_RADIUS <= paddle_x + PADDLE_WIDTH / 2 {
			ball_pos.y = paddle_top - BALL_RADIUS
			ball_vel.y = -abs(ball_vel.y)
		}

		if ball_pos.x - BALL_RADIUS < 0             { ball_pos.x = BALL_RADIUS;                ball_vel.x =  abs(ball_vel.x) }
		if ball_pos.x + BALL_RADIUS > WINDOW_WIDTH  { ball_pos.x = WINDOW_WIDTH - BALL_RADIUS; ball_vel.x = -abs(ball_vel.x) }
		if ball_pos.y - BALL_RADIUS < 0             { ball_pos.y = BALL_RADIUS;                ball_vel.y =  abs(ball_vel.y) }
		if ball_pos.y + BALL_RADIUS > WINDOW_HEIGHT { ball_pos.y = WINDOW_HEIGHT - BALL_RADIUS; ball_vel.y = -abs(ball_vel.y) }

		GL.ClearColor(0, 0, 0, 1)
		GL.Clear(GL.COLOR_BUFFER_BIT)
		GL.UseProgram(program)
		GL.Uniform2f(loc_center, ball_pos.x, ball_pos.y)
		GL.BindVertexArray(vao)
		GL.DrawArrays(GL.TRIANGLE_FAN, 0, VERTEX_COUNT)

		// Draw paddle: upload corners as actual screen positions, center uniform zeroed
		hw := f32(PADDLE_WIDTH  / 2)
		hh := f32(PADDLE_HEIGHT / 2)
		paddle_verts := [4]glsl.vec2{
			{paddle_x - hw, PADDLE_Y - hh},
			{paddle_x + hw, PADDLE_Y - hh},
			{paddle_x - hw, PADDLE_Y + hh},
			{paddle_x + hw, PADDLE_Y + hh},
		}
		GL.BindBuffer(GL.ARRAY_BUFFER, paddle_vbo)
		GL.BufferSubData(GL.ARRAY_BUFFER, 0, size_of(paddle_verts), &paddle_verts)
		GL.Uniform2f(loc_center, 0, 0)
		GL.BindVertexArray(paddle_vao)
		GL.DrawArrays(GL.TRIANGLE_STRIP, 0, 4)

		// Draw blocks
		if block_vert_count > 0 {
			GL.BindVertexArray(block_vao)
			GL.DrawArrays(GL.TRIANGLES, 0, i32(block_vert_count))
		}

		// Draw game name
		GL.BindVertexArray(text_vao)
		GL.DrawArrays(GL.TRIANGLES, 0, i32(text_vert_count))

		if should_screenshot {
			take_screenshot(&screenshot_counter)
			should_screenshot = false
		}

		SDL.GL_SwapWindow(window)
	}
}
