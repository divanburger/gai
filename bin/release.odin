#!/bin/sh
//usr/bin/env -S /home/divan/git/odin/odin run "$0" -file -- ; exit
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"

GAME_NAME :: "shardbreak"
BUILD_DIR :: "build"
GAME_DIR :: BUILD_DIR + "/" + GAME_NAME
OUT_BIN :: GAME_DIR + "/" + GAME_NAME

ODIN :: "/home/divan/git/odin/odin"

ASSETS :: []string{
	"assets/blocks.json",
	"assets/images.json",
	"assets/fonts/Kenney_Future.ttf",
	"assets/ui/button_square.png",
	"assets/ui/button_square_depth.png",
	"assets/ui/button_square_header_blade_square_screws.png",
	"assets/ui/panel_square.png",
	"assets/patterns/pattern_07.png",
	"levels/level_1.json",
	"levels/level_2.json",
	"levels/level_3.json",
	"levels/level_4.json",
}

ARCHIVE_NAME :: GAME_NAME + ".tar.gz"
ARCHIVE_PATH :: BUILD_DIR + "/" + ARCHIVE_NAME

main :: proc() {
	ok := release()
	if !ok {
		os.exit(1)
	}
}

release :: proc() -> bool {
	// Clean build dir
	if os.exists(BUILD_DIR) {
		fmt.println("Cleaning build directory...")
		remove_all(BUILD_DIR) or_return
	}

	make_dir(GAME_DIR) or_return

	// Build binary
	fmt.println("Building binary...")
	run("build", {command = {ODIN, "build", ".", "-o:speed", "-out:" + OUT_BIN}}) or_return
	fmt.println("Build OK")

	// Copy assets
	fmt.println("Copying assets...")
	for asset in ASSETS {
		copy_file(asset, fmt.tprintf("%s/%s", GAME_DIR, asset)) or_return
	}
	fmt.println("Copied", len(ASSETS), "files")

	// Create archive
	fmt.println("Creating archive...")
	run("tar", {command = {"tar", "czf", ARCHIVE_NAME, GAME_NAME + "/"}, working_dir = BUILD_DIR}) or_return

	// Report
	info, stat_err := os.stat(ARCHIVE_PATH, context.temp_allocator)
	if stat_err != nil {
		fmt.eprintln("Failed to stat archive:", stat_err)
		return false
	}
	fmt.printf("Created %s (%.1f MB)\n", ARCHIVE_PATH, f64(info.size) / (1024 * 1024))
	return true
}

run :: proc(label: string, desc: os.Process_Desc) -> bool {
	state, _, stderr, err := os.process_exec(desc, context.allocator)
	if err != nil {
		fmt.eprintln("Failed to start", label, ":", err)
		return false
	}
	if state.exit_code != 0 {
		fmt.eprintf("%s failed (exit code %d)\n", label, state.exit_code)
		fmt.eprint(string(stderr))
		return false
	}
	return true
}

copy_file :: proc(src, dst: string) -> bool {
	make_dir(filepath.dir(dst, context.temp_allocator))
	data, read_err := os.read_entire_file(src, context.temp_allocator)
	if read_err != nil {
		fmt.eprintln("Failed to read:", src, read_err)
		return false
	}
	write_err := os.write_entire_file(dst, data)
	if write_err != nil {
		fmt.eprintln("Failed to write:", dst, write_err)
		return false
	}
	return true
}

remove_all :: proc(path: string) -> bool {
	err := os.remove_all(path)
	if err != nil {
		fmt.eprintln("Failed to remove:", path, err)
		return false
	}
	return true
}

make_dir :: proc(path: string) -> bool {
	err := os.make_directory_all(path)
	if err != nil && err != .Exist {
		fmt.eprintln("Failed to create directory:", path, err)
		return false
	}
	return true
}
