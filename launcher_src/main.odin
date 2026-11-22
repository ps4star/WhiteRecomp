// The launcher: builds this project's FINAL FANTASY XIII port on the player's computer, from the sources it carries
// (bundle.odin) and the player's own game (game.odin). Its window has four tabs:
//   Home     where the game is, what the computer still needs (deps.odin: each with an Install button; an install
//            that needs administrator asks for it then, for that program alone), what is running (task.odin: progress,
//            a log, Cancel), and in the bottom right corner the buttons:
//              Build              the game, with the computer's C compiler and the options (build_game.odin); each
//                                 one compiles only what changed since the last (Clear Cache, left of it, clears the data
//                                 folder: wipe_data_dir -- all but the saves, settings,
//                                 Android key and the player's ffmpeg/)
//              Convert Movies     the Bink movies to MP4, once (movies.odin)
//              Discard Movies     frees the space of the Bink movies that have their MP4 (movies.odin)
//              Cancel             (left of them while a task runs)
//   Options  how the game is built (options.odin): compiler, optimization, audio, tools, FPS, graphics, cutscenes
//   Cross-Compile  the game built for another kind of computer (cross.odin: Linux ARM64), with Clang and lld
//   Features & Mods  what the game plays: Language (voice, subtitles) -- features.odin
// Without any C compiler, a dialog says where to get one. The look and the controls: widgets.odin.
//
// Build: launcher/build.sh (packs the sources with build/bundle.exe, then odin build). Uses shared/ (the iv_* libraries).
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import input "shared:iv_input"
import iv "shared:iv_system"
import "shared:iv_system/platform"
import "shared:iv_system/ren"
import ren_assets "shared:iv_system/ren/assets"
import ui "shared:iv_ui"

Signal :: enum {
	None,
}

// ---------------------------------------------------------------------------------------------- state
Game_State :: struct {
	checked:   bool,
	ok:        bool,
	why:       string,
	to_convert, discardable, kept: int,
	old_deleted, old_lost: int, // old_movies_cleanup: MP4s of an older converter deleted at start; movies cut down by an older Discard
	free_bytes: i64,
	has_mp4, has_bink: bool, // cutscene files there: some converted MP4s; some full .wmp files (not a stub of the install, not discarded)
	edition: string, // the exe's: "EN" (North America / Europe) or "JP" (the Asian edition; game.odin OTHER_EDITIONS)
}
game_mutex: sync.Mutex
game_state: Game_State

// Finds the game if the settings have none, checks its exe and counts its movies; then what is installed.
check_all_task :: proc(t: ^Task) {
	if !is_game_dir(settings.game_dir) {
		set_status(t, -1, "Looking for FINAL FANTASY XIII")
		if d := find_game(); d != "" {
			settings.game_dir = d
			save_settings()
		}
	}
	refresh_game(t)
	check_deps_task(t)
}

refresh_game :: proc(t: ^Task) {
	g := Game_State{checked = true}
	if !is_game_dir(settings.game_dir) {
		g.why = settings.game_dir == "" ? "not found: choose its folder" : "that folder has no white_data/prog/win/bin/ffxiiiimg.exe"
	} else {
		set_status(t, -1, "Checking the game")
		ok, why, edition := check_game_exe(game_exe(settings.game_dir))
		g.edition = edition
		g.ok = ok
		g.why = strings.clone(why)
		if ok {
			// MP4s an older converter made (no .v10): deleted, and the player asked to convert again (movies.odin)
			if deleted, lost := old_movies_cleanup(t, settings.game_dir); deleted > 0 {
				g.old_deleted, g.old_lost = deleted, lost
				sync.atomic_store(&reconvert_dialog, true)
			}
			for m in list_movies(settings.game_dir) {
				if !m.stub && !m.discarded {g.to_convert += m.missing} // (cutscenes: a movie file can hold several)
				if !m.stub && !m.discarded {g.has_bink = true}
				if m.missing < len(m.streams) {g.has_mp4 = true}
			}
			// (Bink2 plays them through the game's own bink2w32.dll, beside its exe)
			if !file_exists(pjoin({filepath.dir(game_exe(settings.game_dir)), "bink2w32.dll"}, context.temp_allocator)) {g.has_bink = false}
			g.discardable, g.free_bytes, g.kept = discard_plan(settings.game_dir)
		}
		logf(t, "Game: %s (%s)", settings.game_dir, ok ? "ready" : why)
	}
	sync.mutex_lock(&game_mutex)
	game_state = g
	sync.mutex_unlock(&game_mutex)
	// (a built game's .cfg follows the cutscene files there now: Discard Movies takes Bink2 away)
	if g.ok {
		gdir := game_out_dir()
		if file_exists(pjoin({gdir, GAME_NAME + ".cfg"}, context.temp_allocator)) {_ = write_cfg(gdir)}
	}
}

get_game :: proc() -> Game_State {
	sync.mutex_lock(&game_mutex)
	defer sync.mutex_unlock(&game_mutex)
	return game_state
}

wake_window :: proc() {} // (the window redraws every frame)

// ---------------------------------------------------------------------------------------------- main
Tab :: enum {
	Home,
	Options,
	Cross,
	Features,
}
tab: Tab
confirm_discard: bool
reconvert_dialog: bool // old cutscene MP4s were deleted: asks for a new conversion
no_compiler_dialog: int // 0 not decided yet, 1 showing, 2 closed
log_scroll: int // lines up from the end
frame_wheel: int // this frame's wheel steps
game_running: bool // the game started by Run is running (game_windows.odin / game_posix.odin: start_game)

// the built game beside the launcher (build_game.odin), "" if there is none yet
built_game :: proc() -> string {
	exe := pjoin({game_out_dir(), GAME_NAME + EXE_SUFFIX}, context.temp_allocator)
	if appimage_on() {exe = pjoin({game_out_dir(), appimage_file(appimage_arch())}, context.temp_allocator)} // (As AppImage)
	return file_exists(exe) ? exe : ""
}

main :: proc() {
	quiet_child_errors()
	init_paths()
	load_settings()
	if !bundle_open() {
		fmt.eprintln("WhiteRecomp: its bundled sources are missing or damaged")
		os.exit(1)
	}

	// --check / --build: without a window, the log to stdout (for scripts and for testing)
	for a in os.args[1:] {
		if a == "--build" {
			task_start("Checking", check_all_task)
			thread_join_task()
			task_start("Build", proc(t: ^Task) {build_task(t)})
			last := ""
			for sync.atomic_load(&task.running) {
				sync.mutex_lock(&task.mutex)
				if task.status != last {last = strings.clone(task.status); fmt.println(last)}
				sync.mutex_unlock(&task.mutex)
				time.sleep(2 * time.Second)
			}
			for l in task.log {fmt.println(l)}
			os.exit(task.failed ? 1 : 0)
		}
		if a == "--cross-build" { 	// (--cross-build [target]: the Cross-Compile tab's Build)
			for b, i in os.args {if b == "--cross-build" && i + 1 < len(os.args) {settings.cross_target = os.args[i + 1]}}
			task_start("Checking", check_all_task)
			thread_join_task()
			task_start("Cross-Compile", proc(t: ^Task) {cross_build_task(t)})
			last := ""
			for sync.atomic_load(&task.running) {
				sync.mutex_lock(&task.mutex)
				if task.status != last {last = strings.clone(task.status); fmt.println(last)}
				sync.mutex_unlock(&task.mutex)
				time.sleep(2 * time.Second)
			}
			for l in task.log {fmt.println(l)}
			os.exit(task.failed ? 1 : 0)
		}
		if a == "--check" {
			task_start("Checking", check_all_task)
			thread_join_task()
			for l in task.log {fmt.println(l)}
			gs := get_game()
			fmt.printfln("game ok %v, %d cutscenes to convert, %d discardable (%.1f GB), %d kept", gs.ok, gs.to_convert, gs.discardable, f64(gs.free_bytes) / 1e9, gs.kept)
			for c in compilers_get() {fmt.printfln("compiler: %s (%s)%s", c.label, c.path, c.path == settings.compiler ? " -- chosen" : "")}
			fmt.printfln("options: %v", runtime_option_flags())
			os.exit(0)
		}
	}

	win_desc := platform.Window_Desc{title = "WhiteRecomp", width = 1080, height = 760, min_width = 940, min_height = 640, background = [3]u8{WIN_BG.r, WIN_BG.g, WIN_BG.b}}
	app, ok := iv.open(win_desc)
	when ODIN_OS != .Windows {
		// (the reason in a dialog, a launcher started from a file manager has no terminal; SDL2 offered for installing
		// when it is missing, and the window tried again: nowindow_posix.odin)
		if !ok && no_window_help() {
			app, ok = iv.open(win_desc)
			if !ok {no_window_help(offer_install = false)}
		}
		if !ok {
			fmt.eprintfln("WhiteRecomp: could not open a window: %s", platform.window_error)
			os.exit(1)
		}
	} else {
		if !ok {
			fmt.eprintln("WhiteRecomp: could not open a window")
			os.exit(1)
		}
	}
	defer iv.close(app)

	// Segoe UI (Windows' own) where it is, else the bundled Noto Sans / Liberation Sans
	lib: ren_assets.Library
	ren_assets.library_init(&lib)
	ren_assets.add_builtin_font(&lib, "noto_sans_regular")
	ren_assets.add_builtin_font(&lib, "liberation_sans_bold")
	regular, semibold := "noto_sans_regular", "liberation_sans_bold"
	when ODIN_OS == .Windows {
		fonts := pjoin({os.get_env("WINDIR", context.temp_allocator), "Fonts"}, context.temp_allocator)
		if ren_assets.font_add_file(&lib, "segoe", pjoin({fonts, "segoeui.ttf"}, context.temp_allocator)) {regular = "segoe"}
		if ren_assets.font_add_file(&lib, "segoe_sb", pjoin({fonts, "seguisb.ttf"}, context.temp_allocator)) {semibold = "segoe_sb"}
	}
	g := Gui{s = max(app.window.dpi_scale, 1), win = app.window}
	g.font = ren_assets.font_make(&lib, &app.renderer, regular, 14 * g.s)
	g.small = ren_assets.font_make(&lib, &app.renderer, regular, 12 * g.s)
	g.bold = ren_assets.font_make(&lib, &app.renderer, semibold, 14 * g.s)
	g.big = ren_assets.font_make(&lib, &app.renderer, semibold, 20 * g.s)

	task_start("Checking", check_all_task)

	ctx: input.Context(Signal)
	// The frame rate: 60 a second for a second after anything happened (input, a window event, a task running, a dialog
	// open), else 20. The renderer's present does not hold the loop back everywhere: Vulkan's MAILBOX mode (taken
	// when offered: Mesa on Linux does) returns at once, and the launcher drew as fast as it could (70% of the CPU).
	last_active := time.tick_now()
	for !app.window.close_requested {
		frame_start := time.tick_now()
		win_events := iv.pump(app, &ctx)
		if len(app.window.input) > 0 || win_events != {} || sync.atomic_load(&task.running) || confirm_discard || sync.atomic_load(&reconvert_dialog) || browser_is_open() {
			last_active = frame_start
		}
		mx, my := input.mouse_position(&ctx)
		g.mouse = {int(mx), int(my)}
		g.clicked = input.mouse_pressed(&ctx, .Left)
		g.down = input.mouse_down(&ctx, .Left)
		if no_compiler_dialog == 0 && sync.atomic_load(&deps_checked) && !sync.atomic_load(&task.running) {
			no_compiler_dialog = len(compilers_get()) == 0 ? 1 : 2
		}
		pick_poll()
		g.modal = confirm_discard || sync.atomic_load(&reconvert_dialog) || no_compiler_dialog == 1 || browser_is_open()
		_, wy := input.wheel(&ctx)
		frame_wheel = int(wy * 3)
		if !g.modal {log_scroll = max(0, log_scroll + frame_wheel)}

		g.dl = ren.begin_frame(&app.renderer, WIN_BG)
		g.screen = {0, 0, app.window.size.x, app.window.size.y}
		gui_begin(&g)
		draw_window(&g, app.window)
		gui_end(&g)
		ren.end_frame(&app.renderer)
		free_all(context.temp_allocator)
		period := time.tick_since(last_active) < time.Second ? 16667 * time.Microsecond : 50 * time.Millisecond
		if spent := time.tick_since(frame_start); spent < period {time.sleep(period - spent)}
	}
	task_cancel()
	if task.th != nil {thread_join_task()}
}

thread_join_task :: proc() {
	for sync.atomic_load(&task.running) {time.sleep(10 * time.Millisecond)}
}

draw_window :: proc(g: ^Gui, w: ^platform.Window) {
	body := ui.inset_xy(g.screen, px(g, 24), px(g, 12))
	bar, rest := ui.cut_top(body, px(g, 40))
	tab = Tab(tabs(g, bar, {"Home", "Options", "Cross-Compile", "Features & Mods"}, int(tab)))
	_, rest = ui.cut_top(rest, px(g, 16))
	switch tab {
	case .Home:
		draw_home(g, w, rest)
	case .Options:
		draw_options(g, rest)
	case .Cross:
		draw_cross(g, rest)
	case .Features:
		draw_features(g, rest)
	}
	if confirm_discard {draw_confirm(g, get_game())}
	if sync.atomic_load(&reconvert_dialog) && !confirm_discard {draw_reconvert(g, get_game())}
	if no_compiler_dialog == 1 {draw_no_compiler(g, w)}
	if browser_is_open() {draw_browser(g, frame_wheel)}
}

// ---------------------------------------------------------------------------------------------- Home
draw_home :: proc(g: ^Gui, w: ^platform.Window, r: ui.Rect) {
	running := sync.atomic_load(&task.running)
	gs := get_game()

	// the buttons: the bottom right corner (Build the larger; Run, green, at its right once the game is built)
	bottom, top := ui.cut_bottom(r, px(g, 44))
	_, top = ui.cut_bottom(top, px(g, 16))
	ai_row: ui.Rect // (Linux launchers: As AppImage, above Build)
	when ODIN_OS == .Linux {
		ai_row, top = ui.cut_bottom(top, px(g, 32))
		_, top = ui.cut_bottom(top, px(g, 10))
	}
	exe := built_game()
	playing := sync.atomic_load(&game_running)
	if exe != "" {
		run_r: ui.Rect
		run_r, bottom = ui.cut_right(bottom, px(g, 120), px(g, 8))
		run_r = ui.Rect{run_r.x, run_r.y, run_r.w, px(g, 44)}
		if button(g, run_r, playing ? "Running…" : "Run", !running && !playing, f = g.bold, green = true) {
			if !start_game(exe, game_out_dir()) {
				task_start("Run", proc(t: ^Task) {logf(t, "Could not start %s.", built_game()); t.failed = true})
			}
		}
		tooltip_zone(g, "run", run_r, playing ? "The game is running." : running ? "Wait for the current task to finish." : fmt.tprintf("Starts %s.", exe))
	}
	build_r, rest := ui.cut_right(bottom, px(g, 150), px(g, 8))
	build_r = ui.Rect{build_r.x, build_r.y, build_r.w, px(g, 44)}
	clear_r, restc := ui.cut_right(rest, px(g, 130), px(g, 8))
	conv_r, rest2 := ui.cut_right(restc, px(g, 140), px(g, 8))
	disc_r, rest3 := ui.cut_right(rest2, px(g, 140), px(g, 8))
	cancel_r, _ := ui.cut_right(rest3, px(g, 150), px(g, 8))
	clear_r = ui.Rect{clear_r.x, clear_r.y + px(g, 6), clear_r.w, px(g, 32)}
	conv_r = ui.Rect{conv_r.x, conv_r.y + px(g, 6), conv_r.w, px(g, 32)}
	disc_r = ui.Rect{disc_r.x, disc_r.y + px(g, 6), disc_r.w, px(g, 32)}
	cancel_r = ui.Rect{cancel_r.x, cancel_r.y + px(g, 6), cancel_r.w, px(g, 32)}

	cc_ok := dep_get(.Compiler).path != ""
	ff := dep_get(.FFmpeg)
	can_build := !running && gs.ok && cc_ok && !playing
	conv_ok, conv_why := convert_possible() // (wine.odin: on Linux and macOS through Wine)
	can_convert := !running && gs.ok && conv_ok && gs.to_convert > 0
	can_discard := !running && gs.ok && gs.discardable > 0
	if button(g, disc_r, "Discard Movies", can_discard) {confirm_discard = true}
	if button(g, conv_r, "Convert Movies", can_convert) {
		task_start("Convert Movies", proc(t: ^Task) {convert_task(t); refresh_game(t)})
	}
	if button(g, build_r, "Build", can_build, primary = true, f = g.bold) {
		task_start("Build", proc(t: ^Task) {build_task(t)})
	}
	// Clear Cache: the data folder cleared (wipe_data_dir: all but the saves, settings, Android key and the player's
	// ffmpeg/), so the next Build unpacks and compiles everything again
	if button(g, clear_r, "Clear Cache", !running && !playing) {
		task_start("Clear Cache", proc(t: ^Task) {if !wipe_data_dir(t) {t.failed = true}})
	}
	when ODIN_OS == .Linux {
		if appimage_switch(g, "appimage", build_r, ai_row, &settings.appimage, !running && !playing) {save_settings()}
	}
	// why a button cannot be pressed (or what it would do)
	busy := running ? "Wait for the current task to finish." : ""
	tooltip_zone(g, "build", build_r, busy != "" ? busy : playing ? "Close the game first: it cannot be rebuilt while it runs." : !gs.ok ? "Needs the game: choose its folder." : !cc_ok ? "Needs a C compiler." : "Builds the game with the options of the Options tab.")
	conv_tip := busy != "" ? busy : !gs.ok ? "Needs the game." : !conv_ok ? conv_why : gs.to_convert == 0 ? "Every movie is converted." : fmt.tprintf("Converts the %d cutscenes that have no MP4 yet (it can be cancelled and continued later).", gs.to_convert)
	tooltip_zone(g, "clear", clear_r, busy != "" ? busy : playing ? "Close the game first." : "Deletes what earlier Builds left in the data folder (unpacked sources, compiled objects, tools), so the next Build starts over and compiles everything. Saves and settings stay.")
	tooltip_zone(g, "convert", conv_r, conv_tip)
	disc_tip := busy != "" ? busy : !gs.ok ? "Needs the game." : gs.discardable == 0 ? "Nothing to discard: no Bink movie has its MP4 yet." : fmt.tprintf("Frees %.1f GB: the Bink movies that have their MP4.", f64(gs.free_bytes) / 1e9)
	tooltip_zone(g, "discard", disc_r, disc_tip)
	if running {
		if button(g, cancel_r, "Cancel") {task_cancel()}
	}

	// the game
	gc, after := ui.cut_top(top, px(g, 68))
	card(g, gc)
	gi := ui.inset_xy(gc, px(g, 16), px(g, 12))
	browse, info := ui.cut_right(gi, px(g, 110), px(g, 12))
	if button(g, ui.center(browse, browse.w, px(g, 32)), "Browse…", !running) {
		browse_for_game(w) // (folder_pick.odin)
	}
	l1, l2 := ui.cut_top(info, info.h / 2)
	label(g, g.bold, "Game folder", l1, TEXT)
	// the edition, as a small tag after the heading
	if gs.ok && gs.edition != "" {
		tx := l1.x + text_w(g.bold, "Game folder") + px(g, 10)
		tw := text_w(g.small, gs.edition) + px(g, 12)
		tag := ui.Rect{tx, l1.y + (l1.h - px(g, 20)) / 2, tw, px(g, 20)}
		fill_round(g, tag, px(g, 4), ACCENT)
		label(g, g.small, gs.edition, tag, ren.WHITE, center = true)
		tooltip_zone(g, "edition", tag, gs.edition == "EN" ? "The North America / Europe edition of the game." : "The Asian edition of the game: Space confirms in menus (Enter does not), and it has Japanese voices only.")
	}
	loc := settings.game_dir != "" ? settings.game_dir : "not found"
	if gs.checked && !gs.ok {loc = fmt.tprintf("%s — %s", loc, gs.why)}
	label(g, g.font, loc, l2, gs.ok || !gs.checked ? DIM : BAD)
	_, after = ui.cut_top(after, px(g, 10))

	// what the computer needs
	// (Wine: only Linux and macOS need it)
	kinds := ODIN_OS == .Windows ? []Dep_Kind{.Compiler, .FFmpeg} : []Dep_Kind{.Compiler, .FFmpeg, .Wine}
	rows := len(kinds)
	dc, after2 := ui.cut_top(after, px(g, 40) + rows * px(g, 48))
	card(g, dc)
	di := ui.inset_xy(dc, px(g, 16), px(g, 10))
	dh, drows := ui.cut_top(di, px(g, 28))
	label(g, g.bold, "Requirements", dh, TEXT)
	if button(g, {dh.x + dh.w - px(g, 110), dh.y, px(g, 110), px(g, 28)}, "Check again", !running, f = g.small) {
		task_start("Checking", check_all_task)
	}
	for k, i in kinds {
		d := dep_get(k)
		row := ui.Rect{drows.x, drows.y + i * px(g, 48), drows.w, px(g, 48)}
		inst, text := ui.cut_right(row, px(g, 250), px(g, 12))
		have := d.path != "" && (k != .FFmpeg || d.can_encode)
		dot(g, text.x + px(g, 5), text.y + px(g, 15), !deps_checked ? FAINT : have ? GOOD : d.path != "" ? WARN : BAD)
		name := k == .Compiler && have ? fmt.tprintf("%s — %s", d.name, compiler_label(d.path)) : fmt.tprintf("%s — %s", d.name, d.purpose)
		label(g, g.font, name, {text.x + px(g, 20), text.y + px(g, 4), text.w - px(g, 20), px(g, 22)}, TEXT)
		note := !deps_checked ? "checking…" : d.note
		label(g, g.small, note, {text.x + px(g, 20), text.y + px(g, 26), text.w - px(g, 20), px(g, 18)}, DIM)
		if deps_checked && !have {
			br := ui.center(inst, inst.w, px(g, 32))
			if d.install != nil {
				how := d.needs_admin ? fmt.tprintf("%s (asks for admin)", d.install_how) : d.install_how
				if button(g, br, how, !running, f = g.small) {
					task_start(d.install_how, install_dep_task, rawptr(uintptr(k)))
				}
			} else if d.install_how != "" {
				label(g, g.small, d.install_how, br, WARN, center = true)
			}
		}
	}
	_, after2 = ui.cut_top(after2, px(g, 10))

	// what is running: name, progress, status, the log
	draw_task(g, after2, running)
}

compiler_label :: proc(path: string) -> string {
	for c in compilers_get() {if c.path == path {return c.label}}
	return path
}

draw_task :: proc(g: ^Gui, r: ui.Rect, running: bool) {
	if r.h < px(g, 60) {return}
	card(g, r)
	inner := ui.inset_xy(r, px(g, 16), px(g, 12))
	sync.mutex_lock(&task.mutex)
	defer sync.mutex_unlock(&task.mutex)
	head, rest := ui.cut_top(inner, px(g, 22))
	state := running ? "" : task.failed ? " — failed" : task.name != "" ? " — done" : ""
	name := task.name != "" ? task.name : "Activity"
	label(g, g.bold, fmt.tprintf("%s%s", name, state), head, running || task.name == "" ? TEXT : task.failed ? BAD : GOOD)
	pb, rest2 := ui.cut_top(rest, px(g, 14))
	prog := task.progress
	if !running && prog < 0 {prog = 0}
	progress_bar(g, ui.Rect{pb.x, pb.y + px(g, 5), pb.w, px(g, 3)}, prog, running)
	st, logr := ui.cut_top(rest2, px(g, 20))
	label(g, g.small, task.status, st, DIM)
	_, logr = ui.cut_top(logr, px(g, 6))

	// the log, newest at the bottom (the wheel scrolls back)
	round_box(g, logr, px(g, 4), LOG_BG, CARD_BORDER)
	li := ui.inset_xy(logr, px(g, 10), px(g, 6))
	lh := g.small.line_height
	rows := max(1, li.h / lh)
	log_scroll = min(log_scroll, max(0, len(task.log) - rows))
	last := len(task.log) - log_scroll
	first := max(0, last - rows)
	{
		ren.scope_clip(g.dl, logr)
		for i in first ..< last {
			label(g, g.small, task.log[i], {li.x, li.y + (i - first) * lh, li.w, lh}, TEXT)
		}
	}
}

// ---------------------------------------------------------------------------------------------- Options
CUTSCENE_TIP :: "Play: each cutscene plays from the files Cutscene Files chooses. With MP4, a cutscene that has no MP4 yet is skipped (Convert Movies on the Home tab makes them all).\nAuto-skip: every cutscene is skipped (for replays and speedruns). They play again if you switch back (with a new Build)."
MOVIE_FILES_TIP :: "FINAL FANTASY XIII's cutscenes are Bink 2 videos (the .wmp files in white_data/movie). Only the kinds your game folder has are offered.\n\nBink2: the game's own videos, played by its own Bink library (bink2w32.dll, translated like the game). Nothing to convert.\nMP4: the MP4s Convert Movies made from them, played by FFmpeg (Windows, Linux, macOS) or the system's decoder (Android). Discard Movies removes the .wmp files afterwards, leaving MP4 the only choice.\n\nNeither there (the .wmp files discarded or missing, and no MP4s): every cutscene is skipped. Have Steam re-install the game (or verify its files) to get them back."

// the options' scroll position (pixels from the top) and its scroll bar's drag
opt_scroll: int
opt_content_h: int
opt_after_head: bool // (no line over the row right under a heading)
opt_drag: bool
opt_grab: int

draw_options :: proc(g: ^Gui, r: ui.Rect) {
	running := sync.atomic_load(&task.running)
	active := !running
	head, rest := ui.cut_top(r, px(g, 24))
	label(g, g.font, running ? "The options can be changed once the current task has finished." : "Most apply at the next Build; Graphics and Memory the next time the game starts.", head, DIM)
	_, rest = ui.cut_top(rest, px(g, 8))
	custom := settings.graphics == GRAPHICS_CUSTOM
	// one option a row: its name, its control, its note beside them (two lines at most), the options under a heading
	// for each category. The card fills the tab; what does not fit scrolls (the wheel over it, or its scroll bar)
	row_h := px(g, 50)
	card(g, rest)
	view := ui.inset_xy(rest, px(g, 20), px(g, 8))
	content_h := opt_content_h // (last frame's: known once the rows are laid out)
	max_scroll := max(0, content_h - view.h)
	sb_w := px(g, 8)
	track := ui.Rect{view.x + view.w - sb_w + px(g, 12), view.y, sb_w, view.h}
	oi := view
	if max_scroll > 0 {oi.w -= px(g, 12)}
	if max_scroll > 0 && live(g) {
		min_th := px(g, 28)
		th := ui.thumb(track, content_h, view.h, opt_scroll, true, min_th)
		if inside(rest, g.mouse) {opt_scroll -= frame_wheel * px(g, 16)}
		if g.clicked && inside(ui.outset(track, px(g, 4)), g.mouse) {
			if inside(th, g.mouse) {opt_drag = true; opt_grab = g.mouse.y - th.y} else {opt_scroll += g.mouse.y < th.y ? -view.h : view.h}
			g.clicked = false
		}
		if opt_drag {
			if g.down {opt_scroll = ui.thumb_offset(track, content_h, view.h, g.mouse.y, opt_grab, true, min_th)} else {opt_drag = false}
		}
	}
	opt_scroll = clamp(opt_scroll, 0, max_scroll)
	if max_scroll > 0 {
		th := ui.thumb(track, content_h, view.h, opt_scroll, true, px(g, 28))
		fill_round(g, track, sb_w / 2, ren.Color{0, 0, 0, 12})
		fill_round(g, th, sb_w / 2, opt_drag || inside(ui.outset(track, px(g, 4)), g.mouse) ? ren.Color{0, 0, 0, 110} : ren.Color{0, 0, 0, 70})
	}
	// (the cells scrolled out of the view are clipped; the mouse outside the view reaches none of them)
	saved_mouse := g.mouse
	if !inside(view, g.mouse) {g.mouse = {-1 << 20, -1 << 20}}
	defer g.mouse = saved_mouse
	ren.push_clip(g.dl, {view.x - px(g, 6), view.y, oi.w + px(g, 12), view.h})
	defer ren.pop_clip(g.dl)
	oi.y -= opt_scroll
	label_w := px(g, 230)
	ctrl_w := px(g, 270)
	changed := false
	game_changed := false // (an option of the game's .cfg: rewritten at once, no Build needed)
	row := 0 // (the next row's top, from the content's)
	// a category's heading
	section :: proc(g: ^Gui, oi: ui.Rect, row: ^int, name: string) {
		top := row^ > 0 ? px(g, 18) : px(g, 4)
		y := oi.y + row^ + top
		label(g, g.bold, name, {oi.x, y, oi.w, px(g, 26)}, ACCENT)
		ren.draw_rect(g.dl, {oi.x, y + px(g, 30), oi.w, 2}, CARD_BORDER)
		row^ += top + px(g, 34)
		opt_after_head = true
	}
	next_row :: proc(g: ^Gui, oi: ui.Rect, row: ^int, row_h, label_w, ctrl_w: int, name: string, indent := 0) -> (whole, ctrl, note: ui.Rect) {
		y := oi.y + row^
		whole = {oi.x, y, oi.w, row_h}
		if !opt_after_head {ren.draw_rect(g.dl, {oi.x + indent, y, oi.w - indent, 1}, CARD_BORDER)}
		opt_after_head = false
		label(g, g.font, name, {oi.x + indent, y, label_w - indent, row_h}, indent > 0 ? DIM : TEXT)
		ctrl = {oi.x + label_w, y + (row_h - px(g, 32)) / 2, ctrl_w, px(g, 32)}
		note = {ctrl.x + ctrl_w + px(g, 16), y, oi.w - label_w - ctrl_w - px(g, 16), row_h}
		row^ += row_h
		return
	}

	// ---- Display
	section(g, oi, &row, "Display")
	// Resolution: the game's -Width= / -Height= (in its .cfg: no Build needed)
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Resolution:")
		res := RESOLUTIONS
		names := make([]string, len(res), context.temp_allocator)
		for r, i in res {
			names[i] = i == RES_DEFAULT ? fmt.tprintf("%d x %d (Default)", r.w, r.h) : i >= RES_ULTRAWIDE ? fmt.tprintf("%d x %d (%s)", r.w, r.h, r.w * 9 > r.h * 30 ? "32:9" : "21:9") : fmt.tprintf("%d x %d", r.w, r.h)
		}
		sel := clamp(settings.resolution, 0, len(res) - 1)
		if n, ch := dropdown(g, "resolution", ctrl, names, sel, active = active); ch {settings.resolution = n; changed = true; game_changed = true}
		note_text(g, sel >= RES_ULTRAWIDE ? "Ultrawide: the 3D fills the width (a little less above and below); no Build needed" : sel == RES_DEFAULT ? "What the game renders at; the window can be resized; no Build needed" : sel < RES_DEFAULT ? "Lower is faster on the GPU, less sharp; the window can be resized; no Build needed" : "Higher costs GPU time; the window can be resized; no Build needed", note, DIM)
	}
	// Window Scaling: the picture in a window of another shape than 16:9 (XRC_STRETCH in its .cfg: no Build needed)
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Window Scaling:")
		if n, ch := dropdown(g, "scaling", ctrl, {"Fit (Default)", "Stretch"}, settings.stretch ? 1 : 0, active = active); ch {settings.stretch = n == 1; changed = true; game_changed = true}
		note_text(g, settings.stretch ? "Fills the window; the picture is squeezed if it isn't 16:9" : "Keeps the 16:9 shape: black bars in a window of another shape", note, DIM)
	}
	// FPS
	{
		_, ctrl, _ := next_row(g, oi, &row, row_h, label_w, ctrl_w, "FPS:")
		fps := FPS_CHOICES
		names := []string{"30", "60"}
		sel := settings.fps == 30 ? 0 : 1
		if n, ch := dropdown(g, "fps", ctrl, names, sel, active = active); ch {settings.fps = fps[n]; changed = true}
	}
	// Graphics Driver
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Graphics Driver:")
		_, _ = dropdown(g, "gfx", ctrl, {"Vulkan"}, 0, active = active) // (the only one)
		note_text(g, "The port's Vulkan renderer", note, DIM)
	}
	// ---- Graphics
	section(g, oi, &row, "Graphics")
	// Graphics: a preset of Shadow Resolution and Anti-aliasing, or Custom -- those, indented below it. The game's
	// arguments (in its .cfg: no Build needed)
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Graphics:")
		names := GRAPHICS_NAMES
		if n, ch := dropdown(g, "graphics", ctrl, names[:], clamp(settings.graphics, 0, GRAPHICS_CUSTOM), active = active); ch {
			settings.graphics = n
			graphics_apply()
			changed = true; game_changed = true
		}
		notes := [5]string{"No shadows, no anti-aliasing: the fastest", "Low-resolution shadows, 2x FXAA", "The game's shadows, 4x FXAA", "The sharpest shadows, 8x FXAA: costly on the GPU", "Shadows and anti-aliasing as set below"}
		note_text(g, fmt.tprintf("%s; no Build needed", notes[clamp(settings.graphics, 0, GRAPHICS_CUSTOM)]), note, DIM)
	}
	IND := px(g, 24)
	if custom {
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Shadow Resolution:", IND)
		res := SHADOW_CHOICES
		names := make([]string, len(res), context.temp_allocator)
		sel := 2
		for v, i in res {
			names[i] = v == 0 ? "Off (No Shadows)" : v == 1024 ? "1024 x 1024 (Default)" : fmt.tprintf("%d x %d", v, v)
			if v == settings.shadow_res {sel = i}
		}
		if n, ch := dropdown(g, "shadow", ctrl, names, sel, active = active); ch {settings.shadow_res = res[n]; changed = true; game_changed = true}
		note_text(g, "Sharper shadows cost GPU time; Off is the fastest", note, DIM)
	}
	if custom {
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Anti-alias Method:", IND)
		names := []string{"MSAA", "FXAA (Default)"}
		if n, ch := dropdown(g, "aa_method", ctrl, names, settings.aa_fxaa ? 1 : 0, active = active); ch {settings.aa_fxaa = n == 1; changed = true; game_changed = true}
		note_text(g, settings.aa_fxaa ? "A cheap filter on the 3D image (not the HUD)" : "Multisampling: costly on integrated GPUs", note, DIM)
	}
	if custom {
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Anti-alias Quality:", IND)
		qs := AA_QUALITIES
		names := []string{"1x (Off)", "2x", "4x (Default)", "8x"}
		sel := 2
		for v, i in qs {if v == settings.aa_quality {sel = i}}
		if n, ch := dropdown(g, "aa_quality", ctrl, names, sel, active = active); ch {settings.aa_quality = qs[n]; changed = true; game_changed = true}
		note_text(g, settings.aa_fxaa ? "FXAA strength: higher smooths longer edges" : "Samples per pixel (up to what the GPU has)", note, DIM)
	}
	// Effects Resolution: the blended effects (fire, sparks, magic) drawn at half resolution (XRC_VK_HALF_FX in its .cfg:
	// no Build needed; Vulkan only)
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Effects Resolution:")
		if n, ch := dropdown(g, "fx_res", ctrl, {"Half (Default)", "Full"}, settings.fx_full ? 1 : 0, active = active); ch {settings.fx_full = n == 1; changed = true; game_changed = true}
		note_text(g, settings.fx_full ? "Effects as sharp as the rest; costly in battle on integrated GPUs" : "Battle effects cost a quarter of the GPU time, a little softer; no Build needed", note, DIM)
	}
	// ---- Audio & Controls
	section(g, oi, &row, "Audio & Controls")
	// Audio
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Audio:")
		if on, ch := toggle(g, ctrl, settings.audio, active); ch {settings.audio = on; changed = true}
		note_text(g, settings.audio ? "Music, sound and voices" : "No audio work at all (play your own music)", note, DIM)
	}
	// Gamepad Scanning
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Gamepad Scanning:")
		names := []string{"Every 2 seconds (Default)", "Once"}
		if n, ch := dropdown(g, "pad_scan", ctrl, names, settings.pad_once ? 1 : 0, active = active); ch {settings.pad_once = n == 1; changed = true}
		note_text(g, settings.pad_once ? "Only the controllers there at the start (plug one in: restart the game)" : "A controller plugged in while playing is found within 2 seconds", note, DIM)
	}
	// ---- Cutscenes
	section(g, oi, &row, "Cutscenes")
	// Cutscene Files: MP4 or Bink2, each offered only if the game has those files (main.odin movie_files); none: grayed
	// out, and every cutscene skipped (no Build needed to switch: XRC_MOVIES in the .cfg)
	mf := movie_files()
	{
		whole, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Cutscene Files:")
		gs := get_game()
		kinds := make([dynamic]Movie_Files, context.temp_allocator)
		names := make([dynamic]string, context.temp_allocator)
		if !gs.checked || !gs.ok || gs.has_mp4 {append(&kinds, Movie_Files.MP4); append(&names, "MP4")}
		if !gs.checked || !gs.ok || gs.has_bink {append(&kinds, Movie_Files.Bink); append(&names, "Bink2")}
		if mf == .None {
			dropdown(g, "movie_files", ctrl, {"None found"}, 0, active = false)
			note_text(g, "No cutscene files: re-install the game fresh from Steam for cutscenes to work", note, BAD)
		} else {
			sel := 0
			for k, i in kinds {if k == mf {sel = i}}
			if n, ch := dropdown(g, "movie_files", ctrl, names[:], sel, active = active); ch {settings.movie_bink = kinds[n] == .Bink; changed = true; game_changed = true}
			note_text(g, mf == .Bink ? "The game's own Bink 2 videos, no conversion; no Build needed" : "The MP4s Convert Movies made; no Build needed", note, DIM)
		}
		tooltip_zone(g, "movie_files", whole, MOVIE_FILES_TIP)
	}
	// Cutscenes (with its tooltip over the whole row): forced to Auto-skip with no cutscene files
	{
		whole, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Cutscenes:")
		names := []string{mf == .Bink ? "Play" : "Play if converted", "Auto-skip"}
		if n, ch := dropdown(g, "cutscenes", ctrl, names, movie_skip() ? 1 : 0, active = active && mf != .None); ch {settings.skip_movies = n == 1; changed = true}
		note_text(g, mf == .None ? "No cutscene files to play" : "Hover for how cutscenes work", note, DIM)
		tooltip_zone(g, "cutscenes", whole, CUTSCENE_TIP)
	}
	// ---- Steam (host_steam.c -- Windows: the achievements helper; Linux x86-64: the player's steamclient.so; both: Steam's
	// overlay)
	when ODIN_OS == .Windows || ODIN_OS == .Linux {
		section(g, oi, &row, "Steam")
		// Steam Integration: achievements and the overlay (XRC_NO_STEAM=1 in its .cfg when off: no Build needed)
		{
			_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Steam Integration:")
			if on, ch := toggle(g, ctrl, !settings.steam_off, active); ch {settings.steam_off = !on; changed = true; game_changed = true}
			note_text(g, settings.steam_off ? "No achievements or overlay; Steam does not show the game as running" : "Achievements and the overlay (Shift+Tab) while Steam runs; no Build needed", note, DIM)
		}
	}
	// ---- Performance
	section(g, oi, &row, "Performance")
	// Pipeline Build Threads (in its .cfg: no Build needed)
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Pipeline Build Threads:")
		n_max, best := max_pipe_threads(), best_pipe_threads()
		names := make([]string, n_max, context.temp_allocator)
		for i in 0 ..< n_max {names[i] = i + 1 == best ? fmt.tprintf("%d (Best)", i + 1) : fmt.tprintf("%d", i + 1)}
		sel := pipe_threads() - 1
		if n, ch := dropdown(g, "pipes", ctrl, names, sel, active = active); ch {settings.pipe_threads = n + 1 == best ? 0 : n + 1; changed = true; game_changed = true}
		note_text(g, "Threads preparing new graphics effects in the background; no Build needed", note, DIM)
	}
	// Memory (in its .cfg: no Build needed)
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Memory:")
		names := []string{"2GB", "4GB (Recommended)"}
		if n, ch := dropdown(g, "memory", ctrl, names, settings.memory_2gb ? 0 : 1, active = active); ch {settings.memory_2gb = n == 0; changed = true; game_changed = true}
		note_text(g, settings.memory_2gb ? "The 2 GB the original exe gets; no Build needed" : "The address space a 4 GB-patched exe gets; no Build needed", note, DIM)
	}
	// ---- Build
	section(g, oi, &row, "Build")
	// Compiler
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Compiler:")
		cs := compilers_get()
		if len(cs) == 0 {
			label(g, g.font, deps_checked ? "No C compiler found" : "Looking for compilers…", ctrl, deps_checked ? BAD : DIM)
			if deps_checked && button(g, {ctrl.x + ctrl.w + px(g, 12), ctrl.y, px(g, 150), ctrl.h}, "Where to get one", active) {no_compiler_dialog = 1}
		} else {
			names := make([]string, len(cs), context.temp_allocator)
			sel := 0
			for c, i in cs {
				names[i] = c.label
				if c.path == settings.compiler {sel = i}
			}
			if n, ch := dropdown(g, "compiler", ctrl, names, sel, active = active); ch {select_compiler(cs[n].path); changed = true}
			note_text(g, cs[sel].clang ? cs[sel].path : fmt.tprintf("%s (Clang makes a faster game; no PGO with GCC)", cs[sel].path), note, DIM)
		}
	}
	// Optimization Level
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Optimization Level:")
		levels := OPT_LEVELS
		if n, ch := dropdown(g, "opt", ctrl, levels[:], settings.opt_level, active = active); ch {settings.opt_level = n; changed = true}
		note_text(g, "Higher: a slower build, a faster game", note, DIM)
	}
	// Profile-Guided Optimization
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Profile-Guided Optimization:")
		if on, ch := toggle(g, ctrl, settings.pgo, active); ch {settings.pgo = on; changed = true}
		why := pgo_blocked()
		pgo_note := !settings.pgo ? "Off: the game built without the profile" : why == "" ? "On: optimized for how the game runs (a faster game)" : why
		note_text(g, pgo_note, note, settings.pgo && why != "" ? WARN : DIM)
	}
	// Link-Time Optimization
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Link-Time Optimization:")
		if on, ch := toggle(g, ctrl, settings.lto, active); ch {settings.lto = on; changed = true}
		lto_note := !settings.lto ? "Off: a faster Build" : lto_on() ? "On: optimizes across files (a much slower Build)" : "Needs LLVM's linker (lld) beside Clang: not found"
		note_text(g, lto_note, note, settings.lto && !lto_on() ? WARN : DIM)
	}
	// Experimental Optimizations
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Experimental Optimizations:")
		if on, ch := toggle(g, ctrl, settings.experimental, active); ch {settings.experimental = on; changed = true}
		note_text(g, settings.experimental ? "On: less-tested speed-ups that may break things" : "Off: only the tested ones", note, settings.experimental ? WARN : DIM)
	}
	// Debug & Profile Tools
	{
		_, ctrl, note := next_row(g, oi, &row, row_h, label_w, ctrl_w, "Debug & Profile Tools:")
		if on, ch := toggle(g, ctrl, settings.tools, active); ch {settings.tools = on; changed = true}
		note_text(g, settings.tools ? "Logs, tracing, the profiler and an FPS counter (console window)" : "Off: no console window, nothing printed", note, DIM)
	}
	opt_content_h = row + px(g, 12)
	if changed {save_settings()}
	if game_changed {
		gdir := game_out_dir()
		if file_exists(pjoin({gdir, GAME_NAME + ".cfg"}, context.temp_allocator)) {_ = write_cfg(gdir)}
	}
}

// an option's note beside its control: wrapped, two lines at most (the second cut with an ellipsis), centered in its row
// "As AppImage:" and its switch in row, the switch over the button below it (Home: Build; Cross-Compile: its Build)
appimage_switch :: proc(g: ^Gui, id: string, button_r, row: ui.Rect, on: ^bool, active: bool) -> bool {
	text :: "As AppImage:"
	lw := text_w(g.font, text) + px(g, 12)
	tr := ui.Rect{button_r.x, row.y, button_r.w, row.h}
	label(g, g.font, text, {tr.x - lw, tr.y, lw, tr.h}, active ? TEXT : FAINT)
	v, ch := toggle(g, tr, on^, active)
	if ch {on^ = v}
	tooltip_zone(g, id, {tr.x - lw, tr.y, lw + px(g, 100), tr.h}, "On: Build makes one file, WhiteRecomp-<CPU>.AppImage, with the game and its settings inside, instead of the program and its .cfg. Off: the program, as before.")
	return ch
}

note_text :: proc(g: ^Gui, s: string, r: ui.Rect, c: ren.Color) {
	lines := wrap(g.small, s, r.w)
	n := min(len(lines), 2)
	y0 := r.y + max(0, (r.h - n * g.small.line_height) / 2)
	for l, i in lines {
		if i == 2 {break}
		t := l
		if i == 1 && len(lines) > 2 {t = fit(g.small, strings.concatenate({l, " ", lines[2]}, context.temp_allocator), r.w)}
		ren.draw_text(g.dl, g.small, t, {r.x, y0 + i * g.small.line_height}, c)
	}
}

// ---------------------------------------------------------------------------------------------- dialogs
dialog_box :: proc(g: ^Gui, w, h: int) -> ui.Rect {
	ren.draw_rect(g.dl, g.screen, ren.Color{0, 0, 0, 77})
	box := ui.center(g.screen, w, h)
	for k in 1 ..= 6 {fill_round(g, ui.translate(ui.outset(box, k), 0, k), px(g, 8) + k, ren.Color{0, 0, 0, 6})}
	round_box(g, box, px(g, 8), ren.Color{255, 255, 255, 255}, ren.Color{200, 200, 200, 255})
	return box
}

// the dialog's button row: a light grey strip at its bottom
dialog_buttons :: proc(g: ^Gui, box: ui.Rect) -> ui.Rect {
	strip := ui.Rect{box.x + 1, box.y + box.h - px(g, 80), box.w - 2, px(g, 80) - px(g, 8)}
	ren.draw_rect(g.dl, strip, WIN_BG)
	fill_round(g, {box.x + 1, box.y + box.h - px(g, 16), box.w - 2, px(g, 15)}, px(g, 7), WIN_BG)
	ren.draw_rect(g.dl, {box.x + 1, strip.y, box.w - 2, 1}, CARD_BORDER)
	return ui.Rect{box.x + px(g, 24), strip.y + px(g, 24), box.w - px(g, 48), px(g, 32)}
}

draw_confirm :: proc(g: ^Gui, gs: Game_State) {
	g.in_modal = true
	defer g.in_modal = false
	box := dialog_box(g, px(g, 520), px(g, 250))
	in_ := ui.inset_xy(box, px(g, 24), px(g, 22))
	ren.draw_text(g.dl, g.big, "Discard the old movies?", {in_.x, in_.y}, TEXT)
	y := in_.y + g.big.line_height + px(g, 12)
	text := fmt.tprintf("%d Bink movies (.wmp) that have their MP4 are cut down to their header, freeing %.1f GB. The game keeps playing the MP4s; to get the originals back, verify the game's files in Steam.", gs.discardable, f64(gs.free_bytes) / 1e9)
	if gs.kept > 0 {text = fmt.tprintf("%s %d movies without an MP4 are kept whole.", text, gs.kept)}
	paragraph(g, g.font, text, {in_.x, y, in_.w, 0}, TEXT, px(g, 2))
	btns := dialog_buttons(g, box)
	yes, no := ui.columns(btns, 0, 2, px(g, 8)), ui.columns(btns, 1, 2, px(g, 8))
	if button(g, yes, "Discard", primary = true) {
		confirm_discard = false
		task_start("Discard Movies", proc(t: ^Task) {discard_task(t); refresh_game(t)})
	}
	if button(g, no, "Keep them") {confirm_discard = false}
}


// old cutscene MP4s deleted at start (movies.odin old_movies_cleanup): asks for a new conversion
draw_reconvert :: proc(g: ^Gui, gs: Game_State) {
	g.in_modal = true
	defer g.in_modal = false
	box := dialog_box(g, px(g, 560), px(g, gs.old_lost > 0 ? 330 : 270))
	in_ := ui.inset_xy(box, px(g, 24), px(g, 22))
	ren.draw_text(g.dl, g.big, "Convert the cutscenes again", {in_.x, in_.y}, TEXT)
	y := in_.y + g.big.line_height + px(g, 12)
	text := fmt.tprintf("%d cutscene MP4s made by an older launcher were deleted. Many movie files hold several cutscenes, and the old converter made only the first one of each, so later scenes played the wrong video under their subtitles, or were skipped.", gs.old_deleted)
	conv_ok, conv_why := convert_possible()
	if conv_ok {
		text = fmt.tprintf("%s Press Convert Movies to convert them all again.", text)
	} else {
		text = fmt.tprintf("%s Convert Movies cannot run yet: %s", text, conv_why)
	}
	y += paragraph(g, g.font, text, {in_.x, y, in_.w, 0}, TEXT, px(g, 2)) + px(g, 12)
	if gs.old_lost > 0 {
		paragraph(g, g.font, fmt.tprintf("%d movie files were cut down by an older Discard Movies, and their cutscenes are gone. Have Steam restore them first: Properties > Installed Files > Verify integrity of game files.", gs.old_lost), {in_.x, y, in_.w, 0}, TEXT, px(g, 2))
	}
	btns := dialog_buttons(g, box)
	yes, no := ui.columns(btns, 0, 2, px(g, 8)), ui.columns(btns, 1, 2, px(g, 8))
	can := !sync.atomic_load(&task.running) && gs.ok && conv_ok && gs.to_convert > 0
	if button(g, yes, "Convert Movies", can, primary = true) {
		sync.atomic_store(&reconvert_dialog, false)
		task_start("Convert Movies", proc(t: ^Task) {convert_task(t); refresh_game(t)})
	}
	if button(g, no, can ? "Later" : "OK") {sync.atomic_store(&reconvert_dialog, false)}
}

draw_no_compiler :: proc(g: ^Gui, w: ^platform.Window) {
	g.in_modal = true
	defer g.in_modal = false
	box := dialog_box(g, px(g, 640), px(g, 450))
	in_ := ui.inset_xy(box, px(g, 24), px(g, 22))
	ren.draw_text(g.dl, g.big, "A C compiler is needed", {in_.x, in_.y}, TEXT)
	y := in_.y + g.big.line_height + px(g, 12)
	when ODIN_OS == .Linux {
		y += paragraph(g, g.font, "The launcher builds the game on your computer, and that needs a C compiler: Clang (the best: a faster game) or GCC. None was found. Install one, then press Check again.", {in_.x, y, in_.w, 0}, TEXT, px(g, 2))
	} else {
		y += paragraph(g, g.font, "The launcher builds the game on your computer, and that needs Clang (the game is built with Clang only: GCC is not used). None was found. Install one, then press Check again -- or, if it is installed but not found, Choose it.", {in_.x, y, in_.w, 0}, TEXT, px(g, 2))
	}
	y += px(g, 12)
	lh := g.font.line_height + px(g, 10)
	when ODIN_OS == .Windows {
		x := in_.x + px(g, 12)
		ren.draw_text(g.dl, g.bold, "Windows", {in_.x, y}, TEXT); y += lh
		lw := link(g, x, y, "LLVM-MinGW (Clang)", "https://github.com/mstorsjo/llvm-mingw/releases")
		ren.draw_text(g.dl, g.small, "  the ucrt-x86_64 zip, or: winget install MartinStorsjo.LLVM-MinGW.UCRT", {x + lw, y + px(g, 2)}, DIM); y += lh
		link(g, x, y, "MSYS2 (its clang64 Clang)", "https://www.msys2.org/"); y += lh
	} else {
		x := in_.x + px(g, 12)
		ren.draw_text(g.dl, g.bold, "Linux", {in_.x, y}, TEXT); y += lh
		lw := link(g, x, y, "Clang", "https://clang.llvm.org/get_started.html")
		ren.draw_text(g.dl, g.small, "  e.g. sudo apt install clang  /  sudo dnf install clang", {x + lw, y + px(g, 2)}, DIM); y += lh
	}
	btns := dialog_buttons(g, box)
	d := dep_get(.Compiler)
	if d.note != "" && d.note != "none found" { // (what was tried, and why each was not taken)
		y += px(g, 6)
		paragraph(g, g.small, fmt.tprintf("Tried: %s", d.note), {in_.x, y, in_.w, 0}, DIM, px(g, 2))
	}
	running := sync.atomic_load(&task.running)
	cols := (d.install != nil ? 3 : 2) + (ODIN_OS != .Linux ? 1 : 0)
	i := 0
	if d.install != nil {
		if button(g, ui.columns(btns, i, cols, px(g, 8)), "Install it for me", !running, primary = true) {
			no_compiler_dialog = 0
			task_start(d.install_how, install_dep_task, rawptr(uintptr(Dep_Kind.Compiler)))
		}
		i += 1
	}
	if button(g, ui.columns(btns, i, cols, px(g, 8)), "Check again", !running, primary = d.install == nil) {
		no_compiler_dialog = 0
		task_start("Checking", check_all_task)
	}
	when ODIN_OS != .Linux {
		if button(g, ui.columns(btns, i + 1, cols, px(g, 8)), ODIN_OS == .Windows ? "Choose clang.exe…" : "Choose clang…", !running) {pick_compiler(w)}
		i += 1
	}
	if button(g, ui.columns(btns, i + 1, cols, px(g, 8)), "Close") {no_compiler_dialog = 2}
}

// Cutscene Files: which cutscene files the game plays -- the choice of the Options tab if the game has those files,
// else the kind it has. .None: neither (the game is not checked yet: the choice as set). The game then skips every
// cutscene (movie_skip: -DXRC_SKIP_MOVIES).
Movie_Files :: enum {
	None,
	MP4,
	Bink,
}
movie_files :: proc() -> Movie_Files {
	gs := get_game()
	if !gs.checked || !gs.ok {return settings.movie_bink ? .Bink : .MP4}
	if settings.movie_bink && gs.has_bink {return .Bink}
	if gs.has_mp4 {return .MP4}
	if gs.has_bink {return .Bink}
	return .None
}
movie_skip :: proc() -> bool {return settings.skip_movies || movie_files() == .None}
