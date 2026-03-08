package main

// ---------------------------------------------------------------------------
// Gameplay tweakables — centralised for easy tuning.
// ---------------------------------------------------------------------------

// Ball
BALL_RADIUS    :: 18.0
BALL_SPEED     :: vec2{450.0, 324.0}
BALL_FAST_MULT :: f32(1.5)  // speed multiplier when FastBall effect active
BALL_SLOW_MULT :: f32(0.6)  // speed multiplier when SlowBall effect active
BALL_GHOST_TIME :: f32(1.5) // seconds newly-split balls are ghosted
BALL_SPLIT_ANGLE :: f32(10.0) // degrees offset for ball split

// Paddle
PADDLE_SIZE       :: vec2{144.0, 18.0}
PADDLE_SPEED      :: 600.0
PADDLE_Y          :: f32(GAME_HEIGHT) - 70.0
PADDLE_BOW_HEIGHT :: f32(4)
PADDLE_SLICES     :: 20
PADDLE_WIDE_MULT  :: f32(1.5)   // multiplier when WidePaddle effect active
PADDLE_NARROW_MULT :: f32(0.7)  // multiplier when NarrowPaddle effect active

// Blocks
BLOCK_COLS   :: 20
BLOCK_ROWS   :: 15
BLOCK_SIZE   :: vec2{57.0, 17.0}
BLOCK_GAP    :: vec2{5.0, 6.0}
BLOCK_AREA_Y :: 50.0
SCORE_PER_BLOCK :: 100

// Lives
STARTING_LIVES :: 3
MAX_BALLS      :: 6

// Item drops
MAX_DROPS        :: 16
ITEM_DROP_CHANCE :: f32(0.25)
ITEM_FALL_SPEED  :: f32(100)
ITEM_SIZE        :: vec2{20, 20}

// Effect durations (seconds) — timed effects
EFFECT_TIMER_EXTRA_BALL    :: f32(22.5)  // was 15
EFFECT_TIMER_WIDE_PADDLE   :: f32(15.0)  // was 10
EFFECT_TIMER_NARROW_PADDLE :: f32(12.0)  // was 8
EFFECT_TIMER_STICKY_PADDLE :: f32(18.0)  // was 12
EFFECT_TIMER_FAST_BALL     :: f32(15.0)  // was 10
EFFECT_TIMER_SLOW_BALL     :: f32(15.0)  // was 10
