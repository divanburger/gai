---
name: ui
description: Reference for ui.odin in Shardbreak. Use when working on UI layout, buttons, windows, labels, or the cursor-based UI system. Triggers on "ui_", "UIInput", "ui_button", "ui_window", "ui_begin", "BUTTON_", "WINDOW_".
user-invocable: false
---

# UI Reference (`ui.odin`)

Immediate-mode UI (dear ImGui style) — no retained widget tree. Each frame, call `ui_begin`, then widget functions that both draw and return interaction results. State lives in the caller, not the UI system.

## Layout Model

`ui_begin` resets `ui.cursor` to `{ui.indent, 0}` — y always starts at 0. Callers are responsible for positioning the overall UI block. `ui.indent` shifts the starting x for all widgets in a block.

## `ui_button_render` — Selected State

`selected=true` applies `BUTTON_SELECT_TINT` to the **normal `button_tex`**, not `button_sel_tex`. The depth texture exists but is currently unused.

## `ui_window_render` — Content Offset

Content must start at `rect.min.y + WINDOW_BORDER` (34px). The function does not enforce or communicate this — callers must account for it manually.

## Input

`UIInput.mouse_clicked` is a single-frame bool set by the caller — the UI system does not manage it.
