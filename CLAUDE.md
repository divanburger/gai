# Project: gai

A game built from scratch in Odin using SDL3 and OpenGL.

## Build & Run

```sh
# Run directly
/home/divan/git/odin/odin run .

# Build binary
/home/divan/git/odin/odin build . -out:main

# Optimized build
/home/divan/git/odin/odin build . -o:speed -out:main
```

## Debugging

To debug visual output, build the binary and use the screenshot flags to capture the game state at a specific time, then read the image:

```sh
/home/divan/git/odin/odin build . -out:main
./main --screenshot-at 1.0 --quit-after-screenshot
```

Screenshots are saved to `screenshots/` and can be read directly with the Read tool to visually inspect the rendered output.

## Odin Toolchain

- Compiler: `/home/divan/git/odin/odin`
- Vendor bindings root: `/home/divan/git/odin/vendor/`

## Libraries

| Library | Import | Bindings path |
|---------|--------|---------------|
| SDL3 | `import SDL "vendor:sdl3"` | `/home/divan/git/odin/vendor/sdl3/` |
| OpenGL | `import GL "vendor:OpenGL"` | `/home/divan/git/odin/vendor/OpenGL/` |
| GLSL math | `import glsl "core:math/linalg/glsl"` | `/home/divan/git/odin/core/math/linalg/glsl/` |
| stb_image_write | `import stbi "vendor:stb/image"` | `/home/divan/git/odin/vendor/stb/image/stb_image_write.odin` |

`glsl.vec2 :: [2]f32` — Odin's array programming operators work element-wise on it (`+`, `-`, `*`, `/` with scalars and vectors). Field accessors `.x` / `.y` work.

## Math Utilities (`math.odin`)

Type aliases (use these everywhere — do not write `glsl.vec2` or `glsl.ivec2` directly):

| Alias | Underlying type | Use for |
|-------|----------------|---------|
| `vec2` | `glsl.vec2` (`[2]f32`) | float positions and sizes |
| `ivec2` | `glsl.ivec2` (`[2]i32`) | integer positions and sizes (e.g. pixel dimensions) |

### Rect

```odin
Rect :: struct { min, max: vec2 }
```

Represents an axis-aligned rectangle by its top-left (`min`) and bottom-right (`max`) corners.

### Helpers

- `point_inside_rect(point: vec2, r: Rect) -> bool` — inclusive bounds check
- `clamp2(v, lo, hi: $T/[2]$E) -> T` — element-wise clamp for `vec2` or `ivec2`; uses polymorphic array type so it works for both without explicit overloads

### Conventions

- Always use `vec2`/`ivec2` for positions and sizes — never separate `x, y` or `w, h` scalar variables
- Use `ivec2` when values are integers (e.g. `WINDOW_SIZE :: ivec2{800, 600}`), `vec2` when float
- Pass values directly — never reconstruct from components (e.g. pass `pos` not `vec2{pos.x, pos.y}`, pass `r` not `Rect{r.min, r.max}`)

## SDL3 + OpenGL Initialization Order

GL attributes **must** be set before `CreateWindow`:

```odin
SDL.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
SDL.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
SDL.GL_SetAttribute(.CONTEXT_PROFILE_MASK, 1)  // 1 = Core profile
SDL.GL_SetAttribute(.DOUBLEBUFFER, 1)

window := SDL.CreateWindow(title, w, h, SDL.WindowFlags{.OPENGL})
gl_ctx := SDL.GL_CreateContext(window)
SDL.GL_MakeCurrent(window, gl_ctx)
GL.load_up_to(3, 3, SDL.gl_set_proc_address)
```

## CLI Flags (`core:flags`)

- Define an `Options` struct with tagged fields inside `main`, initialize with defaults, then call `flags.parse_or_exit(&opts, os.args, .Unix)`
- `flags.parse_or_exit` skips `os.args[0]` (program name) automatically — pass full `os.args`
- Unix style: `screenshot_at f32` field → `--screenshot-at` flag; `quit_after_screenshot bool` → `--quit-after-screenshot`
- Optional flags: initialize the struct field to a sentinel (e.g. `-1`) before parsing; unset flags keep their initial value
- Usage tag: `` `usage:"..."` `` struct field tag

### Current flags

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--screenshot-at` | `f32` | `-1` (disabled) | Take a screenshot this many seconds after startup |
| `--quit-after-screenshot` | `bool` | `false` | Quit the game after the timed screenshot is taken |

```sh
./main --screenshot-at 5.0 --quit-after-screenshot
```

## Screenshot (PrtScr)

- `stbi.flip_vertically_on_write(true)` — call once at startup; handles OpenGL's bottom-up pixel order
- `GL.ReadPixels(0, 0, w, h, GL.RGBA, GL.UNSIGNED_BYTE, ptr)` — read after draw calls, before `SwapWindow`
- `stbi.write_png(filename: cstring, w, h, comp: c.int, data: rawptr, stride: c.int) -> c.int` — 0 = fail
- `comp = 4` (RGBA), `stride = width * 4`
- Filename: use a `[256]u8` stack buffer with `fmt.bprintf(..., "path\x00", ...)`, then `cstring(raw_data(buf[:]))`
- Screenshots saved to `screenshots/` folder; create with `os.make_directory("screenshots")`
- `core:image/png` has NO write support — use `vendor:stb/image` instead

## Odin Gotchas

- **`#partial switch`** is required when switching on an enum without covering all cases (e.g. `event.type`).
- **`GLProfile` → `c.int`**: `GLProfile` is a `distinct bit_set[GLProfileFlag; Uint32]`. Pass the literal integer `1` directly to `GL_SetAttribute(.CONTEXT_PROFILE_MASK, 1)` — untyped int coerces to `c.int`.
- **Shader source**: Use `cstring(raw_data(src))` to get a `cstring` from a `string` without allocation. Pass `&src_ptr` to `GL.ShaderSource`.
- **`GL.BufferData` size**: Use `size_of(array_variable)`, not element count.
- **`GL.VertexAttribPointer` offset**: Last param is `uintptr`; literal `0` coerces fine.

## Coordinate System

Screen space: (0,0) top-left, (WIDTH, HEIGHT) bottom-right (SDL convention).

Vertex shader converts to OpenGL NDC:
```glsl
vec2 ndc = (screen_pos / u_resolution) * 2.0 - 1.0;
ndc.y = -ndc.y;  // flip Y axis
```

## Circle Rendering Pattern

- VBO stores offsets from center (unit circle × radius), generated once at startup with `GL.STATIC_DRAW`.
- Ball position passed as `uniform vec2 u_center`, updated each frame.
- Geometry: `GL_TRIANGLE_FAN` with `SEGMENTS + 2` vertices (center + N perimeter + repeat of first to close).

## Delta Time

```odin
prev := SDL.GetPerformanceCounter()
freq := SDL.GetPerformanceFrequency()
// each frame:
now := SDL.GetPerformanceCounter()
dt  := f32(now - prev) / f32(freq)
prev = now
```

## Memory Management

Three lifecycles govern object lifetimes:

| Lifecycle | Duration | Allocator |
|-----------|----------|-----------|
| Frame | One iteration of the main loop | `context.temp_allocator` — reset at the start of every frame |
| Level | One level/stage (may not exist yet) | TBD |
| Active game | From game start to game over (may not exist yet) | TBD |

### Frame allocator

`free_all(context.temp_allocator)` is called at the top of the main loop before any per-frame work. Use `context.temp_allocator` for any scratch data that only needs to survive one frame (e.g. formatted strings, temporary buffers).

## Bounce Logic

Clamp-then-force-direction prevents the ball from getting stuck inside a wall:
```odin
if ball_pos.x - r < 0    { ball_pos.x = r;     ball_vel.x =  abs(ball_vel.x) }
if ball_pos.x + r > W    { ball_pos.x = W - r; ball_vel.x = -abs(ball_vel.x) }
// same for y
```
