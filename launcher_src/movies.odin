// Convert Movies: every Bink 2 movie of the install (white_data/movie/*.wmp) to MP4s next to it, once, with the
// bundled converter (tools/bink2mp4: the game's own bink2w32.dll decodes, FFmpeg encodes; see its source). The game
// then plays the MP4s (src/runtime/hle_bink.c). A .wmp holds one Bink stream or several, one after the other
// (z016_us: 8 cutscenes); the game seeks to the one it plays. Each stream gets its own MP4: the first <name>.mp4,
// the one at byte offset N <name>_N.mp4. A movie whose streams all have their MP4 is skipped, so it can be cancelled
// and run again. The converter is a 32-bit Windows program around the game's Windows DLL: on Linux and macOS it runs
// through Wine (wine.odin).
//
// Discard Old Movies: frees the space of the .wmp files (about 40 GB) once all their MP4s exist. Each .wmp is cut
// down to its first 4 KB instead of deleted: the game still opens the .wmp to find a movie. Its streams' headers
// (frame counts and rates, which the game's player reads) are kept first in <name>.wmp.heads, a line a stream:
// "offset frames width height rate rate_div" (src/runtime/host_movie_convert.c reads it). A movie without all its
// MP4s is left whole.
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

WMP_KEEP :: 4096 // bytes of a discarded .wmp that stay (its header)

Wmp_Stream :: struct {
	off:                     i64,
	frames, w, h, num, den: u32,
	mp4:                     string,
}

Movie_File :: struct {
	wmp, mp4:  string, // mp4: the first stream's
	size:      i64,
	streams:   [dynamic]Wmp_Stream,
	missing:   int, // streams without their MP4
	has_mp4:   bool, // every stream has its MP4
	discarded: bool, // already cut down
	heads:     bool, // discarded with its streams' headers kept (.heads): by this launcher, not an older one
	stub:      bool, // a 16-byte placeholder of the install (no movie)
}

// the MP4 of the stream at off (src/runtime/host_movie_convert.c host_movie_stream_mp4: the same names)
stream_mp4 :: proc(wmp: string, off: i64, allocator := context.temp_allocator) -> string {
	base := wmp[:len(wmp) - 4]
	return off == 16 ? strings.concatenate({base, ".mp4"}, allocator) : fmt.aprintf("%s_%d.mp4", base, off, allocator = allocator)
}

@(private = "file")
le32 :: proc(b: []u8) -> u32 {return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24}

// the streams of a .wmp: from the file (the first at 16, each next one at the previous one's offset + its size + 8),
// else (cut down) from its .heads
wmp_streams :: proc(wmp: string, allocator := context.temp_allocator) -> (out: [dynamic]Wmp_Stream, from_heads: bool) {
	out = make([dynamic]Wmp_Stream, allocator)
	if f, err := os.open(wmp); err == nil {
		defer os.close(f)
		b: [0x30]u8
		if n, _ := os.read_at(f, b[:16], 0); n == 16 && string(b[:3]) == "WMP" {
			off: i64 = 16
			for len(out) < 256 {
				n, _ = os.read_at(f, b[:], off)
				if n != len(b) || string(b[:3]) != "KB2" {break}
				s := Wmp_Stream{off = off, frames = le32(b[8:]), w = le32(b[20:]), h = le32(b[24:]), num = le32(b[28:]), den = le32(b[32:])}
				append(&out, s)
				l := le32(b[4:])
				if l == 0 {break}
				off += i64(l) + 8
			}
		}
	}
	if data, err := os.read_entire_file(strings.concatenate({wmp, ".heads"}, context.temp_allocator), context.temp_allocator); err == nil {
		kept := make([dynamic]Wmp_Stream, allocator)
		for line in strings.split_lines(string(data), context.temp_allocator) {
			p := strings.fields(line, context.temp_allocator)
			if len(p) != 6 {continue}
			s: Wmp_Stream
			ok: bool
			o, _ := strconv.parse_i64(p[0]); s.off = o
			v: [5]u64
			for k in 0 ..< 5 {v[k], ok = strconv.parse_u64(p[k + 1]); if !ok {break}}
			if !ok {continue}
			s.frames, s.w, s.h, s.num, s.den = u32(v[0]), u32(v[1]), u32(v[2]), u32(v[3]), u32(v[4])
			append(&kept, s)
		}
		if len(kept) > len(out) {return kept, true}
	}
	return
}

list_movies :: proc(game: string, allocator := context.temp_allocator) -> [dynamic]Movie_File {
	out := make([dynamic]Movie_File, allocator)
	dir := movie_dir(game)
	list, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return out}
	for e in list {
		if !strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), ".wmp") {continue}
		m := Movie_File{wmp = strings.clone(e.fullpath, allocator), size = e.size}
		if fi, serr := os.stat(e.fullpath, context.temp_allocator); serr == nil {m.size = fi.size} // (a link: the file's size)
		m.mp4 = stream_mp4(m.wmp, 16, allocator)
		m.stub = m.size <= 16
		m.discarded = !m.stub && m.size <= WMP_KEEP
		if !m.stub {m.streams, m.heads = wmp_streams(m.wmp, allocator)}
		for &s in m.streams {
			s.mp4 = stream_mp4(m.wmp, s.off, allocator)
			if !file_exists(s.mp4) {m.missing += 1}
		}
		m.has_mp4 = len(m.streams) > 0 && m.missing == 0
		append(&out, m)
	}
	return out
}

// ---------------------------------------------------------------------------------------------- Convert Movies
@(private = "file")
Convert_State :: struct {
	total, done: int,
	current:     string,
}
@(private = "file")
conv: Convert_State

convert_task :: proc(t: ^Task) {
	game := settings.game_dir
	ff := dep_get(.FFmpeg)
	if ok, why := convert_possible(); !ok {
		log_line(t, why)
		t.failed = true
		return
	}
	todo, old := 0, 0
	for m in list_movies(game) {
		if !m.stub && !m.discarded {todo += m.missing}
		if m.discarded && !m.heads {old += 1}
	}
	if old > 0 {
		logf(t, "%d movies were discarded by an older launcher, which converted only the first of the cutscenes a movie file can hold: the others are gone from them. To get them back, have Steam verify the game's files (Properties > Installed Files > Verify integrity), then Convert Movies again.", old)
	}
	if todo == 0 {
		log_line(t, "Every movie already has its MP4s.")
		set_status(t, 1, "Nothing to convert")
		return
	}
	if bundle_extract(t, data_dir, {"tools/"}) < 0 {t.failed = true; return}
	tool := data_path("tools", "bink2mp4.exe")
	dll := pjoin({game, "white_data", "prog", "win", "bin", "bink2w32.dll"}, context.temp_allocator)
	dir := movie_dir(game)
	// as many encoder threads as the CPU has threads, less one (options.odin convert_threads)
	threads := fmt.tprintf("%d", convert_threads())
	args := []string{"--dll", win_path(dll), "--ffmpeg", win_path(ff.path), "--threads", threads, "all", win_path(dir), win_path(dir)}
	cmd: []string
	wine := ""
	when ODIN_OS == .Windows {
		cmd = slice.concatenate([][]string{{tool}, args}, context.temp_allocator)
	} else {
		// (Linux, macOS: through Wine, wine.odin)
		wine = dep_get(.Wine).path
		if !wine_ready(t, wine, tool) {t.failed = true; return}
		cmd = wine_cmd(wine, slice.concatenate([][]string{{tool}, args}, context.temp_allocator))
		logf(t, "Converting through %s", wine)
	}
	conv = {total = todo}
	logf(t, "Converting %d cutscenes (all of them: about 7 hours of video, English and Japanese; it can be cancelled and continued later)", todo)
	set_status(t, 0, "Converting: 0 of %d", todo)
	logf(t, "Converting with %s threads", threads)
	code, started := run(t, cmd, on_line = proc(t: ^Task, line: string) {
		// "<in>: 1280x736 (out 1280x720), 5160 frames at 29.970 fps, 4 audio tracks -> <out>" starts one,
		// "  frame N / M (x fps)" is its progress, "  done in N s" ends it
		l := strings.trim_space(line)
		if strings.contains(l, " frames at ") && strings.contains(l, " -> ") {
			conv.current = any_base(l[:strings.index(l, ": ")])
			set_status(t, f32(conv.done) / f32(max(conv.total, 1)), "Converting %s: cutscene %d of %d", conv.current, conv.done + 1, conv.total)
			return
		}
		if strings.has_prefix(l, "done in") {conv.done += 1}
		if strings.has_prefix(l, "frame ") {
			parts := strings.fields(l, context.temp_allocator)
			if len(parts) >= 4 {
				f, _ := strconv.parse_f64(parts[1])
				n, _ := strconv.parse_f64(parts[3])
				if n > 0 {
					p := (f32(conv.done) + f32(f / n)) / f32(conv.total)
					set_status(t, p, "Converting %s: cutscene %d of %d, frame %d of %d", conv.current, conv.done + 1, conv.total, int(f), int(n))
				}
			}
		}
	})
	if wine != "" {wine_stop(t, wine, dir, cancelled(t))} // (a cancel leaves the converter's FFmpeg running under Wine)
	if cancelled(t) {return}
	if !started || code != 0 {
		log_line(t, "The converter failed.")
		t.failed = true
		return
	}
	set_status(t, 1, "Converted %d cutscenes", conv.done)
}

// ---------------------------------------------------------------------------------------------- Discard Old Movies
// What Discard would do (for its confirmation): movies it would cut down, the bytes it frees, movies it would keep.
discard_plan :: proc(game: string) -> (n: int, bytes: i64, kept: int) {
	for m in list_movies(game) {
		if m.stub || m.discarded {continue}
		if m.has_mp4 {
			n += 1
			bytes += m.size - WMP_KEEP
		} else {
			kept += 1
		}
	}
	return
}

discard_task :: proc(t: ^Task) {
	game := settings.game_dir
	freed: i64 = 0
	cut, kept := 0, 0
	list := list_movies(game)
	for m, i in list {
		if cancelled(t) {break}
		if m.stub || m.discarded {continue}
		if !m.has_mp4 {
			logf(t, "Kept %s: %d of its %d cutscenes have no MP4 yet", filepath.base(m.wmp), m.missing, len(m.streams))
			kept += 1
			continue
		}
		set_status(t, f32(i) / f32(len(list)), "Discarding %s", filepath.base(m.wmp))
		// the streams' headers first (the game's player needs their frame counts and rates): without them, not cut down
		{
			sb := strings.builder_make(context.temp_allocator)
			for s in m.streams {fmt.sbprintf(&sb, "%d %d %d %d %d %d\n", s.off, s.frames, s.w, s.h, s.num, s.den)}
			if os.write_entire_file(strings.concatenate({m.wmp, ".heads"}, context.temp_allocator), transmute([]u8)strings.to_string(sb)) != nil {
				logf(t, "Could not write %s.heads: %s kept", filepath.base(m.wmp), filepath.base(m.wmp))
				t.failed = true
				continue
			}
		}
		f, err := os.open(m.wmp, {.Read, .Write})
		if err == nil {
			err = os.truncate(f, WMP_KEEP)
			os.close(f)
		}
		if err != nil {
			logf(t, "Could not cut down %s: %v", filepath.base(m.wmp), err)
			t.failed = true
			continue
		}
		freed += m.size - WMP_KEEP
		cut += 1
	}
	logf(t, "Discarded %d old movies: %.1f GB freed%s", cut, f64(freed) / 1e9, kept > 0 ? fmt.tprintf(" (%d kept: convert them first)", kept) : "")
	set_status(t, 1, "%.1f GB freed", f64(freed) / 1e9)
}

