// Where the launcher keeps things, its settings, and finding programs.
//   data dir:  Windows %LOCALAPPDATA%\ff13-launcher, macOS ~/Library/Application Support/ff13-launcher,
//              Linux $XDG_DATA_HOME/ff13-launcher (~/.local/share/ff13-launcher)
//     src/     the bundled sources, unpacked by Build      obj/   their objects
//     (the built game, WhiteRecomp / WhiteRecomp.exe with its WhiteRecomp.cfg, is beside the launcher: build_game.odin)
//     cdrive/  the game's C: drive (its saves and settings: the install itself is mapped in, XRC_GAME_DIR)
//     tools/   bundled tools (bink2mp4.exe, steamhelper.exe)
//     ffmpeg/  (the player's, never written by the launcher) another FFmpeg build to link the game with: lib/ (libavformat.a,
//              libavcodec.a, libswresample.a, libavutil.a) and include/; without it, the bundled one (src/ffmpeg)
//     settings.txt
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

EXE_SUFFIX :: ".exe" when ODIN_OS == .Windows else ""
PATH_SEP :: ";" when ODIN_OS == .Windows else ":"

data_dir: string

init_paths :: proc() {
	base := ""
	when ODIN_OS == .Windows {
		base = os.get_env("LOCALAPPDATA", context.allocator)
	} else when ODIN_OS == .Darwin {
		base = pjoin({os.get_env("HOME", context.temp_allocator), "Library", "Application Support"})
	} else {
		base = os.get_env("XDG_DATA_HOME", context.allocator)
		if base == "" {base = pjoin({os.get_env("HOME", context.temp_allocator), ".local", "share"})}
	}
	if base == "" {base = "."}
	data_dir = pjoin({base, "ff13-launcher"}, context.allocator)
	_ = os.make_directory_all(data_dir)
}

// macOS: the Frameworks folder of the launcher's .app (Contents/MacOS/<launcher> -> Contents/Frameworks), "" when it
// does not run from one
app_frameworks_dir :: proc() -> string {
	d, err := os.get_executable_directory(context.temp_allocator)
	if err != nil || filepath.base(d) != "MacOS" {return ""}
	fw := pjoin({filepath.dir(d), "Frameworks"}, context.temp_allocator)
	return os.is_dir(fw) ? fw : ""
}

data_path :: proc(parts: ..string) -> string {
	all := make([dynamic]string, context.temp_allocator)
	append(&all, data_dir)
	append(&all, ..parts)
	return pjoin(all[:], context.temp_allocator)
}

// filepath.join that returns only the path (in the temp allocator unless told)
pjoin :: proc(parts: []string, allocator := context.temp_allocator) -> string {
	s, _ := filepath.join(parts, allocator)
	return s
}

file_exists :: proc(p: string) -> bool {return os.exists(p) && !os.is_dir(p)}
dir_exists :: proc(p: string) -> bool {return os.is_dir(p)}

// A program's full path: an absolute path that exists, or a name searched for in PATH (with .exe on Windows).
find_program :: proc(name: string) -> string {
	if filepath.is_abs(name) {return strings.clone(name) if file_exists(name) else ""}
	exe := name
	when ODIN_OS == .Windows {
		if !strings.has_suffix(strings.to_lower(name, context.temp_allocator), ".exe") {exe = strings.concatenate({name, ".exe"}, context.temp_allocator)}
	}
	path := os.get_env("PATH", context.temp_allocator)
	when ODIN_OS == .Windows {path = strings.join({path, registry_path()}, PATH_SEP, context.temp_allocator)}
	for dir in strings.split(path, PATH_SEP, context.temp_allocator) {
		if dir == "" {continue}
		p := pjoin({strings.trim(dir, "\""), exe}, context.temp_allocator)
		if file_exists(p) {return strings.clone(p)}
	}
	return ""
}

// ---------------------------------------------------------------------------------------------- settings
// settings.txt: one "key value" per line. The build options (options.odin) are read when the game is built.
Settings :: struct {
	game_dir:        string, // the install ("FINAL FANTASY XIII", the folder with white_data)
	compiler:        string, // the C compiler's path ("": not chosen yet -- the best one found, Clang first)
	opt_level:       int, // -O0 .. -O3
	audio:           bool,
	tools:           bool, // the debugging and profiling switches (XRC_PROFILE, XRC_TRACE_*, ...)
	fps:             int, // 30 or 60
	vulkan:          bool, // Graphics Driver: Vulkan, the default (else Direct3D 9, Windows only)
	skip_movies:     bool, // Cutscenes: Auto-skip
	movie_bink:      bool, // Cutscene Files: Bink2 (the game's .wmp files through its translated bink2w32.dll: XRC_MOVIES=bink in the .cfg), else MP4
	pad_once:        bool, // Gamepad Scanning: Once (-DXRC_PAD_ONCE); else every 2 seconds
	pipe_threads:    int, // Pipeline Build Threads: the renderer's pipeline builders (XRC_VK_PIPE_THREADS in the .cfg; 0: the best, options.odin)
	resolution:      int, // Resolution: an index into RESOLUTIONS (options.odin) -- the game's -Width= / -Height=
	graphics:        int, // Graphics: a preset of the three below (GRAPHICS_PRESETS), or GRAPHICS_CUSTOM -- them as set
	shadow_res:      int, // Shadow Resolution: the game's -Shadow=N (512 .. 8192; 0: Off -- no shadows, XRC_NO_SHADOWS)
	aa_fxaa:         bool, // Anti-alias Method: FXAA (a post-process at present: XRC_FXAA=quality in the .cfg, the game's -MSAA=0), else MSAA (the game's -MSAA=quality)
	aa_quality:      int, // Anti-alias Quality: 1 (off), 2, 4, 8
	experimental:    bool, // Experimental Optimizations: -DXRC_EXPERIMENTAL
	lto:             bool, // Link-Time Optimization: -flto
	pgo:             bool, // Profile-Guided Optimization (Clang): the bundled profile
	stretch:         bool, // Window Scaling: Stretch -- the picture fills the window, proportions not kept (XRC_STRETCH=1 in the .cfg); else Fit
	memory_2gb:      bool, // Memory: 2 GB, as the original exe gets (XRC_GUEST_2GB=1 in the .cfg); else 4 GB
	fx_full:         bool, // Effects Resolution: Full (XRC_VK_HALF_FX=0 in the .cfg); else Half, the default (vk_d3d9.c)
	steam_off:       bool, // Steam Integration: Off (XRC_NO_STEAM=1 in the .cfg); else On, the default (host_steam.c; Windows, Linux)
	voice_jp:        bool, // Features & Mods > Voice: Japanese (the game's -VoiceJPMode); else English
	subs:            int,  // Features & Mods > Subtitles & UI: an index of SUBTITLE_IDS (features.odin; XRC_LANGUAGE), 0 = English
	cross_target:    string, // the Cross-Compile tab's Target (cross.odin: a Cross_Target key; "": the first)
	cross_cpu:       string, // its CPU (-mcpu=; "": the target's first, generic)
	appimage:        bool, // Home tab's "As AppImage" (Linux launchers): the game as WhiteRecomp-<arch>.AppImage (appimage.odin)
	cross_appimage:  bool, // the Cross-Compile tab's, for its Linux targets
}
settings := Settings {
	opt_level       = 1,
	audio           = true,
	fps             = 60,
	vulkan          = true,
	graphics        = GRAPHICS_FANCY,
	resolution      = RES_DEFAULT,
	pgo             = true,
	shadow_res      = 1024,
	aa_fxaa         = true,
	aa_quality      = 4,
}

load_settings :: proc() {
	d, err := os.read_entire_file(data_path("settings.txt"), context.temp_allocator)
	if err != nil {return}
	version := 1 // (settings_version: 2 since Vulkan became the default; a version 1 file's "vulkan 0" was the old default; 4 since Graphics)
	for line in strings.split_lines(string(d), context.temp_allocator) {
		k, _, v := strings.partition(strings.trim_space(line), " ")
		if k == "settings_version" {version, _ = strconv.parse_int(strings.trim_space(v))}
	}
	for line in strings.split_lines(string(d), context.temp_allocator) {
		k, _, v := strings.partition(strings.trim_space(line), " ")
		v = strings.trim_space(v)
		n, n_ok := strconv.parse_int(v)
		switch k {
		case "game_dir":
			settings.game_dir = strings.clone(v)
		case "compiler":
			settings.compiler = strings.clone(v)
		case "opt_level":
			if n_ok && n >= 0 && n <= 3 {settings.opt_level = n}
		case "audio":
			settings.audio = v != "0"
		case "tools":
			settings.tools = v == "1"
		case "fps":
			if n_ok && (n == 30 || n == 60) {settings.fps = n}
		case "vulkan":
			settings.vulkan = true // (the only renderer since 2026-11-22: Windows' D3D9 choice was removed)
		case "skip_movies":
			settings.skip_movies = v == "1"
		case "movie_files":
			settings.movie_bink = v == "bink"
		case "pad_once":
			settings.pad_once = v == "1"
		case "pipe_threads":
			if n_ok && n >= 0 && n <= 16 {settings.pipe_threads = n}
		case "resolution": // ("WxH": one of RESOLUTIONS, else the default)
			for r, i in RESOLUTIONS {if v == fmt.tprintf("%dx%d", r.w, r.h) {settings.resolution = i}}
		case "shadow_res":
			if n_ok && (n == 0 || (n >= 512 && n <= 8192)) {settings.shadow_res = n}
		case "experimental":
			settings.experimental = v == "1"
		case "lto":
			settings.lto = v == "1"
		case "pgo":
			settings.pgo = v != "0"
		case "memory_2gb":
			settings.memory_2gb = v == "1"
		case "stretch":
			settings.stretch = v == "1"
		case "fx_full":
			settings.fx_full = v == "1"
		case "steam_off":
			settings.steam_off = v == "1"
		case "voice":
			settings.voice_jp = v == "japanese"
		case "subtitles":
			settings.subs = 0
			for id, k in SUBTITLE_IDS {if v == id {settings.subs = k}}
		case "cross_target":
			settings.cross_target = strings.clone(v)
		case "cross_cpu":
			settings.cross_cpu = strings.clone(v)
		case "appimage":
			settings.appimage = v == "1"
		case "cross_appimage":
			settings.cross_appimage = v == "1"
		case "msaa": // (before version 3: MSAA only; Off kept, any other the new default, FXAA 4x)
			if version < 3 && n_ok && n == 0 {settings.aa_quality = 1}
		case "aa_method":
			if version >= 3 {settings.aa_fxaa = v == "fxaa"}
		case "aa_quality":
			if version >= 3 && n_ok && (n == 1 || n == 2 || n == 4 || n == 8) {settings.aa_quality = n}
		case "graphics":
			keys := GRAPHICS_KEYS
			for name, i in keys {if v == name {settings.graphics = i}}
		}
	}
	// (before version 4, no Graphics: the preset the settings match, else Custom -- kept as they were)
	if version < 4 {settings.graphics = graphics_matching()}
	graphics_apply()
}

save_settings :: proc() {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "settings_version 4\n")
	fmt.sbprintf(&b, "game_dir %s\n", settings.game_dir)
	fmt.sbprintf(&b, "compiler %s\n", settings.compiler)
	fmt.sbprintf(&b, "opt_level %d\n", settings.opt_level)
	fmt.sbprintf(&b, "audio %d\n", settings.audio ? 1 : 0)
	fmt.sbprintf(&b, "tools %d\n", settings.tools ? 1 : 0)
	fmt.sbprintf(&b, "fps %d\n", settings.fps)
	fmt.sbprintf(&b, "vulkan %d\n", settings.vulkan ? 1 : 0)
	fmt.sbprintf(&b, "skip_movies %d\n", settings.skip_movies ? 1 : 0)
	fmt.sbprintf(&b, "movie_files %s\n", settings.movie_bink ? "bink" : "mp4")
	fmt.sbprintf(&b, "pad_once %d\n", settings.pad_once ? 1 : 0)
	fmt.sbprintf(&b, "pipe_threads %d\n", settings.pipe_threads)
	keys := GRAPHICS_KEYS
	fmt.sbprintf(&b, "graphics %s\n", keys[clamp(settings.graphics, 0, GRAPHICS_CUSTOM)])
	{
		res := RESOLUTIONS
		r := res[clamp(settings.resolution, 0, len(res) - 1)]
		fmt.sbprintf(&b, "resolution %dx%d\n", r.w, r.h)
	}
	fmt.sbprintf(&b, "shadow_res %d\n", settings.shadow_res)
	fmt.sbprintf(&b, "aa_method %s\n", settings.aa_fxaa ? "fxaa" : "msaa")
	fmt.sbprintf(&b, "aa_quality %d\n", settings.aa_quality)
	fmt.sbprintf(&b, "experimental %d\n", settings.experimental ? 1 : 0)
	fmt.sbprintf(&b, "lto %d\n", settings.lto ? 1 : 0)
	fmt.sbprintf(&b, "pgo %d\n", settings.pgo ? 1 : 0)
	fmt.sbprintf(&b, "memory_2gb %d\n", settings.memory_2gb ? 1 : 0)
	fmt.sbprintf(&b, "stretch %d\n", settings.stretch ? 1 : 0)
	fmt.sbprintf(&b, "fx_full %d\n", settings.fx_full ? 1 : 0)
	fmt.sbprintf(&b, "steam_off %d\n", settings.steam_off ? 1 : 0)
	fmt.sbprintf(&b, "voice %s\n", settings.voice_jp ? "japanese" : "english")
	fmt.sbprintf(&b, "subtitles %s\n", subtitle_id(settings.subs))
	fmt.sbprintf(&b, "cross_target %s\n", settings.cross_target)
	fmt.sbprintf(&b, "cross_cpu %s\n", settings.cross_cpu)
	fmt.sbprintf(&b, "appimage %d\n", settings.appimage ? 1 : 0)
	fmt.sbprintf(&b, "cross_appimage %d\n", settings.cross_appimage ? 1 : 0)
	_ = os.write_entire_file(data_path("settings.txt"), b.buf[:])
}
