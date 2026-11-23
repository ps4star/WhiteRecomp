// The Cross-Compile tab: builds the game for another kind of computer than the one the launcher runs on (Linux on
// ARM64: a Raspberry Pi, an ARM laptop, Asahi Linux on a Mac; Android on ARM64: phones, tablets, handhelds), from any
// launcher -- Windows or Linux, x86-64.
// The same Build as the Home tab's (build_game.odin), with the Options tab's options, but:
//   - the compiler is Clang (every Clang can target every architecture) with LLVM's linker, lld (it links ELF files
//     on Windows too), told the target (--target=aarch64-linux-gnu) and the target's system files: the bundle carries
//     them (cross/linux_arm64/sysroot: the C library, kernel headers, libgcc, OpenSSL, zlib, zstd -- Ubuntu's ARM64
//     packages, trimmed: tools/arm64_toolchain.sh) with that target's FFmpeg (cross/linux_arm64/ffmpeg/lib)
//   - CPU: -mcpu=<the chosen CPU> instead of -march=native (the machine that builds is not the one that plays)
//   - its own objects (data dir obj-<target>/) and output folder beside the launcher (WhiteRecomp-<target>/): the
//     program, a WhiteRecomp.cfg whose paths start with ./ (the game reads them from its own folder:
//     src/runtime/xrc_rt.c load_cfg), an empty cdrive/ for the saves, and a README.txt that says how to set it up there
// Android (ARM64) differs again: the game is the app's libmain.so (a NativeActivity: src/runtime/xrc_android.c),
// position-independent, linked against the bundle's Android system files (cross/android_arm64/sysroot: Android 10's
// API, no NDK needed) with Clang's runtime for it named outright (another computer's Clang has none); no FFmpeg (no
// cutscenes yet); and the launcher packs it into WhiteRecomp.apk itself (apk.odin), with the options as the APK's
// WhiteRecomp.cfg asset.
// --cross-build <target> on the command line does the same without a window.
package launcher

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "shared:iv_system/ren"
import ui "shared:iv_ui"

Cross_Cpu :: struct {
	key:  string, // -mcpu=
	name: string,
}

Cross_Target :: struct {
	key:     string, // the bundle's cross/<key>/, and the names of its objects' and output folders
	name:    string,
	triple:  string,
	cpus:    []Cross_Cpu,
	note:    string, // (the tab's line about it)
	android: bool,
}

cross_targets := []Cross_Target {
	{
		key = "linux_arm64",
		name = "Linux ARM64",
		triple = "aarch64-linux-gnu",
		cpus = {
			{"generic", "Any ARM64 CPU (Default)"},
			{"cortex-a72", "Raspberry Pi 4 (Cortex-A72)"},
			{"cortex-a76", "Raspberry Pi 5 (Cortex-A76)"},
			{"apple-m1", "Apple M1 / M2 (Asahi Linux)"},
			{"neoverse-n1", "Ampere / Graviton 2 servers"},
		},
		note = "64-bit ARM Linux (glibc 2.34 or newer: Debian 12, Ubuntu 22.04, Raspberry Pi OS 12 and later)",
	},
	{
		key = "android_arm64",
		name = "Android ARM64",
		triple = "aarch64-linux-android29",
		cpus = {
			{"generic", "Any ARM64 phone (Default)"},
			{"cortex-a76", "2019 and later flagships (Cortex-A76)"},
			{"cortex-x1", "2021 and later flagships (Cortex-X1)"},
		},
		note = "Android 10 or newer, 64-bit ARM, Vulkan: an APK to install (no cutscenes yet)",
		android = true,
	},
}

// what a target's Build makes in its folder: the program, or Android's APK
cross_out_file :: proc(x: ^Cross_Target) -> string {
	if x.android {return GAME_NAME + ".apk"}
	return appimage_on({cross = x}) ? appimage_file(appimage_arch({cross = x})) : GAME_NAME
}

cross_target :: proc() -> ^Cross_Target {
	for &x in cross_targets {if x.key == settings.cross_target {return &x}}
	return &cross_targets[0]
}

cross_cpu :: proc(x: ^Cross_Target) -> string {
	for c in x.cpus {if c.key == settings.cross_cpu {return c.key}}
	return x.cpus[0].key
}

// where a target's game is built: a folder beside the launcher
cross_out_dir :: proc(x: ^Cross_Target) -> string {
	k, _ := strings.replace_all(x.key, "_", "-", context.temp_allocator)
	return pjoin({game_out_dir(), fmt.tprintf("%s-%s", GAME_NAME, k)}, context.temp_allocator)
}

// The cross toolchain: a Clang (the chosen compiler if it is one, else any found) and LLVM's linker (beside it, else
// in PATH, as ld.lld or a versioned ld.lld-N). why: what is missing ("" when both are there).
cross_toolchain :: proc() -> (cc, lld, why: string) {
	for c in compilers_get() {if c.clang && c.path == settings.compiler {cc = c.path}}
	if cc == "" {for c in compilers_get() {if c.clang {cc = c.path; break}}}
	if cc == "" {
		return "", "", "Needs Clang (GCC compiles only for its own computer): install Clang, then Check again on the Home tab."
	}
	lld = lld_beside(cc)
	if lld == "" {lld = find_program("ld.lld")}
	if lld == "" {for v := 30; v >= 10 && lld == ""; v -= 1 {lld = find_program(fmt.tprintf("ld.lld-%d", v))}}
	if lld == "" {
		when ODIN_OS == .Windows {why = "Needs LLVM's linker (ld.lld.exe) beside Clang: LLVM-MinGW and MSYS2's Clang have it."} else {why = "Needs LLVM's linker, lld (e.g. sudo apt install lld)."}
	}
	return
}

cross_build_task :: proc(t: ^Task) {
	x := cross_target()
	cc, lld, why := cross_toolchain()
	if why != "" {log_line(t, why); t.failed = true; return}
	src := data_path("cross", x.key)
	spec := Build_Spec {
		cross     = x,
		cc        = cc,
		lld       = lld,
		cpu       = cross_cpu(x),
		sysroot   = pjoin({src, "sysroot"}, context.allocator),
		ffdir     = pjoin({src, "ffmpeg"}, context.allocator),
		obj       = data_path(fmt.tprintf("obj-%s", x.key)),
		out_dir   = cross_out_dir(x),
	}
	if x.android {spec.ffdir = ""}
	logf(t, "Target: %s, CPU %s", x.name, spec.cpu)
	logf(t, "Linker: %s", lld)
	build_task(t, spec)
}

// the output folder's README.txt and WhiteRecomp.cfg (paths from the game's own folder); Android: the APK (from the
// linked lib), its README
cross_write_extras :: proc(t: ^Task, x: ^Cross_Target, dir, lib: string, appimage := false) -> bool {
	if x.android {return android_write_output(t, x, dir, lib)}
	if appimage {return cross_write_appimage(t, x, dir, lib)}
	_ = os.remove(pjoin({dir, appimage_file(appimage_arch({cross = x}))}, context.temp_allocator)) // (an earlier AppImage build's)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "# WhiteRecomp's settings for %s, written by the launcher's Cross-Compile Build.\n", x.name)
	fmt.sbprintf(&b, "# A path that starts with ./ is from this folder. The environment overrides any of them.\n")
	fmt.sbprintf(&b, "XRC_GAME_DIR=./FINAL FANTASY XIII\n")
	fmt.sbprintf(&b, "XRC_EXE=./FINAL FANTASY XIII/white_data/prog/win/bin/ffxiiiimg.exe\n")
	fmt.sbprintf(&b, "XRC_CDRIVE=./cdrive\n")
	cfg_game_lines(&b)
	if os.write_entire_file(pjoin({dir, GAME_NAME + ".cfg"}, context.temp_allocator), b.buf[:]) != nil {return false}
	_ = os.make_directory_all(pjoin({dir, "cdrive"}, context.temp_allocator))
	if x.key == "linux_arm64" { 	// (Steam's x86-64 helper, beside the game: src/runtime/host_steam.c looks there)
		if h, hok := bundle_read(STEAMHELPER_LINUX, context.temp_allocator); hok {
			hp := pjoin({dir, "steamhelper_linux_x64"}, context.temp_allocator)
			_ = os.write_entire_file(hp, h)
			when ODIN_OS != .Windows {_ = os.chmod(hp, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other})}
		}
	}
	r := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&r, "WhiteRecomp for %s\n", x.name)
	fmt.sbprintf(&r, "==========================\n\n")
	fmt.sbprintf(&r, "Built by the WhiteRecomp launcher's Cross-Compile tab, for another computer (CPU: %s).\n\n", cross_cpu(x))
	fmt.sbprintf(&r, "To play there:\n")
	fmt.sbprintf(&r, "  1. Copy this whole folder to that computer.\n")
	fmt.sbprintf(&r, "  2. Put your FINAL FANTASY XIII folder (the one with white_data in it) inside it, named \"FINAL FANTASY XIII\",\n")
	fmt.sbprintf(&r, "     or link it there:   ln -s \"/path/to/FINAL FANTASY XIII\" \"FINAL FANTASY XIII\"\n")
	fmt.sbprintf(&r, "     (or change XRC_GAME_DIR and XRC_EXE in %s.cfg to where it is).\n", GAME_NAME)
	fmt.sbprintf(&r, "     Converted cutscenes (white_data/movie/*.mp4) come with it: convert them on a Windows PC first.\n")
	fmt.sbprintf(&r, "  3. Run ./%s  (it needs Vulkan graphics drivers and SDL2: e.g. sudo apt install libsdl2-2.0-0 mesa-vulkan-drivers,\n", GAME_NAME)
	fmt.sbprintf(&r, "     and OpenSSL 3, which every current distribution has).\n\n")
	if x.key == "linux_arm64" {
		fmt.sbprintf(&r, "Steam (achievements, cloud saves, \"Playing\" on your profile): start Steam first. It runs on ARM64 under FEX or\n")
		fmt.sbprintf(&r, "Box64, and so does steamhelper_linux_x64 here, which the game starts for it (chmod +x it if the copy lost that).\n\n")
	}
	fmt.sbprintf(&r, "Saves go in cdrive/ here. To bring your saves from the PC, copy the launcher's cdrive folder over this one.\n")
	return os.write_entire_file(pjoin({dir, "README.txt"}, context.temp_allocator), r.buf[:]) == nil
}

// As AppImage: WhiteRecomp-<arch>.AppImage (its .cfg inside: the game's options; the install and the saves beside it,
// set by its AppRun) and README.txt -- in place of the program, its .cfg and cdrive/ (an earlier plain build's go)
@(private = "file")
cross_write_appimage :: proc(t: ^Task, x: ^Cross_Target, dir, exe: string) -> bool {
	arch := appimage_arch({cross = x})
	name := appimage_file(arch)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "# WhiteRecomp's settings for %s, written by the launcher's Cross-Compile Build (inside its AppImage).\n", x.name)
	fmt.sbprintf(&b, "# The game's install and the saves are beside the .AppImage (its AppRun). The environment overrides any of them.\n")
	cfg_game_lines(&b, {cross = x})
	if !appimage_pack(t, pjoin({dir, name}, context.temp_allocator), exe, strings.to_string(b), arch, portable = true) {return false}
	_ = os.remove(pjoin({dir, GAME_NAME}, context.temp_allocator))
	_ = os.remove(pjoin({dir, GAME_NAME + ".cfg"}, context.temp_allocator))
	if os.is_dir(pjoin({dir, "cdrive"}, context.temp_allocator)) {_ = os.remove(pjoin({dir, "cdrive"}, context.temp_allocator))} // (only when empty)
	r := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&r, "WhiteRecomp for %s (AppImage)\n", x.name)
	fmt.sbprintf(&r, "======================================\n\n")
	fmt.sbprintf(&r, "Built by the WhiteRecomp launcher's Cross-Compile tab, for another computer (CPU: %s).\n\n", cross_cpu(x))
	fmt.sbprintf(&r, "To play there:\n")
	fmt.sbprintf(&r, "  1. Copy %s to a folder on that computer.\n", name)
	fmt.sbprintf(&r, "  2. Put your FINAL FANTASY XIII folder (the one with white_data in it) next to it, named \"FINAL FANTASY XIII\",\n")
	fmt.sbprintf(&r, "     or link it there:   ln -s \"/path/to/FINAL FANTASY XIII\" \"FINAL FANTASY XIII\"\n")
	fmt.sbprintf(&r, "     (or start it with XRC_GAME_DIR set to where it is).\n")
	fmt.sbprintf(&r, "     Converted cutscenes (white_data/movie/*.mp4) come with it: convert them on a Windows PC first.\n")
	fmt.sbprintf(&r, "  3. chmod +x %s, then run ./%s\n", name, name)
	fmt.sbprintf(&r, "     It needs Vulkan graphics drivers and SDL2 (e.g. sudo apt install libsdl2-2.0-0 mesa-vulkan-drivers),\n")
	fmt.sbprintf(&r, "     OpenSSL 3, and FUSE 2 to open AppImages (sudo apt install libfuse2, or libfuse2t64). Without FUSE:\n")
	fmt.sbprintf(&r, "     ./%s --appimage-extract-and-run\n\n", name)
	fmt.sbprintf(&r, "Saves go in cdrive/ next to the AppImage. To bring your saves from the PC, copy the launcher's cdrive folder there.\n")
	return os.write_entire_file(pjoin({dir, "README.txt"}, context.temp_allocator), r.buf[:]) == nil
}

// ---------------------------------------------------------------------------------------------- the tab
draw_cross :: proc(g: ^Gui, r: ui.Rect) {
	running := sync.atomic_load(&task.running)
	active := !running
	gs := get_game()
	x := cross_target()
	cc, lld, why := cross_toolchain()

	bottom, top := ui.cut_bottom(r, px(g, 44))
	_, top = ui.cut_bottom(top, px(g, 16))
	ai_row: ui.Rect // (a Linux target: As AppImage, above the Build button)
	if !x.android {
		ai_row, top = ui.cut_bottom(top, px(g, 32))
		_, top = ui.cut_bottom(top, px(g, 10))
	}
	head, rest := ui.cut_top(top, px(g, 24))
	label(g, g.font, "Builds the game for another kind of computer, with the Options tab's options. It runs there, not here.", head, DIM)
	_, rest = ui.cut_top(rest, px(g, 8))

	row_h := px(g, 46)
	nrows := x.android ? 6 : 5
	oc, after := ui.cut_top(rest, nrows * row_h + px(g, 16))
	card(g, oc)
	oi := ui.inset_xy(oc, px(g, 20), px(g, 8))
	label_w, ctrl_w := px(g, 230), px(g, 270)
	row := 0
	changed := false
	next :: proc(g: ^Gui, oi: ui.Rect, row: ^int, row_h, label_w, ctrl_w: int, name: string) -> (ctrl, note: ui.Rect) {
		y := oi.y + row^ * row_h
		if row^ > 0 {ren.draw_rect(g.dl, {oi.x, y, oi.w, 1}, CARD_BORDER)}
		label(g, g.font, name, {oi.x, y, label_w, row_h}, TEXT)
		ctrl = {oi.x + label_w, y + (row_h - px(g, 32)) / 2, ctrl_w, px(g, 32)}
		note = {ctrl.x + ctrl_w + px(g, 16), y, oi.w - label_w - ctrl_w - px(g, 16), row_h}
		row^ += 1
		return
	}
	// Target
	{
		ctrl, note := next(g, oi, &row, row_h, label_w, ctrl_w, "Target:")
		names := make([]string, len(cross_targets), context.temp_allocator)
		sel := 0
		for t, i in cross_targets {
			names[i] = t.name
			if t.key == x.key {sel = i}
		}
		if n, ch := dropdown(g, "xtarget", ctrl, names, sel, active = active); ch {settings.cross_target = cross_targets[n].key; changed = true}
		label(g, g.small, x.note, note, DIM)
	}
	// CPU
	{
		ctrl, note := next(g, oi, &row, row_h, label_w, ctrl_w, "CPU:")
		names := make([]string, len(x.cpus), context.temp_allocator)
		sel := 0
		cur := cross_cpu(x)
		for c, i in x.cpus {
			names[i] = c.name
			if c.key == cur {sel = i}
		}
		if n, ch := dropdown(g, "xcpu", ctrl, names, sel, active = active); ch {settings.cross_cpu = x.cpus[n].key; changed = true}
		label(g, g.small, sel == 0 ? (x.android ? "Runs on every 64-bit ARM phone" : "Runs on every ARM64 CPU") : "Faster there, but only that CPU and newer ones", note, DIM)
	}
	// Android: built with the Options tab as set; Use Android Preset sets it for a phone (options.odin apply_android_preset)
	if x.android {
		ctrl, note := next(g, oi, &row, row_h, label_w, ctrl_w, "Settings:")
		if button(g, ctrl, "Use Android Preset", active) {apply_android_preset()}
		tooltip_zone(g, "xpreset", ctrl, "Sets the Options tab for a phone: 960x540, 60 fps, 512 shadows, anti-aliasing off, half-resolution effects, 4 GB memory, -O1, 2 pipeline threads. Builds for this computer use them too.")
		label(g, g.small, "Sets the Options tab: 960x540, 60 fps, light graphics", note, DIM)
	}
	// Compiler and linker
	{
		ctrl, note := next(g, oi, &row, row_h, label_w, ctrl_w, "Compiler:")
		if !deps_checked {
			label(g, g.font, "Looking for compilers…", ctrl, DIM)
		} else if cc == "" {
			label(g, g.font, "No Clang found", ctrl, BAD)
			label(g, g.small, why, note, BAD)
		} else {
			label(g, g.font, compiler_label(cc), ctrl, TEXT)
			label(g, g.small, cc, note, DIM)
		}
	}
	{
		ctrl, note := next(g, oi, &row, row_h, label_w, ctrl_w, "Linker:")
		if cc != "" && lld == "" {
			label(g, g.font, "No lld found", ctrl, BAD)
			label(g, g.small, why, note, BAD)
		} else if lld != "" {
			label(g, g.font, "LLVM lld", ctrl, TEXT)
			label(g, g.small, lld, note, DIM)
		}
	}
	// Output
	out := cross_out_dir(x)
	{
		ctrl, note := next(g, oi, &row, row_h, label_w, ctrl_w, "Output:")
		have := file_exists(pjoin({out, cross_out_file(x)}, context.temp_allocator))
		label(g, g.font, have ? "Built" : "Not built yet", ctrl, have ? GOOD : DIM)
		label(g, g.small, out, note, DIM)
	}
	if changed {save_settings()}

	// the button, and what is running
	build_r, left := ui.cut_right(bottom, px(g, 220), px(g, 8))
	build_r = ui.Rect{build_r.x, build_r.y, build_r.w, px(g, 44)}
	can := active && gs.ok && why == "" && deps_checked
	if button(g, build_r, fmt.tprintf("Build for %s", x.name), can, primary = true, f = g.bold) {
		task_start(fmt.tprintf("Build for %s", x.name), proc(t: ^Task) {cross_build_task(t)})
	}
	if !x.android && appimage_switch(g, "xappimage", build_r, ai_row, &settings.cross_appimage, active) {save_settings()}
	tip := running ? "Wait for the current task to finish." : !gs.ok ? "Needs the game (its exe is read for the build): choose its folder on the Home tab." : why != "" ? why : fmt.tprintf("Builds the game for %s into %s.", x.name, out)
	tooltip_zone(g, "xbuild", build_r, tip)
	if running {
		cr := ui.Rect{left.x, build_r.y + px(g, 6), px(g, 100), px(g, 32)}
		if button(g, cr, "Cancel") {task_cancel()}
	}
	_, after = ui.cut_top(after, px(g, 10))
	draw_task(g, after, running)
}
