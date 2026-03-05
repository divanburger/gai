# gai

A breakout-style game built from scratch in [Odin](https://odin-lang.org/) using SDL3 and OpenGL.

## Gameplay

- Move the paddle to keep the ball in play
- Break all 100 blocks to clear the board
- Each block destroyed scores 100 points
- You have 3 lives — the ball falling off the bottom costs one

## Controls

| Key | Action |
|-----|--------|
| Left / Right arrow | Move paddle |
| P / Pause | Pause / unpause |
| PrtScr | Take a screenshot |
| Escape | Quit |

## Building

Requires the [Odin compiler](https://odin-lang.org/docs/install/).

```sh
# Run directly
odin run .

# Build binary
odin build . -out:gai

# Optimized build
odin build . -o:speed -out:gai
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
