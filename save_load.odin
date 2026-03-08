package main

import "core:encoding/json"
import "core:fmt"
import "core:os"

SAVE_FILENAME :: "savegame.json"

save_path: string = SAVE_FILENAME

save_set_dir :: proc(dir: string) {
	save_path = fmt.aprintf("%s/%s", dir, SAVE_FILENAME)
}

// Serializable versions of game state — no dynamic arrays or pointers.

SaveBall :: struct {
	pos:         vec2,
	radius:      f32,
	dir:         vec2,
	locked:      bool,
	lock_offset: vec2,
}

SaveState :: struct {
	// RunState
	lives:     int,
	level_idx: int,

	// LevelState — blocks come from the level definition, but their lives may have changed
	block_lives:    [BLOCK_COLS * BLOCK_ROWS]int,
	balls:          [MAX_BALLS]SaveBall,
	ball_count:     int,
	paddle_pos:     vec2,
	score:          int,
	drops:          [MAX_DROPS]ItemDrop,
	drop_count:     int,
	effect_timers:  [ItemKind]f32,
	playing_area:   Rect,
}

save_game :: proc(run: ^RunState, state: ^LevelState) -> bool {
	ss: SaveState
	ss.lives     = run.lives
	ss.level_idx = run.level_idx

	for i in 0..<BLOCK_COLS * BLOCK_ROWS {
		ss.block_lives[i] = state.blocks[i].lives
	}

	ss.ball_count = min(len(state.balls), MAX_BALLS)
	for i in 0..<ss.ball_count {
		b := state.balls[i]
		ss.balls[i] = SaveBall{
			pos         = b.pos,
			radius      = b.radius,
			dir         = b.dir,
			locked      = b.locked,
			lock_offset = b.lock_offset,
		}
	}

	ss.paddle_pos    = state.paddle.pos
	ss.score         = state.score
	ss.drops         = state.drops
	ss.drop_count    = state.drop_count
	ss.effect_timers = state.effect_timers
	ss.playing_area  = state.playing_area

	data, err := json.marshal(ss, {pretty = true})
	if err != nil {
		fmt.eprintln("save_game: marshal failed")
		return false
	}
	defer delete(data)

	werr := os.write_entire_file(save_path, data)
	if werr != nil {
		fmt.eprintln("save_game: write failed")
		return false
	}
	return true
}

load_game :: proc(run: ^RunState, state: ^LevelState, levels: []Level) -> bool {
	data, rerr := os.read_entire_file(save_path, context.allocator)
	if rerr != nil { return false }
	defer delete(data)

	ss: SaveState
	if json.unmarshal(data, &ss) != nil {
		fmt.eprintln("load_game: unmarshal failed")
		return false
	}

	if ss.level_idx < 0 || ss.level_idx >= len(levels) {
		fmt.eprintln("load_game: invalid level_idx")
		return false
	}

	run.lives     = ss.lives
	run.level_idx = ss.level_idx

	// Initialise level state from the level definition, then overlay saved data
	level := levels[ss.level_idx]
	delete(state.balls)
	state^ = {}
	state.level = level

	// Restore block damage
	for i in 0..<BLOCK_COLS * BLOCK_ROWS {
		state.blocks[i].lives = ss.block_lives[i]
	}

	// Restore balls
	state.balls = make([dynamic]Ball, 0, MAX_BALLS)
	for i in 0..<ss.ball_count {
		sb := ss.balls[i]
		append(&state.balls, Ball{
			circle      = {pos = sb.pos, radius = sb.radius},
			dir         = sb.dir,
			locked      = sb.locked,
			lock_offset = sb.lock_offset,
		})
	}

	state.paddle       = {pos = ss.paddle_pos}
	state.score        = ss.score
	state.drops        = ss.drops
	state.drop_count   = ss.drop_count
	state.effect_timers = ss.effect_timers
	state.playing_area = ss.playing_area

	return true
}

save_exists :: proc() -> bool {
	return os.exists(save_path)
}

save_delete :: proc() {
	os.remove(save_path)
}
