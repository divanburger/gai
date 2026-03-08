package main

import "core:encoding/json"
import "core:fmt"
import "core:os"

BlockType :: struct {
	name:  string,
	lives: int,
	color: Color,
}

Ball :: struct {
	using circle: Circle,
	dir:         vec2,  // unit direction vector; velocity = dir * effective_ball_speed
	locked:      bool,
	lock_offset: vec2,  // offset from paddle center when sticky-locked
	ghost_timer: f32,   // seconds remaining as ghost (newly split balls); 0 = normal
}

Paddle :: struct {
	pos: vec2,
}

Block :: struct {
	lives:    int,
	type_idx: int, // index into block_types slice; -1 = untyped
}

Level :: struct {
	blocks:       [BLOCK_COLS * BLOCK_ROWS]Block,
	playing_area: Rect,
}

ItemKind :: enum { ExtraLife, ExtraBall, WidePaddle, NarrowPaddle, StickyPaddle, FastBall, SlowBall }

ITEM_COLORS :: [ItemKind]Color{
	.ExtraLife    = Color{0, 1, 0, 1},
	.ExtraBall    = Color{0, 0.7, 1, 1},
	.WidePaddle   = Color{1, 0.5, 0, 1},
	.NarrowPaddle = Color{1, 0, 0.5, 1},
	.StickyPaddle = Color{1, 1, 0, 1},
	.FastBall     = Color{1, 0.3, 0.3, 1},
	.SlowBall     = Color{0.3, 0.6, 1, 1},
}

DurationType :: enum { Instant, Timed, Level }

ITEM_DURATIONS :: [ItemKind]DurationType{
	.ExtraLife    = .Instant,
	.ExtraBall    = .Instant,
	.WidePaddle   = .Timed,
	.NarrowPaddle = .Timed,
	.StickyPaddle = .Timed,
	.FastBall     = .Timed,
	.SlowBall     = .Timed,
}

ITEM_TIMERS :: [ItemKind]f32{
	.ExtraLife    = 0,
	.ExtraBall    = EFFECT_TIMER_EXTRA_BALL,
	.WidePaddle   = EFFECT_TIMER_WIDE_PADDLE,
	.NarrowPaddle = EFFECT_TIMER_NARROW_PADDLE,
	.StickyPaddle = EFFECT_TIMER_STICKY_PADDLE,
	.FastBall     = EFFECT_TIMER_FAST_BALL,
	.SlowBall     = EFFECT_TIMER_SLOW_BALL,
}

ItemDrop :: struct {
	pos:    vec2,
	kind:   ItemKind,
	active: bool,
}

LevelState :: struct {
	using level:  Level,
	balls:        [dynamic]Ball,
	paddle:       Paddle,
	score:        int,
	drops:         [MAX_DROPS]ItemDrop,
	drop_count:    int,
	effect_timers: [ItemKind]f32,
	sim_steps:       int,
	sim_time:        f32,
	sim_accumulator: f32,
}

RunState :: struct {
	lives:     int,
	level_idx: int,
	run_score: int,
}

// JSON file shapes
BlockTypeFile :: struct {
	name:  string,
	lives: int,
	color: [4]f32,
}

LevelFile :: struct {
	blocks:             [dynamic][dynamic]int,
	playing_area_width: f32,
}

block_types_load :: proc(allocator := context.allocator) -> (types: []BlockType, ok: bool) {
	data, err := os.read_entire_file("assets/blocks.json", context.temp_allocator)
	if err != nil {
		fmt.eprintln("block_types_load: could not read assets/blocks.json")
		return
	}

	raw: [dynamic]BlockTypeFile
	if json.unmarshal(data, &raw) != nil {
		fmt.eprintln("block_types_load: could not parse assets/blocks.json")
		return
	}
	defer delete(raw)

	result := make([]BlockType, len(raw), allocator)
	for f, i in raw {
		result[i] = BlockType{
			name  = f.name,
			lives = f.lives,
			color = Color{f.color[0], f.color[1], f.color[2], f.color[3]},
		}
	}
	return result, true
}

// Find the block type index whose lives value matches. Falls back to -1.
block_type_for_lives :: proc(types: []BlockType, lives: int) -> int {
	for t, i in types {
		if t.lives == lives { return i }
	}
	return -1
}

block_color :: proc(b: Block, types: []BlockType) -> Color {
	if b.type_idx >= 0 && b.type_idx < len(types) {
		return types[b.type_idx].color
	}
	return YELLOW if b.lives > 1 else WHITE
}

level_load :: proc(path: string, types: []BlockType) -> (level: Level, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return }
	defer delete(data)

	file: LevelFile
	if json.unmarshal(data, &file) != nil {
		fmt.eprintln("level_load: could not parse", path)
		return
	}
	defer {
		for row in file.blocks { delete(row) }
		delete(file.blocks)
	}

	for row, r in file.blocks {
		if r >= BLOCK_ROWS { break }
		for lives, c in row {
			if c >= BLOCK_COLS { break }
			level.blocks[r * BLOCK_COLS + c] = Block{
				lives    = lives,
				type_idx = block_type_for_lives(types, lives),
			}
		}
	}

	w := file.playing_area_width if file.playing_area_width > 0 else GAME_SIZE.x
	half := w / 2
	cx   := GAME_SIZE.x / 2
	level.playing_area = Rect{min = {cx - half, BLOCK_AREA_Y}, max = {cx + half, GAME_SIZE.y}}
	return level, true
}

level_state_init :: proc(s: ^LevelState, level: Level) {
	delete(s.balls)
	s^ = {}
	s.level      = level
	s.paddle     = {pos = {GAME_SIZE.x / 2, PADDLE_Y}}
	s.balls      = make([dynamic]Ball, 0, MAX_BALLS)
	spawn_locked_ball(s, PADDLE_SIZE.x)
}

add_effect :: proc(state: ^LevelState, kind: ItemKind) {
	durations := ITEM_DURATIONS
	timers    := ITEM_TIMERS
	if durations[kind] == .Instant { return }
	state.effect_timers[kind] = timers[kind]
}

has_effect :: proc(state: ^LevelState, kind: ItemKind) -> bool {
	return state.effect_timers[kind] > 0
}

effective_paddle_width :: proc(state: ^LevelState) -> f32 {
	w := PADDLE_SIZE.x
	if has_effect(state, .WidePaddle)   { w *= PADDLE_WIDE_MULT }
	if has_effect(state, .NarrowPaddle) { w *= PADDLE_NARROW_MULT }
	return w
}


// Spawn a ball locked to the paddle at a slight horizontal offset.
spawn_locked_ball :: proc(s: ^LevelState, paddle_width: f32) {
	lock_x := paddle_width * 0.2
	lock_t := lock_x / (paddle_width / 2)
	lock_y := paddle_surface_y(0, PADDLE_SIZE.y / 2, lock_t) - BALL_RADIUS
	append(&s.balls, Ball{
		circle      = {pos = s.paddle.pos + {lock_x, lock_y}, radius = BALL_RADIUS},
		locked      = true,
		lock_offset = {lock_x, lock_y},
	})
}

run_state_init :: proc(run: ^RunState, ls: ^LevelState, levels: []Level) {
	run.lives     = STARTING_LIVES
	run.level_idx = 0
	run.run_score = 0
	level_state_init(ls, levels[0])
}

levels_load :: proc(types: []BlockType, allocator := context.allocator) -> (levels: []Level, ok: bool) {
	result := make([dynamic]Level, allocator)
	for i := 1; ; i += 1 {
		path := fmt.tprintf("levels/level_%d.json", i)
		level, level_ok := level_load(path, types)
		if !level_ok { break }
		append(&result, level)
	}
	if len(result) == 0 { return nil, false }
	return result[:], true
}
