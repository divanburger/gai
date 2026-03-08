---
name: renderer
description: Reference for renderer.odin in Shardbreak. Use when working on rendering, draw functions, shaders, textures, nine-patch, sprites, or any visual output. Triggers on "renderer", "draw_", "nine patch", "texture", "shader", "sprite", "snap_rect".
user-invocable: false
---

# Renderer Reference (`renderer.odin`)

## Architecture

Single-pass immediate-mode 2D batch renderer on OpenGL 3.3 core profile.

### Structs

```odin
Vertex :: struct { pos, uv: vec2 }  // 16 bytes

DrawCall :: struct {
    prim_type:  u32,       // GL.TRIANGLES or GL.TRIANGLE_FAN
    vert_start: i32,       // offset into verts array
    vert_count: i32,       // number of vertices
    color:      Color,     // passed as u_color uniform
    texture_id: u32,       // 0 = no texture (flat color)
}

Renderer :: struct {
    program:          u32,
    loc_color:        i32,
    loc_use_texture:  i32,
    vao, vbo:         u32,
    verts:            [dynamic]Vertex,    // dynamic, initial cap 4096
    calls:            [dynamic]DrawCall,  // dynamic, initial cap 256
    window_size:      ivec2,
    clear_color:      Color,
}
```

### Lifecycle

```
renderer_init() → start_frame() → draw calls → end_frame() → renderer_destroy()
```

- `renderer_init`: compiles shaders, sets up VAO/VBO, allocates dynamic arrays, sets `u_resolution` to `WINDOW_SIZE`
- `renderer_start_frame`: `clear(&r.verts)` + `clear(&r.calls)` (preserves capacity)
- `renderer_end_frame`: clears screen, uploads vertex buffer via `GL.BufferData` (DYNAMIC_DRAW), iterates draw calls setting uniforms + issuing `GL.DrawArrays`, handles screenshots, swaps window
- `renderer_destroy`: deletes GL objects + dynamic arrays
- `renderer_set_window_size`: recalculates viewport with letterboxing to maintain `GAME_SIZE` aspect ratio

## Shaders

### Vertex Shader
Converts screen-space position to NDC with Y-flip:
```glsl
vec2 ndc = (a_pos / u_resolution) * 2.0 - 1.0;
ndc.y = -ndc.y;
```
`u_resolution` is set once at init to `WINDOW_SIZE`. Passes through `a_uv` → `v_uv`.

### Fragment Shader
Two modes controlled by `u_use_texture` bool uniform:
- **Textured** (`u_use_texture = true`): Anti-aliased pixel-art sampling using `fwidth` + `smoothstep` to get crisp edges without jaggies. Samples texture and multiplies by `u_color`.
- **Flat color** (`u_use_texture = false`): Outputs `u_color` directly.

## UV Convention (Critical)

`stbi.set_flip_vertically_on_load(1)` is called at init — stb_image flips rows on load, so **image top = UV y=1, image bottom = UV y=0** in OpenGL. All texture draw functions follow this:
- `draw_image`: top-left UV = `{0, 1}`, bottom-right UV = `{1, 0}`
- `draw_sprite`: `v0 = 1 - src.min.y / th` (top), `v1 = 1 - src.max.y / th` (bottom)
- `draw_nine_patch`: `uy = {1, 1 - border/th, border/th, 0}` — descending from 1 to 0

`stbi.flip_vertically_on_write(true)` is also set for screenshots.

## Draw Functions

| Function | Verts | Primitive | Texture | Notes |
|----------|-------|-----------|---------|-------|
| `draw_rect(r, rect, color)` | 6 | TRIANGLES | No | Flat colored rectangle |
| `draw_circle(r, circle, color)` | SEGMENTS+2 (66) | TRIANGLE_FAN | No | Uses `SEGMENTS` and `VERTEX_COUNT` from main.odin |
| `draw_text(r, text, pos, scale, color, align?)` | 6/quad, max 256 quads | TRIANGLES | No | Uses `stb/easy_font`; align: `.Left`/`.Center`/`.Right` |
| `draw_image(r, rect, texture, color?)` | 6 | TRIANGLES | Yes | Full texture in rect, default color=WHITE |
| `draw_sprite(r, rect, texture, src, color?)` | 6 | TRIANGLES | Yes | `src` is in image-space pixels (origin top-left, y down) |
| `draw_nine_patch(r, rect, texture, border, color?)` | 54 | TRIANGLES | Yes | Symmetric border (same px in texture and screen) |
| `draw_nine_patch_splits(r, rect, texture, sx, sy, color?)` | 54 | TRIANGLES | Yes | Asymmetric splits per axis |
| `snap_rect(rect) -> Rect` | — | — | — | Rounds min/max to nearest integer for pixel-perfect placement |

### Text details
- `ef.width(text)` returns pixel width at scale=1 (each glyph ~6-8px wide)
- Text quads have **no UVs** (flat color only, no texture)
- Max 256 quads per `draw_text` call
- `TextAlign :: enum { Left, Center, Right }`

### Nine-patch details
- `draw_nine_patch`: single `border` value used for all 4 corners — border px in texture = border px on screen
- `draw_nine_patch_splits`: `sx = {left_col_end, right_col_start}`, `sy = {top_row_end, bottom_row_start}` in texture pixels. Right/bottom fixed widths inferred as `(texture_size - split[1])`.
- Both always emit exactly 54 vertices (9 cells × 6 verts)

## Texture System

```odin
Texture :: struct { id: u32, size: ivec2 }
```

- `texture_load(path) -> (Texture, bool)`: loads via stb_image (forces 4 channels RGBA), creates GL texture with `GL_NEAREST` filtering and `GL_CLAMP_TO_EDGE` wrapping
- `texture_destroy(t)`: deletes GL texture, zeros id

## Kenney UI Nine-Patch Split Points (from `ui.odin`)

| Texture file | Constant | Value | Notes |
|---|---|---|---|
| `button_square.png` | `BUTTON_BORDER` | `12` | Symmetric nine-patch border |
| `button_square_depth.png` (64×64) | `BUTTON_SEL_SPLITS_X` | `{16, 48}` | Screw circles at corners x=8-11/52-55 |
| | `BUTTON_SEL_SPLITS_Y` | `{16, 44}` | Bottom zone captures shadow rows (y=56-63) |
| `button_square_header_blade_square_screws.png` (64×64) | `WINDOW_SPLITS_X` | `{13, 20}` | Only 7px middle stretches; 44px right col fixed (blade shape) |
| | `WINDOW_SPLITS_Y` | `{34, 50}` | 34px top = full blue header; 14px bottom = screw decorations |

UI constants: `BUTTON_PAD_X=32`, `BUTTON_PAD_Y=14`, `BUTTON_SPACING=16`, `UI_TEXT_SCALE=2`, `BUTTON_DEPTH_PX=8`, `WINDOW_BORDER=34`.

## Color Constants

```odin
BLACK      :: Color{0,    0,    0,    1}
WHITE      :: Color{1,    1,    1,    1}
DARK_GREY  :: Color{0.12, 0.12, 0.12, 1}
GREY       :: Color{0.4,  0.4,  0.4,  1}
RED        :: Color{1,   0,   0,   1}
GREEN      :: Color{0,   1,   0,   1}
BLUE       :: Color{0,   0,   1,   1}
YELLOW     :: Color{1,   1,   0,   1}
```

`BUTTON_SELECT_TINT :: Color{0.68, 0.88, 1.0, 1.0}` — light-blue tint for selected buttons.

## Gotchas

- `u_resolution` is set once at init to `WINDOW_SIZE`, not updated per-frame — all draw positions are in game-space coordinates
- `GL.BufferData` uses `len(r.verts) * size_of(Vertex)` (byte size, not element count)
- Text quads have zero UVs — they use flat color mode (`texture_id = 0`)
- Nine-patch always emits exactly 54 vertices regardless of cell visibility
- `SEGMENTS` (64) and `VERTEX_COUNT` (66) constants live in `main.odin`, not `renderer.odin`
- `draw_circle` uses `GL.TRIANGLE_FAN` — all other draw functions use `GL.TRIANGLES`
- Alpha blending is always on: `GL.BlendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)`
- Dynamic arrays grow automatically — no buffer overflow risk, but watch for excessive draw calls impacting performance
