package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import GL "vendor:OpenGL"

AssetType :: enum { Image, NinePatch, SpriteSheet }

// NinePatch metadata: if border > 0, symmetric; otherwise splits_x/splits_y for asymmetric.
NinePatchInfo :: struct {
	border:   f32,
	splits_x: [2]f32,
	splits_y: [2]f32,
}

SpriteSheetInfo :: struct {
	frame_width:  int,
	frame_height: int,
	frame_names:  []string,
}

Asset :: struct {
	texture:      Texture,
	type:         AssetType,
	nine_patch:   NinePatchInfo,
	sprite_sheet: SpriteSheetInfo,
}

AssetSystem :: struct {
	assets: map[string]Asset,
}

// JSON file shapes for parsing
AssetEntryFile :: struct {
	path:         string,
	name:         string,
	type:         string,
	border:       f32,
	splits_x:     Maybe([2]f32),
	splits_y:     Maybe([2]f32),
	frame_width:  int,
	frame_height: int,
	frame_names:  [dynamic]string,
}

asset_system_init :: proc(as: ^AssetSystem) -> bool {
	as.assets = make(map[string]Asset)

	data, err := os.read_entire_file("assets/images.json", context.allocator)
	if err != nil {
		fmt.eprintln("asset_system_init: could not read assets/images.json")
		return false
	}
	defer delete(data)

	entries: [dynamic]AssetEntryFile
	if json.unmarshal(data, &entries) != nil {
		fmt.eprintln("asset_system_init: could not parse assets/images.json")
		return false
	}
	defer {
		for &e in entries {
			delete(e.frame_names)
		}
		delete(entries)
	}

	for &e in entries {
		tex, tex_ok := texture_load(e.path)
		if !tex_ok {
			fmt.eprintln("asset_system_init: failed to load texture:", e.path)
			continue
		}

		asset: Asset
		asset.texture = tex

		switch e.type {
		case "nine_patch":
			asset.type = .NinePatch
			if e.border > 0 {
				asset.nine_patch.border = e.border
			}
			if sx, ok := e.splits_x.?; ok {
				asset.nine_patch.splits_x = sx
			}
			if sy, ok := e.splits_y.?; ok {
				asset.nine_patch.splits_y = sy
			}
		case "sprite_sheet":
			asset.type = .SpriteSheet
			asset.sprite_sheet.frame_width  = e.frame_width
			asset.sprite_sheet.frame_height = e.frame_height
			asset.sprite_sheet.frame_names  = e.frame_names[:]
		case:
			asset.type = .Image
		}

		as.assets[e.name] = asset
	}
	return true
}

asset_system_destroy :: proc(as: ^AssetSystem) {
	for _, &a in as.assets {
		texture_destroy(&a.texture)
	}
	delete(as.assets)
}

asset_get :: proc(as: ^AssetSystem, name: string) -> ^Asset {
	if name in as.assets {
		return &as.assets[name]
	}
	return nil
}

asset_get_texture :: proc(as: ^AssetSystem, name: string) -> Texture {
	a := asset_get(as, name)
	if a == nil { return {} }
	return a.texture
}

// asset_setup_bg_pattern configures the bg_pattern texture for tiling (GL_REPEAT).
// Called after asset_system_init, since texture_load defaults to GL_CLAMP_TO_EDGE.
asset_setup_bg_pattern :: proc(as: ^AssetSystem) {
	a := asset_get(as, "bg_pattern")
	if a == nil { return }
	GL.BindTexture(GL.TEXTURE_2D, a.texture.id)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_S, GL.REPEAT)
	GL.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_T, GL.REPEAT)
}
