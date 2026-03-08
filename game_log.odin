package main

import "core:fmt"

game_log :: proc(state: ^LevelState, event: string) {
	fmt.printfln("[step=%d t=%.3f] %s", state.sim_steps, state.sim_time, event)
}
