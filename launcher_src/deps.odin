// What the launcher needs on the computer, how it finds each, and how it installs what is missing.
//   C compiler  builds the game from the bundled sources: Clang (on Windows a MinGW one, LLVM-MinGW or MSYS2's clang64:
//               the runtime needs pthreads and the DXGI header; Visual C++ cannot build it yet). On Linux GCC
//               too, listed after Clang (the Options tab's choice; Clang stays the default); elsewhere GCC is not taken.
//               Probed by compiling and running a small program, so a compiler that is there but cannot build this is
//               not taken.
//   FFmpeg      encodes the movies (Convert Movies: libx264 + aac). Playing them needs no FFmpeg program: the game
//               links FFmpeg's libraries statically (third_party/ffmpeg, bundled)
//   Wine        (Linux, macOS) runs the movie converter there: it is a 32-bit Windows program around the game's own
//               Windows Bink DLL (wine.odin). The FFmpeg it runs is then the Windows one the launcher brings.
// Installs: Windows winget (per user: no administrator), Linux the distribution's package manager (always as
// administrator: pkexec asks), macOS Xcode's command line tools and Homebrew (neither needs administrator).
// A dependency whose install needs administrator says so on its button, and only that program is elevated.
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "shared:iv_system/platform"

Dep_Kind :: enum {
	Compiler,
	FFmpeg,
	Wine, // (Linux and macOS: runs the Windows converter, wine.odin; not listed on Windows)
}

Dep :: struct {
	name:        string,
	purpose:     string,
	path:        string, // found: the program
	note:        string, // what was found, or why not
	can_encode:  bool, // FFmpeg: has libx264 and aac
	install:     []string, // the install command (nil: cannot install it automatically)
	install_how: string, // what the button says happens
	needs_admin: bool,
}

deps_mutex: sync.Mutex
deps: [Dep_Kind]Dep
deps_checked: bool

// Every C compiler that can build the game (Clang first: it makes the faster game). The Options tab chooses one
// (settings.compiler); deps[.Compiler] is the one chosen.
Compiler :: struct {
	path:  string,
	clang: bool,
	label: string, // what the Options tab lists: "Clang (Best)", "GCC", ...
}
compilers: [dynamic]Compiler

compilers_get :: proc(allocator := context.temp_allocator) -> []Compiler {
	sync.mutex_lock(&deps_mutex)
	defer sync.mutex_unlock(&deps_mutex)
	return slice.clone(compilers[:], allocator)
}

// The compiler to use: the one in the settings if it still works, else the best (and the settings remember it).
choose_compiler :: proc() {
	sync.mutex_lock(&deps_mutex)
	defer sync.mutex_unlock(&deps_mutex)
	if len(compilers) == 0 {return}
	pick := compilers[0]
	for c in compilers {if c.path == settings.compiler {pick = c}}
	if settings.compiler != pick.path {
		settings.compiler = strings.clone(pick.path)
		save_settings()
	}
	deps[.Compiler].path = pick.path
	deps[.Compiler].note = pick.path
}

// The Options tab picked another compiler.
select_compiler :: proc(path: string) {
	settings.compiler = strings.clone(path)
	save_settings()
	choose_compiler()
}

dep_get :: proc(k: Dep_Kind) -> Dep {
	sync.mutex_lock(&deps_mutex)
	defer sync.mutex_unlock(&deps_mutex)
	return deps[k]
}
@(private = "file")
dep_set :: proc(k: Dep_Kind, d: Dep) {
	sync.mutex_lock(&deps_mutex)
	defer sync.mutex_unlock(&deps_mutex)
	deps[k] = d
}

// ---------------------------------------------------------------------------------------------- the compiler
PROBE_C :: `#include <pthread.h>
#include <stdio.h>
#if defined(__x86_64__)
#include <xmmintrin.h>
#else
#include <arm_neon.h>
#endif
#ifdef _WIN32
#include <windows.h>
#include <dxgi.h>
#endif
static void *f(void *p) { return p; }
int main(void) {
	pthread_t t;
	pthread_create(&t, 0, f, 0);
	pthread_join(t, 0);
#if defined(__x86_64__)
	printf("ok %d\n", (int)_mm_cvtss_f32(_mm_sqrt_ss(_mm_set_ss(16.0f))));
#else
	printf("ok %d\n", (int)vgetq_lane_f32(vsqrtq_f32(vdupq_n_f32(16.0f)), 0));
#endif
	return 0;
}
`

// the flags every compile of the game uses for the target: macOS names the architecture (the launcher is one program
// for both kinds of Mac, and each builds its own: Apple silicon a native ARM64 game, an Intel Mac an x86-64 one)
when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	@(rodata) ARCH_FLAGS := []string{"-arch", "arm64"}
} else when ODIN_OS == .Darwin {
	@(rodata) ARCH_FLAGS := []string{"-arch", "x86_64"}
} else when ODIN_ARCH == .arm64 {
	@(rodata) ARCH_FLAGS := []string{}
} else {
	@(rodata) ARCH_FLAGS := []string{"-m64"}
}
// what FFmpeg's static libraries need of the system (TLS for libavformat's https: Schannel / OpenSSL 3 /
// SecureTransport, plus the VideoToolbox hwaccel's frameworks on macOS); the game only reads local files
when ODIN_OS == .Windows {
	@(rodata) FFMPEG_SYS_LIBS := []string{"-lws2_32", "-lsecur32", "-lcrypt32", "-lncrypt", "-lbcrypt"}
} else when ODIN_OS == .Darwin {
	@(rodata) FFMPEG_SYS_LIBS := []string{"-framework", "Security", "-framework", "CoreFoundation", "-framework", "CoreMedia", "-framework", "CoreVideo", "-framework", "VideoToolbox", "-framework", "CoreServices"}
} else {
	@(rodata) FFMPEG_SYS_LIBS := []string{"-l:libssl.so.3", "-l:libcrypto.so.3"}
}
when ODIN_OS == .Windows {
	// (--image-base: the exe above guest memory, which is at a fixed address from 0x7fff0000 to 0x17fff0000: src/include/xrc.h)
	@(rodata) LINK_LIBS := []string{"-static", "-Wl,--image-base,0x200000000", "-pthread", "-ldxguid", "-lole32", "-loleaut32", "-luuid", "-luser32", "-lgdi32", "-lwinmm", "-limm32", "-lshell32", "-lsetupapi", "-lversion", "-lm"} // (imm32 .. version: SDL2, linked in)
} else {
	@(rodata) LINK_LIBS := []string{"-pthread", "-lm", "-ldl"} // (-ldl: Vulkan and SDL2 are loaded at run time)
}
// a cross build's (cross.odin: Linux targets): FFmpeg's OpenSSL, and the game's own
@(rodata) CROSS_LINUX_SYS_LIBS := []string{"-l:libssl.so.3", "-l:libcrypto.so.3", "-pthread", "-lm", "-ldl"}
@(rodata) CROSS_ANDROID_SYS_LIBS := []string{"-landroid", "-llog", "-laaudio", "-lmediandk", "-lm", "-ldl", "-lc"}
arch_flags :: proc() -> []string {return ARCH_FLAGS}
link_libs :: proc() -> []string {return LINK_LIBS}

@(private = "file")
compiler_candidates :: proc() -> [dynamic]string {
	c := make([dynamic]string, context.temp_allocator)
	add :: proc(c: ^[dynamic]string, p: string) {if p != "" {append(c, p)}}
	// the one the settings name -- also one chosen with "Choose clang" (draw_no_compiler) -- is tried first
	if filepath.is_abs(settings.compiler) && file_exists(settings.compiler) {append(&c, settings.compiler)}
	when ODIN_OS == .Windows {
		for n in ([]string{"x86_64-w64-mingw32-clang", "clang"}) {add(&c, find_program(n))}
		// winget's llvm-mingw (not on this process's PATH right after it was installed)
		la := os.get_env("LOCALAPPDATA", context.temp_allocator)
		pk := pjoin({la, "Microsoft", "WinGet", "Packages"}, context.temp_allocator)
		if list, err := os.read_all_directory_by_path(pk, context.temp_allocator); err == nil {
			for e in list {
				if !strings.has_prefix(e.name, "MartinStorsjo.LLVM-MinGW") {continue}
				if sub, serr := os.read_all_directory_by_path(e.fullpath, context.temp_allocator); serr == nil {
					for s in sub {
						p := pjoin({s.fullpath, "bin", "x86_64-w64-mingw32-clang.exe"}, context.temp_allocator)
						if file_exists(p) {append(&c, p)}
					}
				}
			}
		}
		for p in ([]string{`C:\msys64\ucrt64\bin\clang.exe`, `C:\msys64\clang64\bin\clang.exe`}) {
			if file_exists(p) {append(&c, p)}
		}
	} else {
		// (cc: macOS's is clang; a GCC one is taken on Linux only, below)
		when ODIN_OS == .Linux {
			for n in ([]string{"clang", "gcc", "cc"}) {add(&c, find_program(n))}
		} else {
			for n in ([]string{"clang", "cc"}) {add(&c, find_program(n))}
		}
	}
	return c
}

// Compiles and runs the probe with cc. why: what went wrong.
@(private = "file")
probe_compiler :: proc(t: ^Task, cc: string) -> (ok: bool, why: string) {
	dir := data_path("probe")
	_ = os.make_directory_all(dir)
	src := pjoin({dir, "probe.c"}, context.temp_allocator)
	exe := pjoin({dir, strings.concatenate({"probe", EXE_SUFFIX}, context.temp_allocator)}, context.temp_allocator)
	_ = os.remove(exe)
	if os.write_entire_file(src, transmute([]u8)string(PROBE_C)) != nil {return false, "cannot write in the launcher's folder"}
	args := make([dynamic]string, context.temp_allocator)
	append(&args, cc)
	append(&args, ..arch_flags())
	append(&args, "-O0", src, "-o", exe)
	append(&args, ..link_libs())
	out := strings.builder_make(context.temp_allocator)
	code, started := run(t, args[:], mode = .Quiet, capture = &out)
	if !started {return false, "it does not start"}
	if why := child_failure(code); why != "" {return false, why}
	if code != 0 {
		s := strings.to_string(out)
		first, _, _ := strings.partition(s, "\n")
		when ODIN_OS == .Linux {
			if (strings.contains(s, "pthread.h") || strings.contains(s, "stdio.h")) && (strings.contains(s, "not found") || strings.contains(s, "No such file")) {
				return false, is_steamos() ? "the C library's headers (pthread.h) are missing -- SteamOS removes them; Install it for me puts them back" : "the C library's headers (pthread.h) are missing: install glibc's development files (Install it for me)"
			}
		}
		return false, fmt.tprintf("it cannot build the game (%s)", strings.trim_space(first))
	}
	res := strings.builder_make(context.temp_allocator)
	code, started = run(t, {exe}, mode = .Quiet, capture = &res)
	if why := child_failure(code); started && why != "" {return false, fmt.tprintf("the programs it makes do not run here (%s)", why)}
	if !started || code != 0 || !strings.has_prefix(strings.to_string(res), "ok 4") {return false, "the programs it makes do not run here"}
	return true, ""
}

@(private = "file")
check_compiler :: proc(t: ^Task) -> Dep {
	d := Dep{name = "C compiler", purpose = "builds the game from the bundled sources"}
	tried := make([dynamic]string, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	found := make([dynamic]Compiler)
	versions := make(map[string]bool, context.temp_allocator) // (cc and gcc are often the same program)
	for cc in compiler_candidates() {
		key := strings.to_lower(cc, context.temp_allocator)
		if key in seen {continue}
		seen[key] = true
		ok, why := probe_compiler(t, cc)
		if !ok {
			append(&tried, fmt.tprintf("%s: %s", filepath.base(cc), why))
			continue
		}
		ver := strings.builder_make(context.temp_allocator)
		_, _ = run(t, {cc, "--version"}, mode = .Quiet, capture = &ver)
		v := strings.to_string(ver)
		// the same compiler under another name (cc / gcc): its version text without the name it starts with
		_, _, key_v := strings.partition(v, " ")
		if key_v != "" && key_v in versions {continue}
		versions[strings.clone(key_v, context.temp_allocator)] = true
		is_clang := strings.contains(v, "clang")
		when ODIN_OS != .Linux {
			if !is_clang {
				append(&tried, fmt.tprintf("%s: GCC (the game is built with Clang here)", filepath.base(cc)))
				continue
			}
		}
		append(&found, Compiler{path = strings.clone(cc), clang = is_clang})
	}
	if len(found) > 0 {
		// Clang first (the default: it makes the faster game), then GCC (Linux); a kind found twice shows its path
		slice.stable_sort_by(found[:], proc(a, b: Compiler) -> bool {return a.clang && !b.clang})
		nclang := 0
		for c in found {if c.clang {nclang += 1}}
		for &c in found {
			n := c.clang ? nclang : len(found) - nclang
			kind := c.clang ? "Clang" : "GCC"
			c.label = n > 1 ? fmt.aprintf("%s — %s", kind, c.path) : strings.clone(kind)
		}
		sync.mutex_lock(&deps_mutex)
		compilers = found
		sync.mutex_unlock(&deps_mutex)
		d.path = found[0].path
		d.note = found[0].path
		return d
	}
	sync.mutex_lock(&deps_mutex)
	clear(&compilers)
	sync.mutex_unlock(&deps_mutex)
	when ODIN_OS == .Windows {
		if find_program("cl") != "" {append(&tried, "Visual C++ (cl) is installed, but it cannot build the game yet (it needs clang)")}
	}
	if len(tried) == 0 {
		d.note = "none found"
	} else {
		d.note = strings.clone(strings.join(tried[:], "; ", context.temp_allocator))
	}
	when ODIN_OS == .Windows {
		if wg := find_program("winget"); wg != "" {
			d.install = clone_cmd({wg, "install", "--id", "MartinStorsjo.LLVM-MinGW.UCRT", "-e", "--scope", "user", "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity"})
			d.install_how = "Install LLVM-MinGW (winget)"
		}
	} else when ODIN_OS == .Darwin {
		d.install = clone_cmd({"/usr/bin/xcode-select", "--install"})
		d.install_how = "Install Apple's command line tools"
	} else {
		pm, cmd := linux_install_cmd("compiler")
		if pm != "" {
			d.install = cmd
			d.install_how = c_headers_missing() ? fmt.aprintf("Install Clang and the C headers (%s)", pm) : fmt.aprintf("Install Clang (%s)", pm)
			d.needs_admin = true
		}
	}
	return d
}

// ---------------------------------------------------------------------------------------------- FFmpeg
@(private = "file")
ffmpeg_candidates :: proc() -> [dynamic]string {
	c := make([dynamic]string, context.temp_allocator)
	if p := find_program("ffmpeg"); p != "" {append(&c, p)}
	when ODIN_OS == .Windows {
		la := os.get_env("LOCALAPPDATA", context.temp_allocator)
		home := os.get_env("USERPROFILE", context.temp_allocator)
		for p in ([]string{
				pjoin({la, "Microsoft", "WinGet", "Links", "ffmpeg.exe"}, context.temp_allocator),
				`C:\ProgramData\chocolatey\bin\ffmpeg.exe`,
				pjoin({home, "scoop", "shims", "ffmpeg.exe"}, context.temp_allocator),
			}) {
			if file_exists(p) {append(&c, p)}
		}
		pk := pjoin({la, "Microsoft", "WinGet", "Packages"}, context.temp_allocator)
		if list, err := os.read_all_directory_by_path(pk, context.temp_allocator); err == nil {
			for e in list {
				if !strings.has_prefix(e.name, "Gyan.FFmpeg") {continue}
				if sub, serr := os.read_all_directory_by_path(e.fullpath, context.temp_allocator); serr == nil {
					for s in sub {
						p := pjoin({s.fullpath, "bin", "ffmpeg.exe"}, context.temp_allocator)
						if file_exists(p) {append(&c, p)}
					}
				}
			}
		}
	} else when ODIN_OS == .Darwin {
		for p in ([]string{"/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"}) {if file_exists(p) {append(&c, p)}}
	}
	return c
}

@(private = "file")
check_ffmpeg :: proc(t: ^Task) -> Dep {
	d := Dep{name = "FFmpeg", purpose = "converts the movies (the game plays them without it)"}
	// the launcher's own (the Windows bundle: tools/ffmpeg.exe, unpacked with the converter by Build and Convert Movies)
	if bundle_has("tools/ffmpeg.exe") {
		d.path = strings.clone(data_path("tools", "ffmpeg.exe"))
		d.note = "included with the launcher"
		d.can_encode = true
		return d
	}
	// (Linux x86-64, macOS: the Windows one, which the converter runs under Wine -- wine.odin; the system's FFmpeg is not used)
	if bundle_has("tools/wine/ffmpeg.exe") {
		d.path = strings.clone(data_path("tools", "wine", "ffmpeg.exe"))
		d.note = "included with the launcher (the Windows FFmpeg: Convert Movies runs it through Wine)"
		d.can_encode = true
		return d
	}
	fallback := ""
	for p in ffmpeg_candidates() {
		out := strings.builder_make(context.temp_allocator)
		code, started := run(t, {p, "-hide_banner", "-encoders"}, mode = .Quiet, capture = &out)
		if !started || code != 0 {continue}
		s := strings.to_string(out)
		if strings.contains(s, " libx264 ") && strings.contains(s, " aac ") {
			d.path = strings.clone(p)
			d.note = strings.clone(p)
			d.can_encode = true
			return d
		}
		if fallback == "" {fallback = p}
	}
	if fallback != "" {
		// it plays the MP4s, but cannot make them
		d.path = strings.clone(fallback)
		d.note = fmt.aprintf("%s (it has no H.264 encoder: it cannot convert the movies)", fallback)
	} else {
		d.note = "not found"
	}
	when ODIN_OS == .Windows {
		if wg := find_program("winget"); wg != "" {
			d.install = clone_cmd({wg, "install", "--id", "Gyan.FFmpeg", "-e", "--scope", "user", "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity"})
			d.install_how = "Install FFmpeg (winget)"
		}
	} else when ODIN_OS == .Darwin {
		brew := ""
		for p in ([]string{"/opt/homebrew/bin/brew", "/usr/local/bin/brew"}) {if file_exists(p) {brew = p}}
		if brew != "" {
			d.install = clone_cmd({brew, "install", "ffmpeg"})
			d.install_how = "Install FFmpeg (Homebrew)"
		} else {
			d.install_how = "Install Homebrew (brew.sh) first, then FFmpeg"
		}
	} else {
		pm, cmd := linux_install_cmd("ffmpeg")
		if pm != "" {
			d.install = cmd
			d.install_how = fmt.aprintf("Install FFmpeg (%s)", pm)
			d.needs_admin = true
		}
	}
	return d
}

// ---------------------------------------------------------------------------------------------- installing
@(private = "file")
clone_cmd :: proc(cmd: []string) -> []string {
	out := make([]string, len(cmd))
	for s, i in cmd {out[i] = strings.clone(s)}
	return out
}

// The distribution's package manager and the command that installs what: "compiler", "ffmpeg", "wine" or "sdl2" (the
// launcher's own window: nowindow_posix.odin).
linux_install_cmd :: proc(what: string) -> (pm: string, cmd: []string) {
	if p := find_program("apt-get"); p != "" {
		if what == "sdl2" {return "apt", clone_cmd({p, "install", "-y", "libsdl2-2.0-0"})}
		if what == "compiler" {return "apt", clone_cmd({p, "install", "-y", "clang", "libc6-dev"})}
		if what == "wine" { // (its 32-bit half, wine32, is an i386 package: that architecture added first)
			return "apt", clone_cmd({"/bin/sh", "-c", fmt.tprintf("dpkg --add-architecture i386 && '%s' update && '%s' install -y wine wine32:i386", p, p)})
		}
		return "apt", clone_cmd({p, "install", "-y", "ffmpeg"})
	}
	if p := find_program("dnf"); p != "" {
		if what == "sdl2" {return "dnf", clone_cmd({p, "install", "-y", "SDL2"})}
		if what == "compiler" {return "dnf", clone_cmd({p, "install", "-y", "clang", "glibc-devel"})}
		if what == "wine" {return "dnf", clone_cmd({p, "install", "-y", "wine"})}
		return "dnf", clone_cmd({p, "install", "-y", "ffmpeg-free"})
	}
	if p := find_program("pacman"); p != "" {
		return "pacman", pacman_cmd(p, what)
	}
	if p := find_program("zypper"); p != "" {
		if what == "sdl2" {return "zypper", clone_cmd({p, "--non-interactive", "install", "libSDL2-2_0-0"})}
		if what == "compiler" {return "zypper", clone_cmd({p, "--non-interactive", "install", "clang", "glibc-devel"})}
		if what == "wine" {return "zypper", clone_cmd({p, "--non-interactive", "install", "wine"})}
		return "zypper", clone_cmd({p, "--non-interactive", "install", "ffmpeg"})
	}
	return "", nil
}

check_deps_task :: proc(t: ^Task) {
	set_status(t, -1, "Looking for C compilers")
	dep_set(.Compiler, check_compiler(t))
	choose_compiler()
	set_status(t, -1, "Looking for FFmpeg")
	dep_set(.FFmpeg, check_ffmpeg(t))
	when ODIN_OS != .Windows {
		set_status(t, -1, "Looking for Wine")
		dep_set(.Wine, check_wine(t))
	}
	for k in Dep_Kind {
		d := dep_get(k)
		if k == .Wine && ODIN_OS == .Windows {continue}
		logf(t, "%s: %s", d.name, d.note)
	}
	sync.atomic_store(&deps_checked, true)
	set_status(t, 1, "Checked what is installed")
}

// Installs one dependency (task user = the Dep_Kind), then checks again.
install_dep_task :: proc(t: ^Task) {
	k := Dep_Kind(uintptr(t.user))
	d := dep_get(k)
	if d.install == nil {return}
	set_status(t, -1, "%s", d.install_how)
	code: int
	started: bool
	if d.needs_admin {
		code, started = run_elevated(t, d.install)
	} else {
		code, started = run(t, d.install)
	}
	if !started || code != 0 {
		if started {logf(t, "The install ended with code %d.", code)}
		t.failed = true
	}
	when ODIN_OS == .Darwin {
		if k == .Compiler {log_line(t, "Finish the installer Apple opened, then press Check again.")}
	}
	check_deps_task(t)
}

// "Choose clang…" (the no-compiler dialog): the user points at the compiler, which is then probed as the others are
// (a clang that cannot build the game -- e.g. LLVM's own Windows one, which targets MSVC: no pthreads -- is still not
// taken, and the dialog says why). Not on Linux (the platform layer has no file dialog there yet).
pick_compiler :: proc(w: ^platform.Window) {
	dir := ""
	if filepath.is_abs(settings.compiler) {dir, _ = filepath.split(settings.compiler)}
	when ODIN_OS == .Windows {title := "Choose clang.exe (e.g. LLVM-MinGW's bin\\clang.exe)"} else {title := "Choose clang"}
	if p, ok := platform.pick_program(w, title, dir); ok {
		settings.compiler = strings.clone(p)
		save_settings()
		no_compiler_dialog = 0
		task_start("Checking", check_all_task)
	}
}

// SteamOS (the Steam Deck; also what Valve's Holo images are): an Arch Linux whose system is read-only and whose
// packages come with their headers removed -- glibc is installed but /usr/include/pthread.h & co are not there, and
// pacman -S --needed skips glibc as up to date, so Clang installs and still cannot build anything.
is_steamos :: proc() -> bool {
	data, err := os.read_entire_file_from_path("/etc/os-release", context.temp_allocator)
	if err != nil {return false}
	for line in strings.split_lines(string(data), context.temp_allocator) {
		if strings.trim_space(line) == "ID=steamos" {return true}
	}
	return file_exists("/usr/bin/steamos-readonly")
}

// the C library's headers are missing (SteamOS, or an Arch system set up without them)
c_headers_missing :: proc() -> bool {return !file_exists("/usr/include/pthread.h") || !file_exists("/usr/include/stdio.h")}

// pacman: the package, and for the compiler glibc's and the kernel's headers reinstalled when they are missing (no
// --needed for those: they count as installed). SteamOS: its read-only system unlocked first (steamos-readonly
// disable) and pacman's keyring set up (it is empty on a new Deck: every install would fail its signature check).
// A SteamOS update puts the read-only system back, without what was installed: then Install again.
@(private = "file")
pacman_cmd :: proc(pm, what: string) -> []string {
	pkg := what == "compiler" ? "clang" : what == "wine" ? "wine" : what == "sdl2" ? "sdl2" : "ffmpeg"
	steps := make([dynamic]string, context.temp_allocator)
	if is_steamos() {
		append(&steps, "(steamos-readonly disable || true)", "(pacman-key --init && pacman-key --populate archlinux holo) || true")
	}
	append(&steps, fmt.tprintf("'%s' -S --needed --noconfirm %s", pm, pkg))
	if what == "compiler" && (c_headers_missing() || is_steamos()) {
		append(&steps, fmt.tprintf("'%s' -S --noconfirm glibc linux-api-headers", pm))
	}
	if len(steps) == 1 {return clone_cmd({pm, "-S", "--needed", "--noconfirm", pkg})}
	return clone_cmd({"/bin/sh", "-c", strings.join(steps[:], " && ", context.temp_allocator)})
}

// ---------------------------------------------------------------------------------------------- Wine
// (Linux, macOS) the wine that runs Windows programs: PATH's, then where WineHQ's packages and the macOS apps put it.
// Found when `wine --version` runs; whether it runs 32-bit programs (the converter is one) is tried when Convert
// Movies starts (wine.odin wine_ready), since that sets up its folder first.
// (macOS) the PATH a Terminal window has: an app started from the Finder gets only the system's
// (/usr/bin:/bin:/usr/sbin:/sbin), so a wine the player put on PATH in ~/.zshrc (as the macOS Wine builds' instructions
// say) was not found although `wine` works in Terminal (a player's bug report). The login shell is asked, interactive
// so its ~/.zshrc counts too, and stopped after 5 s should its profile wait for something. "" if it says nothing.
@(private = "file")
shell_path :: proc(t: ^Task) -> string {
	sh := os.get_env("SHELL", context.temp_allocator)
	if sh == "" || !file_exists(sh) {sh = "/bin/zsh"}
	MARK :: "@@WHITERECOMP_PATH@@"
	// (its output through a file: a program its profile leaves running would hold a pipe open; -9: an interactive shell
	// ignores SIGTERM)
	script := `f=$(mktemp) || exit 0; "$0" -ilc 'printf "\n` + MARK + `%s` + MARK + `\n" "$PATH"' </dev/null >"$f" 2>/dev/null & p=$!; (sleep 5; kill -9 $p) >/dev/null 2>&1 & k=$!; wait $p 2>/dev/null; kill $k 2>/dev/null; cat "$f"; rm -f "$f"; exit 0`
	out := strings.builder_make(context.temp_allocator)
	if _, started := run(t, {"/bin/sh", "-c", script, sh}, mode = .Quiet, capture = &out); !started {return ""}
	s := strings.to_string(out)
	a := strings.index(s, MARK)
	if a < 0 {return ""}
	r := s[a + len(MARK):]
	b := strings.index(r, MARK)
	return b < 0 ? "" : r[:b]
}

@(private = "file")
wine_candidates :: proc(t: ^Task) -> [dynamic]string {
	c := make([dynamic]string, context.temp_allocator)
	add :: proc(c: ^[dynamic]string, p: string) {
		if !file_exists(p) {return}
		for q in c {if q == p {return}}
		append(c, p)
	}
	when ODIN_OS == .Darwin {if p := app_wine(); p != "" {add(&c, p)}} // (first: the one the launcher carries)
	if p := find_program("wine"); p != "" {add(&c, p)}
	when ODIN_OS == .Darwin {
		// the Terminal's PATH (shell_path), then every app with a Wine inside (Gcenx's Wine Stable / Devel / Staging,
		// or a renamed or test build of them), in /Applications and ~/Applications, then Homebrew's
		for dir in strings.split(shell_path(t), ":", context.temp_allocator) {
			if dir != "" {add(&c, pjoin({dir, "wine"}, context.temp_allocator))}
		}
		for base in ([]string{"/Applications", pjoin({os.get_env("HOME", context.temp_allocator), "Applications"}, context.temp_allocator)}) {
			list, err := os.read_all_directory_by_path(base, context.temp_allocator)
			if err != nil {continue}
			for e in list {
				if strings.has_suffix(e.name, ".app") {add(&c, pjoin({e.fullpath, "Contents", "Resources", "wine", "bin", "wine"}, context.temp_allocator))}
			}
		}
		for p in ([]string{"/opt/homebrew/bin/wine", "/usr/local/bin/wine"}) {add(&c, p)}
	} else {
		for p in ([]string{"/usr/bin/wine", "/opt/wine-stable/bin/wine", "/opt/wine-staging/bin/wine", "/opt/wine-devel/bin/wine"}) {add(&c, p)}
		for p in proton_wines() {add(&c, p)} // (Steam's Protons: a Steam Deck's Wine -- game.odin)
	}
	// (last: a wine64 alone runs no 32-bit program unless it is a WoW64 build; wine_ready tells)
	if p := find_program("wine64"); p != "" {add(&c, p)}
	return c
}

@(private = "file")
check_wine :: proc(t: ^Task) -> Dep {
	d := Dep{name = "Wine", purpose = "runs the movie converter (a Windows program) for Convert Movies"}
	when ODIN_OS == .Darwin {
		if w := app_wine(); w != "" {
			// (the .app's own Wine: unzipped from a download, its files carry the quarantine flag, which would have
			// Gatekeeper stop each of them -- taken off, as the app's README says to do for the app itself)
			wine_root := filepath.dir(filepath.dir(w))
			_, _ = run(t, {"/usr/bin/xattr", "-dr", "com.apple.quarantine", wine_root}, mode = .Quiet)
			when ODIN_ARCH == .arm64 {
				// (an Intel program: Apple silicon runs it through Rosetta 2, which macOS installs only when asked)
				if code, started := run(t, {"/usr/bin/arch", "-x86_64", "/usr/bin/true"}, mode = .Quiet); !started || code != 0 {
					d.note = "the launcher's Wine needs Rosetta 2 (Apple's, for Intel programs), which is not installed"
					d.install = clone_cmd({"/usr/sbin/softwareupdate", "--install-rosetta", "--agree-to-license"})
					d.install_how = "Install Rosetta 2"
					d.needs_admin = true
					return d
				}
			}
		}
	}
	for p in wine_candidates(t) {
		out := strings.builder_make(context.temp_allocator)
		code, started := run(t, {p, "--version"}, mode = .Quiet, capture = &out)
		if !started || code != 0 {continue}
		d.path = strings.clone(p)
		d.note = fmt.aprintf("%s (%s)", strings.trim_space(strings.to_string(out)), p)
		return d
	}
	d.note = "not found (only Convert Movies needs it)"
	when ODIN_OS == .Darwin {
		brew := ""
		for p in ([]string{"/opt/homebrew/bin/brew", "/usr/local/bin/brew"}) {if file_exists(p) {brew = p}}
		if brew != "" {
			d.install = clone_cmd({brew, "install", "--cask", "wine-stable"})
			d.install_how = "Install Wine (Homebrew)"
		} else {
			d.install_how = "Install Homebrew (brew.sh) first, then Wine"
		}
	} else {
		pm, cmd := linux_install_cmd("wine")
		if is_steamos() { // (Wine's packages do not fit SteamOS's read-only system partition, and an update wipes them: Proton's Wine)
			d.note = "not found: install Proton in Steam (only Convert Movies needs it)"
			d.install_how = "In Steam: Library > search Proton > install one, then Check again"
		} else if pm != "" {
			d.install = cmd
			d.install_how = fmt.aprintf("Install Wine (%s)", pm)
			d.needs_admin = true
		}
	}
	return d
}
