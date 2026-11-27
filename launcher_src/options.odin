// The build options (the Options tab; kept in settings.txt) and what they make of the game's build:
//   Compiler                  the C compiler (deps.odin finds them; Clang first: it makes the faster game; GCC on Linux too)
//   Optimization Level        -O0 (the fastest build, the slowest game) .. -O3; 1 is the default
//   Audio                     OFF: -DXRC_NO_AUDIO -- no sound output, no mixing, no movie audio thread, no XAudio2
//                             (the game's own audio engine is a silent stand-in that only keeps its time)
//   Debug & Profile Tools     OFF: -DXRC_NO_TOOLS -- the XRC_PROFILE / XRC_TRACE_* / log switches cannot be turned on,
//                             nothing is printed (src/runtime/xrc_quiet.h) and on Windows there is no console window;
//                             ON: stack dumps and the profiler walk the guest's frame chain for every caller (free);
//                             a build with -DXRC_DEEP_STACKS (pages and runtime: tools/xrc_build.sh XRC_CFLAGS / XRC_DEFS)
//                             records each call instead -- exact, but ~35% slower, so not the launcher's
//   FPS                       -DXRC_FRAME_LIMIT=30|60
//   Graphics Driver           Vulkan, the only one (the launcher always builds it in: -DXRC_VULKAN; Windows' real Direct3D 9
//                             path was removed 2026-11-22)
//   Gamepad Scanning          Once: -DXRC_PAD_ONCE -- the game controllers looked for once, at the start (else every 2
//                             seconds, the default: the game asks that often; src/runtime/hle_dinput.c)
//   Cutscenes                 Auto-skip: -DXRC_SKIP_MOVIES (every movie skipped)
//   Aspect Ratio              16:9, 16:10, Ultrawide or 4:3: which resolutions the Resolution dropdown shows (not saved
//                             itself: the resolution's; RESOLUTIONS)
//   Pipeline Build Threads    XRC_VK_PIPE_THREADS=N in WhiteRecomp.cfg (no Build needed): the threads that make the
//                             renderer's pipelines in the background (vk_d3d9.c pj_threads); Best (0, the default):
//                             none written, the game's own default (half the CPU threads, 1 to 8)
//   Graphics                  a preset of the three below (FXAA always): Ultrafast (no shadows, no anti-aliasing), Fast
//                             (512 shadows, 2x FXAA), Fancy (the default: 1024, 4x FXAA), Ultrafancy (8192, 8x
//                             FXAA); or Custom, which shows the three (indented) and keeps them as set
//   Shadow Resolution         the game's own arguments, as the retail launcher passes them: -Shadow=512..8192 (the
//   Anti-Aliasing             game's default 1024; Off: -Shadow=512 and XRC_NO_SHADOWS=1, nothing drawn into the
//                             shadow maps) and -MSAA=0|2|4|8 -- in WhiteRecomp.cfg (XRC_GAME_ARGS), not the build: a
//                             change rewrites the .cfg of a built game at once (build_game.odin). Anti-aliasing is two
//                             settings: Method MSAA (the game's -MSAA=Quality) or FXAA (the default: -MSAA=0 and
//                             XRC_FXAA=Quality, a filter on the 3D image before the HUD -- vk_d3d9.c), Quality 1x (off),
//                             2x, 4x (the default), 8x
//   Effects Resolution        Half (the default) or Full: the blended effects that add light (fire, sparks, magic)
//                             drawn into a half-size image and added to the 3D image (vk_d3d9.c, Vulkan only); Full:
//                             XRC_VK_HALF_FX=0 in WhiteRecomp.cfg, no Build needed
//   Anisotropic Filtering     On (the default) or Off: 16x anisotropic filtering (at most what the GPU has) on every
//                             filtered mipmapped texture, not only where the game asks for it: XRC_VK_ANISO=16 in
//                             WhiteRecomp.cfg, no Build needed (vk_d3d9.c sampler_for); Off in the Android preset
//                             (a phone's memory bandwidth)
//   Steam Integration         On (the default) or Off: achievements, cloud saves (Windows: through
//                             tools/steamhelper.exe; Linux x86-64, macOS: the player's own steamclient.so / .dylib;
//                             Linux ARM64: tools/steamhelper_linux_x64 through FEX / Box64) and Steam's overlay (not macOS, ARM64),
//                             while Steam runs (src/runtime/host_steam.c); Off: XRC_NO_STEAM=1 in
//                             WhiteRecomp.cfg, no Build needed
//   Memory                    4 GB (the default) or 2 GB: the guest address space the game runs in; 2 GB is what the
//                             original exe gets (not large-address-aware): XRC_GUEST_2GB=1 in WhiteRecomp.cfg, no
//                             Build needed (src/runtime/xrc_rt.h's layout)
//   Experimental Optimizations -DXRC_EXPERIMENTAL: less-tested optimizations that may break things (xrc_rt.h)
//   Profile-Guided Optimization  (Clang) -fprofile-instr-use=<the bundle's pgo/ff13.profdata> on every unit: the profile
//                             of a play of the game (the project's tools/xrc_build.sh XRC_PGO: how it is made), so
//                             the compiler lays out and inlines the code for how the game runs (~6% less main-thread
//                             time a frame). Checked first on a small file (an older Clang may not read the profile's
//                             format: then the Build goes on without it). On Windows linked with lld: GNU ld leaves
//                             the profile's .llvm.call-graph-profile section below the image base, and Windows will
//                             not start the game. Off with GCC, or on Windows without lld beside Clang.
//   Link-Time Optimization    -flto (Clang: -flto=thin, on Windows linked with lld; GCC: -flto=auto): optimizing
//                             across files
// Always: -march=native (the build runs on the machine that plays it) and -ffast-math -fno-associative-math when
// compiling (not linking: no flush-to-zero for the whole process; the x86 semantics the translated code needs -- NaN
// compares, conversions -- do not depend on it: src/include/xrc.h tests NaN on the bits; reassociation stays off: it
// cancels the game's own add-and-subtract rounding tricks, and the title menu disappears); on Linux without the distributions' hardening defaults
// (PIE, CET, stack protector: costs, and nothing to protect here)
// The page sources (the translated code) take only the compiler and the optimization level; the runtime takes all.
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

OPT_LEVELS :: [4]string{"0 (Fastest)", "1 (Recommended)", "2", "3 (Slowest)"}
FPS_CHOICES :: [2]int{30, 60}

// Convert Movies' encoder threads: the CPU's threads less one (nproc - 1), at least 1
convert_threads :: proc() -> int {return max(1, os.get_processor_core_count() - 1)}

// Pipeline Build Threads: the most (all the CPU threads but one, at most 16), the best (half of them, at most 8:
// the rest for the game's own threads and the movie conversion), and the one the settings ask for (0: the best)
max_pipe_threads :: proc() -> int {return clamp(os.get_processor_core_count() - 1, 1, 16)}
best_pipe_threads :: proc() -> int {return clamp(os.get_processor_core_count() / 2, 1, 8)}
pipe_threads :: proc() -> int {return settings.pipe_threads == 0 ? best_pipe_threads() : clamp(settings.pipe_threads, 1, max_pipe_threads())}

// The options a Build uses: the player's, for every target (an Android build too: the Cross-Compile tab's Use Android
// Preset sets the Options tab to a phone's, apply_android_preset)
build_settings :: proc(spec: Build_Spec = {}) -> Settings {return settings}

// Use Android Preset (the Cross-Compile tab, Android ARM64): the Options tab set for a phone -- 960x540, 60 fps, the
// lowest graphics but shadows kept (512 shadows, anti-aliasing off, effects at half resolution), 4 GB of memory, -O1
// and 2 pipeline build threads. Sound, cutscenes, tools and the rest stay
// as they are. They are the Options tab's own settings afterwards (a Build for this computer uses them too), and a
// built game's .cfg here is rewritten as an Options change would.
ANDROID_RESOLUTION :: 1 // (960x540: RESOLUTIONS)
ANDROID_FPS :: 60
ANDROID_SHADOW_RES :: 512
ANDROID_OPT_LEVEL :: 1
ANDROID_PIPE_THREADS :: 2
apply_android_preset :: proc() {
	settings.resolution = ANDROID_RESOLUTION
	settings.fps = ANDROID_FPS
	settings.graphics = GRAPHICS_CUSTOM
	settings.shadow_res = ANDROID_SHADOW_RES
	settings.aa_taa = false
	settings.aa_fsr = false
	settings.aa_fxaa = true
	settings.aa_quality = 1
	settings.fx_full = false
	settings.minimap_circle = false
	settings.hdr = false
	settings.fullscreen = false
	settings.aniso = false
	settings.memory_2gb = false
	settings.opt_level = ANDROID_OPT_LEVEL
	settings.pipe_threads = ANDROID_PIPE_THREADS
	save_settings()
	gdir := game_out_dir()
	if file_exists(pjoin({gdir, GAME_NAME + ".cfg"}, context.temp_allocator)) {_ = write_cfg(gdir)}
}

// the flags of every unit (pages and runtime): the host CPU, fast math, LTO, no Linux hardening
// (a cross build, cross.odin: the chosen CPU, and the target's no-hardening flags: ARM64 Linux has branch protection, not CET)
common_flags :: proc(spec: Build_Spec = {}) -> []string {
	f := make([dynamic]string, context.temp_allocator)
	if spec.cross != nil {
		append(&f, fmt.tprintf("-mcpu=%s", spec.cpu))
	} else {
		// (macOS: Apple's Clang may not know -mcpu=native; every Apple-silicon Mac runs the M1's instructions)
		when ODIN_ARCH == .amd64 {append(&f, "-march=native")} else when ODIN_OS == .Darwin {append(&f, "-mcpu=apple-m1")} else {append(&f, "-mcpu=native")}
	}
	append(&f, "-ffast-math", "-fno-associative-math") // (reassociation folds the game's own rounding tricks: a broken title menu)
	// (and no reciprocals: fast math turns x / C into x * (1 / C), 1 ulp off the x86 divide for some inputs -- 2026-11-25,
	// measured not slower; tools/xrc_build.sh)
	append(&f, "-fno-reciprocal-math")
	// (signed zeros and NaNs kept: fast math folds the guest's 0 - x into a negation, -0 for +0, and assumes no NaN in
	// compares -- 2026-11-24, measured not slower; tools/xrc_build.sh)
	// (and no FMA contraction: a fused mulps + addps rounds once, x86 twice -- 1-ulp differences)
	append(&f, "-fsigned-zeros", "-fno-finite-math-only", "-ffp-contract=off")
	// (x86: no reciprocal estimates -- fast math would compute every packed divide as rcpps and a Newton step, a few
	// ulp off and the CPU's own, x / 0 a NaN; tools/xrc_build.sh)
	if spec.cross == nil && ODIN_ARCH == .amd64 {append(&f, "-mrecip=none")}
	if spec.cross != nil && spec.cross.android { 	// (a shared library: position-independent, only the activity's entry exported)
		append(&f, "-fPIC", "-fvisibility=hidden", "-mbranch-protection=none", "-fno-stack-protector")
	} else if spec.cross != nil {
		append(&f, "-fno-pie", "-mbranch-protection=none", "-fno-stack-protector")
	} else {
		when ODIN_OS == .Linux {
			when ODIN_ARCH == .amd64 {append(&f, "-fno-pie", "-fcf-protection=none", "-fno-stack-protector")} else {append(&f, "-fno-pie", "-mbranch-protection=none", "-fno-stack-protector")}
		}
	}
	if lto_on(spec) {append(&f, lto_flag(spec))}
	if pgo_profile != "" {append(&f, fmt.tprintf("-fprofile-instr-use=%s", pgo_profile))}
	return f[:]
}

// the link's own: LTO (the optimization happens there), no PIE on Linux
link_option_flags :: proc(spec: Build_Spec = {}) -> []string {
	f := make([dynamic]string, context.temp_allocator)
	if spec.cross != nil && spec.cross.android {
		// (the app's libmain.so: 16 KB pages, nothing left undefined, the glue's entry kept, symbols stripped; the
		// libraries -- Clang's runtime among them, by path: build_game.odin -- named outright: no default ones)
		append(&f, "-shared", "-fuse-ld=lld", fmt.tprintf("--ld-path=%s", spec.lld), "-Wl,-z,max-page-size=16384", "-Wl,--no-undefined",
		       "-u", "ANativeActivity_onCreate", "-nodefaultlibs", "-s")
		if lto_on(spec) {append(&f, lto_flag(spec), fmt.tprintf("-O%d", clamp(build_settings(spec).opt_level, 0, 3)))}
		return f[:]
	}
	if spec.cross != nil { 	// (always LLVM's linker: it links ELF on any computer)
		append(&f, "-no-pie", "-fuse-ld=lld", fmt.tprintf("--ld-path=%s", spec.lld), "-Wl,-S")
		if lto_on(spec) {append(&f, lto_flag(spec), fmt.tprintf("-O%d", clamp(build_settings(spec).opt_level, 0, 3)))}
		return f[:]
	}
	// (-Wl,-S: no debug info in the game -- only the prebuilt SDL2 library has any, about 10 MB on Windows; the symbol
	// table stays: crash reports name functions from it)
	append(&f, "-Wl,-S")
	when ODIN_OS == .Linux {append(&f, "-no-pie")}
	if lto_on() {
		append(&f, lto_flag(), fmt.tprintf("-O%d", clamp(settings.opt_level, 0, 3)))
		when ODIN_OS == .Windows {if compiler_is_clang() {append(&f, "-fuse-ld=lld")}}
	} else if pgo_profile != "" {
		when ODIN_OS == .Windows {append(&f, "-fuse-ld=lld")} // (see Profile-Guided Optimization above)
	}
	return f[:]
}

// Profile-Guided Optimization: the profile's path while a Build uses it (pgo_prepare), else ""
pgo_profile: string

// why Profile-Guided Optimization cannot be on with these settings ("": it can)
pgo_blocked :: proc(spec: Build_Spec = {}) -> string {
	if spec.cross != nil {return ""} // (Clang and lld)
	if !compiler_is_clang() {return "Needs Clang (GCC cannot read the profile)"}
	when ODIN_OS == .Windows {if lld_path() == "" {return "Needs LLVM's linker (lld) beside Clang: not found"}}
	return ""
}

lto_flag :: proc(spec: Build_Spec = {}) -> string {return spec.cross != nil || compiler_is_clang() ? "-flto=thin" : "-flto=auto"}

// Link-Time Optimization on and possible: on Windows Clang's needs LLVM's linker (lld) beside it (MinGW's GNU ld
// cannot read its objects); on Linux GNU ld reads them through LLVM's plugin
lto_on :: proc(spec: Build_Spec = {}) -> bool {
	if !settings.lto {return false}
	if spec.cross != nil {return true}
	when ODIN_OS != .Windows {return true}
	if !compiler_is_clang() {return true}
	return lld_path() != ""
}

lld_path :: proc() -> string {return lld_beside(settings.compiler)}

// LLVM's linker in a compiler's folder ("": none)
lld_beside :: proc(cc: string) -> string {
	dir := filepath.dir(cc)
	for n in ([]string{"ld.lld.exe", "ld.lld"}) {
		if p := pjoin({dir, n}, context.temp_allocator); file_exists(p) {return p}
	}
	return ""
}

// the flags of the translated pages (gen/src, gen/match)
page_option_flags :: proc(spec: Build_Spec = {}) -> []string {
	f := make([dynamic]string, context.temp_allocator)
	append(&f, fmt.tprintf("-O%d", clamp(build_settings(spec).opt_level, 0, 3)))
	append(&f, ..common_flags(spec))
	append(&f, "-w", "-fno-strict-aliasing", "-fwrapv")
	if spec.cross != nil || compiler_is_clang() {append(&f, "-fno-addrsig")}
	return f[:]
}

// the flags of the runtime (and xrc_table.c): the options as defines
runtime_option_flags :: proc(spec: Build_Spec = {}) -> []string {
	f := make([dynamic]string, context.temp_allocator)
	bs := build_settings(spec)
	append(&f, fmt.tprintf("-O%d", clamp(bs.opt_level, 0, 3)), "-w")
	append(&f, ..common_flags(spec))
	if spec.cross != nil || compiler_is_clang() {append(&f, "-fno-addrsig")}
	append(&f, fmt.tprintf("-DXRC_FRAME_LIMIT=%d", bs.fps == 30 ? 30 : 60))
	if !settings.audio {append(&f, "-DXRC_NO_AUDIO")}
	// (an Android build never has the Debug & Profile Tools: no tracing, profiling or test hooks on a phone, whatever
	// this computer's own build has)
	if !settings.tools || (spec.cross != nil && spec.cross.android) {append(&f, "-DXRC_NO_TOOLS")}
	if movie_skip() {append(&f, "-DXRC_SKIP_MOVIES")} // (also when the game has no cutscene files: main.odin movie_files)
	if settings.pad_once {append(&f, "-DXRC_PAD_ONCE")}
	if settings.experimental {append(&f, "-DXRC_EXPERIMENTAL")}
	return f[:]
}

// Resolution: the game's own -Width= / -Height= (what it renders at: its back buffer and full-screen targets; the
// window is resizable and the picture scaled to fit it). 1280x720 (RES_DEFAULT) passes neither, as before; 854x480 and
// 960x540 below it for slow GPUs. Then the ultrawide ones (21:9, 32:9; RES_ULTRAWIDE on): the runtime draws the 3D across
// the whole width instead of the game's 16:9 pillarbox (xrc_widescreen, hle_d3d9.c: the 13UW mod's patches, Hor+, the HUD
// centred; F5 / F6 / F7 the field of view). 1280x540 first: an ultrawide picture with fewer pixels than 720p (691,200), for
// trying ultrawide on a slow machine. Then 16:10 (RES_16_10 on): the runtime fills them (xrc_widescreen, narrower than 16:9: the 3D Vert+, the HUD
// 1280 x 720 centred in a taller canvas, movies letterboxed -- not the retail game's letterbox of everything); no
// 1280x800 (the game falls back to 1280x720 for a size 1280 wide): 1200x750 instead, fewer pixels than 720p (900,000). The Aspect Ratio dropdown (Display) shows one
// group: res_aspect.
Resolution :: struct {w, h: int}
RESOLUTIONS :: [28]Resolution{{854, 480}, {960, 540}, {1280, 720}, {1600, 900}, {1920, 1080}, {2560, 1440}, {3200, 1800}, {3840, 2160},
	{1280, 540}, {2560, 1080}, {3440, 1440}, {3840, 1600}, {5120, 2160}, {3840, 1080}, {5120, 1440},
	{1200, 750}, {1440, 900}, {1680, 1050}, {1920, 1200}, {2560, 1600}, {2880, 1800}, {3840, 2400},
	{960, 720}, {1024, 768}, {1440, 1080}, {1600, 1200}, {1920, 1440}, {2880, 2160}}
RES_ULTRAWIDE :: 8 // (the first ultrawide one)
RES_16_10 :: 15 // (the first 16:10 one)
RES_4_3 :: 22 // (the first 4:3 one: as 16:10, the runtime's "narrower than 16:9" -- 3D Vert+, the HUD 16:9 centred, movies letterboxed)
RES_DEFAULT :: 2 // (1280x720)

// Aspect Ratio: the groups of RESOLUTIONS (not saved: the resolution decides it)
ASPECT_16_9 :: 0
ASPECT_16_10 :: 1
ASPECT_ULTRAWIDE :: 2
ASPECT_4_3 :: 3
ASPECT_NAMES :: [4]string{"16:9", "16:10", "Ultrawide", "4:3"}
res_aspect :: proc(i: int) -> int {return i >= RES_4_3 ? ASPECT_4_3 : i >= RES_16_10 ? ASPECT_16_10 : i >= RES_ULTRAWIDE ? ASPECT_ULTRAWIDE : ASPECT_16_9}

// an aspect ratio picked: the resolution of that group nearest in height to the current one (16:9 from another: the
// default, 1280x720, unless the current one is taller)
res_for_aspect :: proc(a, cur: int) -> int {
	res := RESOLUTIONS
	c := res[clamp(cur, 0, len(res) - 1)]
	best, bd := -1, max(int)
	for r, i in res {
		if res_aspect(i) != a {continue}
		d := abs(r.h - c.h)
		if d < bd {best, bd = i, d}
	}
	if a == ASPECT_16_9 && res[best].h < res[RES_DEFAULT].h {best = RES_DEFAULT}
	return best < 0 ? RES_DEFAULT : best
}
SHADOW_CHOICES :: [6]int{0, 512, 1024, 2048, 4096, 8192} // (8192: the most the retail launcher offers)
AA_QUALITIES :: [4]int{1, 2, 4, 8}

// Graphics: presets of Shadow Resolution and Anti-aliasing (FXAA always), or Custom -- those three options as set
Graphics_Preset :: struct {
	shadow_res, aa_quality: int,
}
GRAPHICS_ULTRAFAST :: 0
GRAPHICS_FAST :: 1
GRAPHICS_FANCY :: 2
GRAPHICS_ULTRAFANCY :: 3
GRAPHICS_CUSTOM :: 4
GRAPHICS_PRESETS :: [4]Graphics_Preset {
	{shadow_res = 0, aa_quality = 1}, // Ultrafast: no shadows, no anti-aliasing
	{shadow_res = 512, aa_quality = 2}, // Fast: 512 shadows, 2x FXAA
	{shadow_res = 1024, aa_quality = 4}, // Fancy (the default: the game's own shadow size): 4x FXAA
	{shadow_res = 8192, aa_quality = 8}, // Ultrafancy: the most of both
}
GRAPHICS_KEYS :: [5]string{"ultrafast", "fast", "fancy", "ultrafancy", "custom"} // (in settings.txt)
GRAPHICS_NAMES :: [5]string{"Ultrafast (Worst Quality)", "Fast", "Fancy (Default)", "Ultrafancy", "Custom"}

// a preset's values into the three options (Custom: as they are)
graphics_apply :: proc() {
	if settings.graphics < 0 || settings.graphics > GRAPHICS_CUSTOM {settings.graphics = GRAPHICS_FANCY}
	if settings.graphics == GRAPHICS_CUSTOM {return}
	p := GRAPHICS_PRESETS
	settings.shadow_res = p[settings.graphics].shadow_res
	settings.aa_fxaa = true
	settings.aa_taa = false
	settings.aa_fsr = false
	settings.aa_quality = p[settings.graphics].aa_quality
}

// the preset the three options make, else Custom
graphics_matching :: proc() -> int {
	for p, i in GRAPHICS_PRESETS {
		if settings.shadow_res == p.shadow_res && settings.aa_quality == p.aa_quality && !settings.aa_taa && (settings.aa_fxaa || p.aa_quality <= 1) {return i}
	}
	return GRAPHICS_CUSTOM
}

// the game's arguments for the options (XRC_GAME_ARGS)
game_args :: proc(s: Settings = settings) -> string {
	msaa := s.aa_taa || s.aa_fxaa || s.aa_quality <= 1 ? 0 : s.aa_quality
	args := fmt.tprintf("-Shadow=%d -MSAA=%d", s.shadow_res == 0 ? 512 : s.shadow_res, msaa)
	res := RESOLUTIONS
	r := res[clamp(s.resolution, 0, len(res) - 1)]
	if r.w != 1280 || r.h != 720 {args = fmt.tprintf("%s -Width=%d -Height=%d", args, r.w, r.h)}
	if s.voice_jp {args = fmt.tprintf("%s -VoiceJPMode", args)} // (Japanese voices: the retail launcher's argument -- features.odin)
	return args
}

compiler_is_clang :: proc() -> bool {
	for c in compilers_get() {if c.path == settings.compiler {return c.clang}}
	return strings.contains(strings.to_lower(settings.compiler, context.temp_allocator), "clang")
}
