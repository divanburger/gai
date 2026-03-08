# Shardbreak

A breakout-style game built from scratch in [Odin](https://odin-lang.org/) using SDL3 and OpenGL.

## Gameplay

- Move the paddle to keep the ball in play
- Break all blocks to clear the level and advance to the next
- Each block destroyed scores 100 points
- You have 3 lives — the ball falling off the bottom costs one, lives carry over between levels
- Blocks have different types: normal (1 hit), tough (2 hits, yellow), strong (3 hits, red), and treasure (1 hit, green, always drops an item)
- Destroying blocks has a chance to drop items that grant temporary effects

## Items & Effects

| Item | Effect |
|------|--------|
| Extra Life | Gain an extra life (instant) |
| Extra Ball | Split all balls into two |
| Wide Paddle | Widens the paddle temporarily |
| Narrow Paddle | Narrows the paddle temporarily |
| Sticky Paddle | Ball sticks to paddle on contact |
| Fast Ball | Increases ball speed |
| Slow Ball | Decreases ball speed |
| Punch | Ball punches through destroyed blocks without bouncing |

Active paddle effects tint the paddle color. Item drop rarity varies — Extra Life is the rarest.

## Controls

| Key | Action |
|-----|--------|
| Left / Right arrow | Move paddle |
| Space | Launch ball from paddle |
| P / Pause | Pause / unpause |
| PrtScr | Take a screenshot |
| Escape | Quit |

## Levels

Levels are defined as JSON files in `levels/` using a character-based format. Each character maps to a block type defined in `assets/blocks.json`:

| Char | Block Type |
|------|-----------|
| `.` | Empty |
| `1` | Normal (1 HP) |
| `2` | Tough (2 HP) |
| `3` | Strong (3 HP) |
| `T` | Treasure (1 HP, always drops item) |

## Building

Requires the [Odin compiler](https://odin-lang.org/docs/install/).

```sh
# Run directly
odin run .

# Build binary
odin build . -out:main

# Optimized build
odin build . -o:speed -out:main
```

## Dependencies

All dependencies are part of the Odin standard library and vendor collection — no external packages needed.

| Library | Purpose |
|---------|---------|
| `vendor:sdl3` | Window, input, and OpenGL context |
| `vendor:OpenGL` | Rendering |
| `vendor:stb/image` | PNG screenshot saving |
| `vendor:stb/easy_font` | Bitmap text rendering |
| `core:math/linalg/glsl` | Vector math |
