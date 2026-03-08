package main

import "core:c"
import "core:fmt"
import "core:os"
import glsl "core:math/linalg/glsl"
import SDL "vendor:sdl3"
import GL "vendor:OpenGL"
import stbi "vendor:stb/image"
import stbtt "vendor:stb/truetype"

VERT_SRC :: `#version 330 core
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_uv;
uniform vec2 u_resolution;
out vec2 v_uv;
void main() {
    vec2 ndc = (a_pos / u_resolution) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_uv = a_uv;
}`

FRAG_SRC :: `#version 330 core
uniform sampler2D u_texture;
uniform vec4 u_color;
uniform vec4 u_color_b;
uniform bool u_use_texture;
uniform bool u_two_tone;
in vec2 v_uv;
out vec4 frag_color;
void main() {
    if (u_two_tone) {
        float lum = texture(u_texture, v_uv).r;
        frag_color = mix(u_color_b, u_color, lum);
    } else if (u_use_texture) {
        vec2 res   = vec2(textureSize(u_texture, 0));
        vec2 texel = v_uv * res + 0.5;
        vec2 fl    = floor(texel);
        vec2 fr    = fract(texel);
        vec2 aa    = fwidth(texel) * 0.75;
        fr         = smoothstep(vec2(0.5) - aa, vec2(0.5) + aa, fr);
        vec2 aa_uv = (fl + fr - 0.5) / res;
        frag_color = texture(u_texture, aa_uv) * u_color;
    } else {
        frag_color = u_color;
    }
}`

BLACK      :: Color{0,    0,    0,    1}
WHITE      :: Color{1,    1,    1,    1}
DARK_GREY  :: Color{0.12, 0.12, 0.12, 1}
GREY       :: Color{0.4,  0.4,  0.4,  1}
RED    :: Color{1,   0,   0,   1}
GREEN  :: Color{0,   1,   0,   1}
BLUE   :: Color{0,   0,   1,   1}
YELLOW :: Color{1,   1,   0,   1}

Vertex :: struct { pos, uv: vec2 }

DrawCall :: struct {
	prim_type:  u32,
	vert_start: i32,
	vert_count: i32,
	color:      Color,
	color_b:    Color,
	texture_id: u32,
	two_tone:   bool,
}

INIT_VERTS     :: 4096
INIT_DRAWCALLS :: 256

// Font atlas — covers printable ASCII (chars 32..126)
FONT_ATLAS_SIZE :: 512
FONT_FIRST_CHAR :: 32
FONT_CHAR_COUNT :: 95

Font :: struct {
	texture_id: u32,
	atlas_size: i32,
	glyphs:     [FONT_CHAR_COUNT]stbtt.bakedchar,
	size:       f32,
	ascent:     f32,  // distance from baseline to top of tallest glyph (positive, in pixels)
	descent:    f32,  // distance from baseline to bottom of lowest glyph (negative, in pixels)
}

Renderer :: struct {
	program:          u32,
	loc_color:        i32,
	loc_color_b:      i32,
	loc_use_texture:  i32,
	loc_two_tone:     i32,
	vao:              u32,
	vbo:              u32,
	verts:            [dynamic]Vertex,
	calls:            [dynamic]DrawCall,
	window_size:      ivec2,
	viewport_offset:  vec2,
	viewport_scale:   f32,
	clear_color:      Color,
	font:             Font,
	ui_font:          Font,
	item_icons:       [ItemKind]Texture,
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

take_screenshot :: proc(counter: int, state: ^LevelState, window_size: ivec2, dir: string) {
	pixels := make([]u8, window_size.x * window_size.y * 4)
	defer delete(pixels)

	GL.ReadPixels(0, 0, window_size.x, window_size.y, GL.RGBA, GL.UNSIGNED_BYTE, raw_data(pixels))

	buf: [256]u8
	filename := fmt.bprintf(buf[:], "%s/screenshot_%d_step_%d.png\x00", dir, counter, state.sim_steps)

	if stbi.write_png(cstring(raw_data(buf[:])), window_size.x, window_size.y, 4, raw_data(pixels), window_size.x * 4) == 0 {
		fmt.eprintln("screenshot failed")
	} else {
		name := filename[:len(filename)-1]
		game_log(state, fmt.tprintf("screenshot file=%s", name))
	}
}

font_load :: proc(path: string, size: f32) -> (f: Font, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintln("font_load: failed to read", path, err)
		return {}, false
	}
	defer delete(data)

	f.size       = size
	f.atlas_size = FONT_ATLAS_SIZE
	line_gap: f32
	stbtt.GetScaledFontVMetrics(raw_data(data), 0, size, &f.ascent, &f.descent, &line_gap)

	bitmap := make([]u8, FONT_ATLAS_SIZE * FONT_ATLAS_SIZE)
	defer delete(bitmap)

	result := stbtt.BakeFontBitmap(
		raw_data(data), 0,
		size,
		raw_data(bitmap), FONT_ATLAS_SIZE, FONT_ATLAS_SIZE,
		FONT_FIRST_CHAR, FONT_CHAR_COUNT,
		&f.glyphs[0],
	)
	if result <= 0 {
		fmt.eprintln("font_load: BakeFontBitmap failed (result=", result, ")")
		return {}, false
	}

	// Upload as single-channel RED texture; shader reads .r for luminance
	GL.GenTextures(1, &f.texture_id)
	GL.BindTexture(GL.TEXTURE_2D, f.texture_id)
	GL.PixelStorei(GL.UNPACK_ALIGNMENT, 1)
	GL.TexImage2D(GL.TEXTURE_2D, 0, GL.RED, FONT_ATLAS_SIZE, FONT_ATLAS_SIZE, 0, GL.RED, GL.UNSIGNED_BYTE, raw_data(bitmap))
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, GL.LINEAR)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, GL.LINEAR)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_S, GL.CLAMP_TO_EDGE)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_T, GL.CLAMP_TO_EDGE)
	GL.PixelStorei(GL.UNPACK_ALIGNMENT, 4)

	return f, true
}

font_destroy :: proc(f: ^Font) {
	if f.texture_id != 0 {
		GL.DeleteTextures(1, &f.texture_id)
		f.texture_id = 0
	}
}

renderer_init :: proc(r: ^Renderer) -> bool {
	stbi.flip_vertically_on_write(true)
	stbi.set_flip_vertically_on_load(1)

	program, program_ok := compile_shader_program(VERT_SRC, FRAG_SRC)
	if !program_ok { return false }
	r.program = program

	GL.Enable(GL.BLEND)
	GL.BlendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)

	GL.UseProgram(r.program)
	loc_resolution    := GL.GetUniformLocation(r.program, "u_resolution")
	r.loc_color        = GL.GetUniformLocation(r.program, "u_color")
	r.loc_color_b      = GL.GetUniformLocation(r.program, "u_color_b")
	r.loc_use_texture  = GL.GetUniformLocation(r.program, "u_use_texture")
	r.loc_two_tone     = GL.GetUniformLocation(r.program, "u_two_tone")
	GL.Uniform2f(loc_resolution, f32(WINDOW_SIZE.x), f32(WINDOW_SIZE.y))
	GL.Uniform1i(GL.GetUniformLocation(r.program, "u_texture"), 0)

	GL.GenVertexArrays(1, &r.vao)
	GL.GenBuffers(1, &r.vbo)
	GL.BindVertexArray(r.vao)
	GL.BindBuffer(GL.ARRAY_BUFFER, r.vbo)
	stride := i32(size_of(Vertex))
	GL.VertexAttribPointer(0, 2, GL.FLOAT, false, stride, uintptr(offset_of(Vertex, pos)))
	GL.EnableVertexAttribArray(0)
	GL.VertexAttribPointer(1, 2, GL.FLOAT, false, stride, uintptr(offset_of(Vertex, uv)))
	GL.EnableVertexAttribArray(1)
	GL.BindVertexArray(0)

	r.verts = make([dynamic]Vertex, 0, INIT_VERTS)
	r.calls = make([dynamic]DrawCall, 0, INIT_DRAWCALLS)

	r.window_size = WINDOW_SIZE
	r.clear_color = BLACK
	GL.Viewport(0, 0, WINDOW_SIZE.x, WINDOW_SIZE.y)

	// Load fonts at their target pixel sizes (no runtime scaling)
	if font, font_ok := font_load("assets/fonts/Kenney_Future.ttf", 36); font_ok {
		r.font = font
	} else {
		fmt.eprintln("renderer_init: failed to load game font")
	}
	if ui_font, ui_ok := font_load("assets/fonts/Kenney_Future.ttf", 18); ui_ok {
		r.ui_font = ui_font
	} else {
		fmt.eprintln("renderer_init: failed to load UI font")
	}

	// Load or generate item icon textures
	icon_paths := [ItemKind]string{
		.ExtraLife    = "assets/icons/extra_life.png",
		.ExtraBall   = "assets/icons/extra_ball.png",
		.WidePaddle  = "assets/icons/wide_paddle.png",
		.NarrowPaddle = "assets/icons/narrow_paddle.png",
		.StickyPaddle = "assets/icons/sticky_paddle.png",
		.FastBall    = "assets/icons/fast_ball.png",
		.SlowBall    = "assets/icons/slow_ball.png",
	}
	for kind in ItemKind {
		if tex, tex_ok := texture_load_silent(icon_paths[kind]); tex_ok {
			r.item_icons[kind] = tex
		} else {
			// Generate a simple procedural icon as fallback
			r.item_icons[kind] = generate_item_icon(kind)
		}
	}

	return true
}

DisplayMode :: enum { Windowed, Borderless, Fullscreen }

display_mode_name :: proc(m: DisplayMode) -> string {
	switch m {
	case .Windowed:   return "Windowed"
	case .Borderless: return "Borderless"
	case .Fullscreen: return "Fullscreen"
	}
	return ""
}

renderer_apply_display :: proc(r: ^Renderer, window: ^SDL.Window, mode: DisplayMode, resolution: ivec2) {
	switch mode {
	case .Windowed:
		SDL.SetWindowFullscreen(window, false)
		SDL.SetWindowBordered(window, true)
		SDL.SetWindowSize(window, resolution.x, resolution.y)
	case .Borderless:
		SDL.SetWindowFullscreen(window, false)
		SDL.SetWindowBordered(window, false)
		SDL.SetWindowSize(window, resolution.x, resolution.y)
	case .Fullscreen:
		SDL.SetWindowFullscreen(window, true)
		// Viewport is updated when SDL fires WINDOW_RESIZED
		return
	}
	renderer_set_window_size(r, resolution)
}

renderer_set_window_size :: proc(r: ^Renderer, size: ivec2) {
	r.window_size = size
	scale := min(f32(size.x) / GAME_SIZE.x, f32(size.y) / GAME_SIZE.y)
	vp_w  := i32(GAME_SIZE.x * scale)
	vp_h  := i32(GAME_SIZE.y * scale)
	vp_x  := (size.x - vp_w) / 2
	vp_y  := (size.y - vp_h) / 2
	r.viewport_offset = {f32(vp_x), f32(vp_y)}
	r.viewport_scale  = scale
	GL.Viewport(vp_x, vp_y, vp_w, vp_h)
}

renderer_destroy :: proc(r: ^Renderer) {
	GL.DeleteVertexArrays(1, &r.vao)
	GL.DeleteBuffers(1, &r.vbo)
	GL.DeleteProgram(r.program)
	delete(r.verts)
	delete(r.calls)
	font_destroy(&r.font)
	font_destroy(&r.ui_font)
	for kind in ItemKind {
		texture_destroy(&r.item_icons[kind])
	}
}

renderer_start_frame :: proc(r: ^Renderer) {
	clear(&r.verts)
	clear(&r.calls)
}

renderer_end_frame :: proc(r: ^Renderer, should_screenshot: ^bool, screenshot_counter: ^int, state: ^LevelState, window: ^SDL.Window, screenshot_dir: string) {
	c := r.clear_color
	GL.ClearColor(c[0], c[1], c[2], c[3])
	GL.Clear(GL.COLOR_BUFFER_BIT)
	GL.UseProgram(r.program)

	if len(r.verts) > 0 {
		GL.BindBuffer(GL.ARRAY_BUFFER, r.vbo)
		GL.BufferData(GL.ARRAY_BUFFER, len(r.verts) * size_of(Vertex), raw_data(r.verts), GL.DYNAMIC_DRAW)
	}

	GL.BindVertexArray(r.vao)
	for dc in r.calls {
		is_tex := dc.texture_id != 0
		if dc.two_tone {
			GL.Uniform1i(r.loc_two_tone, 1)
			GL.Uniform1i(r.loc_use_texture, 0)
			GL.ActiveTexture(GL.TEXTURE0)
			GL.BindTexture(GL.TEXTURE_2D, dc.texture_id)
			GL.Uniform4f(r.loc_color,   dc.color[0],   dc.color[1],   dc.color[2],   dc.color[3])
			GL.Uniform4f(r.loc_color_b, dc.color_b[0], dc.color_b[1], dc.color_b[2], dc.color_b[3])
		} else {
			GL.Uniform1i(r.loc_two_tone, 0)
			GL.Uniform1i(r.loc_use_texture, i32(is_tex))
			if is_tex {
				GL.ActiveTexture(GL.TEXTURE0)
				GL.BindTexture(GL.TEXTURE_2D, dc.texture_id)
			}
			GL.Uniform4f(r.loc_color, dc.color[0], dc.color[1], dc.color[2], dc.color[3])
		}
		GL.DrawArrays(dc.prim_type, dc.vert_start, dc.vert_count)
	}

	if should_screenshot^ {
		take_screenshot(screenshot_counter^, state, r.window_size, screenshot_dir)
		screenshot_counter^ += 1
		should_screenshot^ = false
	}

	SDL.GL_SwapWindow(window)
}

draw_rect :: proc(r: ^Renderer, rect: Rect, color: Color) {
	start := i32(len(r.verts))
	append(&r.verts,
		Vertex{rect.min, {}},
		Vertex{{rect.max.x, rect.min.y}, {}},
		Vertex{{rect.min.x, rect.max.y}, {}},
		Vertex{{rect.max.x, rect.min.y}, {}},
		Vertex{{rect.min.x, rect.max.y}, {}},
		Vertex{rect.max, {}},
	)
	append(&r.calls, DrawCall{GL.TRIANGLES, start, 6, color, {}, 0, false})
}

draw_polygon :: proc(r: ^Renderer, points: []vec2, color: Color) {
	if len(points) < 3 { return }
	start := i32(len(r.verts))
	// Use centroid as fan hub — guarantees correct triangulation for any convex polygon
	centroid: vec2
	for p in points { centroid += p }
	centroid /= f32(len(points))
	append(&r.verts, Vertex{centroid, {}})
	for p in points {
		append(&r.verts, Vertex{p, {}})
	}
	// Close the fan by repeating the first perimeter vertex
	append(&r.verts, Vertex{points[0], {}})
	append(&r.calls, DrawCall{GL.TRIANGLE_FAN, start, i32(len(points) + 2), color, {}, 0, false})
}

draw_circle :: proc(r: ^Renderer, circle: Circle, color: Color) {
	start := i32(len(r.verts))
	append(&r.verts, Vertex{circle.pos, {}})
	for i in 0..<SEGMENTS {
		angle := f32(i) / f32(SEGMENTS) * glsl.TAU
		append(&r.verts, Vertex{circle.pos + vec2{glsl.cos(angle), glsl.sin(angle)} * circle.radius, {}})
	}
	append(&r.verts, r.verts[int(start)+1])
	append(&r.calls, DrawCall{GL.TRIANGLE_FAN, start, VERTEX_COUNT, color, {}, 0, false})
}

// draw_triangle renders a filled triangle from three points.
draw_triangle :: proc(r: ^Renderer, a, b, c: vec2, color: Color) {
	start := i32(len(r.verts))
	append(&r.verts, Vertex{a, {}}, Vertex{b, {}}, Vertex{c, {}})
	append(&r.calls, DrawCall{GL.TRIANGLES, start, 3, color, {}, 0, false})
}

// draw_line renders a line between two points with a given width.
draw_line :: proc(r: ^Renderer, line: Line, width: f32, color: Color) {
	d := line.end - line.start
	l := glsl.length(d)
	if l == 0 { return }
	perp := vec2{-d.y, d.x} / l * (width * 0.5)
	a := line.start + perp
	b := line.start - perp
	c := line.end   - perp
	d2 := line.end  + perp
	start := i32(len(r.verts))
	append(&r.verts, Vertex{a, {}}, Vertex{b, {}}, Vertex{c, {}}, Vertex{a, {}}, Vertex{c, {}}, Vertex{d2, {}})
	append(&r.calls, DrawCall{GL.TRIANGLES, start, 6, color, {}, 0, false})
}

TextAlign  :: enum { Left, Center, Right }
VAlign     :: enum { Top, Middle, Bottom, Baseline }

// text_width returns the total advance width of text at native font size (no scaling).
text_width :: proc(f: Font, text: string) -> f32 {
	w: f32
	for ch in text {
		idx := int(ch) - FONT_FIRST_CHAR
		if idx < 0 || idx >= FONT_CHAR_COUNT { continue }
		w += f.glyphs[idx].xadvance
	}
	return w
}

draw_text :: proc(r: ^Renderer, f: Font, text: string, pos: vec2, color: Color, align: TextAlign = .Left, valign: VAlign = .Top) {
	if f.texture_id == 0 { return }

	x := glsl.round(pos.x)
	switch align {
	case .Center: x = glsl.round(x - text_width(f, text) / 2)
	case .Right:  x = glsl.round(x - text_width(f, text))
	case .Left:
	}

	y := pos.y
	switch valign {
	case .Top:      y += f.ascent
	case .Middle:   y += (f.ascent + f.descent) / 2
	case .Bottom:   y -= f.descent
	case .Baseline:
	}

	atlas := f32(f.atlas_size)
	xf    := glsl.round(x)
	yf    := glsl.round(y)

	start := i32(len(r.verts))
	for ch in text {
		idx := int(ch) - FONT_FIRST_CHAR
		if idx < 0 || idx >= FONT_CHAR_COUNT { continue }
		g := f.glyphs[idx]

		// Screen-space quad corners (1:1 with atlas pixels)
		x0 := xf + f32(g.xoff)
		y0 := yf + f32(g.yoff)
		x1 := xf + f32(g.xoff) + f32(g.x1 - g.x0)
		y1 := yf + f32(g.yoff) + f32(g.y1 - g.y0)

		// Atlas UV
		u0 := f32(g.x0) / atlas
		v0 := f32(g.y0) / atlas
		u1 := f32(g.x1) / atlas
		v1 := f32(g.y1) / atlas

		append(&r.verts,
			Vertex{{x0, y0}, {u0, v0}},
			Vertex{{x1, y0}, {u1, v0}},
			Vertex{{x0, y1}, {u0, v1}},
			Vertex{{x1, y0}, {u1, v0}},
			Vertex{{x1, y1}, {u1, v1}},
			Vertex{{x0, y1}, {u0, v1}},
		)
		xf += g.xadvance
	}

	count := i32(len(r.verts)) - start
	if count > 0 {
		transparent := Color{0, 0, 0, 0}
		append(&r.calls, DrawCall{GL.TRIANGLES, start, count, color, transparent, f.texture_id, true})
	}
}

draw_text_rect :: proc(r: ^Renderer, f: Font, text: string, rect: Rect, color: Color, align: TextAlign = .Center, valign: VAlign = .Middle) {
	x: f32
	switch align {
	case .Left:   x = rect.min.x
	case .Center: x = (rect.min.x + rect.max.x) / 2
	case .Right:  x = rect.max.x
	}
	y: f32
	switch valign {
	case .Top:      y = rect.min.y
	case .Middle:   y = (rect.min.y + rect.max.y) / 2
	case .Bottom:   y = rect.max.y
	case .Baseline: y = rect.min.y  // baseline semantics not meaningful for rect; treat as top
	}
	draw_text(r, f, text, {x, y}, color, align, valign)
}

Texture :: struct {
	id:   u32,
	size: ivec2,
}

texture_load :: proc(path: string) -> (t: Texture, ok: bool) {
	buf: [512]u8
	fmt.bprintf(buf[:], "%s\x00", path)

	w, h, channels: c.int
	data := stbi.load(cstring(raw_data(buf[:])), &w, &h, &channels, 4)
	if data == nil {
		fmt.eprintln("texture_load failed:", path)
		return {}, false
	}
	defer stbi.image_free(data)

	GL.GenTextures(1, &t.id)
	GL.BindTexture(GL.TEXTURE_2D, t.id)
	GL.TexImage2D(GL.TEXTURE_2D, 0, GL.RGBA, w, h, 0, GL.RGBA, GL.UNSIGNED_BYTE, data)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, GL.NEAREST)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, GL.NEAREST)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_S, GL.CLAMP_TO_EDGE)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_T, GL.CLAMP_TO_EDGE)

	t.size = {i32(w), i32(h)}
	return t, true
}

// texture_load_silent is like texture_load but does not print an error on failure.
texture_load_silent :: proc(path: string) -> (t: Texture, ok: bool) {
	buf: [512]u8
	fmt.bprintf(buf[:], "%s\x00", path)

	w, h, channels: c.int
	data := stbi.load(cstring(raw_data(buf[:])), &w, &h, &channels, 4)
	if data == nil { return {}, false }
	defer stbi.image_free(data)

	GL.GenTextures(1, &t.id)
	GL.BindTexture(GL.TEXTURE_2D, t.id)
	GL.TexImage2D(GL.TEXTURE_2D, 0, GL.RGBA, w, h, 0, GL.RGBA, GL.UNSIGNED_BYTE, data)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, GL.NEAREST)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, GL.NEAREST)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_S, GL.CLAMP_TO_EDGE)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_T, GL.CLAMP_TO_EDGE)

	t.size = {i32(w), i32(h)}
	return t, true
}

// generate_item_icon creates a simple 16x16 white-on-transparent procedural icon
// for use when PNG icons are not available.
generate_item_icon :: proc(kind: ItemKind) -> Texture {
	SIZE :: 16
	pixels: [SIZE * SIZE * 4]u8

	// Helper to set a pixel (white with full alpha)
	set :: proc(pixels: ^[SIZE * SIZE * 4]u8, x, y: int) {
		SIZE :: 16
		if x < 0 || x >= SIZE || y < 0 || y >= SIZE { return }
		idx := (y * SIZE + x) * 4
		pixels[idx]     = 255
		pixels[idx + 1] = 255
		pixels[idx + 2] = 255
		pixels[idx + 3] = 255
	}

	switch kind {
	case .ExtraLife:
		// Heart shape
		for y in 0..<SIZE {
			for x in 0..<SIZE {
				fx := f32(x) - 7.5
				fy := f32(y) - 7.5
				fx2 := fx * fx
				fy_adj := fy + 2
				heart := (fx2 + fy_adj * fy_adj - 20) * (fx2 + fy_adj * fy_adj - 20) * (fx2 + fy_adj * fy_adj - 20) - fx2 * fy_adj * fy_adj * fy_adj
				if heart < 0 { set(&pixels, x, y) }
			}
		}
	case .ExtraBall:
		// Circle
		for y in 0..<SIZE {
			for x in 0..<SIZE {
				dx := f32(x) - 7.5
				dy := f32(y) - 7.5
				if dx*dx + dy*dy <= 25 { set(&pixels, x, y) }
			}
		}
	case .WidePaddle:
		// Wide horizontal arrows pointing outward: <-->
		for x in 3..<13 { set(&pixels, x, 7); set(&pixels, x, 8) }
		set(&pixels, 4, 6); set(&pixels, 3, 7); set(&pixels, 4, 9)
		set(&pixels, 11, 6); set(&pixels, 12, 7); set(&pixels, 11, 9)
	case .NarrowPaddle:
		// Narrow horizontal arrows pointing inward
		for x in 3..<13 { set(&pixels, x, 7); set(&pixels, x, 8) }
		set(&pixels, 5, 6); set(&pixels, 6, 7); set(&pixels, 5, 9)
		set(&pixels, 10, 6); set(&pixels, 9, 7); set(&pixels, 10, 9)
	case .StickyPaddle:
		// Droplet / glue shape
		for y in 0..<SIZE {
			for x in 0..<SIZE {
				dx := f32(x) - 7.5
				dy := f32(y) - 7.5
				if dy > 0 && dx*dx + dy*dy <= 20 { set(&pixels, x, y) }
				if dy <= 0 && abs(dx) <= -dy * 0.6 + 2 { set(&pixels, x, y) }
			}
		}
	case .FastBall:
		// Double right chevron >>
		for i in 0..<6 {
			set(&pixels, 3 + i, 5 + i); set(&pixels, 3 + i, 11 - i)
			set(&pixels, 7 + i, 5 + i); set(&pixels, 7 + i, 11 - i)
		}
	case .SlowBall:
		// Pause bars ||
		for y in 4..<12 {
			set(&pixels, 5, y); set(&pixels, 6, y)
			set(&pixels, 9, y); set(&pixels, 10, y)
		}
	}

	t: Texture
	t.size = {SIZE, SIZE}
	GL.GenTextures(1, &t.id)
	GL.BindTexture(GL.TEXTURE_2D, t.id)
	GL.TexImage2D(GL.TEXTURE_2D, 0, GL.RGBA, SIZE, SIZE, 0, GL.RGBA, GL.UNSIGNED_BYTE, raw_data(pixels[:]))
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, GL.NEAREST)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, GL.NEAREST)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_S, GL.CLAMP_TO_EDGE)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_T, GL.CLAMP_TO_EDGE)
	return t
}

texture_destroy :: proc(t: ^Texture) {
	GL.DeleteTextures(1, &t.id)
	t.id = 0
}

// draw_nine_patch renders a texture as a nine-patch (3x3 grid of cells).
// border is the corner size in both source texture pixels and destination screen pixels.
// Corners are unscaled; edges stretch in one axis; center stretches in both.
draw_nine_patch :: proc(r: ^Renderer, rect: Rect, texture: Texture, border: f32, color: Color = WHITE) {
	tw := f32(texture.size.x)
	th := f32(texture.size.y)
	draw_nine_patch_splits(r, rect, texture, {border, tw - border}, {border, th - border}, color)
}

// draw_nine_patch_splits renders a nine-patch with explicit per-axis split pixels.
// sx = {x where left col ends, x where right col begins}  — in texture pixels
// sy = {y where top row ends,  y where bottom row begins} — in texture pixels
// The right/bottom fixed widths are inferred as (texture.size - split[1]).
draw_nine_patch_splits :: proc(r: ^Renderer, rect: Rect, texture: Texture, sx, sy: [2]f32, color: Color = WHITE) {
	tw    := f32(texture.size.x)
	th    := f32(texture.size.y)
	right := tw - sx[1]
	bot   := th - sy[1]
	dx := [4]f32{rect.min.x, rect.min.x + sx[0], rect.max.x - right, rect.max.x}
	dy := [4]f32{rect.min.y, rect.min.y + sy[0], rect.max.y - bot,   rect.max.y}
	ux := [4]f32{0, sx[0]/tw, sx[1]/tw, 1}
	uy := [4]f32{1, 1 - sy[0]/th, 1 - sy[1]/th, 0}
	start := i32(len(r.verts))
	for row in 0..<3 {
		for col in 0..<3 {
			x0, x1 := dx[col], dx[col+1]
			y0, y1 := dy[row], dy[row+1]
			u0, u1 := ux[col], ux[col+1]
			v0, v1 := uy[row], uy[row+1]
			append(&r.verts,
				Vertex{{x0, y0}, {u0, v0}},
				Vertex{{x1, y0}, {u1, v0}},
				Vertex{{x0, y1}, {u0, v1}},
				Vertex{{x1, y0}, {u1, v0}},
				Vertex{{x1, y1}, {u1, v1}},
				Vertex{{x0, y1}, {u0, v1}},
			)
		}
	}
	append(&r.calls, DrawCall{GL.TRIANGLES, start, 54, color, {}, texture.id, false})
}

draw_image :: proc(r: ^Renderer, rect: Rect, texture: Texture, color: Color = WHITE) {
	start := i32(len(r.verts))
	tl := rect.min
	tr := vec2{rect.max.x, rect.min.y}
	bl := vec2{rect.min.x, rect.max.y}
	br := rect.max
	// UV y is flipped: stb row 0 = image top = UV y=1 in OpenGL
	append(&r.verts,
		Vertex{tl, {0, 1}},
		Vertex{tr, {1, 1}},
		Vertex{bl, {0, 0}},
		Vertex{tr, {1, 1}},
		Vertex{br, {1, 0}},
		Vertex{bl, {0, 0}},
	)
	append(&r.calls, DrawCall{GL.TRIANGLES, start, 6, color, {}, texture.id, false})
}

// draw_sprite draws a sub-rect of a texture (sprite sheet slice).
// src is in image-space pixels (origin top-left, y down).
draw_sprite :: proc(r: ^Renderer, rect: Rect, texture: Texture, src: Rect, color: Color = WHITE) {
	tw := f32(texture.size.x)
	th := f32(texture.size.y)
	// UV x: left-to-right; UV y: flipped (image top = UV y=1)
	u0 := src.min.x / tw
	u1 := src.max.x / tw
	v0 := 1 - src.min.y / th  // top of src → UV y near 1
	v1 := 1 - src.max.y / th  // bottom of src → UV y near 0
	start := i32(len(r.verts))
	tl := rect.min
	tr := vec2{rect.max.x, rect.min.y}
	bl := vec2{rect.min.x, rect.max.y}
	br := rect.max
	append(&r.verts,
		Vertex{tl, {u0, v0}},
		Vertex{tr, {u1, v0}},
		Vertex{bl, {u0, v1}},
		Vertex{tr, {u1, v0}},
		Vertex{br, {u1, v1}},
		Vertex{bl, {u0, v1}},
	)
	append(&r.calls, DrawCall{GL.TRIANGLES, start, 6, color, {}, texture.id, false})
}

// draw_two_tone renders a full texture rect with two-tone color mapping.
// Bright (white) pixels in the texture map to color_a; dark (black) pixels map to color_b.
draw_two_tone :: proc(r: ^Renderer, rect: Rect, texture: Texture, color_a, color_b: Color) {
	start := i32(len(r.verts))
	tl := rect.min
	tr := vec2{rect.max.x, rect.min.y}
	bl := vec2{rect.min.x, rect.max.y}
	br := rect.max
	// UV y flipped to match stbi load convention
	append(&r.verts,
		Vertex{tl, {0, 1}},
		Vertex{tr, {1, 1}},
		Vertex{bl, {0, 0}},
		Vertex{tr, {1, 1}},
		Vertex{br, {1, 0}},
		Vertex{bl, {0, 0}},
	)
	append(&r.calls, DrawCall{GL.TRIANGLES, start, 6, color_a, color_b, texture.id, true})
}

// draw_block_damage overlays crack lines on a block rect based on damage level.
// damage_level 0 = no damage, 1 = light cracks, 2+ = heavy cracks.
draw_block_damage :: proc(r: ^Renderer, rect: Rect, damage_level: int) {
	if damage_level <= 0 { return }
	w  := rect.max.x - rect.min.x
	h  := rect.max.y - rect.min.y
	cx := rect.min.x + w / 2
	cy := rect.min.y + h / 2
	if damage_level == 1 {
		// One diagonal crack: top-left to bottom-right, 1px wide
		draw_rect(r, Rect{min = {rect.min.x + w*0.2, cy - 1}, max = {rect.min.x + w*0.65, cy + 1}}, Color{0, 0, 0, 0.3})
		draw_rect(r, Rect{min = {cx - 1, rect.min.y + h*0.2}, max = {cx + 1, rect.min.y + h*0.65}}, Color{0, 0, 0, 0.3})
	} else {
		// Heavy cracks: two crossing diagonals, more opaque
		draw_rect(r, Rect{min = {rect.min.x + w*0.1, cy - 1}, max = {rect.max.x - w*0.1, cy + 1}}, Color{0, 0, 0, 0.5})
		draw_rect(r, Rect{min = {cx - 1, rect.min.y + h*0.1}, max = {cx + 1, rect.max.y - h*0.1}}, Color{0, 0, 0, 0.5})
		draw_rect(r, Rect{min = {rect.min.x + w*0.2, rect.min.y + h*0.2}, max = {rect.min.x + w*0.6, rect.min.y + h*0.6}}, Color{0, 0, 0, 0.4})
		draw_rect(r, Rect{min = {rect.min.x + w*0.4, rect.min.y + h*0.4}, max = {rect.max.x - w*0.1, rect.max.y - h*0.1}}, Color{0, 0, 0, 0.4})
	}
}

// draw_two_tone_tiled renders a tiled texture across rect with two-tone color mapping.
// tile_size controls the screen-space size of one texture repetition.
draw_two_tone_tiled :: proc(r: ^Renderer, rect: Rect, texture: Texture, tile_size: f32, color_a, color_b: Color, uv_offset: vec2 = {}) {
	size := rect.max - rect.min
	// UV goes from 0 to (size/tile_size) so the texture tiles across the rect
	u0 := uv_offset.x
	v0 := uv_offset.y
	u1 := u0 + size.x / tile_size
	v1 := v0 + size.y / tile_size
	start := i32(len(r.verts))
	tl := rect.min
	tr := vec2{rect.max.x, rect.min.y}
	bl := vec2{rect.min.x, rect.max.y}
	br := rect.max
	append(&r.verts,
		Vertex{tl, {u0, v1}},
		Vertex{tr, {u1, v1}},
		Vertex{bl, {u0, v0}},
		Vertex{tr, {u1, v1}},
		Vertex{br, {u1, v0}},
		Vertex{bl, {u0, v0}},
	)
	append(&r.calls, DrawCall{GL.TRIANGLES, start, 6, color_a, color_b, texture.id, true})
}

// snap_rect rounds min/max to the nearest integer for pixel-perfect placement.
snap_rect :: proc(rect: Rect) -> Rect {
	return Rect{
		min = {glsl.round(rect.min.x), glsl.round(rect.min.y)},
		max = {glsl.round(rect.max.x), glsl.round(rect.max.y)},
	}
}
