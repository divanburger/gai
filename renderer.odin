package main

import "core:fmt"
import glsl "core:math/linalg/glsl"
import SDL "vendor:sdl3"
import GL "vendor:OpenGL"
import stbi "vendor:stb/image"
import ef   "vendor:stb/easy_font"

VERT_SRC :: `#version 330 core
layout(location = 0) in vec2 a_pos;
uniform vec2 u_resolution;
void main() {
    vec2 ndc = (a_pos / u_resolution) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    gl_Position = vec4(ndc, 0.0, 1.0);
}`

FRAG_SRC :: `#version 330 core
uniform vec4 u_color;
out vec4 frag_color;
void main() {
    frag_color = u_color;
}`

BLACK  :: Color{0, 0, 0, 1}
WHITE  :: Color{1, 1, 1, 1}
RED    :: Color{1, 0, 0, 1}
GREEN  :: Color{0, 1, 0, 1}
BLUE   :: Color{0, 0, 1, 1}
YELLOW :: Color{1, 1, 0, 1}

DrawCall :: struct {
	prim_type:  u32,
	vert_start: i32,
	vert_count: i32,
	color:      Color,
}

MAX_VERTS     :: 8192
MAX_DRAWCALLS :: 256

Renderer :: struct {
	program:    u32,
	loc_color:  i32,
	vao:        u32,
	vbo:        u32,
	verts:      [MAX_VERTS]vec2,
	vert_count: int,
	calls:      [MAX_DRAWCALLS]DrawCall,
	call_count: int,
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
	pixels := make([]u8, WINDOW_SIZE.x * WINDOW_SIZE.y * 4)
	defer delete(pixels)

	GL.ReadPixels(0, 0, WINDOW_SIZE.x, WINDOW_SIZE.y, GL.RGBA, GL.UNSIGNED_BYTE, raw_data(pixels))

	counter^ += 1

	buf: [256]u8
	filename := fmt.bprintf(buf[:], "screenshots/screenshot_%04d.png\x00", counter^)

	if stbi.write_png(cstring(raw_data(buf[:])), WINDOW_SIZE.x, WINDOW_SIZE.y, 4, raw_data(pixels), WINDOW_SIZE.x * 4) == 0 {
		fmt.eprintln("screenshot failed")
	} else {
		fmt.println("screenshot saved:", filename[:len(filename)-1])
	}
}

renderer_init :: proc() -> (r: Renderer, ok: bool) {
	stbi.flip_vertically_on_write(true)

	r.program = compile_shader_program(VERT_SRC, FRAG_SRC) or_return

	GL.Enable(GL.BLEND)
	GL.BlendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)

	GL.UseProgram(r.program)
	loc_resolution := GL.GetUniformLocation(r.program, "u_resolution")
	r.loc_color     = GL.GetUniformLocation(r.program, "u_color")
	GL.Uniform2f(loc_resolution, f32(WINDOW_SIZE.x), f32(WINDOW_SIZE.y))

	GL.GenVertexArrays(1, &r.vao)
	GL.GenBuffers(1, &r.vbo)
	GL.BindVertexArray(r.vao)
	GL.BindBuffer(GL.ARRAY_BUFFER, r.vbo)
	GL.BufferData(GL.ARRAY_BUFFER, MAX_VERTS * size_of(vec2), nil, GL.DYNAMIC_DRAW)
	GL.VertexAttribPointer(0, 2, GL.FLOAT, false, size_of(vec2), 0)
	GL.EnableVertexAttribArray(0)
	GL.BindVertexArray(0)

	return r, true
}

renderer_destroy :: proc(r: ^Renderer) {
	GL.DeleteVertexArrays(1, &r.vao)
	GL.DeleteBuffers(1, &r.vbo)
	GL.DeleteProgram(r.program)
}

renderer_start_frame :: proc(r: ^Renderer) {
	r.vert_count = 0
	r.call_count = 0
}

renderer_end_frame :: proc(r: ^Renderer, screenshot_counter: ^int, should_screenshot: ^bool, window: ^SDL.Window) {
	GL.ClearColor(0, 0, 0, 1)
	GL.Clear(GL.COLOR_BUFFER_BIT)
	GL.UseProgram(r.program)

	if r.vert_count > 0 {
		GL.BindBuffer(GL.ARRAY_BUFFER, r.vbo)
		GL.BufferData(GL.ARRAY_BUFFER, r.vert_count * size_of(vec2), &r.verts, GL.DYNAMIC_DRAW)
	}

	GL.BindVertexArray(r.vao)
	for i in 0..<r.call_count {
		c := r.calls[i]
		GL.Uniform4f(r.loc_color, c.color[0], c.color[1], c.color[2], c.color[3])
		GL.DrawArrays(c.prim_type, c.vert_start, c.vert_count)
	}

	if should_screenshot^ {
		take_screenshot(screenshot_counter)
		should_screenshot^ = false
	}

	SDL.GL_SwapWindow(window)
}

draw_rect :: proc(r: ^Renderer, rect: Rect, color: Color) {
	start := i32(r.vert_count)
	r.verts[r.vert_count+0] = rect.min
	r.verts[r.vert_count+1] = {rect.max.x, rect.min.y}
	r.verts[r.vert_count+2] = {rect.min.x, rect.max.y}
	r.verts[r.vert_count+3] = {rect.max.x, rect.min.y}
	r.verts[r.vert_count+4] = {rect.min.x, rect.max.y}
	r.verts[r.vert_count+5] = rect.max
	r.vert_count += 6
	r.calls[r.call_count] = DrawCall{GL.TRIANGLES, start, 6, color}
	r.call_count += 1
}

draw_circle :: proc(r: ^Renderer, circle: Circle, color: Color) {
	start := i32(r.vert_count)
	r.verts[r.vert_count] = circle.pos
	r.vert_count += 1
	for i in 0..<SEGMENTS {
		angle := f32(i) / f32(SEGMENTS) * glsl.TAU
		r.verts[r.vert_count] = circle.pos + vec2{glsl.cos(angle), glsl.sin(angle)} * circle.radius
		r.vert_count += 1
	}
	r.verts[r.vert_count] = r.verts[int(start)+1]
	r.vert_count += 1
	r.calls[r.call_count] = DrawCall{GL.TRIANGLE_FAN, start, VERTEX_COUNT, color}
	r.call_count += 1
}

draw_text :: proc(r: ^Renderer, text: string, pos: vec2, scale: f32, color: Color) {
	start := i32(r.vert_count)
	quads: [256]ef.Quad
	num_quads := ef.print(pos.x, pos.y, text, {255, 255, 255, 255}, quads[:], scale)
	for i in 0..<num_quads {
		q := quads[i]
		r.verts[r.vert_count+0] = {q.tl.v[0], q.tl.v[1]}
		r.verts[r.vert_count+1] = {q.tr.v[0], q.tr.v[1]}
		r.verts[r.vert_count+2] = {q.bl.v[0], q.bl.v[1]}
		r.verts[r.vert_count+3] = {q.tr.v[0], q.tr.v[1]}
		r.verts[r.vert_count+4] = {q.br.v[0], q.br.v[1]}
		r.verts[r.vert_count+5] = {q.bl.v[0], q.bl.v[1]}
		r.vert_count += 6
	}
	count := i32(r.vert_count) - start
	if count > 0 {
		r.calls[r.call_count] = DrawCall{GL.TRIANGLES, start, count, color}
		r.call_count += 1
	}
}
