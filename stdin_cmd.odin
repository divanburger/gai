package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import SDL "vendor:sdl3"

STDIN_CMD_MAX :: 4096

StdinCmdType :: enum { Screenshot, Quit, KeyDown, KeyUp, Step, State, Blocks }

StdinCmd :: struct {
	type:     StdinCmdType,
	scancode: SDL.Scancode,
	count:    int,
}

StdinReader :: struct {
	cmds:       [STDIN_CMD_MAX]StdinCmd,
	write_idx:  int,
	read_idx:   int,
	mutex:      sync.Mutex,
	t:          ^thread.Thread,
}

stdin_reader_init :: proc(sr: ^StdinReader) -> bool {
	sr^ = {}
	sr.t = thread.create_and_start_with_data(sr, stdin_reader_thread_proc)
	return true
}

stdin_reader_destroy :: proc(sr: ^StdinReader) {
	if sr.t != nil {
		thread.terminate(sr.t, 0)
		thread.destroy(sr.t)
		sr.t = nil
	}
}

stdin_reader_thread_proc :: proc(data: rawptr) {
	sr := cast(^StdinReader)data
	buf: [4096]u8
	line_buf: [4096]u8
	line_len := 0

	for {
		n, err := os.read(os.stdin, buf[:])
		if err != nil || n <= 0 { break }

		for i in 0..<n {
			ch := buf[i]
			if ch == '\n' || ch == '\r' {
				if line_len > 0 {
					line := string(line_buf[:line_len])
					cmd, ok := parse_stdin_cmd(line)
					if ok {
						sync.lock(&sr.mutex)
						idx := sr.write_idx % STDIN_CMD_MAX
						sr.cmds[idx] = cmd
						sr.write_idx += 1
						sync.unlock(&sr.mutex)
					}
					line_len = 0
				}
			} else if line_len < len(line_buf) {
				line_buf[line_len] = ch
				line_len += 1
			}
		}
	}
}

parse_stdin_cmd :: proc(line: string) -> (cmd: StdinCmd, ok: bool) {
	trimmed := strings.trim_space(line)
	if trimmed == "" { return }

	if trimmed == "screenshot" {
		return StdinCmd{type = .Screenshot}, true
	}
	if trimmed == "quit" {
		return StdinCmd{type = .Quit}, true
	}
	if trimmed == "state" {
		return StdinCmd{type = .State}, true
	}
	if trimmed == "blocks" {
		return StdinCmd{type = .Blocks}, true
	}

	// "step" or "step N"
	if trimmed == "step" || (len(trimmed) > 5 && trimmed[:5] == "step ") {
		n := 1
		if len(trimmed) > 5 {
			if parsed, parse_ok := strconv.parse_int(trimmed[5:]); parse_ok {
				n = parsed
			}
		}
		return StdinCmd{type = .Step, count = n}, true
	}

	// "key <name>" for key down, "key <name> up" for key up
	if len(trimmed) > 4 && trimmed[:4] == "key " {
		rest := trimmed[4:]
		is_down := true
		if len(rest) > 3 && rest[len(rest)-3:] == " up" {
			rest = rest[:len(rest)-3]
			is_down = false
		}
		cname := strings.clone_to_cstring(rest, context.temp_allocator)
		scancode := SDL.GetScancodeFromName(cname)
		if scancode == .UNKNOWN { return }
		return StdinCmd{
			type     = .KeyDown if is_down else .KeyUp,
			scancode = scancode,
		}, true
	}

	return
}

stdin_reader_pump :: proc(sr: ^StdinReader, should_screenshot: ^bool, running: ^bool, sim_steps_requested: ^int, gs: ^GameState, run: ^RunState, state: ^LevelState) {
	sync.lock(&sr.mutex)
	defer sync.unlock(&sr.mutex)

	cmd_loop: for sr.read_idx < sr.write_idx {
		cmd := sr.cmds[sr.read_idx % STDIN_CMD_MAX]
		sr.read_idx += 1

		switch cmd.type {
		case .Screenshot:
			should_screenshot^ = true
			break cmd_loop  // let the frame complete (render + save) before processing more commands
		case .Quit:
			running^ = false
		case .Step:
			sim_steps_requested^ += cmd.count
			break cmd_loop  // let the frame complete before processing more commands
		case .State:
			blocks_remaining := 0
			for i in 0..<BLOCK_COLS * BLOCK_ROWS {
				if state.blocks[i].lives > 0 { blocks_remaining += 1 }
			}
			game_log(state, fmt.tprintf("state screen=%v playing=%v lives=%d score=%d run_score=%d blocks=%d paddle_x=%.1f paddle_y=%.1f ball_count=%d",
				gs.screen, gs.playing_state, run.lives, state.score, run.run_score, blocks_remaining,
				state.paddle.pos.x, state.paddle.pos.y, len(state.balls)))
			for b, i in state.balls {
				game_log(state, fmt.tprintf("ball idx=%d x=%.1f y=%.1f dx=%.2f dy=%.2f locked=%v ghost=%.2f",
					i, b.pos.x, b.pos.y, b.dir.x, b.dir.y, b.locked, b.ghost_timer))
			}
		case .Blocks:
			for row in 0..<BLOCK_ROWS {
				for col in 0..<BLOCK_COLS {
					b := state.blocks[row * BLOCK_COLS + col]
					if b.lives > 0 {
						game_log(state, fmt.tprintf("block col=%d row=%d lives=%d", col, row, b.lives))
					}
				}
			}
		case .KeyDown, .KeyUp:
			is_down := cmd.type == .KeyDown
			e: SDL.Event
			e.key.type     = .KEY_DOWN if is_down else .KEY_UP
			e.key.scancode = cmd.scancode
			e.key.down     = is_down
			_ = SDL.PushEvent(&e)
		}
	}
}
