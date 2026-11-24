// Features & Mods > HD Textures: the FF XIII HD Project (www.nexusmods.com/finalfantasy13/mods/17), imported from its
// ZIP. The mod is an installer: its batch files (_FFXIII HD Project.bat, SupportFiles/FFXIII HD Setup.bat and
// FFXIII HD Installer.bat) unpack the game's archives with ff13tool.exe (FluffyQuack's), put the HD textures into the
// models and zone blocks with FFXIII_HDProject.exe / FFXIII_ModelsHD.exe, and write the archives back INTO the game's
// white_data. Here the same steps run (its "A) Install All HD Textures", the same tools with the same arguments, in
// the same working-folder layout), but on copies: the archives it changes are written to a folder of their own beside
// the install's white_data -- <game>/white_data_hd/ (sys/, zone/; or the launcher's data folder's hd/ when the game's
// folder cannot be written) -- and the install is never touched. With the switch On, the .cfg gets XRC_HD_DIR and the
// runtime reads a white_data file from there when it has it (hle_kernel32_io.c hd_overlay).
//
// Which archives: the voice language's -- English voices u (white_scru, white_imgu, white_zNNNu_img), Japanese c --
// as the mod's "Update (E)nglish or (J)apanese version?" asks; whiterecomp_hd.txt in the folder records it.
// The tools are Windows programs: on Linux and macOS they run through Wine (wine.odin), as the movie converter does.
// It needs about 25 GB free while it runs (the ZIP's 6.5 GB of textures, the game's archives unpacked) and leaves
// about 8 GB.
package launcher

import "core:compress/deflate"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "rar5"
import "shared:iv_system/ren"
import ui "shared:iv_ui"

HD_URL :: "https://www.nexusmods.com/finalfantasy13/mods/17"
HD_DIR_NAME :: "white_data_hd"
HD_MARKER :: "whiterecomp_hd.txt"
// the "HD Fonts and GUI" mod (Dendonflo's, Nexus Mods 67): its hd_textures/ folder (hash_database.txt and the .dds files)
// unpacked into the same HD folder; the runtime swaps textures by their contents as the mod's version.dll does
// (hle_d3d9.c hdt_*). One switch: HD Textures On uses every HD pack installed.
HD_GUI_URL :: "https://www.nexusmods.com/finalfantasy13/mods/67"
HD_GUI_MARKER :: "whiterecomp_hd_gui.txt"

// the HD folder made by an import ("" if none: nothing imported) -- the HD Project's archives and/or the GUI mod's
// hd_textures/, each with its marker
hd_dir :: proc() -> string {
	has :: proc(d: string) -> bool {return file_exists(pjoin({d, HD_MARKER}, context.temp_allocator)) || file_exists(pjoin({d, HD_GUI_MARKER}, context.temp_allocator))}
	if settings.game_dir != "" {
		if d := pjoin({settings.game_dir, HD_DIR_NAME}, context.temp_allocator); has(d) {return d}
	}
	if d := data_path("hd"); has(d) {return d}
	return ""
}
hd_ready :: proc() -> bool {return hd_dir() != ""} // (any HD pack: the switch can be On)
hd_project_ready :: proc() -> bool {d := hd_dir(); return d != "" && file_exists(pjoin({d, HD_MARKER}, context.temp_allocator))}
hd_gui_ready :: proc() -> bool {d := hd_dir(); return d != "" && file_exists(pjoin({d, HD_GUI_MARKER}, context.temp_allocator))}

// where a new HD folder goes: beside white_data (else the launcher's data folder, the game's folder not writable)
hd_place :: proc() -> (parent, final: string) {
	parent = settings.game_dir
	probe := pjoin({parent, "whiterecomp_hd_probe.tmp"}, context.temp_allocator)
	if os.write_entire_file(probe, transmute([]u8)string("x")) != nil {parent = data_dir}
	_ = os.remove(probe)
	final = parent == settings.game_dir ? pjoin({parent, HD_DIR_NAME}, context.temp_allocator) : data_path("hd")
	return
}

// what the HD Project's marker says (key=value lines): "region", "zip"; gui: the GUI mod's marker ("archive", "files")
hd_info :: proc(key: string, gui := false) -> string {
	d := hd_dir()
	if d == "" {return ""}
	data, err := os.read_entire_file(pjoin({d, gui ? HD_GUI_MARKER : HD_MARKER}, context.temp_allocator), context.temp_allocator)
	if err != nil {return ""}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		k, _, v := strings.partition(strings.trim_space(line), "=")
		if k == key {return v}
	}
	return ""
}

// the .cfg's line: the switch On and a folder there
hd_cfg_line :: proc(b: ^strings.Builder) {
	if !settings.hd_on && !hd_discarded() {return} // (after Discard Old Assets the game has only the HD copies: always On)
	if d := hd_dir(); d != "" {fmt.sbprintf(b, "XRC_HD_DIR=%s\n", d)}
}

hd_open_page :: proc() {open_url(HD_URL)}
hd_gui_open_page :: proc() {open_url(HD_GUI_URL)}

// Import (the ZIP chosen: folder_pick.odin)
@(private = "file")
hd_zip_path: string
hd_import_start :: proc(zip: string) {
	delete(hd_zip_path)
	hd_zip_path = strings.clone(zip)
	if task_start("HD Textures", proc(t: ^Task) {hd_import_any(t, hd_zip_path)}) {tab = .Home} // (its progress and log: on Home, as a Build's)
}

// ---------------------------------------------------------------------------------------------- ZIP reading

Zip_Entry :: struct {
	name:   string,
	method: u16,
	csize:  u64,
	usize:  u64,
	lho:    u64, // its local header's offset
}

@(private = "file")
le16 :: proc(b: []u8, o: int) -> u16 {return u16(b[o]) | u16(b[o + 1]) << 8}
@(private = "file")
le32 :: proc(b: []u8, o: int) -> u32 {return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24}
@(private = "file")
le64 :: proc(b: []u8, o: int) -> u64 {return u64(le32(b, o)) | u64(le32(b, o + 4)) << 32}

// the ZIP's central directory (ZIP64 too: the mod's ZIP is 6.5 GB)
zip_entries :: proc(f: ^os.File, allocator := context.allocator) -> (entries: [dynamic]Zip_Entry, ok: bool) {
	size, serr := os.file_size(f)
	if serr != nil || size < 22 {return}
	tail_n := min(size, 65557 + 20)
	tail := make([]u8, int(tail_n), context.temp_allocator)
	if n, err := os.read_at(f, tail, size - tail_n); err != nil || i64(n) != tail_n {return}
	eocd := -1
	for i := len(tail) - 22; i >= 0; i -= 1 {if le32(tail, i) == 0x06054b50 {eocd = i; break}}
	if eocd < 0 {return}
	count := u64(le16(tail, eocd + 10))
	cd_size := u64(le32(tail, eocd + 12))
	cd_off := u64(le32(tail, eocd + 16))
	if (count == 0xffff || cd_size == 0xffffffff || cd_off == 0xffffffff) && eocd >= 20 && le32(tail, eocd - 20) == 0x07064b50 {
		z64 := make([]u8, 56, context.temp_allocator)
		if n, err := os.read_at(f, z64, i64(le64(tail, eocd - 20 + 8))); err != nil || n != 56 || le32(z64, 0) != 0x06064b50 {return}
		count, cd_size, cd_off = le64(z64, 32), le64(z64, 40), le64(z64, 48)
	}
	if cd_size > 256 << 20 || i64(cd_off + cd_size) > size {return}
	cd := make([]u8, int(cd_size), context.temp_allocator)
	if n, err := os.read_at(f, cd, i64(cd_off)); err != nil || u64(n) != cd_size {return}
	entries = make([dynamic]Zip_Entry, allocator)
	o := 0
	for _ in 0 ..< count {
		if o + 46 > len(cd) || le32(cd, o) != 0x02014b50 {return entries, false}
		e := Zip_Entry {
			method = le16(cd, o + 10),
			csize  = u64(le32(cd, o + 20)),
			usize  = u64(le32(cd, o + 24)),
			lho    = u64(le32(cd, o + 42)),
		}
		nl, xl, cl := int(le16(cd, o + 28)), int(le16(cd, o + 30)), int(le16(cd, o + 32))
		if o + 46 + nl + xl + cl > len(cd) {return entries, false}
		name, _ := strings.replace_all(string(cd[o + 46:][:nl]), "\\", "/", allocator)
		e.name = name
		// (ZIP64: the sizes and the offset that did not fit, in this order, in extra field 1)
		x := cd[o + 46 + nl:][:xl]
		for k := 0; k + 4 <= len(x); {
			id, l := le16(x, k), int(le16(x, k + 2))
			if id == 1 {
				p := k + 4
				if e.usize == 0xffffffff && p + 8 <= k + 4 + l {e.usize = le64(x, p); p += 8}
				if e.csize == 0xffffffff && p + 8 <= k + 4 + l {e.csize = le64(x, p); p += 8}
				if e.lho == 0xffffffff && p + 8 <= k + 4 + l {e.lho = le64(x, p)}
			}
			k += 4 + l
		}
		append(&entries, e)
		o += 46 + nl + xl + cl
	}
	return entries, true
}

// one entry written to dest (stored or deflated)
zip_extract :: proc(f: ^os.File, e: Zip_Entry, dest: string) -> bool {
	if e.method != 0 && e.method != 8 {return false}
	if e.csize > 1 << 31 || e.usize > 1 << 31 {return false} // (no entry of the mod's is near that)
	lh: [30]u8
	if n, err := os.read_at(f, lh[:], i64(e.lho)); err != nil || n != 30 || le32(lh[:], 0) != 0x04034b50 {return false}
	start := i64(e.lho) + 30 + i64(le16(lh[:], 26)) + i64(le16(lh[:], 28))
	data := make([]u8, int(e.csize))
	defer delete(data)
	if n, err := os.read_at(f, data, start); err != nil || u64(n) != e.csize {return false}
	_ = os.make_directory_all(filepath.dir(dest))
	if e.method == 0 {return os.write_entire_file(dest, data) == nil}
	out := make([dynamic]u8)
	defer delete(out)
	if deflate.inflate_raw_from_bytes(&out, data, int(e.usize)) != nil {return false}
	return u64(len(out)) == e.usize && os.write_entire_file(dest, out[:]) == nil
}

// ---------------------------------------------------------------------------------------------- the import

// the mod's files the import needs (a ZIP without them is not the FF XIII HD Project)
@(private = "file")
HD_NEEDS := []string{"SupportFiles/ff13tool.exe", "SupportFiles/FFXIII_HDProject.exe", "SupportFiles/FFXIII_ModelsHD.exe", "Data/LoadHDPCs.tx1", "Data/LoadHDEnvironments.txt"}

// the zones the mod changes: its list's code -> the zone, and the folder its blocks are in (Z29's is loc019: as the mod has it)
@(private = "file")
Hd_Zone :: struct {
	code, zone, loc: string,
}
@(private = "file")
HD_ZONES := []Hd_Zone {
	{"Z2", "z002", "loc006"}, {"Z3", "z003", "loc007"}, {"Z4", "z004", "loc008"}, {"Z6", "z006", "loc010"}, {"Z8", "z008", "loc012"},
	{"Z10", "z010", "loc014"}, {"Z15", "z015", "loc015"}, {"Z16", "z016", "loc016"}, {"Z17", "z017", "loc017"}, {"Z18", "z018", "loc018"},
	{"Z19", "z019", "loc019"}, {"Z20", "z020", "loc020"}, {"Z21", "z021", "loc021"}, {"Z22", "z022", "loc022"}, {"Z23", "z023", "loc023"},
	{"Z24", "z024", "loc024"}, {"Z26", "z026", "loc026"}, {"Z27", "z027", "loc027"}, {"Z29", "z029", "loc019"}, {"Z30", "z030", "loc030"},
}
// the single models' codes -> their chr/ folder
@(private = "file")
hd_single :: proc(code: string) -> (cat: string, ok: bool) {
	switch code {
	case "W":
		return "weapon", true
	case "N":
		return "npc", true
	case "P":
		return "pc", true
	case "M":
		return "mon", true
	case "S":
		return "summon", true
	case "F":
		return "fa", true
	}
	return "", false
}
// the PCs' original sizes (the mod's check: other sizes are another mod's models, and the PCs are left out)
@(private = "file")
HD_PC_SIZES := [][3]int{{201, 794339, 2130264}, {202, 886815, 2410136}, {203, 777069, 2128868}, {204, 714859, 2326632}, {205, 719745, 2164820}, {206, 830980, 2288372}}

@(private = "file")
Hd :: struct {
	t:      ^Task,
	work:   string, // the mod's folder (what the batch files' %~dp0 is)
	out:    string, // the new HD folder (white_data's layout), moved into place at the end
	r:      string, // "u" / "c"
	wine:   string, // (Linux, macOS)
	log:    ^os.File,
	failed: bool,
}

// a path for the tools' command line: as given (relative, with \), or an absolute one as the tools see it
@(private = "file")
hw :: proc(p: string) -> string {
	when ODIN_OS == .Windows {
		s, _ := strings.replace_all(p, "/", "\\", context.temp_allocator)
		return s
	} else {
		return win_path(p)
	}
}
@(private = "file")
hlog :: proc(h: ^Hd, f: string, args: ..any) {
	if h.log != nil {_, _ = os.write_string(h.log, fmt.tprintf(f, ..args)); _, _ = os.write_string(h.log, "\n")}
}

// one of the mod's tools (SupportFiles/<exe>), run in dir (the work folder or one inside it); its exit code as the
// batch files' %ERRORLEVEL% sees it (signed)
@(private = "file")
hd_tool :: proc(h: ^Hd, exe: string, args: []string, dir: string = "") -> (code: int, ok: bool) {
	prog := pjoin({h.work, "SupportFiles", exe}, context.temp_allocator)
	cmd := make([dynamic]string, context.temp_allocator)
	when ODIN_OS == .Windows {
		append(&cmd, prog)
		append(&cmd, ..args)
	} else {
		all := make([dynamic]string, context.temp_allocator)
		append(&all, prog)
		append(&all, ..args)
		append(&cmd, ..wine_cmd(h.wine, all[:]))
	}
	out := strings.builder_make(context.temp_allocator)
	c, started := run(h.t, cmd[:], dir = dir != "" ? dir : h.work, mode = .Quiet, capture = &out)
	code = int(i32(u32(c & 0xffffffff)))
	hlog(h, "> %s %s  [%s]\n%s(exit %d)", exe, strings.join(args, " ", context.temp_allocator), dir != "" ? dir : h.work, strings.to_string(out), code)
	if !started {logf(h.t, "Cannot run %s.", exe); h.failed = true}
	return code, started
}
// ff13tool -i: one file into an archive (the batch files' LOADMODELFILE / LOADMISCFILE)
@(private = "file")
hd_inject :: proc(h: ^Hd, filelist, archive, file, dir: string) -> bool {
	_, ok := hd_tool(h, "ff13tool.exe", {"-i", filelist, archive, file}, dir)
	return ok
}

@(private = "file")
copy_into :: proc(h: ^Hd, src, dst: string) -> bool {
	_ = os.make_directory_all(filepath.dir(dst))
	if os.copy_file(dst, src) != nil {logf(h.t, "Cannot copy %s to %s (is there room?).", src, dst); h.failed = true; return false}
	return true
}
@(private = "file")
move_into :: proc(h: ^Hd, src, dst: string) -> bool {
	_ = os.make_directory_all(filepath.dir(dst))
	_ = os.remove(dst)
	if os.rename(src, dst) == nil {return true}
	if !copy_into(h, src, dst) {return false}
	_ = os.remove(src)
	return true
}
// every file under src whose name ends with one of exts, copied to the same place under dst (robocopy /S)
@(private = "file")
copy_tree :: proc(h: ^Hd, src, dst: string, exts: []string) -> bool {
	list, err := os.read_all_directory_by_path(src, context.temp_allocator)
	if err != nil {return true}
	for e in list {
		d := pjoin({dst, e.name}, context.temp_allocator)
		if e.type == .Directory {
			if !copy_tree(h, e.fullpath, d, exts) {return false}
			continue
		}
		for x in exts {if strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), x) {if !copy_into(h, e.fullpath, d) {return false}; break}}
	}
	return true
}
// src's folders made again under dst, without files (robocopy /e /xf *)
@(private = "file")
mirror_dirs :: proc(src, dst: string) {
	_ = os.make_directory_all(dst)
	list, err := os.read_all_directory_by_path(src, context.temp_allocator)
	if err != nil {return}
	for e in list {if e.type == .Directory {mirror_dirs(e.fullpath, pjoin({dst, e.name}, context.temp_allocator))}}
}
// a folder's files deleted, its folders kept (del /q /s)
@(private = "file")
clear_files :: proc(dir: string) {
	list, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return}
	for e in list {if e.type == .Directory {clear_files(e.fullpath)} else {_ = os.remove(e.fullpath)}}
}
@(private = "file")
subdirs :: proc(dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if list, err := os.read_all_directory_by_path(dir, context.temp_allocator); err == nil {
		for e in list {if e.type == .Directory {append(&out, e.name)}}
	}
	slice.sort_by(out[:], proc(a, b: string) -> bool {return strings.to_lower(a, context.temp_allocator) < strings.to_lower(b, context.temp_allocator)})
	return out[:]
}

// a tool's result as the installer reads it: FFXIII_ModelsHD 0 = done; either tool 1..1000 = that many textures
@(private = "file")
hd_success :: proc(models: bool, code: int) -> bool {return (models && code == 0) || (code > 0 && code <= 1000)}

hd_import_task :: proc(t: ^Task, zip_path: string) {
	h := Hd {
		t = t,
		r = settings.voice_jp ? "c" : "u",
	}
	game := settings.game_dir
	if game == "" || !dir_exists(pjoin({game, "white_data"}, context.temp_allocator)) {
		log_line(t, "Choose the FINAL FANTASY XIII folder first (Home).")
		t.failed = true
		return
	}
	if hd_discarded() {
		log_line(t, "The game's original archives were discarded (Discard Old Assets): an import needs them. Have Steam restore them (Properties > Installed Files > Verify integrity of game files), then Import again.")
		t.failed = true
		return
	}
	gsys := pjoin({game, "white_data", "sys"}, context.temp_allocator)
	gzone := pjoin({game, "white_data", "zone"}, context.temp_allocator)
	r := h.r

	// ---- the ZIP: is it the mod?
	set_status(t, 0, "Checking the ZIP")
	f, ferr := os.open(zip_path)
	if ferr != nil {logf(t, "Cannot open %s.", zip_path); t.failed = true; return}
	defer os.close(f)
	entries, zok := zip_entries(f, context.temp_allocator)
	if !zok {logf(t, "%s is not a ZIP file (or it is damaged).", filepath.base(zip_path)); t.failed = true; return}
	have := make(map[string]bool, context.temp_allocator)
	ntex := 0
	for e in entries {
		have[strings.to_lower(e.name, context.temp_allocator)] = true
		if strings.has_prefix(strings.to_lower(e.name, context.temp_allocator), "textures/") && !strings.has_suffix(e.name, "/") {ntex += 1}
	}
	for n in HD_NEEDS {
		if !have[strings.to_lower(n, context.temp_allocator)] || ntex == 0 {
			logf(t, "%s is not the FF XIII HD Project's ZIP (it has no %s). Get it with Get, from %s.", filepath.base(zip_path), ntex == 0 ? "textures/" : n, HD_URL)
			t.failed = true
			return
		}
	}
	for x in ([]string{"filelist", "white_img", "filelist_scr", "white_scr"}) {
		if !file_exists(pjoin({gsys, fmt.tprintf("%s%s.win32.bin", x, r)}, context.temp_allocator)) {
			logf(t, "The game has no white_data/sys/%s%s.win32.bin (%s voices).", x, r, r == "c" ? "Japanese" : "English")
			t.failed = true
			return
		}
	}

	// ---- Wine (Linux, macOS)
	when ODIN_OS != .Windows {
		h.wine = dep_get(.Wine).path
		if h.wine == "" {log_line(t, "The mod's tools are Windows programs: install Wine (Home tab: Check) and Import again."); t.failed = true; return}
		if !file_exists(pjoin({wine_prefix(), "system.reg"}, context.temp_allocator)) {
			set_status(t, -1, "Setting up Wine (the first time: about a minute)")
			_ = os.make_directory_all(wine_prefix())
			if code, started := run(t, wine_cmd(h.wine, {"wineboot", "--init"}), mode = .Quiet); !started || code != 0 {
				logf(t, "Wine could not set up its folder (%s).", wine_prefix())
				t.failed = true
				return
			}
		}
	}

	// ---- where: beside white_data (else the launcher's data folder), and the mod's working folder beside that
	parent, final := hd_place()
	h.work = pjoin({parent, parent == game ? "white_data_hd_work" : "hd_work"}, context.temp_allocator)
	h.out = pjoin({h.work, "out"}, context.temp_allocator)
	_ = os.remove_all(h.work)
	if os.make_directory_all(h.out) != nil {logf(t, "Cannot make %s.", h.out); t.failed = true; return}
	keep_work := false
	defer if !keep_work {_ = os.remove_all(h.work)}
	logp := data_path("hd_import.log")
	if lf, err := os.open(logp, {.Write, .Create, .Trunc}); err == nil {h.log = lf}
	defer if h.log != nil {os.close(h.log)}
	logf(t, "Importing %s (%d textures) for %s voices into %s", filepath.base(zip_path), ntex, r == "c" ? "Japanese" : "English", final)
	log_line(t, "This takes a while and needs about 25 GB free while it runs (about 8 GB stay). The game's own files are not changed.")
	hlog(&h, "FF XIII HD Project import: %s -> %s (region %s)", zip_path, final, r)

	// ---- 1. the ZIP's textures, data and tools
	{
		n := 0
		for e in entries {
			l := strings.to_lower(e.name, context.temp_allocator)
			if strings.has_suffix(l, "/") {continue}
			if !(strings.has_prefix(l, "textures/") || strings.has_prefix(l, "data/") || strings.has_prefix(l, "supportfiles/")) {continue}
			if cancelled(t) {return}
			n += 1
			if n % 25 == 0 {set_status(t, 0.15 * f32(n) / f32(ntex + 60), "Unpacking the ZIP: %d of about %d files", n, ntex + 60)}
			if !zip_extract(f, e, pjoin({h.work, e.name}, context.temp_allocator)) {logf(t, "Cannot unpack %s from the ZIP (is there room?).", e.name); t.failed = true; return}
		}
		// (the PCs' list: the mod's "install all" uses LoadHDPCs.tx1)
		pcs := pjoin({h.work, "Data", "LoadHDPCs.txt"}, context.temp_allocator)
		_ = os.copy_file(pcs, pjoin({h.work, "Data", "LoadHDPCs.tx1"}, context.temp_allocator))
	}
	// (the tools run at all? -- Wine's 32-bit support)
	{
		out := strings.builder_make(context.temp_allocator)
		cmd := make([dynamic]string, context.temp_allocator)
		prog := pjoin({h.work, "SupportFiles", "ff13tool.exe"}, context.temp_allocator)
		when ODIN_OS == .Windows {append(&cmd, prog)} else {append(&cmd, ..wine_cmd(h.wine, {prog}))}
		_, started := run(t, cmd[:], dir = h.work, mode = .Quiet, capture = &out)
		if !started || !strings.contains(strings.to_string(out), "FF13 extract/repack tool") {
			log_line(t, "The mod's ff13tool.exe does not run here.")
			when ODIN_OS != .Windows {log_line(t, "Wine needs its 32-bit support for it (see the Home tab's Wine line).")}
			t.failed = true
			return
		}
	}
	orig := pjoin({h.work, "models", "orig"}, context.temp_allocator)
	mod := pjoin({h.work, "models", "mod"}, context.temp_allocator)
	ozone := pjoin({orig, fmt.tprintf("zone%s", r)}, context.temp_allocator)

	// ---- 2. Setup: the zones' archives unpacked (white_img's zone filelists, then each zone's blocks)
	set_status(t, 0.15, "Copying the game's archives")
	if !copy_into(&h, pjoin({gsys, fmt.tprintf("filelist%s.win32.bin", r)}, context.temp_allocator), pjoin({h.work, fmt.tprintf("filelist%s.win32.bin", r)}, context.temp_allocator)) {t.failed = true; return}
	if !copy_into(&h, pjoin({gsys, fmt.tprintf("white_img%s.win32.bin", r)}, context.temp_allocator), pjoin({h.work, fmt.tprintf("white_img%s.win32.bin", r)}, context.temp_allocator)) {t.failed = true; return}
	set_status(t, 0.2, "Unpacking white_img%s", r)
	hd_tool(&h, "ff13tool.exe", {"-x", "-ff13", fmt.tprintf("filelist%s.win32.bin", r), fmt.tprintf("white_img%s.win32.bin", r)})
	if h.failed || cancelled(t) {t.failed = true; return}
	for z, i in HD_ZONES {
		if cancelled(t) {return}
		set_status(t, 0.22 + 0.13 * f32(i) / f32(len(HD_ZONES)), "Unpacking zone %s", z.zone)
		fl := fmt.tprintf("filelist_%s%s.win32.bin", z.zone, r)
		img := fmt.tprintf("white_%s%s_img.win32.bin", z.zone, r)
		src_fl := pjoin({h.work, fmt.tprintf("white_img%s", r), "zone", fl}, context.temp_allocator)
		src_img := pjoin({gzone, img}, context.temp_allocator)
		if !file_exists(src_fl) || !file_exists(src_img) {hlog(&h, "zone %s: no %s / %s", z.zone, src_fl, src_img); continue}
		if !copy_into(&h, src_fl, pjoin({ozone, fl}, context.temp_allocator)) || !copy_into(&h, src_img, pjoin({ozone, img}, context.temp_allocator)) {t.failed = true; return}
		hd_tool(&h, "ff13tool.exe", {"-x", "-ff13", fmt.tprintf("models\\orig\\zone%s\\%s", r, fl), fmt.tprintf("models\\orig\\zone%s\\%s", r, img)})
		unpacked := pjoin({ozone, fmt.tprintf("white_%s%s_img", z.zone, r)}, context.temp_allocator)
		_ = os.make_directory_all(pjoin({ozone, z.zone}, context.temp_allocator))
		if dir_exists(pjoin({unpacked, "bg"}, context.temp_allocator)) {_ = os.rename(pjoin({unpacked, "bg"}, context.temp_allocator), pjoin({ozone, z.zone, "bg"}, context.temp_allocator))}
		_ = os.remove_all(unpacked)
	}
	_ = os.remove_all(pjoin({h.work, fmt.tprintf("white_img%s", r)}, context.temp_allocator))
	_ = os.remove(pjoin({h.work, fmt.tprintf("white_img%s.win32.bin", r)}, context.temp_allocator))
	_ = os.remove(pjoin({h.work, fmt.tprintf("filelist%s.win32.bin", r)}, context.temp_allocator))

	// ---- the models' archive unpacked (white_scr: kept unpacked, the changed models copied into it, packed again at the end)
	set_status(t, 0.36, "Unpacking white_scr%s", r)
	if !copy_into(&h, pjoin({gsys, fmt.tprintf("filelist_scr%s.win32.bin", r)}, context.temp_allocator), pjoin({h.work, fmt.tprintf("filelist_scr%s.win32.bin", r)}, context.temp_allocator)) {t.failed = true; return}
	if !copy_into(&h, pjoin({gsys, fmt.tprintf("white_scr%s.win32.bin", r)}, context.temp_allocator), pjoin({h.work, fmt.tprintf("white_scr%s.win32.bin", r)}, context.temp_allocator)) {t.failed = true; return}
	hd_tool(&h, "ff13tool.exe", {"-x", "-ff13", fmt.tprintf("filelist_scr%s.win32.bin", r), fmt.tprintf("white_scr%s.win32.bin", r)})
	if h.failed || cancelled(t) {t.failed = true; return}
	_ = os.remove(pjoin({h.work, fmt.tprintf("white_scr%s.win32.bin", r)}, context.temp_allocator))
	scr := pjoin({h.work, fmt.tprintf("white_scr%s", r)}, context.temp_allocator)
	if !dir_exists(pjoin({scr, "chr"}, context.temp_allocator)) {log_line(t, "ff13tool did not unpack white_scr (see the import log)."); logf(t, "Log: %s", logp); t.failed = true; return}
	// (the PCs only from the original files: another mod's models are left as they are, as the mod does)
	pcs_ok := true
	for s in HD_PC_SIZES {
		b := pjoin({scr, "chr", "pc", fmt.tprintf("c%d", s[0]), "bin", fmt.tprintf("c%d.win32", s[0])}, context.temp_allocator)
		fi1, e1 := os.stat(strings.concatenate({b, ".trb"}, context.temp_allocator), context.temp_allocator)
		fi2, e2 := os.stat(strings.concatenate({b, ".imgb"}, context.temp_allocator), context.temp_allocator)
		if e1 != nil || e2 != nil || fi1.size != i64(s[1]) || fi2.size != i64(s[2]) {pcs_ok = false}
	}
	if !pcs_ok {
		log_line(t, "The main characters' models are not the original ones (another mod's?): they are left as they are.")
		_ = os.copy_file(pjoin({h.work, "Data", "LoadHDPCs.txt"}, context.temp_allocator), pjoin({h.work, "Data", "LoadHDPCs.tx3"}, context.temp_allocator))
	}
	for cat in ([]string{"pc", "npc", "weapon", "summon", "mon", "fa"}) {
		if cat == "pc" && !pcs_ok {continue}
		if !copy_tree(&h, pjoin({scr, "chr", cat}, context.temp_allocator), pjoin({orig, "chr", cat}, context.temp_allocator), {".trb", ".imgb"}) {t.failed = true; return}
	}
	mirror_dirs(orig, mod)

	// the archives the zones go into: white_img's (its zone filelists) -- copies, in the new folder
	osys := pjoin({h.out, "sys"}, context.temp_allocator)
	if !copy_into(&h, pjoin({gsys, fmt.tprintf("filelist%s.win32.bin", r)}, context.temp_allocator), pjoin({osys, fmt.tprintf("filelist%s.win32.bin", r)}, context.temp_allocator)) {t.failed = true; return}
	if !copy_into(&h, pjoin({gsys, fmt.tprintf("white_img%s.win32.bin", r)}, context.temp_allocator), pjoin({osys, fmt.tprintf("white_img%s.win32.bin", r)}, context.temp_allocator)) {t.failed = true; return}
	ofl := hw(pjoin({osys, fmt.tprintf("filelist%s.win32.bin", r)}, context.temp_allocator))
	oimg := hw(pjoin({osys, fmt.tprintf("white_img%s.win32.bin", r)}, context.temp_allocator))

	// ---- 3. Install all: every Data/LoadHD*.txt, in the folder's order
	lists := make([dynamic]string, context.temp_allocator)
	if dl, err := os.read_all_directory_by_path(pjoin({h.work, "Data"}, context.temp_allocator), context.temp_allocator); err == nil {
		for e in dl {
			l := strings.to_lower(e.name, context.temp_allocator)
			if strings.has_prefix(l, "loadhd") && strings.has_suffix(l, ".txt") {append(&lists, e.name)}
		}
	}
	slice.sort_by(lists[:], proc(a, b: string) -> bool {return strings.to_lower(a, context.temp_allocator) < strings.to_lower(b, context.temp_allocator)})
	Line :: struct {
		code, name: string,
	}
	lines := make([dynamic]Line, context.temp_allocator)
	for name in lists {
		data, err := os.read_entire_file(pjoin({h.work, "Data", name}, context.temp_allocator), context.temp_allocator)
		if err != nil {continue}
		text := string(data)
		for raw in strings.split_lines_iterator(&text) {
			l := strings.trim_space(raw)
			if l == "" || strings.has_prefix(l, ";") || strings.has_prefix(l, "#:") {continue}
			fields := strings.fields(l, context.temp_allocator)
			append(&lines, Line{strings.to_upper(fields[0], context.temp_allocator), len(fields) > 1 ? fields[1] : ""})
		}
	}
	zones_done, models_done := 0, 0
	for ln, i in lines {
		if cancelled(t) {return}
		set_status(t, 0.4 + 0.5 * f32(i) / f32(max(1, len(lines))), "Putting in the HD textures: %d of %d (%s %s)", i + 1, len(lines), ln.code, ln.name)
		zi := -1
		for z, k in HD_ZONES {if z.code == ln.code {zi = k}}
		if zi >= 0 {
			// GENERATEZONE: each block of the zone's location; changed ones into the zone's archive; the zone's filelist into white_img
			z := HD_ZONES[zi]
			fl := fmt.tprintf("filelist_%s%s.win32.bin", z.zone, r)
			img := fmt.tprintf("white_%s%s_img.win32.bin", z.zone, r)
			if !file_exists(pjoin({ozone, fl}, context.temp_allocator)) || !file_exists(pjoin({ozone, img}, context.temp_allocator)) {continue}
			mzone := pjoin({mod, "zone"}, context.temp_allocator)
			if !copy_into(&h, pjoin({ozone, fl}, context.temp_allocator), pjoin({mzone, fl}, context.temp_allocator)) || !copy_into(&h, pjoin({ozone, img}, context.temp_allocator), pjoin({mzone, img}, context.temp_allocator)) {t.failed = true; return}
			updated := false
			for m in subdirs(pjoin({ozone, z.zone, "bg", z.loc}, context.temp_allocator)) {
				if cancelled(t) {return}
				num := m[max(0, len(m) - 3):]
				base := fmt.tprintf("zone%s\\%s\\bg\\%s\\%s", r, z.zone, z.loc, m)
				clear_files(pjoin({mod, fmt.tprintf("zone%s", r), z.zone, "bg", z.loc, m, "bin"}, context.temp_allocator))
				txt := fmt.tprintf("%sblock%s%s.txt", z.zone, num, r)
				code: int
				models := file_exists(pjoin({h.work, "Data", txt}, context.temp_allocator))
				if models {
					code, _ = hd_tool(&h, "FFXIII_ModelsHD.exe", {fmt.tprintf("data\\%s", txt)})
				} else {
					code, _ = hd_tool(&h, "FFXIII_HDProject.exe", {fmt.tprintf("block%s.win32", num), fmt.tprintf("models\\orig\\%s\\bin\\", base), fmt.tprintf("models\\mod\\%s\\bin\\", base), fmt.tprintf("zone%s\\%s\\", r, z.zone), "/s"})
				}
				if h.failed {t.failed = true; return}
				if !hd_success(models, code) {continue}
				zdir := pjoin({mod, fmt.tprintf("zone%s", r), z.zone}, context.temp_allocator)
				entry := fmt.tprintf("bg\\%s\\%s\\bin\\block%s.win32", z.loc, m, num)
				zfl := fmt.tprintf("..\\..\\zone\\%s", fl)
				zimg := fmt.tprintf("..\\..\\zone\\%s", img)
				if !hd_inject(&h, zfl, zimg, fmt.tprintf("%s.trb", entry), zdir) || !hd_inject(&h, zfl, zimg, fmt.tprintf("%s.imgb", entry), zdir) {t.failed = true; return}
				updated = true
			}
			if updated {
				if !move_into(&h, pjoin({mzone, img}, context.temp_allocator), pjoin({h.out, "zone", img}, context.temp_allocator)) {t.failed = true; return}
				if !hd_inject(&h, ofl, oimg, fmt.tprintf("zone\\%s", fl), mod) {t.failed = true; return}
				zones_done += 1
			}
			_ = os.remove(pjoin({mzone, img}, context.temp_allocator))
			_ = os.remove(pjoin({mzone, fl}, context.temp_allocator))
			clear_files(pjoin({mod, fmt.tprintf("zone%s", r), z.zone}, context.temp_allocator))
			continue
		}
		cat, single := hd_single(ln.code)
		if !single || ln.name == "" {continue}
		if cat == "pc" && !pcs_ok {continue}
		// GENERATESINGLE (copied into the unpacked white_scr: packed again at the end)
		code: int
		models := file_exists(pjoin({h.work, "Data", fmt.tprintf("%s.txt", ln.name)}, context.temp_allocator))
		if models {
			code, _ = hd_tool(&h, "FFXIII_ModelsHD.exe", {fmt.tprintf("Data\\%s.txt", ln.name)})
		} else {
			code, _ = hd_tool(&h, "FFXIII_HDProject.exe", {fmt.tprintf("%s.win32", ln.name), fmt.tprintf("models\\orig\\chr\\%s\\%s\\bin\\", cat, ln.name), fmt.tprintf("models\\mod\\chr\\%s\\%s\\bin\\", cat, ln.name), fmt.tprintf("%s\\", cat)})
		}
		if h.failed {t.failed = true; return}
		if !hd_success(models, code) {continue}
		for x in ([]string{".trb", ".imgb"}) {
			src := pjoin({mod, "chr", cat, ln.name, "bin", fmt.tprintf("%s.win32%s", ln.name, x)}, context.temp_allocator)
			if file_exists(src) {if !copy_into(&h, src, pjoin({scr, "chr", cat, ln.name, "bin", fmt.tprintf("%s.win32%s", ln.name, x)}, context.temp_allocator)) {t.failed = true; return}}
		}
		models_done += 1
	}
	if zones_done == 0 { 	// (nothing went into white_img: the copies are not needed)
		_ = os.remove(pjoin({osys, fmt.tprintf("filelist%s.win32.bin", r)}, context.temp_allocator))
		_ = os.remove(pjoin({osys, fmt.tprintf("white_img%s.win32.bin", r)}, context.temp_allocator))
	}

	// ---- 4. REPACK: white_scr packed again from its folder, with the changed models
	if models_done > 0 {
		set_status(t, 0.92, "Packing white_scr%s again", r)
		hd_tool(&h, "ff13tool.exe", {"-c", fmt.tprintf("filelist_scr%s.win32.bin", r), fmt.tprintf("white_scr%s", r)})
		nscr := pjoin({h.work, fmt.tprintf("white_scr%s.win32.bin", r)}, context.temp_allocator)
		if h.failed || !file_exists(nscr) {log_line(t, "ff13tool could not pack white_scr again (see the import log)."); logf(t, "Log: %s", logp); t.failed = true; return}
		if !move_into(&h, nscr, pjoin({osys, fmt.tprintf("white_scr%s.win32.bin", r)}, context.temp_allocator)) {t.failed = true; return}
		if !move_into(&h, pjoin({h.work, fmt.tprintf("filelist_scr%s.win32.bin", r)}, context.temp_allocator), pjoin({osys, fmt.tprintf("filelist_scr%s.win32.bin", r)}, context.temp_allocator)) {t.failed = true; return}
	}
	if zones_done == 0 && models_done == 0 {
		log_line(t, "No texture could be put in (see the import log): nothing was changed.")
		logf(t, "Log: %s", logp)
		t.failed = true
		return
	}

	// ---- done: the new folder in place of an earlier import's, the switch On
	set_status(t, 0.97, "Finishing")
	marker := fmt.tprintf("# FF XIII HD Project, imported by WhiteRecomp's launcher (Features & Mods > HD Textures)\nzip=%s\nzip_path=%s\nregion=%s\nzones=%d\nmodels=%d\n", filepath.base(zip_path), zip_path, r, zones_done, models_done)
	if os.write_entire_file(pjoin({h.out, HD_MARKER}, context.temp_allocator), transmute([]u8)marker) != nil {logf(t, "Cannot write %s.", h.out); t.failed = true; return}
	if old := hd_dir(); old != "" {
		// (the GUI mod's hd_textures/, if installed: carried into the new folder)
		if dir_exists(pjoin({old, "hd_textures"}, context.temp_allocator)) {
			if os.rename(pjoin({old, "hd_textures"}, context.temp_allocator), pjoin({h.out, "hd_textures"}, context.temp_allocator)) == nil {
				_ = os.rename(pjoin({old, HD_GUI_MARKER}, context.temp_allocator), pjoin({h.out, HD_GUI_MARKER}, context.temp_allocator))
			} else {
				log_line(t, "Could not keep the HD Fonts and GUI textures: import that mod's archive again.")
			}
		}
		_ = os.remove_all(old)
	}
	_ = os.remove_all(final)
	if os.rename(h.out, final) != nil {
		logf(t, "Cannot move the new archives to %s.", final)
		t.failed = true
		return
	}
	settings.hd_on = true
	save_settings()
	gdir := game_out_dir()
	if file_exists(pjoin({gdir, GAME_NAME + ".cfg"}, context.temp_allocator)) {_ = write_cfg(gdir)}
	logf(t, "HD Textures imported: %d zones and %d models, in %s. HD Textures is On.", zones_done, models_done, final)
	set_status(t, 1, "Imported")
}

// ---------------------------------------------------------------------------------------------- Discard Old Assets
// After a finished import (its ZIP checked, every step done: the marker is written last): the mod's ZIP and the game's
// own archives that the HD folder has copies of (white_data/sys/... and zone/... of the same names) deleted. The game
// then reads those only from the HD folder, so HD Textures stays On; Steam's Verify integrity of game files brings
// the originals back (and an Import needs them).
HD_DISCARDED :: "discarded.txt" // (in the HD folder: what was deleted)

hd_discarded :: proc() -> bool {
	d := hd_dir()
	return d != "" && file_exists(pjoin({d, HD_DISCARDED}, context.temp_allocator))
}

// the mod's ZIP, if it is still where it was imported from
hd_zip_file :: proc() -> string {
	p := hd_info("zip_path")
	if p == "" && hd_info("zip") != "" { 	// (an import before zip_path was recorded: the usual download folder)
		p = pjoin({zip_start_dir(), hd_info("zip")}, context.temp_allocator)
	}
	return p != "" && file_exists(p) ? p : ""
}

Hd_Old :: struct {
	path: string,
	size: i64,
}
// the game's files the HD folder replaces (and their sizes)
hd_old_assets :: proc(allocator := context.temp_allocator) -> (list: [dynamic]Hd_Old, total: i64) {
	list = make([dynamic]Hd_Old, allocator)
	d := hd_dir()
	if d == "" || settings.game_dir == "" {return}
	for sub in ([]string{"sys", "zone"}) {
		entries, err := os.read_all_directory_by_path(pjoin({d, sub}, context.temp_allocator), context.temp_allocator)
		if err != nil {continue}
		for e in entries {
			if e.type == .Directory {continue}
			g := pjoin({settings.game_dir, "white_data", sub, e.name}, allocator)
			if fi, serr := os.stat(g, context.temp_allocator); serr == nil {
				append(&list, Hd_Old{g, fi.size})
				total += fi.size
			}
		}
	}
	return
}

confirm_hd_discard: bool

hd_discard_task :: proc(t: ^Task) {
	d := hd_dir()
	if d == "" || hd_discarded() {log_line(t, "There is no finished HD Textures import."); t.failed = true; return}
	list, total := hd_old_assets()
	zip := hd_zip_file()
	rec := strings.builder_make(context.temp_allocator)
	strings.write_string(&rec, "# deleted by Discard Old Assets (Steam's Verify integrity of game files restores the game's)\n")
	freed: i64 = 0
	n := 0
	// (recorded first: from here on the game has only the HD copies, even if a delete fails halfway)
	if os.write_entire_file(pjoin({d, HD_DISCARDED}, context.temp_allocator), transmute([]u8)strings.to_string(rec)) != nil {logf(t, "Cannot write in %s.", d); t.failed = true; return}
	for o, i in list {
		set_status(t, f32(i) / f32(max(1, len(list))), "Deleting %s", filepath.base(o.path))
		if err := os.remove(o.path); err != nil {
			logf(t, "Could not delete %s: %v", o.path, err)
			t.failed = true
			continue
		}
		fmt.sbprintf(&rec, "%s\n", o.path)
		freed += o.size
		n += 1
	}
	if zip != "" {
		if fi, err := os.stat(zip, context.temp_allocator); err == nil {
			if os.remove(zip) == nil {fmt.sbprintf(&rec, "%s\n", zip); freed += fi.size} else {logf(t, "Could not delete %s.", zip); t.failed = true}
		}
	}
	_ = os.write_entire_file(pjoin({d, HD_DISCARDED}, context.temp_allocator), transmute([]u8)strings.to_string(rec))
	settings.hd_on = true
	save_settings()
	gdir := game_out_dir()
	if file_exists(pjoin({gdir, GAME_NAME + ".cfg"}, context.temp_allocator)) {_ = write_cfg(gdir)}
	_ = total
	logf(t, "Discarded %d of the game's original archives%s: %.1f GB freed. HD Textures stays On; Steam's Verify integrity of game files brings the originals back.", n, zip != "" ? " and the mod's ZIP" : "", f64(freed) / 1e9)
	set_status(t, 1, "%.1f GB freed", f64(freed) / 1e9)
}

draw_hd_discard_confirm :: proc(g: ^Gui) {
	g.in_modal = true
	defer g.in_modal = false
	box := dialog_box(g, px(g, 560), px(g, 290))
	in_ := ui.inset_xy(box, px(g, 24), px(g, 22))
	ren.draw_text(g.dl, g.big, tr("Discard the old assets?"), {in_.x, in_.y}, TEXT)
	y := in_.y + g.big.line_height + px(g, 12)
	list, total := hd_old_assets()
	zip := hd_zip_file()
	zsize: i64 = 0
	if zip != "" {if fi, err := os.stat(zip, context.temp_allocator); err == nil {zsize = fi.size}}
	text := fmt.tprintf("%d of the game's original archives that the HD Project's copies replace are deleted%s, freeing %.1f GB. The game then uses the HD textures only (HD Textures stays On), and the original game cannot start without them. To get them back, verify the game's files in Steam (Properties > Installed Files > Verify integrity of game files).", len(list), zip != "" ? fmt.tprintf(", and the mod's ZIP (%s)", filepath.base(zip)) : "", f64(total + zsize) / 1e9)
	paragraph(g, g.font, text, {in_.x, y, in_.w, 0}, TEXT, px(g, 2))
	btns := dialog_buttons(g, box)
	yes, no := ui.columns(btns, 0, 2, px(g, 8)), ui.columns(btns, 1, 2, px(g, 8))
	if button(g, yes, "Discard", sync.atomic_load(&task.running) == false, primary = true) {
		confirm_hd_discard = false
		task_start("Discard Old Assets", hd_discard_task)
	}
	if button(g, no, "Keep them") {confirm_hd_discard = false}
}

// ---------------------------------------------------------------------------------------------- HD Fonts and GUI
// The import picked (a .zip or a .rar): which mod it is, by its contents -- an hd_textures/hash_database.txt is the
// HD Fonts and GUI mod's (a RAR5 archive, or a ZIP of the same folder), else the HD Project's ZIP
hd_import_any :: proc(t: ^Task, path: string) {
	f, ferr := os.open(path)
	if ferr != nil {logf(t, "Cannot open %s.", path); t.failed = true; return}
	sig: [8]u8
	n, _ := os.read_at(f, sig[:], 0)
	if n == 8 && sig == rar5.SIGNATURE {
		defer os.close(f)
		entries, ok := rar5.list(f, context.temp_allocator)
		if !ok {logf(t, "%s is a RAR archive this launcher cannot read (encrypted, multi-part, or damaged).", filepath.base(path)); t.failed = true; return}
		files := make([dynamic]Gui_File, context.temp_allocator)
		for e in entries {if !e.dir {append(&files, Gui_File{name = e.name, size = e.usize, rar = e})}}
		hd_gui_import(t, path, f, files[:], true)
		return
	}
	if n >= 4 && sig[0] == 'R' && sig[1] == 'a' && sig[2] == 'r' && sig[3] == '!' {
		os.close(f)
		logf(t, "%s is an old RAR (RAR 4) archive: unpack it with 7-Zip or WinRAR and make a ZIP of it, or get the mod again.", filepath.base(path))
		t.failed = true
		return
	}
	if entries, ok := zip_entries(f, context.temp_allocator); ok {
		for e in entries {
			if strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), "hd_textures/hash_database.txt") {
				defer os.close(f)
				files := make([dynamic]Gui_File, context.temp_allocator)
				for z in entries {if !strings.has_suffix(z.name, "/") {append(&files, Gui_File{name = z.name, size = z.usize, zip = z})}}
				hd_gui_import(t, path, f, files[:], false)
				return
			}
		}
	}
	os.close(f)
	hd_import_task(t, path) // (the HD Project's ZIP, or not a mod at all: it says which)
}

@(private = "file")
Gui_File :: struct {
	name: string,
	size: u64,
	rar:  rar5.Entry,
	zip:  Zip_Entry,
}

// the GUI mod's hd_textures/ unpacked into the HD folder (made beside white_data if there is none yet); the mod's
// version.dll and README are not needed (the runtime does what the DLL does)
@(private = "file")
hd_gui_import :: proc(t: ^Task, path: string, f: ^os.File, files: []Gui_File, is_rar: bool) {
	if settings.game_dir == "" || !dir_exists(pjoin({settings.game_dir, "white_data"}, context.temp_allocator)) {
		log_line(t, "Choose the FINAL FANTASY XIII folder first (Home).")
		t.failed = true
		return
	}
	set_status(t, 0, "Checking %s", filepath.base(path))
	// (the hd_textures/ folder: at the top, or inside one folder of the archive)
	prefix := ""
	for e in files {
		l := strings.to_lower(e.name, context.temp_allocator)
		if strings.has_suffix(l, "hd_textures/hash_database.txt") {prefix = e.name[:len(e.name) - len("hash_database.txt")]; break}
	}
	if prefix == "" {
		logf(t, "%s is not the HD Fonts and GUI mod (it has no hd_textures/hash_database.txt). Get it with Get, from %s.", filepath.base(path), HD_GUI_URL)
		t.failed = true
		return
	}
	todo := make([dynamic]Gui_File, context.temp_allocator)
	total: u64 = 0
	for e in files {if strings.has_prefix(e.name, prefix) {append(&todo, e); total += e.size}}
	dest := hd_dir()
	if dest == "" {_, dest = hd_place()}
	tmp := pjoin({dest, "hd_textures.new"}, context.temp_allocator)
	_ = os.remove_all(tmp)
	if os.make_directory_all(tmp) != nil {logf(t, "Cannot make %s.", tmp); t.failed = true; return}
	ok := false
	defer if !ok {_ = os.remove_all(tmp)}
	logf(t, "Importing %s (%d files, %.1f GB) into %s", filepath.base(path), len(todo), f64(total) / 1e9, pjoin({dest, "hd_textures"}, context.temp_allocator))
	done: u64 = 0
	for e, i in todo {
		if cancelled(t) {return}
		rel := e.name[len(prefix):]
		if rel == "" || strings.contains(rel, "..") {continue}
		out := pjoin({tmp, rel}, context.temp_allocator)
		if i % 10 == 0 {set_status(t, f32(f64(done) / f64(max(total, 1))), "Unpacking: %d of %d files", i, len(todo))}
		if is_rar {
			data, xok := rar5.extract(f, e.rar)
			if !xok {logf(t, "Cannot unpack %s (%s).", e.name, rar5.last_error); t.failed = true; return}
			_ = os.make_directory_all(filepath.dir(out))
			werr := os.write_entire_file(out, data)
			delete(data)
			if werr != nil {logf(t, "Cannot write %s (is there room?).", out); t.failed = true; return}
		} else if !zip_extract(f, e.zip, out) {
			logf(t, "Cannot unpack %s from the ZIP (is there room?).", e.name)
			t.failed = true
			return
		}
		done += e.size
	}
	// (in place of an earlier import's)
	final := pjoin({dest, "hd_textures"}, context.temp_allocator)
	_ = os.remove_all(final)
	if os.rename(tmp, final) != nil {logf(t, "Cannot move the textures to %s.", final); t.failed = true; return}
	ok = true
	marker := fmt.tprintf("# HD Fonts and GUI (%s), imported by WhiteRecomp's launcher (Features & Mods > HD Textures)\narchive=%s\narchive_path=%s\nfiles=%d\n", HD_GUI_URL, filepath.base(path), path, len(todo))
	if os.write_entire_file(pjoin({dest, HD_GUI_MARKER}, context.temp_allocator), transmute([]u8)marker) != nil {logf(t, "Cannot write in %s.", dest); t.failed = true; return}
	settings.hd_on = true
	save_settings()
	gdir := game_out_dir()
	if file_exists(pjoin({gdir, GAME_NAME + ".cfg"}, context.temp_allocator)) {_ = write_cfg(gdir)}
	logf(t, "HD Fonts and GUI imported: %d files in %s. HD Textures is On.", len(todo), final)
	set_status(t, 1, "Imported")
}
