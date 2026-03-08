package main

import "core:encoding/json"
import "core:fmt"
import "core:os"

BlockType :: struct {
	name:        string,
	char:        u8,    // character used in level files to identify this type
	hit_points:  int,   // hits to destroy
	color:       Color,
	drop_chance: f32,   // probability of dropping an item on destroy
}

Block :: struct {
	lives:    int,
	type_idx: int, // index into block_types slice; -1 = untyped
}

Level :: struct {
	blocks:       [BLOCK_COLS * BLOCK_ROWS]Block,
	playing_area: Rect,
}

// JSON file shapes
BlockTypeFile :: struct {
	name:        string,
	char:        string,
	hit_points:  int,
	color:       [4]f32,
	drop_chance: f32,
}

LevelFile :: struct {
	blocks:             [dynamic]string,
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
			name        = f.name,
			char        = f.char[0] if len(f.char) > 0 else '?',
			hit_points  = f.hit_points,
			color       = Color{f.color[0], f.color[1], f.color[2], f.color[3]},
			drop_chance = f.drop_chance if f.drop_chance > 0 else ITEM_DROP_CHANCE,
		}
	}
	return result, true
}

// Find the block type index whose char matches. Falls back to -1.
block_type_for_char :: proc(types: []BlockType, ch: u8) -> int {
	for t, i in types {
		if t.char == ch { return i }
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
	defer delete(file.blocks)

	for row, r in file.blocks {
		if r >= BLOCK_ROWS { break }
		for ch, c in row {
			if c >= BLOCK_COLS { break }
			if ch == '.' || ch == ' ' { continue } // empty cell
			type_idx := block_type_for_char(types, u8(ch))
			if type_idx < 0 { continue }
			level.blocks[r * BLOCK_COLS + c] = Block{
				lives    = types[type_idx].hit_points,
				type_idx = type_idx,
			}
		}
	}

	w := file.playing_area_width if file.playing_area_width > 0 else GAME_SIZE.x
	half := w / 2
	cx   := GAME_SIZE.x / 2
	level.playing_area = Rect{min = {cx - half, BLOCK_AREA_Y}, max = {cx + half, GAME_SIZE.y}}
	return level, true
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
