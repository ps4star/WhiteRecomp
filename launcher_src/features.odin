// The Features & Mods tab: options that change what the game plays rather than how it is built. Each one goes into
// the built game's WhiteRecomp.cfg (build_game.odin cfg_game_lines), so a change applies the next time the game starts,
// no Build needed (a built game's .cfg is rewritten at once, as on the Options tab).
//   Language
//     Voice       English, or Japanese: the game's own -VoiceJPMode argument (XRC_GAME_ARGS), as the retail launcher
//                 passes it (its setup.xml voice_mode). Both voice sets come with the game (sys/white_*u: English,
//                 white_*c; the cutscenes zNNN_us.win32.wmp English, zNNN.win32.wmp Japanese: Convert Movies does both).
//     Subtitles & UI  the game's text language (SUBTITLE_IDS: every one its files hold -- tested: the title menu translated;
//                 the NA/EU data lacks "tchinese" and "koreana": those two only with the Asian edition), the string the runtime gives it (XRC_LANGUAGE;
//                 src/runtime/hle_system.c steam_language -- else Steam's language for the game)
package launcher

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "shared:iv_system/platform"
import "shared:iv_system/ren"
import ui "shared:iv_ui"

LANGUAGES :: [2]string{"English", "Japanese"}
// the text languages: names shown, and Steam's names the game takes (hle_system.c steam_language)
// (from SUBTITLE_ASIA on: only the Asian ("JP") edition -- its region keeps the game's codes 8 "kr" and 10 "ch", and
// only its data has their text and fonts; the runtime presets the game's language global for them, hle_system.c)
SUBTITLE_NAMES :: [8]string{"English", "Japanese", "French", "German", "Italian", "Spanish", "Korean", "Traditional Chinese"}
SUBTITLE_IDS :: [8]string{"english", "japanese", "french", "german", "italian", "spanish", "koreana", "tchinese"}
SUBTITLE_ASIA :: 6
subtitle_id :: proc(k: int) -> string {ids := SUBTITLE_IDS; return ids[k] if k >= 0 && k < len(ids) else "english"}
// the choices this game offers (Korean and Traditional Chinese with the Asian edition only)
subtitle_count :: proc() -> int {return get_game().edition == "JP" ? len(SUBTITLE_IDS) : SUBTITLE_ASIA}
// the language the game is given (XRC_LANGUAGE): an Asian-only one with another edition: English (its text is not there)
subtitle_for_game :: proc(k: int) -> string {return subtitle_id(k) if k < subtitle_count() else "english"}

draw_features :: proc(g: ^Gui, w: ^platform.Window, r: ui.Rect) {
	running := sync.atomic_load(&task.running)
	active := !running
	head, rest := ui.cut_top(r, px(g, 24))
	label(g, g.font, running ? "These can be changed once the current task has finished." : "These apply the next time the game starts; no Build needed.", head, DIM)
	_, rest = ui.cut_top(rest, px(g, 8))
	row_h := px(g, 50)
	label_w, ctrl_w := px(g, 230), px(g, 270)
	nrows := 2 + len(settings.save_dirs) + 1 + 3 // (Language: 2; Save Folders: one a folder, and Add Folder…; HD Textures: 3)
	oc, _ := ui.cut_top(rest, px(g, 4) + 3 * px(g, 34) + 2 * px(g, 18) + nrows * row_h + px(g, 16))
	card(g, oc)
	oi := ui.inset_xy(oc, px(g, 20), px(g, 8))
	row := 0
	first := true
	changed := false
	section :: proc(g: ^Gui, oi: ui.Rect, row: ^int, first: ^bool, name: string) {
		top := row^ > 0 ? px(g, 18) : px(g, 4)
		y := oi.y + row^ + top
		label(g, g.bold, name, {oi.x, y, oi.w, px(g, 26)}, ACCENT)
		ren.draw_rect(g.dl, {oi.x, y + px(g, 30), oi.w, 2}, CARD_BORDER)
		row^ += top + px(g, 34)
		first^ = true
	}
	next_row :: proc(g: ^Gui, oi: ui.Rect, row: ^int, first: ^bool, row_h, label_w, ctrl_w: int, name: string) -> (ctrl, note: ui.Rect) {
		y := oi.y + row^
		if !first^ {ren.draw_rect(g.dl, {oi.x, y, oi.w, 1}, CARD_BORDER)}
		first^ = false
		label(g, g.font, name, {oi.x, y, label_w, row_h}, TEXT)
		ctrl = {oi.x + label_w, y + (row_h - px(g, 32)) / 2, ctrl_w, px(g, 32)}
		note = {ctrl.x + ctrl_w + px(g, 16), y, oi.w - label_w - ctrl_w - px(g, 16), row_h}
		row^ += row_h
		return
	}
	names := LANGUAGES
	section(g, oi, &row, &first, "Language")
	{
		ctrl, note := next_row(g, oi, &row, &first, row_h, label_w, ctrl_w, "Voice:")
		if n, ch := dropdown(g, "voice", ctrl, names[:], settings.voice_jp ? 1 : 0, active = active); ch {settings.voice_jp = n == 1; changed = true}
		note_text(g, "The spoken language, cutscenes included", note, DIM)
	}
	{
		ctrl, note := next_row(g, oi, &row, &first, row_h, label_w, ctrl_w, "Subtitles & UI:")
		subs := SUBTITLE_NAMES
		sel := settings.subs if settings.subs < subtitle_count() else 0 // (Korean / Chinese chosen with the Asian edition, now another: English)
		if n, ch := dropdown(g, "subtitles", ctrl, subs[:subtitle_count()], sel, active = active); ch {settings.subs = n; changed = true}
		note_text(g, "The language of subtitles, menus and all other text", note, DIM)
	}
	section(g, oi, &row, &first, "Save Folders")
	{ // (each: its own .dat files, not its subfolders' -- taken in when newer than the game's, as Steam's cloud copies are)
		remove := -1
		for d, k in settings.save_dirs {
			y := oi.y + row
			if !first {ren.draw_rect(g.dl, {oi.x, y, oi.w, 1}, CARD_BORDER)}
			first = false
			n := count_dat(d)
			bw := px(g, 100)
			label(g, g.font, d, {oi.x, y, oi.w - bw - px(g, 200), row_h}, TEXT)
			note_text(g, !dir_exists(d) ? "Not found" : n == 1 ? "1 .dat file" : fmt.tprintf("%d .dat files", n), {oi.x + oi.w - bw - px(g, 190), y, px(g, 180), row_h}, !dir_exists(d) ? BAD : DIM)
			if button(g, {oi.x + oi.w - bw, y + (row_h - px(g, 32)) / 2, bw, px(g, 32)}, "Remove", active) {remove = k}
			row += row_h
		}
		if remove >= 0 {delete(settings.save_dirs[remove]); ordered_remove(&settings.save_dirs, remove); changed = true}
		ctrl, note := next_row(g, oi, &row, &first, row_h, label_w, ctrl_w, len(settings.save_dirs) == 0 ? "No folders added" : "")
		if button(g, {ctrl.x, ctrl.y, px(g, 160), ctrl.h}, "Add Folder…", active) {browse_for_saves(w)}
		note_text(g, "Folders with save files (.dat) for the game to take in, besides Steam's; the newest copy of each save wins", note, DIM)
	}
	section(g, oi, &row, &first, "HD Textures")
	{ // (the FF XIII HD Project: its ZIP imported into white_data_hd/ beside the game's white_data -- hd.odin)
		ready := hd_ready()
		importing := running && task.name == "HD Textures"
		ctrl, note := next_row(g, oi, &row, &first, row_h, label_w, ctrl_w, "FF XIII HD Project:")
		gw := px(g, 80)
		if button(g, {ctrl.x, ctrl.y, ctrl.w - gw - px(g, 8), ctrl.h}, ready ? "Import ZIP Again…" : "Import ZIP…", active) {browse_for_hd_zip(w)}
		if button(g, {ctrl.x + ctrl.w - gw, ctrl.y, gw, ctrl.h}, "Get") {hd_open_page()}
		msg := "Get downloads the mod's ZIP (Nexus Mods); Import ZIP… puts its textures beside the game's (about 25 GB free needed while it runs)"
		if importing {
			sync.mutex_lock(&task.mutex)
			msg = fmt.tprintf("Importing: %s", task.status)
			sync.mutex_unlock(&task.mutex)
		} else if ready {
			msg = fmt.tprintf("Imported from %s (%s voices); the game's own files are unchanged", hd_info("zip"), hd_info("region") == "c" ? "Japanese" : "English")
		}
		note_text(g, msg, note, importing ? ACCENT : DIM)

		ctrl, note = next_row(g, oi, &row, &first, row_h, label_w, ctrl_w, "HD Textures:")
		if on, ch := toggle(g, ctrl, ready && (settings.hd_on || hd_discarded()), active && ready && !hd_discarded()); ch && ready && !hd_discarded() {settings.hd_on = on; changed = true}
		hint := "Import the mod's ZIP first"
		if ready {
			hint = settings.hd_on ? "The game uses the HD Project's textures" : "The game's own textures"
			if hd_discarded() {hint = "The game's original archives were discarded: the HD textures are always used"}
			if settings.hd_on && hd_info("region") != (settings.voice_jp ? "c" : "u") {hint = fmt.tprintf("Imported for %s voices: with these voices the game's own textures are used (Import again)", hd_info("region") == "c" ? "Japanese" : "English")}
		}
		note_text(g, hint, note, DIM)

		ctrl, note = next_row(g, oi, &row, &first, row_h, label_w, ctrl_w, "Old Assets:")
		can_discard := active && ready && !hd_discarded()
		if button(g, ctrl, "Discard Old Assets", can_discard) {confirm_hd_discard = true}
		dnote := "After an import: deletes the mod's ZIP and the game's archives the HD copies replace"
		if hd_discarded() {dnote = "Discarded (Steam's Verify integrity of game files restores them)"} else if ready {
			_, total := hd_old_assets()
			dnote = fmt.tprintf("Frees about %.1f GB (the mod's ZIP and the game's replaced archives)", f64(total) / 1e9)
		}
		note_text(g, dnote, note, DIM)
	}
	if changed {
		save_settings()
		gdir := game_out_dir()
		if file_exists(pjoin({gdir, GAME_NAME + ".cfg"}, context.temp_allocator)) {_ = write_cfg(gdir)}
	}
}

// Save Folders: one more (Add Folder…), each once
add_save_dir :: proc(p: string) {
	for d in settings.save_dirs {if d == p {return}}
	append(&settings.save_dirs, strings.clone(p))
	save_settings()
	gdir := game_out_dir()
	if file_exists(pjoin({gdir, GAME_NAME + ".cfg"}, context.temp_allocator)) {_ = write_cfg(gdir)}
}
// the .dat files in a folder (its own, not its subfolders': what the game looks at)
count_dat :: proc(dir: string) -> int {
	n := 0
	if list, err := os.read_all_directory_by_path(dir, context.temp_allocator); err == nil {
		for e in list {if e.type != .Directory && strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), ".dat") {n += 1}}
	}
	return n
}
