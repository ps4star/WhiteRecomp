// Finding the player's FINAL FANTASY XIII (a Steam install) and checking that its ffxiiiimg.exe is the version the
// bundled code was translated from: the same check the game makes when it starts (src/runtime/xrc_rt.c), a FNV-1a 64
// over the data sections, with the ranges and the hash read from the bundled dispatch table (gen/xrc_table.c).
package launcher

import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

GAME_FOLDER :: "FINAL FANTASY XIII"

game_exe :: proc(dir: string) -> string {return pjoin({dir, "white_data", "prog", "win", "bin", "ffxiiiimg.exe"}, context.temp_allocator)}
movie_dir :: proc(dir: string) -> string {return pjoin({dir, "white_data", "movie"}, context.temp_allocator)}

is_game_dir :: proc(dir: string) -> bool {return dir != "" && file_exists(game_exe(dir))}

// Steam's install folders (each with steamapps/)
@(private = "file")
steam_roots :: proc() -> [dynamic]string {
	r := make([dynamic]string, context.temp_allocator)
	home := os.get_env("HOME", context.temp_allocator)
	when ODIN_OS == .Windows {
		if p := steam_path_from_registry(); p != "" {append(&r, p)}
		for env in ([]string{"ProgramFiles(x86)", "ProgramFiles"}) {
			if v := os.get_env(env, context.temp_allocator); v != "" {append(&r, pjoin({v, "Steam"}, context.temp_allocator))}
		}
	} else when ODIN_OS == .Darwin {
		append(&r, pjoin({home, "Library", "Application Support", "Steam"}, context.temp_allocator))
	} else {
		append(&r, pjoin({home, ".steam", "steam"}, context.temp_allocator))
		append(&r, pjoin({home, ".local", "share", "Steam"}, context.temp_allocator))
		append(&r, pjoin({home, ".var", "app", "com.valvesoftware.Steam", ".local", "share", "Steam"}, context.temp_allocator))
	}
	return r
}

// Every Steam library: the roots, and the "path" entries of their steamapps/libraryfolders.vdf.
@(private = "file")
steam_libraries :: proc() -> [dynamic]string {
	libs := make([dynamic]string, context.temp_allocator)
	for root in steam_roots() {
		append(&libs, root)
		d, err := os.read_entire_file(pjoin({root, "steamapps", "libraryfolders.vdf"}, context.temp_allocator), context.temp_allocator)
		if err != nil {continue}
		for line in strings.split_lines(string(d), context.temp_allocator) {
			l := strings.trim_space(line)
			if !strings.has_prefix(l, "\"path\"") {continue}
			v := strings.trim_space(l[6:])
			if len(v) < 2 || v[0] != '"' {continue}
			p, _ := strings.replace_all(v[1:len(v) - 1], `\\`, `\`, context.temp_allocator)
			append(&libs, p)
		}
	}
	return libs
}

find_game :: proc() -> string {
	for lib in steam_libraries() {
		d := pjoin({lib, "steamapps", "common", GAME_FOLDER}, context.temp_allocator)
		if is_game_dir(d) {return strings.clone(d)}
	}
	// (a regional edition installed under another folder name: any folder of a library that holds the game)
	for lib in steam_libraries() {
		list, err := os.read_all_directory_by_path(pjoin({lib, "steamapps", "common"}, context.temp_allocator), context.temp_allocator)
		if err != nil {continue}
		for e in list {if is_game_dir(e.fullpath) {return strings.clone(e.fullpath)}}
	}
	return ""
}

// Steam's record of an install: steamapps/appmanifest_<app>.acf (two folders above it) whose "installdir" is the
// install's folder name -- the regional editions are told apart there. The runtime does the same
// (src/runtime/host_steam.c host_steam_manifest). Its path (temp), or "".
steam_manifest :: proc(game: string) -> string {
	name := filepath.base(game)
	context.allocator = context.temp_allocator // (filepath.dir allocates)
	steamapps := filepath.dir(filepath.dir(game))
	installdir :: proc(acf: string) -> string {
		d, err := os.read_entire_file(acf, context.temp_allocator)
		if err != nil {return ""}
		for line in strings.split_lines(string(d), context.temp_allocator) {
			l := strings.trim_space(line)
			if !strings.has_prefix(l, "\"installdir\"") {continue}
			v := strings.trim_space(l[12:])
			if len(v) >= 2 && v[0] == '"' && v[len(v) - 1] == '"' {return v[1:len(v) - 1]}
		}
		return ""
	}
	na := pjoin({steamapps, "appmanifest_292120.acf"}, context.temp_allocator)
	if strings.equal_fold(installdir(na), name) {return na}
	list, err := os.read_all_directory_by_path(steamapps, context.temp_allocator)
	if err != nil {return ""}
	for e in list {
		if strings.has_prefix(e.name, "appmanifest_") && strings.has_suffix(e.name, ".acf") && strings.equal_fold(installdir(e.fullpath), name) {return e.fullpath}
	}
	return ""
}

// Whether exe is the version the bundled code needs. why: what is wrong.
// Other editions of the same build, which the translated code runs as they are: their data hash (as xrc_data_hash, over
// xrc_hash_ranges). The runtime has the same list (src/runtime/xrc_rt.c xrc_other_editions, with why).
//   the region-locked Asian edition (Steam): the same code, one 16-byte edition key different
OTHER_EDITIONS :: [?]u64{0x9727f06b4c294964}

check_game_exe :: proc(exe: string) -> (ok: bool, why: string, edition: string) {
	table, tok := bundle_read("gen/xrc_table.c", context.temp_allocator)
	if !tok {return false, "the launcher's sources are damaged (no dispatch table)", ""}
	// const XrcRange xrc_hash_ranges[] = {\n\t{0x...u, N},\n...}; ... xrc_data_hash = 0x...ull;
	t := string(table)
	at := strings.index(t, "xrc_hash_ranges[] = {")
	hat := strings.index(t, "xrc_data_hash = 0x")
	if at < 0 || hat < 0 {return false, "the launcher's sources are damaged (no exe check)", ""}
	want, _ := strconv.parse_u64_of_base(t[hat + 18:hat + 34], 16)
	Range :: struct {va, n: u32}
	ranges := make([dynamic]Range, context.temp_allocator)
	rest := t[at:]
	rest = rest[:strings.index(rest, "};")]
	for line in strings.split_lines(rest, context.temp_allocator) {
		l := strings.trim_space(line)
		if !strings.has_prefix(l, "{0x") {continue}
		va, _ := strconv.parse_u64_of_base(l[3:11], 16)
		comma := strings.index(l, ",")
		n, _ := strconv.parse_u64(strings.trim(l[comma + 1:], " }"))
		append(&ranges, Range{u32(va), u32(n)})
	}
	d, err := os.read_entire_file(exe, context.temp_allocator)
	if err != nil {return false, "it cannot be read", ""}
	u32le :: proc(d: []u8, o: int) -> u32 {return u32(d[o]) | u32(d[o + 1]) << 8 | u32(d[o + 2]) << 16 | u32(d[o + 3]) << 24}
	if len(d) < 0x400 || d[0] != 'M' || d[1] != 'Z' {return false, "it is not a Windows program", ""}
	pe := int(u32le(d, 0x3c))
	nsec := int(u32le(d, pe + 6) & 0xffff)
	base := u32le(d, pe + 24 + 28)
	sh := pe + 24 + int(u32le(d, pe + 20) & 0xffff)
	h: u64 = 0xcbf29ce484222325
	for r in ranges {
		// the file offset of the range's address (a range is the start of a section)
		off := -1
		for i in 0 ..< nsec {
			o := sh + 40 * i
			va := base + u32le(d, o + 12)
			if r.va == va {off = int(u32le(d, o + 20))}
		}
		if off < 0 || off + int(r.n) > len(d) {return false, exe_mismatch(exe, d, pe, nsec, sh), ""}
		for b in d[off:off + int(r.n)] {h = (h ~ u64(b)) * 0x100000001b3}
	}
	others := OTHER_EDITIONS
	if h != want && !slice.contains(others[:], h) {return false, exe_mismatch(exe, d, pe, nsec, sh), ""}
	return true, "", h == want ? "EN" : "JP" // (the edition the Home tab shows: North America / Europe, or the Asian one)
}

// Why an exe is not the one this launcher's code was translated from, as far as the file shows: a 4GB (large-address)
// patch alone does not change what is checked, so a flag set says the patcher changed more; SteamStub's .bind gone says
// it was unpacked. With its SHA-256 (for a bug report) and the fix: Steam's own copy back.
@(private = "file")
exe_mismatch :: proc(exe: string, d: []u8, pe, nsec, sh: int) -> string {
	// Steam's record of the install (steam_manifest: steamapps/appmanifest_<app>.acf, two folders above the game): the depot it has.
	// The code here is from 292122, "Content NE" (North America / Europe); Steam sells others (the region-locked Asian
	// one) whose exe is another program -- a fresh install gets that one again, so verifying the files does not help.
	context.allocator = context.temp_allocator // (filepath.dir allocates)
	game := filepath.dir(filepath.dir(filepath.dir(filepath.dir(filepath.dir(exe)))))
	acf := steam_manifest(game)
	if text, err := os.read_entire_file(acf, context.temp_allocator); err == nil {
		t := string(text)
		if at := strings.index(t, "\"InstalledDepots\""); at >= 0 {
			r := t[at + 17:]
			q := strings.index(r, "\"")
			if q >= 0 {
				r = r[q + 1:]
				if e := strings.index(r, "\""); e > 0 && r[:e] != "292122" {
					return fmt.tprintf("it is another regional edition of the game (Steam depot %s; this launcher's code is from the North America / Europe edition, depot 292122): it is not supported yet, and re-installing gets the same one", r[:e])
				}
			}
		}
	}
	u32le :: proc(d: []u8, o: int) -> u32 {return u32(d[o]) | u32(d[o + 1]) << 8 | u32(d[o + 2]) << 16 | u32(d[o + 3]) << 24}
	notes := make([dynamic]string, context.temp_allocator)
	if u32le(d, pe + 22) & 0x20 != 0 {append(&notes, "4GB-patched")}
	bind := false
	for i in 0 ..< nsec {if string(d[sh + 40 * i:][:5]) == ".bind" {bind = true}}
	if !bind {append(&notes, "Steam's DRM wrapper removed")}
	sum: [32]u8
	c: sha2.Context_256
	sha2.init_256(&c)
	sha2.update(&c, d)
	sha2.final(&c, sum[:])
	hex := strings.builder_make(context.temp_allocator)
	for b in sum[:8] {fmt.sbprintf(&hex, "%02x", b)}
	what := len(notes) > 0 ? fmt.tprintf("a modified copy of the game (%s)", strings.join(notes[:], ", ", context.temp_allocator)) : "a different version of the game or a modified copy"
	return fmt.tprintf("%s, SHA-256 %s…. This launcher needs the Steam release's own ffxiiiimg.exe: in Steam, Properties > Installed Files > Verify integrity of game files, and do not patch it again (WhiteRecomp has its own 4GB mode)", what, strings.to_string(hex))
}

@(private = "file")
steam_path_from_registry :: proc() -> string {return registry_steam_path()}

// (Linux) the wine of each Proton Steam has: steamapps/common/Proton* in every library (the microSD card's too) and
// compatibilitytools.d/* (GE-Proton and the like) in Steam's folders. Proton 5.13 on keeps it in files/bin, older
// ones in dist/bin. Convert Movies uses it when no other Wine is installed: on a Steam Deck, SteamOS's system
// partition is read-only and too small for Wine's packages (and an update would wipe them), while any Deck that runs
// FF13 through Steam already has a Proton. Newest-looking name first.
proton_wines :: proc() -> [dynamic]string {
	dirs := make([dynamic]string, context.temp_allocator)
	add :: proc(dirs: ^[dynamic]string, parent: string, prefix: string) {
		list, err := os.read_all_directory_by_path(parent, context.temp_allocator)
		if err != nil {return}
		for e in list {if strings.has_prefix(e.name, prefix) {append(dirs, e.fullpath)}}
	}
	when ODIN_OS == .Linux {
		for lib in steam_libraries() {add(&dirs, pjoin({lib, "steamapps", "common"}, context.temp_allocator), "Proton")}
		for root in steam_roots() {add(&dirs, pjoin({root, "compatibilitytools.d"}, context.temp_allocator), "")}
	}
	slice.sort_by(dirs[:], proc(a, b: string) -> bool {return filepath.base(a) > filepath.base(b)})
	wines := make([dynamic]string, context.temp_allocator)
	for d in dirs {
		for sub in ([]string{"files", "dist"}) {
			p := pjoin({d, sub, "bin", "wine"}, context.temp_allocator)
			if file_exists(p) {append(&wines, p); break}
		}
	}
	return wines
}

// (Linux) when wine is a Proton's (files/bin/wine or dist/bin/wine beside a proton script): its files (dist) folder,
// whose libraries it needs (Steam normally gives it them through LD_LIBRARY_PATH: wine.odin wine_cmd); else ""
proton_dir :: proc(wine: string) -> string {
	up :: proc(p: string) -> string {i := strings.last_index_byte(p, '/'); return i > 0 ? p[:i] : p}
	files := up(up(wine)) // (.../files)
	if b := filepath.base(files); b != "files" && b != "dist" {return ""}
	if !file_exists(pjoin({up(files), "proton"}, context.temp_allocator)) {return ""}
	return files
}
