package main

Ball :: struct {
	using circle: Circle,
	vel: vec2,
}

Paddle :: struct {
	pos: vec2,
}

LevelState :: struct {
	ball:   Ball,
	paddle: Paddle,
	lives:  int,
	score:  int,
	blocks: [BLOCK_COLS * BLOCK_ROWS]bool,
}
