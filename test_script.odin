package main

import "core:encoding/json"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import SDL "vendor:sdl3"

TestEvent :: struct {
	at:     f32,
	key:    string,
	action: string, // "down" (default) or "up"
}

TestScript :: struct {
	settings:  Maybe(Settings),
	level_idx: Maybe(int),
	pause_sim: bool,
	events:    []TestEvent,
	next:      int,
}

TestScriptFile :: struct {
	settings:  Maybe(Settings),
	level_idx: Maybe(int),
	pause_sim: bool,
	events:    [dynamic]TestEvent,
}

test_script_load :: proc(path: string) -> (script: TestScript, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return }
	defer delete(data)
	file: TestScriptFile
	json.unmarshal(data, &file)
	slice.sort_by(file.events[:], proc(a, b: TestEvent) -> bool { return a.at < b.at })
	return TestScript{settings = file.settings, level_idx = file.level_idx, pause_sim = file.pause_sim, events = file.events[:]}, true
}

test_script_pump :: proc(s: ^TestScript, elapsed: f32, should_screenshot: ^bool, running: ^bool, sim_steps_requested: ^int) {
	for s.next < len(s.events) {
		ev := s.events[s.next]
		if elapsed < ev.at { break }
		s.next += 1
		if ev.key == "screenshot" {
			should_screenshot^ = true
			continue
		}
		if ev.key == "quit" {
			running^ = false
			continue
		}
		if ev.key == "step" || strings.has_prefix(ev.key, "step ") {
			n := 1
			if len(ev.key) > 5 {
				if parsed, parse_ok := strconv.parse_int(ev.key[5:]); parse_ok {
					n = parsed
				}
			}
			sim_steps_requested^ += n
			continue
		}
		cname    := strings.clone_to_cstring(ev.key, context.temp_allocator)
		scancode := SDL.GetScancodeFromName(cname)
		if scancode == .UNKNOWN { continue }
		is_down := ev.action != "up"
		e: SDL.Event
		e.key.type     = .KEY_DOWN if is_down else .KEY_UP
		e.key.scancode = scancode
		e.key.down     = is_down
		_ = SDL.PushEvent(&e)
	}
}
