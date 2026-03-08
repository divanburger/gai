# Shardbreak TODO

## Block Types
- [ ] Define block types in a separate config file (e.g. `assets/blocks.json`) with properties: name, starting lives, color, etc.
- [ ] Level files reference block type (by name/id) instead of raw life count
- [ ] Crack/damage overlay on blocks to visually indicate lost lives (e.g. progressive crack textures layered on top)

## Particle System
- [ ] 2D particle system (spawn, update, render with lifetime/velocity/fade)
- [ ] Breaking blocks releases particles

## Item Drops
- [ ] Certain blocks have a chance to drop items when broken
- [ ] Dropped items slowly fall down the screen
- [ ] Dropped items grant abilities with three durations: timed (expires after N seconds), level (lasts until level ends), or permanent (lasts the whole run)
- [ ] +1 life drop item (permanent — lasts the run)
- [ ] +1 ball drop item (timed)
- [ ] Wide paddle drop item (timed) — increases paddle width
- [ ] Narrow paddle drop item (timed) — decreases paddle width
- [ ] Sticky paddle drop item (timed) — ball sticks on contact, player presses Space to re-launch (like waiting_to_start)
- [ ] Active effects HUD: show icons/indicators for active timed and level-only effects, with countdown timer for timed effects

## Multi-Ball
- [ ] Support up to 6 balls in play (start with 1)

## Paddle
- [ ] Allow paddle movement during `waiting_to_start` — ball stays centered on paddle until Space launches it. Consolidate with sticky paddle logic (both hold the ball on the paddle and release with Space)
- [ ] Curved paddle shape: slight bow with increasing bend rate near edges, slightly rounded corners
  - Render as a series of thin vertical slices or a polyline with the curve baked in
  - Physics: use the surface normal at the ball's contact point to determine bounce direction (steeper angle near edges = more horizontal bounce). Can approximate with a parametric curve (e.g. parabola or cosine) mapped across the paddle width

## Font Rendering
- [ ] Switch from `vendor:stb/easy_font` to proper TTF rendering using `vendor:stb/truetype` + `vendor:stb/rect_pack`
  - Font: `assets/fonts/Kenney_Future.ttf`
  - Bake a glyph atlas texture at init, render text as textured quads

## Renderer Dynamic Buffers
- [ ] Replace fixed-size vertex/draw call arrays (`[16384]Vertex`, `[1100]DrawCall`) with a dynamic buffer system
  - Options: chunk linked-list (each chunk holds N verts + draw calls, allocate new chunks as needed) or a growable buffer from `core:container`
  - Must still upload to GPU efficiently (single or few VBO uploads per frame)

## UI Widgets
- [ ] Expand `ui.odin` with generic immediate-mode widgets (inspired by Kenney UI kit in `assets/ui/previews/`):
  - [ ] `ui_selector` — left/right arrow selector for cycling through options (e.g. display mode, resolution). Renders `< value >` with arrow indicators
  - [ ] `ui_progress_bar` — horizontal bar with fill ratio, configurable colors (for health, energy, timers)
  - [ ] `ui_indicator` — small colored circle/dot for status display (red/yellow/green, like Gate A/B/C)
  - [ ] `ui_slider` — horizontal draggable slider with track and handle (for volume, brightness)
  - [ ] `ui_dialog` — centered dialog window with title, message text, and a row of buttons (e.g. Yes/No confirmation)
  - [ ] `ui_row` / `ui_col` layout helpers — arrange widgets horizontally or vertically with spacing, advancing the cursor

## Refactor main.odin to use UI widgets
- [ ] Replace hand-rolled `draw_options` with `ui_selector` widgets for Display Mode and Resolution cycling (removes manual `< value >` rendering and Left/Right key handling)
- [ ] Replace `draw_main_menu` and `draw_paused` window+button layout with `ui_window_render` + `ui_button` using the cursor-based API (`ui_begin`/`ui_button`) instead of manual position math
- [ ] Replace `draw_game_over` and `draw_level_complete` with `ui_dialog` (centered window with message + buttons)
- [ ] Remove `ef.width()` calls from `main.odin` — use `text_width` from the new TTF renderer instead
- [ ] Remove `import ef "vendor:stb/easy_font"` from `main.odin` once all usages are migrated

## Text Quality
- [ ] Audit all `draw_text` calls to ensure text is crisp and readable at all sizes — check font atlas resolution, glyph alignment to pixel grid, and scaling factors. Snap text positions to integer coordinates where needed to avoid subpixel blurring.

## Two-Tone Texture Rendering
- [ ] Renderer support for two-tone textures: black/white source textures where caller provides two colors; white maps to color A, black maps to color B, grey interpolates between them
- [ ] Render game background using a two-tone texture instead of solid clear color (subtle effect)
- Tileable B&W pattern textures available in `assets/patterns/` (84 patterns) — use for backgrounds and particles
