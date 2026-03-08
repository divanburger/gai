package main

import "core:encoding/json"
import "core:os"

SETTINGS_PATH :: "settings.json"

RESOLUTIONS :: [5]ivec2{
	{800,  600},
	{1024, 768},
	{1280, 720},
	{1280, 960},
	{1920, 1080},
}

Settings :: struct {
	resolution_idx: int,
	display_mode:   DisplayMode,
}

settings_load :: proc() -> Settings {
	s := Settings{resolution_idx = 2, display_mode = .Windowed}
	data, err := os.read_entire_file(SETTINGS_PATH, context.allocator)
	if err != nil { return s }
	defer delete(data)
	json.unmarshal(data, &s)
	if s.resolution_idx < 0 || s.resolution_idx >= len(RESOLUTIONS) {
		s.resolution_idx = 0
	}
	return s
}

settings_save :: proc(s: Settings) {
	data, err := json.marshal(s, {use_enum_names = true, pretty = true})
	if err != nil { return }
	defer delete(data)
	_ = os.write_entire_file(SETTINGS_PATH, data)
}
