// Build: the game from the bundled sources, with the computer's own C compiler (deps.odin), into the data dir:
//   1. checks the player's ffxiiiimg.exe (the version the code was translated from)
//   2. unpacks the sources (src/: gen/, runtime/, include/, ffmpeg/; files that did not change are left alone)
//   3. compiles them on every core into obj/ (a file whose object is newer than it, and than include/xrc.h, with the
//      same compiler and flags as last time, is not compiled again)
//   4. links WhiteRecomp (.exe) beside the launcher -- with FFmpeg's static libraries (the movies; LGPL 2.1+): the
//      bundled ones (src/ffmpeg), or the player's own build if the data dir has one in ffmpeg/ -- and writes
//      WhiteRecomp.cfg beside it: where the player's install, its exe and the saves are (the game reads it at start,
//      so it starts with a double click)
// The same steps as tools/xrc_build.sh, with the Options tab's choices (options.odin). Windows builds the reference
// target (the real Direct3D 9 -- or Vulkan --, input and windows of Windows); Linux the Vulkan one (an SDL2 window).
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

REFERENCE :: ODIN_OS == .Windows

// What a Build makes: the zero value is the game for this computer (the Home tab); the Cross-Compile tab's
// (cross.odin) names another target, its Clang and lld, and where its files are
Build_Spec :: struct {
	cross:   ^Cross_Target,
	cc, lld: string,
	cpu:     string, // -mcpu=
	sysroot: string, // the target's system files (unpacked from the bundle's cross/<target>/sysroot)
	ffdir:   string, // the target's FFmpeg (lib/)
	obj:     string,
	out_dir: string,
}

// the target's flags before every other: its architecture (and, cross, the target and its system files)
spec_arch_flags :: proc(spec: Build_Spec) -> []string {
	if spec.cross == nil {return arch_flags()}
	f := make([]string, 2, context.temp_allocator)
	f[0] = fmt.tprintf("--target=%s", spec.cross.triple)
	f[1] = fmt.tprintf("--sysroot=%s", spec.sysroot)
	return f
}

@(private = "file")
Unit :: struct {
	src, obj: string,
	flags:    []string,
}

@(private = "file")
mtime :: proc(p: string) -> time.Time {
	fi, err := os.stat(p, context.temp_allocator)
	if err != nil {return {}}
	return fi.modification_time
}

build_task :: proc(t: ^Task, spec: Build_Spec = {}) {
	x := spec.cross
	reference := REFERENCE && x == nil
	game := settings.game_dir
	exe := game_exe(game)
	set_status(t, 0, "Checking the game")
	if ok, why, _ := check_game_exe(exe); !ok {
		logf(t, "%s cannot be used: %s.", exe, why)
		t.failed = true
		return
	}
	cc := x != nil ? spec.cc : dep_get(.Compiler).path
	if cc == "" {
		log_line(t, "No C compiler that can build the game: install one first.")
		t.failed = true
		return
	}
	logf(t, "Game: %s", game)
	logf(t, "Compiler: %s", cc)

	// 2. the sources
	src := data_path("src")
	// (no clean data folder first: the objects of the last Build are kept, and only what changed is compiled again --
	// the Home tab's Clear Cache deletes them; sources an older bundle had and this one does not are deleted)
	src_dirs := []string{"gen/", "runtime/", "include/", "ffmpeg/", "vulkan/", "pgo/"}
	n := bundle_extract(t, src, src_dirs)
	if n < 0 {t.failed = true; return}
	if pruned := bundle_prune(t, src, src_dirs); pruned > 0 {logf(t, "Deleted %d old source files", pruned)}
	if cancelled(t) {return}
	logf(t, "Sources: %s (%d files changed)", src, n)
	if x != nil { 	// (the target's system files and FFmpeg)
		xn := bundle_extract(t, data_dir, {fmt.tprintf("cross/%s/", x.key)})
		if xn < 0 {t.failed = true; return}
		have := x.android ? file_exists(pjoin({spec.sysroot, "glue", "android_native_app_glue.c"}, context.temp_allocator)) : file_exists(pjoin({spec.ffdir, "lib", "libavcodec.a"}, context.temp_allocator))
		if !have {
			logf(t, "This launcher carries no files for %s.", x.name)
			t.failed = true
			return
		}
		logf(t, "%s system files: %s (%d files changed)", x.name, spec.sysroot, xn)
	}
	pgo_prepare(t, cc, pjoin({src, "pgo", "ff13.profdata"}, context.temp_allocator), spec)

	// 3. compile
	obj := x != nil ? spec.obj : data_path("obj")
	_ = os.make_directory_all(obj)
	inc := pjoin({src, "include"}, context.temp_allocator)
	rt := pjoin({src, "runtime"}, context.temp_allocator)
	units := make([dynamic]Unit, context.temp_allocator)
	page_flags := make([dynamic]string, context.temp_allocator)
	append(&page_flags, ..spec_arch_flags(spec))
	append(&page_flags, ..page_option_flags(spec))
	append(&page_flags, "-I", inc)
	rt_flags := make([dynamic]string, context.temp_allocator)
	append(&rt_flags, ..spec_arch_flags(spec))
	append(&rt_flags, ..runtime_option_flags(spec))
	// FFmpeg: the player's own build in the data dir's ffmpeg/ (LGPL: they may relink the game with a modified FFmpeg;
	// the launcher never writes there), else the bundled one
	ffdir := x != nil ? spec.ffdir : pjoin({src, "ffmpeg"}, context.temp_allocator)
	fflib := "lib"
	// (the macOS bundle carries both kinds of Mac's: lib/ Apple silicon's, lib_x86_64/ Intel's)
	when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 {if x == nil {fflib = "lib_x86_64"}}
	if own := data_path("ffmpeg"); x == nil && file_exists(pjoin({own, "lib", "libavcodec.a"}, context.temp_allocator)) {
		ffdir = own
		fflib = "lib"
		logf(t, "FFmpeg: your own build in %s", own)
	}
	append(&rt_flags, "-I", inc, "-I", rt, "-I", pjoin({src, "ffmpeg", "include"}, context.temp_allocator)) // (the headers: the same for every target)
	if own := data_path("ffmpeg"); x == nil && ffdir == own {append(&rt_flags, "-I", pjoin({own, "include"}, context.temp_allocator))}
	append(&rt_flags, "-DXRC_VULKAN", "-I", pjoin({src, "vulkan", "include"}, context.temp_allocator))
	if x != nil && x.android {append(&rt_flags, "-I", pjoin({spec.sysroot, "glue"}, context.temp_allocator))} // (android_native_app_glue.h)
	if reference {append(&rt_flags, "-DXRC_REFERENCE")}
	logf(t, "Options: %v", runtime_option_flags(spec))
	if settings.lto && !lto_on(spec) {logf(t, "Link-Time Optimization is off for this build: Clang's needs LLVM's linker (ld.lld) beside it, and there is none.")}
	if list, err := os.read_all_directory_by_path(pjoin({src, "gen", "src"}, context.temp_allocator), context.temp_allocator); err == nil {
		for e in list {
			if strings.has_suffix(e.name, ".c") {
				append(&units, Unit{e.fullpath, pjoin({obj, strings.concatenate({e.name[:len(e.name) - 2], ".o"}, context.temp_allocator)}, context.temp_allocator), page_flags[:]})
			}
		}
	}
	append(&units, Unit{pjoin({src, "gen", "xrc_table.c"}, context.temp_allocator), pjoin({obj, "xrc_table.o"}, context.temp_allocator), rt_flags[:]})
	// the byte-matched functions (ff xrcmatch): page flags, and the runtime's header (xrc_rt.h)
	match_flags := make([dynamic]string, context.temp_allocator)
	append(&match_flags, ..page_flags[:])
	append(&match_flags, "-I", rt)
	if list, err := os.read_all_directory_by_path(pjoin({src, "gen", "match"}, context.temp_allocator), context.temp_allocator); err == nil {
		for e in list {
			if strings.has_suffix(e.name, ".c") {
				append(&units, Unit{e.fullpath, pjoin({obj, strings.concatenate({"m_", e.name[:len(e.name) - 2], ".o"}, context.temp_allocator)}, context.temp_allocator), match_flags[:]})
			}
		}
	}
	if list, err := os.read_all_directory_by_path(rt, context.temp_allocator); err == nil {
		for e in list {
			if !strings.has_suffix(e.name, ".c") {continue}
			if strings.has_prefix(e.name, "ref_") && !reference {continue}
			append(&units, Unit{e.fullpath, pjoin({obj, strings.concatenate({"rt_", e.name[:len(e.name) - 2], ".o"}, context.temp_allocator)}, context.temp_allocator), rt_flags[:]})
		}
	}
	// the game's hand-written override routines (xrc --override, copied beside the pages: gen/src/overrides)
	if list, err := os.read_all_directory_by_path(pjoin({src, "gen", "src", "overrides"}, context.temp_allocator), context.temp_allocator); err == nil {
		for e in list {
			if !strings.has_suffix(e.name, ".c") {continue}
			append(&units, Unit{e.fullpath, pjoin({obj, strings.concatenate({"ovr_", e.name[:len(e.name) - 2], ".o"}, context.temp_allocator)}, context.temp_allocator), rt_flags[:]})
		}
	}
	if x != nil && x.android { 	// (the NDK's NativeActivity glue: its entry, ANativeActivity_onCreate, exported)
		glue_flags := make([dynamic]string, context.temp_allocator)
		append(&glue_flags, ..rt_flags[:])
		append(&glue_flags, "-fvisibility=default")
		append(&units, Unit{pjoin({spec.sysroot, "glue", "android_native_app_glue.c"}, context.temp_allocator), pjoin({obj, "rt_android_native_app_glue.o"}, context.temp_allocator), glue_flags[:]})
	}
	slice.sort_by(units[:], proc(a, b: Unit) -> bool {return a.src < b.src})

	// the compiler and flags of the objects there, per kind (the pages / the runtime): different ones rebuild that
	// kind (an option such as Audio rebuilds only the runtime; another compiler, everything)
	pgo_t := pgo_profile != "" ? mtime(pgo_profile) : time.Time{} // (a new profile: everything again)
	page_stamp := fmt.tprintf("%s|%v|%v|%v", cc, page_flags[:], reference, pgo_t)
	rt_stamp := fmt.tprintf("%s|%v|%v|%v", cc, rt_flags[:], reference, pgo_t)
	page_stamp_file := pjoin({obj, "pages.stamp"}, context.temp_allocator)
	rt_stamp_file := pjoin({obj, "runtime.stamp"}, context.temp_allocator)
	old_page, _ := os.read_entire_file(page_stamp_file, context.temp_allocator)
	old_rt, _ := os.read_entire_file(rt_stamp_file, context.temp_allocator)
	same_page, same_rt := string(old_page) == page_stamp, string(old_rt) == rt_stamp
	// the headers an object depends on: the pages only xrc.h; the runtime, the table and the matched functions also
	// the runtime's own (src/runtime/*.h: a change there rebuilds them all)
	header := mtime(pjoin({inc, "xrc.h"}, context.temp_allocator))
	rt_header := header
	if hs, err := os.read_all_directory_by_path(rt, context.temp_allocator); err == nil {
		for h in hs {
			if strings.has_suffix(h.name, ".h") && time.diff(rt_header, h.modification_time) > 0 {rt_header = h.modification_time}
		}
	}
	todo := make([dynamic]Unit, context.temp_allocator)
	for u in units {
		ot := mtime(u.obj)
		is_page := raw_data(u.flags) == raw_data(page_flags[:])
		same := same_page if is_page else same_rt
		if raw_data(u.flags) != raw_data(rt_flags[:]) && !is_page {same = same_page} // (the matched functions: the page flags' kind)
		hdr := header if is_page else rt_header
		if same && time.diff(mtime(u.src), ot) > 0 && time.diff(hdr, ot) > 0 {continue}
		append(&todo, u)
	}
	_ = os.remove(page_stamp_file) // (until this build's objects are all made)
	_ = os.remove(rt_stamp_file)
	_ = os.remove(pjoin({obj, "build.stamp"}, context.temp_allocator)) // (the old single stamp)
	logf(t, "Compiling %d of %d files on %d cores", len(todo), len(units), os.get_processor_core_count())
	Job :: struct {
		t:      ^Task,
		cc:     string,
		list:   []Unit,
		next:   int,
		done:   int,
		failed: bool,
	}
	job := Job{t = t, cc = cc, list = todo[:]}
	worker :: proc(th: ^thread.Thread) {
		j := (^Job)(th.data)
		for !cancelled(j.t) && !sync.atomic_load(&j.failed) {
			k := sync.atomic_add(&j.next, 1)
			if k >= len(j.list) {return}
			u := j.list[k]
			args := make([dynamic]string, context.temp_allocator)
			append(&args, j.cc)
			append(&args, ..u.flags)
			append(&args, "-c", u.src, "-o", u.obj)
			out := strings.builder_make(context.temp_allocator)
			_ = os.remove(u.obj)
			code, started := run(j.t, args[:], mode = .Quiet, capture = &out)
			if !cancelled(j.t) && (!started || code != 0) {
				sync.atomic_store(&j.failed, true)
				logf(j.t, "%s does not compile:", filepath.base(u.src))
				lines := strings.split_lines(strings.to_string(out), context.temp_allocator)
				for l, i in lines {
					if i >= 30 {log_line(j.t, "  ..."); break}
					log_line(j.t, l)
				}
			}
			d := sync.atomic_add(&j.done, 1) + 1
			set_status(j.t, 0.1 + 0.8 * f32(d) / f32(len(j.list)), "Compiling: %d of %d (%s)", d, len(j.list), filepath.base(u.src))
			free_all(context.temp_allocator)
		}
	}
	threads := make([dynamic]^thread.Thread, context.temp_allocator)
	for _ in 0 ..< max(1, os.get_processor_core_count()) {
		th := thread.create(worker)
		th.data = &job
		th.init_context = context
		thread.start(th)
		append(&threads, th)
	}
	for th in threads {thread.join(th); thread.destroy(th)}
	if cancelled(t) {return}
	if job.failed {t.failed = true; return}
	_ = os.write_entire_file(page_stamp_file, transmute([]u8)page_stamp)
	_ = os.write_entire_file(rt_stamp_file, transmute([]u8)rt_stamp)

	// 4. link (the objects through a response file: the command line of 230 paths is long on Windows)
	set_status(t, 0.92, "Linking")
	gdir := x != nil ? spec.out_dir : game_out_dir()
	_ = os.make_directory_all(gdir)
	out_exe := pjoin({gdir, strings.concatenate({GAME_NAME, x != nil ? "" : EXE_SUFFIX}, context.temp_allocator)}, context.temp_allocator)
	if x != nil && x.android {out_exe = pjoin({obj, "libmain.so"}, context.temp_allocator)} // (packed into the APK after)
	appimage := appimage_on(spec)
	if appimage {out_exe = pjoin({obj, GAME_NAME}, context.temp_allocator)} // (packed into the AppImage after)
	rsp := strings.builder_make(context.temp_allocator)
	for u in units {
		p, _ := strings.replace_all(u.obj, "\\", "/", context.temp_allocator)
		fmt.sbprintf(&rsp, "\"%s\"\n", p)
	}
	rsp_file := pjoin({obj, "link.rsp"}, context.temp_allocator)
	_ = os.write_entire_file(rsp_file, rsp.buf[:])
	args := make([dynamic]string, context.temp_allocator)
	append(&args, cc)
	append(&args, ..spec_arch_flags(spec))
	append(&args, ..link_option_flags(spec))
	append(&args, "-o", out_exe, strings.concatenate({"@", rsp_file}, context.temp_allocator))
	// FFmpeg (static, in dependency order), then what it needs of the system
	if x == nil || !x.android {
		for l in ([]string{"libavformat.a", "libavcodec.a", "libswresample.a", "libavutil.a"}) {
			append(&args, pjoin({ffdir, fflib, l}, context.temp_allocator))
		}
	}
	if x != nil && x.android { 	// (Android: Clang's runtime from the bundle, then the system's libraries)
		append(&args, pjoin({spec.sysroot, "builtins", "libclang_rt.builtins-aarch64-android.a"}, context.temp_allocator))
		append(&args, ..CROSS_ANDROID_SYS_LIBS)
	} else if x != nil {
		append(&args, ..CROSS_LINUX_SYS_LIBS)
	} else {
		append(&args, ..FFMPEG_SYS_LIBS)
		append(&args, ..link_libs())
	}
	// Debug & Profile Tools OFF: nothing is printed (xrc_quiet.h), so no console window either (a GUI program; its
	// entry point stays main)
	when ODIN_OS == .Windows {if !settings.tools && x == nil {append(&args, "-Wl,--subsystem,windows")}}
	if code, started := run(t, args[:]); !started || code != 0 {
		log_line(t, "Linking failed.")
		when ODIN_OS == .Windows {if x == nil {logf(t, "(If WhiteRecomp is running, close it and Build again: Windows cannot replace a running program.)")}}
		t.failed = true
		return
	}
	if x != nil { 	// (a cross build: its own .cfg and README.txt; nothing of this computer's)
		if !cross_write_extras(t, x, gdir, out_exe, appimage) {logf(t, "Cannot write the output in %s.", gdir); t.failed = true; return}
		if appimage {
			logf(t, "Built %s: copy it to the %s computer with %s (it says how).", pjoin({gdir, cross_out_file(x)}, context.temp_allocator), x.name, pjoin({gdir, "README.txt"}, context.temp_allocator))
		} else if x.android {
			logf(t, "Built %s: install it on the %s device; %s says how, and where the game's files go.", pjoin({gdir, cross_out_file(x)}, context.temp_allocator), x.name, pjoin({gdir, "README.txt"}, context.temp_allocator))
		} else {
			logf(t, "Built %s: copy the folder %s to the %s computer (its README.txt says how).", out_exe, gdir, x.name)
		}
		set_status(t, 1, "Built")
		return
	}
	// the movie converter the game runs in the background for movies without their MP4 (Windows: tools/bink2mp4.exe),
	// and the Steam achievements helper (tools/steamhelper.exe)
	when ODIN_OS == .Windows {_ = bundle_extract(t, data_dir, {"tools/"})}
	if appimage { 	// (its .cfg inside it, with this computer's paths)
		ai := pjoin({gdir, appimage_file(appimage_arch())}, context.temp_allocator)
		if !appimage_pack(t, ai, out_exe, cfg_text(), appimage_arch(), portable = false) {t.failed = true; return}
		_ = os.make_directory_all(data_path("cdrive"))
		logf(t, "Built %s", ai)
		set_status(t, 1, "Built")
		return
	}
	if !write_cfg(gdir) {
		logf(t, "Cannot write %s in %s.", GAME_NAME + ".cfg", gdir)
		t.failed = true
		return
	}
	_ = os.make_directory_all(data_path("cdrive"))
	logf(t, "Built %s", out_exe)
	set_status(t, 1, "Built")
}

// Profile-Guided Optimization (options.odin): pgo_profile set when this Build can use the profile -- the option on,
// Clang (with lld on Windows), and the compiler reading it (a small file compiled with it first)
@(private = "file")
pgo_prepare :: proc(t: ^Task, cc, profile: string, spec: Build_Spec = {}) {
	pgo_profile = ""
	if !settings.pgo {return}
	if why := pgo_blocked(spec); why != "" {logf(t, "Profile-Guided Optimization is off for this build: %s.", why); return}
	if !file_exists(profile) {logf(t, "Profile-Guided Optimization is off for this build: no profile in the bundle."); return}
	obj := data_path("obj")
	_ = os.make_directory_all(obj)
	probe := pjoin({obj, "pgo_probe.c"}, context.temp_allocator)
	_ = os.write_entire_file(probe, transmute([]u8)string("int pgo_probe(int x) { return x + 1; }\n"))
	out := strings.builder_make(context.temp_allocator)
	pa := make([dynamic]string, context.temp_allocator)
	append(&pa, cc)
	append(&pa, ..spec_arch_flags(spec))
	append(&pa, fmt.tprintf("-fprofile-instr-use=%s", profile), "-c", probe, "-o", pjoin({obj, "pgo_probe.o"}, context.temp_allocator))
	args := pa[:]
	if code, started := run(t, args, mode = .Quiet, capture = &out); !started || code != 0 {
		logf(t, "Profile-Guided Optimization is off for this build: this Clang cannot read the profile (an older version?).")
		return
	}
	pgo_profile = strings.clone(profile)
	logf(t, "Profile-Guided Optimization: %s", profile)
}

GAME_NAME :: "WhiteRecomp"

// where the game is built: the launcher's own folder (macOS: the data folder's game/ -- the launcher is inside its
// signed .app, which nothing may be added to, and often in /Applications)
game_out_dir :: proc() -> string {
	when ODIN_OS == .Darwin {return data_path("game")}
	d, err := os.get_executable_directory(context.temp_allocator)
	if err != nil || d == "" {return data_path("game")}
	return d
}

// WhiteRecomp.cfg: the built game's settings, NAME=value lines it puts in its environment at start
// (src/runtime/xrc_rt.c load_cfg): the player's install (its C:\FINAL FANTASY XIII), its exe, the saves (the launcher's
// cdrive), and the game's own arguments (Shadow
// Resolution, Anti-Aliasing, Voice: XRC_GAME_ARGS) and its text language (Subtitles: XRC_LANGUAGE)
// the .cfg lines of the game's own options (every build's)
cfg_game_lines :: proc(b: ^strings.Builder, spec: Build_Spec = {}) {
	s := build_settings(spec)
	fmt.sbprintf(b, "XRC_GAME_ARGS=%s\n", game_args(s))
	fmt.sbprintf(b, "XRC_LANGUAGE=%s\n", subtitle_id(s.subs)) // (the text language: Features & Mods > Subtitles & UI)
	if movie_files() == .Bink {fmt.sbprintf(b, "XRC_MOVIES=bink\n")} // (Cutscene Files: Bink2 -- the game's .wmp files through its translated bink2w32.dll)
	if s.shadow_res == 0 {fmt.sbprintf(b, "XRC_NO_SHADOWS=1\n")}
	if s.memory_2gb {fmt.sbprintf(b, "XRC_GUEST_2GB=1\n")}
	if s.stretch {fmt.sbprintf(b, "XRC_STRETCH=1\n")}
	if s.fx_full {fmt.sbprintf(b, "XRC_VK_HALF_FX=0\n")}
	if s.steam_off {fmt.sbprintf(b, "XRC_NO_STEAM=1\n")}
	if s.aa_fxaa && s.aa_quality > 1 {fmt.sbprintf(b, "XRC_FXAA=%d\n", s.aa_quality)}
	n := spec.cross != nil && spec.cross.android ? s.pipe_threads : pipe_threads()
	if n > 0 {fmt.sbprintf(b, "XRC_VK_PIPE_THREADS=%d\n", n)} // (0, Best: none written -- the game's default, half the CPU threads)
}

write_cfg :: proc(gdir: string) -> bool {
	text := cfg_text()
	return os.write_entire_file(pjoin({gdir, GAME_NAME + ".cfg"}, context.temp_allocator), transmute([]u8)text) == nil
}

cfg_text :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "# WhiteRecomp's settings, written by the launcher's Build (the environment overrides them)\n")
	fmt.sbprintf(&b, "XRC_GAME_DIR=%s\n", settings.game_dir)
	fmt.sbprintf(&b, "XRC_EXE=%s\n", game_exe(settings.game_dir))
	fmt.sbprintf(&b, "XRC_CDRIVE=%s\n", data_path("cdrive"))
	when ODIN_OS == .Windows {
		fmt.sbprintf(&b, "XRC_STEAM_HELPER=%s\n", data_path("tools", "steamhelper.exe"))
		// SDL2 for game controllers (any one shown to the game as an Xbox 360 controller: src/runtime/hle_dinput.c)
		if sdl := data_path("tools", "SDL2.dll"); file_exists(sdl) {fmt.sbprintf(&b, "XRC_SDL_LIB=%s\n", sdl)}
	}
	when ODIN_OS == .Darwin {
		// the .app's own MoltenVK (Vulkan on Metal) and SDL2 (window, controllers, sound), if it has them: the game
		// loads those; else it looks in Homebrew's and /usr/local's lib
		if fw := app_frameworks_dir(); fw != "" {
			if mvk := pjoin({fw, "libMoltenVK.dylib"}, context.temp_allocator); file_exists(mvk) {fmt.sbprintf(&b, "XRC_VK_LIB=%s\n", mvk)}
			if sdl := pjoin({fw, "libSDL2-2.0.0.dylib"}, context.temp_allocator); file_exists(sdl) {fmt.sbprintf(&b, "XRC_SDL_LIB=%s\n", sdl)}
		}
		fmt.sbprintf(&b, "XRC_NO_STEAM=1\n") // (Steam's macOS client has no FINAL FANTASY XIII to report to)
	}
	cfg_game_lines(&b)
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------------------------- a clean data folder
// Clear Cache (the Home tab) clears the data folder: everything in it is deleted -- the unpacked
// sources, the objects of every earlier build (this computer's and each Cross-Compile target's), the compiler probe,
// the tools, the cross files, macOS's built game -- so nothing an older launcher or build left there can stick around
// (a Build itself keeps them: it compiles only what changed).
// Kept, as nothing can make them again: the saves and the game's own settings (cdrive/), the launcher's settings
// (settings.txt), the Android signing key (an APK signed with another one cannot update the installed app) and the
// player's own FFmpeg (ffmpeg/, which the launcher never writes).
DATA_KEEP :: [?]string{"cdrive", "settings.txt", "android_key.bin", "android_cert.der", "ffmpeg"}

wipe_data_dir :: proc(t: ^Task) -> bool {
	list, err := os.read_all_directory_by_path(data_dir, context.temp_allocator)
	if err != nil {
		logf(t, "Could not read the data folder %s: %v", data_dir, err)
		return false
	}
	n, failed := 0, 0
	outer: for e in list {
		for k in DATA_KEEP {if strings.equal_fold(e.name, k) {continue outer}}
		set_status(t, 0, "Clearing the data folder: %s", e.name)
		// (a link is deleted, not what it points to)
		r := e.type == .Directory ? os.remove_all(e.fullpath) : os.remove(e.fullpath)
		if r != nil {
			logf(t, "Could not delete %s: %v", e.fullpath, r)
			failed += 1
		} else {
			n += 1
		}
	}
	if failed > 0 {
		log_line(t, "The data folder could not be cleared: close any program using its files and Build again.")
		return false
	}
	logf(t, "Cleared the data folder %s (%d items deleted; the saves, settings, Android key and ffmpeg/ stay).", data_dir, n)
	return true
}
