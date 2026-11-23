// Choosing the game's folder (Home's Browse…). Windows: its own folder dialog (iv_system). macOS: Finder's, through
// osascript (AppleScript's choose folder). Linux: iv_system has no
// dialog there yet, so the desktop's own, through the program it has for scripts -- zenity (GNOME), kdialog (KDE) or
// yad -- run on a thread of its own (the window keeps drawing); without any of them, a folder browser in the launcher:
// the folders of one place at a time, with shortcuts (home, /, the Windows drives under WSL), and the game's folder
// marked once it is reached.
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "shared:iv_system/platform"
import "shared:iv_system/ren"
import ui "shared:iv_ui"

@(private = "file")
Pick :: struct {
	running: bool, // the desktop's dialog is open
	done:    bool, // it answered: path ("" = cancelled)
	path:    string,
	no_tool: bool, // there is no dialog program: the launcher's own browser instead
}
@(private = "file")
pick: Pick

// the browser's state
@(private = "file")
Browser :: struct {
	open:    bool,
	dir:     string,
	entries: [dynamic]string,
	nfolders: int, // (entries[:nfolders] folders; then, choosing a ZIP, the .zip files)
	scroll:  int,
}
@(private = "file")
browser: Browser

// what the picker chooses: the game's folder (Home's Browse…), a folder of saves (Features & Mods > Save Folders) or
// the FF XIII HD Project's ZIP (Features & Mods > HD Textures: a file, not a folder)
@(private = "file")
Pick_Kind :: enum {
	Game,
	Saves,
	Zip,
}
@(private = "file")
pick_kind: Pick_Kind
@(private = "file")
pick_saves: bool // (pick_kind == .Saves)
@(private = "file")
pick_title :: proc() -> string {
	switch pick_kind {
	case .Saves:
		return "Choose a folder with save files (.dat)"
	case .Zip:
		return "Choose the FF XIII HD Project's ZIP file"
	case .Game:
	}
	return "Choose the FINAL FANTASY XIII folder"
}

browse_for_game :: proc(w: ^platform.Window) {pick_kind = .Game; pick_saves = false; browse(w)}
browse_for_saves :: proc(w: ^platform.Window) {pick_kind = .Saves; pick_saves = true; browse(w)}
browse_for_hd_zip :: proc(w: ^platform.Window) {pick_kind = .Zip; pick_saves = false; browse(w)}

// where a ZIP is looked for first: Downloads, else home
zip_start_dir :: proc() -> string {
	home := os.get_env(ODIN_OS == .Windows ? "USERPROFILE" : "HOME", context.temp_allocator)
	if d := pjoin({home, "Downloads"}, context.temp_allocator); dir_exists(d) {return d}
	return home
}

@(private = "file")
browse :: proc(w: ^platform.Window) {
	when ODIN_OS == .Windows {
		if pick_kind == .Zip {
			if p, picked := platform.pick_open_file(w, pick_title(), zip_start_dir(), "ZIP archives", "*.zip"); picked {use_picked(p)}
			return
		}
		if p, picked := platform.pick_folder(w, pick_title()); picked {use_picked(p)}
	} else {
		if sync.atomic_load(&pick.running) {return}
		sync.atomic_store(&pick.running, true)
		th := thread.create_and_start(proc() {
			p, has_tool := desktop_folder_dialog()
			pick.path = p
			pick.no_tool = !has_tool
			sync.atomic_store(&pick.done, true)
			sync.atomic_store(&pick.running, false)
		})
		_ = th
	}
}

@(private = "file")
use_picked :: proc(p: string) {
	switch pick_kind {
	case .Saves:
		add_save_dir(p)
	case .Zip:
		hd_import_start(p) // (hd.odin)
	case .Game:
		use_game_folder(p)
	}
}

@(private = "file")
use_game_folder :: proc(p: string) {
	settings.game_dir = strings.clone(p)
	save_settings()
	task_start("Checking", proc(t: ^Task) {refresh_game(t)})
}

// zenity, kdialog or yad: the chosen folder ("" if cancelled); has_tool false if there is none of them
@(private = "file")
desktop_folder_dialog :: proc() -> (path: string, has_tool: bool) {
	start := settings.game_dir != "" && pick_kind == .Game ? settings.game_dir : os.get_env("HOME", context.temp_allocator)
	if pick_kind == .Zip {start = zip_start_dir()}
	title := pick_title()
	zip := pick_kind == .Zip
	when ODIN_OS == .Darwin { 	// (macOS: Finder's own folder / file dialog, through AppleScript)
		q, _ := strings.replace_all(start, `\`, `\\`, context.temp_allocator) // (inside an AppleScript string)
		q, _ = strings.replace_all(q, `"`, `\"`, context.temp_allocator)
		what := zip ? `choose file of type {"zip", "public.zip-archive"} with prompt "` : `choose folder with prompt "`
		script := strings.concatenate({`POSIX path of (`, what, title, `" default location POSIX file "`, q, `")`}, context.temp_allocator)
		tools := [][]string{{"/usr/bin/osascript", "-e", script}}
	} else {
		tools := [][]string {
		{"zenity", "--file-selection", "--directory", strings.concatenate({"--title=", title}, context.temp_allocator), strings.concatenate({"--filename=", start, "/"}, context.temp_allocator)},
		{"kdialog", "--getexistingdirectory", start, "--title", title},
		{"yad", "--file", "--directory", strings.concatenate({"--title=", title}, context.temp_allocator)},
		}
		if zip {
			tools = [][]string {
			{"zenity", "--file-selection", "--file-filter=ZIP archives | *.zip *.ZIP", strings.concatenate({"--title=", title}, context.temp_allocator), strings.concatenate({"--filename=", start, "/"}, context.temp_allocator)},
			{"kdialog", "--getopenfilename", start, "*.zip *.ZIP|ZIP archives", "--title", title},
			{"yad", "--file", "--file-filter=ZIP archives | *.zip *.ZIP", strings.concatenate({"--title=", title}, context.temp_allocator)},
			}
		}
	}
	for t in tools {
		prog := find_program(t[0])
		if prog == "" {continue}
		cmd := slice.clone(t, context.temp_allocator)
		cmd[0] = prog
		c, r, ok := child_start(cmd, "")
		if !ok {continue}
		out := strings.builder_make(context.temp_allocator)
		buf: [4096]u8
		for {
			n := child_read(r, buf[:])
			if n <= 0 {break}
			strings.write_bytes(&out, buf[:n])
		}
		code := child_wait(c, r)
		// (stderr shares the pipe: GTK and the like print warnings there -- "Gtk-WARNING **: Unable to acquire the
		// address of the accessibility bus" -- so the answer is the last line that is an existing absolute folder)
		p := ""
		text := strings.to_string(out)
		for line in strings.split_lines_iterator(&text) {
			l := strings.trim_space(line)
			if len(l) > 1 && !zip {l = strings.trim_suffix(l, "/")} // (AppleScript's folder paths end in /)
			if strings.has_prefix(l, "/") && (zip ? file_exists(l) : dir_exists(l)) {p = l}
		}
		return code == 0 && p != "" ? strings.clone(p) : "", true
	}
	return "", false
}

// each frame: a dialog that answered, or the launcher's browser to open
pick_poll :: proc() {
	if !sync.atomic_load(&pick.done) {return}
	sync.atomic_store(&pick.done, false)
	if pick.no_tool {
		start := settings.game_dir != "" && pick_kind == .Game ? settings.game_dir : os.get_env("HOME", context.temp_allocator)
		if pick_kind == .Zip {start = zip_start_dir()}
		if !dir_exists(start) {start = "/"}
		browser_go(start)
		browser.open = true
	} else if pick.path != "" {
		use_picked(pick.path)
	}
}

browser_is_open :: proc() -> bool {return browser.open}

@(private = "file")
browser_go :: proc(dir: string) {
	clean, _ := filepath.clean(dir, context.temp_allocator)
	delete(browser.dir)
	browser.dir = strings.clone(clean)
	for e in browser.entries {delete(e)}
	clear(&browser.entries)
	browser.scroll = 0
	if list, err := os.read_all_directory_by_path(browser.dir, context.temp_allocator); err == nil {
		for e in list {
			if e.type == .Directory && !strings.has_prefix(e.name, ".") {append(&browser.entries, strings.clone(e.name))}
		}
	}
	slice.sort_by(browser.entries[:], proc(a, b: string) -> bool {return strings.to_lower(a, context.temp_allocator) < strings.to_lower(b, context.temp_allocator)})
	browser.nfolders = len(browser.entries)
	if pick_kind == .Zip {
		if list, err := os.read_all_directory_by_path(browser.dir, context.temp_allocator); err == nil {
			for e in list {
				if e.type != .Directory && strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), ".zip") {append(&browser.entries, strings.clone(e.name))}
			}
		}
		slice.sort_by(browser.entries[browser.nfolders:], proc(a, b: string) -> bool {return strings.to_lower(a, context.temp_allocator) < strings.to_lower(b, context.temp_allocator)})
	}
}

// the launcher's folder browser (a dialog)
draw_browser :: proc(g: ^Gui, wheel: int) {
	g.in_modal = true
	defer g.in_modal = false
	box := dialog_box(g, min(px(g, 640), g.screen.w - px(g, 40)), min(px(g, 520), g.screen.h - px(g, 40)))
	in_ := ui.inset_xy(box, px(g, 24), px(g, 20))
	ren.draw_text(g.dl, g.big, pick_title(), {in_.x, in_.y}, TEXT)
	y := in_.y + g.big.line_height + px(g, 10)

	// the shortcuts
	x := in_.x
	shortcut :: proc(g: ^Gui, x: ^int, y: int, name, dir: string) {
		if !dir_exists(dir) {return}
		w := text_w(g.small, name) + px(g, 24)
		if button(g, {x^, y, w, px(g, 28)}, name, f = g.small) {browser_go(dir)}
		x^ += w + px(g, 6)
	}
	shortcut(g, &x, y, "Up", filepath.dir(browser.dir))
	shortcut(g, &x, y, "Home", os.get_env("HOME", context.temp_allocator))
	shortcut(g, &x, y, "/", "/")
	for d in ([]string{"c", "d", "e", "f"}) { // (WSL: the Windows drives)
		shortcut(g, &x, y, strings.concatenate({strings.to_upper(d, context.temp_allocator), ":"}, context.temp_allocator), strings.concatenate({"/mnt/", d}, context.temp_allocator))
	}
	y += px(g, 36)
	label(g, g.small, browser.dir, {in_.x, y, in_.w, px(g, 20)}, DIM)
	y += px(g, 24)

	// the folders here
	btns := dialog_buttons(g, box)
	list := ui.Rect{in_.x, y, in_.w, btns.y - px(g, 24) - y}
	round_box(g, list, px(g, 4), LOG_BG, CARD_BORDER)
	rh := px(g, 30)
	rows := max(1, (list.h - px(g, 8)) / rh)
	if inside(list, g.mouse) {browser.scroll = clamp(browser.scroll - wheel, 0, max(0, len(browser.entries) - rows))}
	go_to, chosen := "", ""
	{
		ren.scope_clip(g.dl, list)
		for i in 0 ..< rows {
			k := browser.scroll + i
			if k >= len(browser.entries) {break}
			r := ui.Rect{list.x + px(g, 4), list.y + px(g, 4) + i * rh, list.w - px(g, 8), rh}
			hot := inside(r, g.mouse)
			if hot {fill_round(g, r, px(g, 4), ren.Color{0, 0, 0, 12}); g.cursor = .Hand}
			is_file := k >= browser.nfolders
			if is_file {
				fill_round(g, {r.x + px(g, 12), r.y + rh / 2 - px(g, 8), px(g, 12), px(g, 16)}, px(g, 2), ren.Color{120, 132, 150, 255}) // (a file)
			} else {
				fill_round(g, {r.x + px(g, 10), r.y + rh / 2 - px(g, 6), px(g, 16), px(g, 12)}, px(g, 2), ren.Color{232, 186, 72, 255}) // (a folder)
			}
			label(g, g.font, browser.entries[k], {r.x + px(g, 36), r.y, r.w - px(g, 40), rh}, TEXT)
			if hot && g.clicked {
				if is_file {chosen = pjoin({browser.dir, browser.entries[k]}, context.temp_allocator)} else {go_to = pjoin({browser.dir, browser.entries[k]}, context.temp_allocator)}
			}
		}
	}
	if len(browser.entries) == 0 {label(g, g.small, pick_kind == .Zip ? "(no folders or ZIP files here)" : "(no folders here)", ui.inset(list, px(g, 12)), FAINT, center = true)}
	if chosen != "" {
		browser.open = false
		use_picked(chosen)
		return
	}
	if go_to != "" {browser_go(go_to)}
	if pick_kind == .Zip { 	// (a ZIP is chosen by clicking it)
		label(g, g.small, "Click the FF XIII HD Project's ZIP file to import it.", {in_.x, btns.y - px(g, 22), in_.w, px(g, 18)}, DIM)
		if button(g, ui.columns(btns, 1, 2, px(g, 8)), "Cancel") {browser.open = false}
		return
	}

	// the game here? (choosing saves: how many .dat files are in it)
	here := pick_saves || is_game_dir(browser.dir)
	note := here ? "FINAL FANTASY XIII is in this folder." : "Open the folder FINAL FANTASY XIII is installed in (the one with white_data)."
	if pick_saves {
		n := count_dat(browser.dir)
		note = n > 0 ? fmt.tprintf("%d .dat file%s in this folder.", n, n == 1 ? "" : "s") : "No .dat files in this folder (only its own files are looked at, not its subfolders')."
	}
	label(g, g.small, note, {in_.x, btns.y - px(g, 22), in_.w, px(g, 18)}, here ? GOOD : DIM)
	if button(g, ui.columns(btns, 0, 2, px(g, 8)), "Choose this folder", here, primary = true) {
		browser.open = false
		use_picked(browser.dir)
	}
	if button(g, ui.columns(btns, 1, 2, px(g, 8)), "Cancel") {browser.open = false}
}
