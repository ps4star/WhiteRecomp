// Convert Movies on Linux and macOS: the converter (tools/bink2mp4.exe) is a 32-bit Windows program around the game's
// own Windows Bink DLL, so it runs through Wine there (deps.odin finds Wine). It starts the Windows FFmpeg the launcher
// brings (tools/wine/ffmpeg.exe, packed in the Linux x86-64 and macOS launchers: under Wine, the converter's pipe to
// FFmpeg and FFmpeg itself are Windows ones).
//
// Wine gets a folder of its own (WINEPREFIX: the launcher's data folder's wine/), so nothing of the user's own Wine
// setup is touched, and ending the conversion can end every Wine process in it (wineserver -k: a cancelled
// conversion's FFmpeg too, which killing the converter alone leaves running). Paths go to the Windows programs as
// Wine's Z: drive (Z: is /). Mono's and Gecko's installers, which a new folder offers, are turned off (neither is
// needed), and so is Wine's debug output.
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

wine_prefix :: proc() -> string {return data_path("wine")}

// a Unix path as Wine's Windows programs see it (Z:\...)
win_path :: proc(p: string) -> string {
	if ODIN_OS == .Windows {return p}
	s, _ := strings.replace_all(p, "/", "\\", context.temp_allocator)
	return strings.concatenate({"Z:", s}, context.temp_allocator)
}

// args run through Wine (args[0] the program: a Windows .exe as a Unix path, or one of Wine's own: wineboot ...),
// in the launcher's own Wine folder
wine_cmd :: proc(wine: string, args: []string) -> []string {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "/usr/bin/env", fmt.tprintf("WINEPREFIX=%s", wine_prefix()), "WINEDEBUG=-all", "WINEDLLOVERRIDES=mscoree,mshtml=")
	when ODIN_OS == .Linux {
		if files := proton_dir(wine); files != "" { // (a Proton's Wine: its own libraries first, as Steam would set them)
			lp := make([dynamic]string, context.temp_allocator)
			for sub in ([]string{"lib64", "lib", "lib/x86_64-linux-gnu", "lib/i386-linux-gnu"}) {
				if d := pjoin({files, sub}, context.temp_allocator); dir_exists(d) {append(&lp, d)}
			}
			if old := os.get_env("LD_LIBRARY_PATH", context.temp_allocator); old != "" {append(&lp, old)}
			if len(lp) > 0 {append(&cmd, fmt.tprintf("LD_LIBRARY_PATH=%s", strings.join(lp[:], ":", context.temp_allocator)))}
		}
	}
	append(&cmd, wine)
	append(&cmd, ..args)
	return cmd[:]
}

// Wine's folder set up (the first time: a minute), and the converter run once without arguments: it prints its usage
// and ends with code 2 if this Wine runs 32-bit Windows programs
wine_ready :: proc(t: ^Task, wine, tool: string) -> bool {
	if !file_exists(pjoin({wine_prefix(), "system.reg"}, context.temp_allocator)) {
		set_status(t, -1, "Setting up Wine (the first time: about a minute)")
		log_line(t, "Setting up Wine's folder for the converter (only the first time)")
		_ = os.make_directory_all(wine_prefix())
		code, started := run(t, wine_cmd(wine, {"wineboot", "--init"}), mode = .Quiet)
		if !started || code != 0 {
			logf(t, "Wine could not set up its folder (%s; code %d).", wine_prefix(), code)
			return false
		}
	}
	out := strings.builder_make(context.temp_allocator)
	code, started := run(t, wine_cmd(wine, {tool}), mode = .Quiet, capture = &out)
	if started && code == 2 && strings.contains(strings.to_string(out), "usage: bink2mp4") {return true}
	log_line(t, "Wine cannot run the converter, a 32-bit Windows program.")
	when ODIN_OS == .Darwin {
		log_line(t, "Use a Wine that runs 32-bit programs (Wine 9 or later, e.g. Homebrew's wine-stable); on an Apple silicon Mac it also needs Rosetta 2 (softwareupdate --install-rosetta).")
	} else when ODIN_OS == .Linux {
		if proton_dir(wine) != "" {
			log_line(t, "This is a Proton's Wine (found in Steam). Install another Proton in Steam (Library > search Proton; e.g. Proton 9.0 or Proton - Experimental) and Check again, or install Wine itself.")
		} else {
			log_line(t, "Install Wine's 32-bit support: Debian / Ubuntu wine32 (sudo dpkg --add-architecture i386; sudo apt install wine32:i386), Fedora wine (it brings it), Arch wine.")
		}
	}
	if s := strings.trim_space(strings.to_string(out)); s != "" {logf(t, "Wine said: %s", s)}
	return false
}

// every Wine process of the launcher's folder ended (the converter's FFmpeg after a cancel), and the temporary files
// of the conversion that was running deleted
wine_stop :: proc(t: ^Task, wine: string, movies: string, cancelled: bool) {
	wdir, _ := filepath.split(wine)
	server := pjoin({wdir, "wineserver"}, context.temp_allocator)
	if !file_exists(server) {server = find_program("wineserver")}
	if server != "" {_, _ = run(t, {"/usr/bin/env", fmt.tprintf("WINEPREFIX=%s", wine_prefix()), server, "-k"}, mode = .Quiet)}
	if !cancelled {return}
	if list, err := os.read_all_directory_by_path(movies, context.temp_allocator); err == nil {
		for e in list {
			if strings.contains(e.name, ".tmp.") {_ = os.remove(e.fullpath)}
		}
	}
}

// the file name at the end of a path of either kind (the converter under Wine prints Z:\...\name.wmp)
any_base :: proc(p: string) -> string {
	i := max(strings.last_index_byte(p, '/'), strings.last_index_byte(p, '\\'))
	return p[i + 1:]
}

// Whether Convert Movies can run here, and if not why (the Home tab's button and tooltip, the re-convert dialog)
convert_possible :: proc() -> (ok: bool, why: string) {
	ff := dep_get(.FFmpeg)
	when ODIN_OS == .Windows {
		if !ff.can_encode {return false, "Needs FFmpeg with its H.264 encoder (install it above)."}
		return true, ""
	} else {
		if !strings.has_suffix(ff.path, ".exe") {
			return false, "This launcher has no Windows FFmpeg to convert the movies with (only the x86-64 Linux and the macOS launchers do): convert them on another PC."
		}
		if dep_get(.Wine).path == "" {return false, "Needs Wine (install it above): the converter is a Windows program."}
		return true, ""
	}
}

// Wine's server for the launcher's folder kept running (wineserver -p) while a task runs many short Windows programs in
// a row -- the HD import: about three per block of every zone, thousands in all (issue #25). Otherwise the server ends
// 3 s after each program and the next one starts it, and Wine's services, all over again. Ended with wine_server_end.
wine_server :: proc(wine: string) -> string {
	wdir, _ := filepath.split(wine)
	server := pjoin({wdir, "wineserver"}, context.temp_allocator)
	if !file_exists(server) {server = find_program("wineserver")}
	return server
}
wine_server_keep :: proc(t: ^Task, wine, scratch: string) {
	when ODIN_OS != .Windows {
		server := wine_server(wine)
		if server == "" {return}
		// (it puts itself in the background: its output to a file, not a pipe it would keep open -- run_to_file)
		_, _ = run_to_file(t, wine_cmd(server, {"-p"}), "", scratch)
	}
}
wine_server_end :: proc(t: ^Task, wine, scratch: string) {
	when ODIN_OS != .Windows {
		server := wine_server(wine)
		if server == "" {return}
		_, _ = run_to_file(t, wine_cmd(server, {"-k"}), "", scratch)
	}
}
