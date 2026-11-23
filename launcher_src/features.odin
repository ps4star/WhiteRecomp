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

import "core:sync"
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

draw_features :: proc(g: ^Gui, r: ui.Rect) {
	running := sync.atomic_load(&task.running)
	active := !running
	head, rest := ui.cut_top(r, px(g, 24))
	label(g, g.font, running ? "These can be changed once the current task has finished." : "These apply the next time the game starts; no Build needed.", head, DIM)
	_, rest = ui.cut_top(rest, px(g, 8))
	row_h := px(g, 50)
	label_w, ctrl_w := px(g, 230), px(g, 270)
	nrows := 2
	oc, _ := ui.cut_top(rest, px(g, 4) + px(g, 34) + nrows * row_h + px(g, 16))
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
	if changed {
		save_settings()
		gdir := game_out_dir()
		if file_exists(pjoin({gdir, GAME_NAME + ".cfg"}, context.temp_allocator)) {_ = write_cfg(gdir)}
	}
}
