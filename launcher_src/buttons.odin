// Features & Mods > Better Button Icons: the "Console Button Prompts" mod (www.nexusmods.com/finalfantasy13/mods/60),
// imported from its ZIP. The mod is two copies of the game's system.win32.imgb (mod/prog/misc/system.win32.ps3 and
// .360), installed by its .bat with ff13tool; they differ from the game's only in "button_set01", the 256 x 128
// A8R8G8B8 texture of the controller prompts. Here only that texture is cut from each (at BB_OFFSET) and written as a
// .dds (button_ps.dds, button_xb.dds) in the launcher's data folder; the game's files are not changed. The game is
// given the folder (XRC_BUTTON_ICONS in the .cfg) and picks by the controllers plugged in (hle_d3d9.c bbi_*): none --
// the keyboard's keys, a PlayStation one -- Cross Square Circle Triangle, any other -- the Xbox 360 buttons.
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

BB_URL :: "https://www.nexusmods.com/finalfantasy13/mods/60?tab=files&file_id=1250"
BB_DIR :: "button_icons"
BB_IMGB_SIZE :: 9247264 // (system.win32.imgb, every edition; the mod's copies are the same size)
BB_OFFSET :: 0x4cbc20 // (button_set01's level 0 in it)
BB_W :: 256
BB_H :: 128
BB_BYTES :: BB_W * BB_H * 4

bb_dir :: proc() -> string {return data_path(BB_DIR)}
bb_ready :: proc() -> bool {
	d := bb_dir()
	return file_exists(pjoin({d, "button_ps.dds"}, context.temp_allocator)) && file_exists(pjoin({d, "button_xb.dds"}, context.temp_allocator))
}
bb_open_page :: proc() {open_url(BB_URL)}

// the .cfg's line: the switch On and the icons there (this computer's folder: not for a cross-compiled build)
bb_cfg_line :: proc(b: ^strings.Builder) {
	if settings.button_icons && bb_ready() {fmt.sbprintf(b, "XRC_BUTTON_ICONS=%s\n", bb_dir())}
}

// the ZIP is the button mod's: it has both of its imgb copies
bb_is_mod :: proc(entries: []Zip_Entry) -> bool {
	ps, xb := false, false
	for e in entries {
		l := strings.to_lower(e.name, context.temp_allocator)
		if strings.has_suffix(l, "system.win32.ps3") {ps = true}
		if strings.has_suffix(l, "system.win32.360") {xb = true}
	}
	return ps && xb
}

// a .dds of the texture (A8R8G8B8, one level: as hdt_load_file reads it)
@(private = "file")
bb_dds :: proc(pixels: []u8) -> []u8 {
	out := make([]u8, 128 + len(pixels), context.temp_allocator)
	put :: proc(b: []u8, o: int, v: u32) {b[o] = u8(v); b[o + 1] = u8(v >> 8); b[o + 2] = u8(v >> 16); b[o + 3] = u8(v >> 24)}
	put(out, 0, 0x20534444) // "DDS "
	put(out, 4, 124)
	put(out, 8, 0x1 | 0x2 | 0x4 | 0x8 | 0x1000) // CAPS HEIGHT WIDTH PITCH PIXELFORMAT
	put(out, 12, BB_H)
	put(out, 16, BB_W)
	put(out, 20, BB_W * 4)
	put(out, 76, 32) // the pixel format's size
	put(out, 80, 0x40 | 0x1) // DDPF_RGB | DDPF_ALPHAPIXELS
	put(out, 88, 32)
	put(out, 92, 0x00ff0000)
	put(out, 96, 0x0000ff00)
	put(out, 100, 0x000000ff)
	put(out, 104, 0xff000000)
	put(out, 108, 0x1000) // DDSCAPS_TEXTURE
	copy(out[128:], pixels)
	return out
}

bb_import :: proc(t: ^Task, path: string, f: ^os.File, entries: []Zip_Entry) {
	set_status(t, 0, "Checking %s", filepath.base(path))
	dest := bb_dir()
	tmp := pjoin({dest, "unpack"}, context.temp_allocator)
	_ = os.remove_all(tmp)
	if os.make_directory_all(tmp) != nil {logf(t, "Cannot make %s.", tmp); t.failed = true; return}
	defer os.remove_all(tmp)
	for kind in ([2]string{"ps3", "360"}) {
		ent: Zip_Entry
		found := false
		for e in entries {if strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), fmt.tprintf("system.win32.%s", kind)) {ent = e; found = true; break}}
		if !found {continue}
		if ent.usize != BB_IMGB_SIZE {
			logf(t, "%s's system.win32.%s is %d bytes, not %d: not the version this launcher knows (v2.0). Get it with Get.", filepath.base(path), kind, ent.usize, BB_IMGB_SIZE)
			t.failed = true
			return
		}
		out := pjoin({tmp, kind}, context.temp_allocator)
		if !zip_extract(f, ent, out) {logf(t, "Cannot unpack %s from the ZIP.", ent.name); t.failed = true; return}
		data, err := os.read_entire_file(out, context.temp_allocator)
		if err != nil || len(data) != BB_IMGB_SIZE {logf(t, "Cannot read %s.", out); t.failed = true; return}
		px := data[BB_OFFSET:BB_OFFSET + BB_BYTES]
		// (the prompts: mostly see-through, but not all -- a slice of something else would not be)
		clear_px, solid_px := 0, 0
		for i := 3; i < len(px); i += 4 {if px[i] == 0 {clear_px += 1} else if px[i] == 0xff {solid_px += 1}}
		if clear_px < BB_W * BB_H / 4 || solid_px < 500 {logf(t, "system.win32.%s does not hold button icons where the launcher expects them.", kind); t.failed = true; return}
		name := kind == "ps3" ? "button_ps.dds" : "button_xb.dds"
		if os.write_entire_file(pjoin({dest, name}, context.temp_allocator), bb_dds(px)) != nil {logf(t, "Cannot write in %s.", dest); t.failed = true; return}
		logf(t, "%s: the %s icons", name, kind == "ps3" ? "PlayStation" : "Xbox 360")
	}
	settings.button_icons = true
	save_settings()
	gdir := game_out_dir()
	if file_exists(pjoin({gdir, GAME_NAME + ".cfg"}, context.temp_allocator)) {_ = write_cfg(gdir)}
	logf(t, "Better Button Icons imported into %s. It is On: with no controller the game shows the keyboard's keys, with a PlayStation controller its buttons, with any other the Xbox 360 ones.", dest)
	set_status(t, 1, "Imported")
}
