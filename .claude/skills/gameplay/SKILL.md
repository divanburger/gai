---
name: gameplay
description: Gameplay rules and mechanics for Shardbreak. Use when working on game logic, ball behavior, paddle mechanics, lives, scoring, items, or level progression. Triggers on "simulate", "life", "lives", "ball", "paddle", "block", "item", "effect", "sticky", "level_complete", "game_over", "bounce".
user-invocable: false
---

# Shardbreak Gameplay Rules

## Core Loop

The player controls a paddle at the bottom of the screen to bounce balls upward and destroy blocks. When all blocks in a level are destroyed, the level is complete. If the player runs out of lives, it's game over.

## Lives

- The player starts with 3 lives.
- A life is lost only when all balls are gone — no balls remain on screen or locked to the paddle.
- If locked balls remain (stuck to the paddle), no life is lost.
- After losing a life, a new ball spawns locked to the paddle and the player must press Space to launch it.

## Ball

- The ball moves at a constant speed. Its velocity is renormalized every simulation step.
- The ball cannot travel near-horizontally — a minimum vertical speed is enforced.
- When launched from the paddle, the ball releases in the direction of the paddle surface normal at its lock position.
- The initial ball spawns offset from the paddle center (not dead center) to avoid launching straight up.

### Ball Locking (Sticky Paddle)

- When the StickyPaddle effect is active and a ball hits the paddle, the ball locks to the paddle at the contact point.
- Locked balls follow the paddle's movement with a fixed offset.
- The player can press Space at any time to release all locked balls.
- When the StickyPaddle effect expires, all locked balls are automatically released.
- Multiple balls can be locked simultaneously.

## Paddle

- The paddle has a curved bow-shaped top surface (parabolic arc).
- Ball bounce direction depends on where the ball hits the paddle — hits near the edges produce steeper angles, hits near the center produce more vertical bounces.
- The maximum bounce angle is 67.5 degrees from vertical.
- The paddle is clamped within the playing area boundaries.

### Paddle Collision

- A ball can only bounce off the paddle when moving downward.
- After a paddle bounce, the ball's vertical velocity is forced upward to prevent multi-bounce issues.

## Blocks

- Blocks have a lives count. Each hit reduces lives by 1.
- When a block's lives reach 0, it is destroyed.
- Each block hit scores 100 points.
- Only one block collision is processed per ball per simulation step.
- Destroyed blocks may drop an item (25% chance).

## Items

Items are small colored squares that fall downward after a block is destroyed. The player catches them by touching them with the paddle.

### Item Types

| Item | Duration | Effect |
|------|----------|--------|
| Extra Life | Instant | Gain 1 life |
| Extra Ball | Timed (15s) | Spawn a duplicate of ball 0 with mirrored horizontal velocity |
| Wide Paddle | Timed (10s) | Paddle width increased by 50% |
| Narrow Paddle | Timed (8s) | Paddle width reduced to 70% |
| Sticky Paddle | Timed (12s) | Balls stick to paddle on contact |

- Multiple effects can stack (e.g. Wide + Narrow apply simultaneously).
- Items that fall below the playing area are removed.
- Item drops are random — the item type is chosen uniformly from all types.
- Maximum 16 active item drops on screen at once.
- Maximum 8 active effects at once.

## Walls

- The ball bounces off the left, right, and top walls of the playing area.
- The bottom of the playing area is open — balls that fall below are lost.

## Level Progression

- When all blocks are destroyed, the level is complete.
- The player advances to the next level with their current score and lives preserved.
- Each level can define its own block layout and playing area width.
- If the player completes all available levels, the game returns to the main menu.

## Screens and Transitions

- **Main Menu**: Start Game, Options, Quit.
- **Playing (WaitingToStart)**: Overlay shown at the start of each life. Any key press dismissed it; Space launches the ball.
- **Playing (Active)**: Normal gameplay. Escape/P pauses.
- **Playing (Paused)**: Resume or Quit to menu.
- **Level Complete**: Press Space/Enter to advance, Escape to return to menu.
- **Game Over**: Press Enter/Escape to return to menu. Space does NOT dismiss this screen (prevents accidental skip).

## Simulation

- Physics runs on a fixed timestep (10ms per step).
- Simulation pauses during non-Active playing states (Paused, WaitingToStart) and non-Playing screens (menus, game over, level complete).
